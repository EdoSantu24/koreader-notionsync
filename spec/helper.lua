--
-- KOReader module stubs, so plugin modules can be loaded off-device.
--
-- These are installed into package.preload, which means a plugin module's
-- `require("logger")` resolves to the stub without the plugin knowing.
--
-- Keep this file small. It stays small only as long as the plugin's pure logic
-- (block rendering, escaping, filename sanitisation) depends on `logger` and
-- nothing else. Treat a growing stub list as a signal that testable logic is
-- getting entangled with the UI or the network, not as a reason to grow the file.
--

local M = {}

local PLUGIN_DIR = "notionsync.koplugin/"

--------------------------------------------------------------------------------
-- logger: records calls so tests can assert that a warning was emitted
--------------------------------------------------------------------------------

local logger = { records = {} }

local function record(level)
    return function(...)
        local parts = {}
        for i = 1, select("#", ...) do
            parts[#parts + 1] = tostring((select(i, ...)))
        end
        logger.records[#logger.records + 1] = {
            level = level,
            message = table.concat(parts, " "),
        }
    end
end

logger.dbg = record("dbg")
logger.info = record("info")
logger.warn = record("warn")
logger.err = record("err")

function logger.reset()
    logger.records = {}
end

-- Returns true if any logged message at `level` contains `needle`.
function logger.logged(level, needle)
    for _, r in ipairs(logger.records) do
        if r.level == level and r.message:find(needle, 1, true) then
            return true
        end
    end
    return false
end

M.logger = logger

--------------------------------------------------------------------------------
-- util: the handful of helpers the plugin actually uses
--------------------------------------------------------------------------------

local util = {}

function util.pathExists(path)
    local f = io.open(path, "r")
    if f then f:close() return true end
    return false
end

function util.makePath(path)
    M.made_paths[#M.made_paths + 1] = path
    return true
end

function util.urlEncode(s)
    return (tostring(s):gsub("[^%w%-%._~]", function(c)
        return string.format("%%%02X", string.byte(c))
    end))
end

-- Byte length of the UTF-8 character starting at `s:sub(i, i)`.
function util.getUtf8CharSize(s, i)
    local b = s:byte(i)
    if not b then return 0 end
    if b < 0x80 then return 1 end
    if b >= 0xF0 then return 4 end
    if b >= 0xE0 then return 3 end
    if b >= 0xC0 then return 2 end
    return 1 -- continuation byte; caller is mid-sequence
end

M.util = util
M.made_paths = {}

--------------------------------------------------------------------------------
-- lfs: no real luafilesystem available locally, so this is a programmable fake.
-- Tests set M.fake_fs = { ["/some/path"] = "directory", ... } as needed.
--------------------------------------------------------------------------------

M.fake_fs = {}

local lfs = {}

function lfs.attributes(path, what)
    local mode = M.fake_fs[path]
    if not mode then
        -- Fall back to a real existence check so tests can point at real files.
        local f = io.open(path, "r")
        if f then f:close() mode = "file" end
    end
    if not mode then return nil end
    if what == "mode" then return mode end
    if what == "size" then return M.fake_sizes and M.fake_sizes[path] or 0 end
    return { mode = mode }
end

function lfs.mkdir(path)
    M.fake_fs[path] = "directory"
    return true
end

function lfs.dir(path)
    local entries, i = { ".", ".." }, 0
    for p, mode in pairs(M.fake_fs) do
        if mode == "file" then
            local rest = p:match("^" .. path:gsub("%p", "%%%0") .. "/([^/]+)$")
            if rest then entries[#entries + 1] = rest end
        end
    end
    return function()
        i = i + 1
        return entries[i]
    end
end

M.lfs = lfs

--------------------------------------------------------------------------------
-- ffi/util: joinPath and the T() template function
--------------------------------------------------------------------------------

local ffiutil = {}

function ffiutil.joinPath(a, b)
    if a:sub(-1) == "/" then return a .. b end
    return a .. "/" .. b
end

-- KOReader's T(): substitutes %1, %2, ... positionally.
function ffiutil.template(str, ...)
    local args = { ... }
    return (str:gsub("%%(%d+)", function(n)
        return tostring(args[tonumber(n)])
    end))
end

M.ffiutil = ffiutil

--------------------------------------------------------------------------------
-- ffi/archiver: a recording fake Writer, so EPUB assembly is assertable
--------------------------------------------------------------------------------

local Archiver = { Writer = {} }

-- Reset before each test that inspects archives.
M.archives = {}

function Archiver.Writer:new()
    local o = {
        entries = {},      -- ordered { path, content, compression, mtime }
        compression = nil,
        opened = nil,
        closed = false,
        err = nil,
    }
    setmetatable(o, self)
    self.__index = self
    M.archives[#M.archives + 1] = o
    return o
end

function Archiver.Writer:open(path, format)
    self.opened = path
    self.format = format
    return true
end

function Archiver.Writer:setZipCompression(method)
    self.compression = method
    return true
end

function Archiver.Writer:addFileFromMemory(entry_path, content, mtime)
    self.entries[#self.entries + 1] = {
        path = entry_path,
        content = content,
        compression = self.compression,
        mtime = mtime,
        from = "memory",
    }
    return true
end

function Archiver.Writer:addPath(entry_root, root, recursive, mtime)
    self.entries[#self.entries + 1] = {
        path = entry_root,
        disk_path = root,
        recursive = recursive,
        compression = self.compression,
        mtime = mtime,
        from = "path",
    }
    return true
end

function Archiver.Writer:close()
    self.closed = true
    return true
end

M.Archiver = Archiver

--------------------------------------------------------------------------------
-- Install stubs
--------------------------------------------------------------------------------

package.preload["logger"] = function() return logger end
package.preload["util"] = function() return util end
package.preload["libs/libkoreader-lfs"] = function() return lfs end
package.preload["ffi/util"] = function() return ffiutil end
package.preload["ffi/archiver"] = function() return Archiver end
package.preload["gettext"] = function()
    return function(s) return s end
end

--------------------------------------------------------------------------------
-- Loading plugin modules under test
--------------------------------------------------------------------------------

-- Loads a plugin module by name, e.g. load_plugin("converter").
--
-- Uses loadfile with the real on-disk path so that a module's internal
-- `debug.getinfo(1).source:match "@?(.*/)"` still resolves to the plugin
-- directory, which is how the plugin loads its own sibling modules via dofile.
function M.load_plugin(name)
    local path = PLUGIN_DIR .. name .. ".lua"
    local chunk, err = loadfile(path)
    if not chunk then
        error("could not load " .. path .. ": " .. tostring(err))
    end
    return chunk()
end

M.PLUGIN_DIR = PLUGIN_DIR

-- Every non-vendored plugin module, for the syntax check.
M.PLUGIN_MODULES = {
    "_meta", "api", "converter", "epub", "imagemanager", "main", "storage",
}

_G.helper = M
return M
