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
-- Minimal XML well-formedness checker
--------------------------------------------------------------------------------
--
-- An EPUB 2 content document is parsed as XML, and crengine's response to
-- malformed XML is to silently render a truncated page -- which is exactly the
-- "content is randomly missing" symptom this project is trying to fix. So
-- generated documents get checked rather than eyeballed.
--
-- This is not a conforming XML parser. It checks the three things that actually
-- break these documents: unbalanced tags, raw `<` or `&` in text, and unquoted
-- attribute values. luaexpat would be stricter but needs a C toolchain.

local VOID_OK = { br = true, hr = true, img = true, link = true, meta = true }
local ENTITY = "^&(#?%w+);"

-- Returns true, or false plus a description of the first problem found.
function M.check_xml(doc)
    if type(doc) ~= "string" then return false, "not a string" end

    local stack = {}
    local pos = 1
    local len = #doc

    while pos <= len do
        local lt = doc:find("<", pos, true)

        -- Text run before the next tag: no raw ampersands allowed.
        local text_end = (lt or len + 1) - 1
        local i = pos
        while i <= text_end do
            local amp = doc:find("&", i, true)
            if not amp or amp > text_end then break end
            if not doc:sub(amp):match(ENTITY) then
                return false, string.format("raw '&' at byte %d: %q",
                    amp, doc:sub(amp, math.min(amp + 20, len)))
            end
            i = amp + 1
        end

        if not lt then break end

        -- Declarations, doctypes and comments are skipped wholesale.
        if doc:sub(lt, lt + 4) == "<?xml" then
            local close = doc:find("?>", lt, true)
            if not close then return false, "unterminated <?xml" end
            pos = close + 2
        elseif doc:sub(lt, lt + 3) == "<!--" then
            local close = doc:find("-->", lt, true)
            if not close then return false, "unterminated comment" end
            pos = close + 3
        elseif doc:sub(lt, lt + 1) == "<!" then
            local close = doc:find(">", lt, true)
            if not close then return false, "unterminated <! declaration" end
            pos = close + 1
        else
            local gt = doc:find(">", lt, true)
            if not gt then return false, "unterminated tag at byte " .. lt end
            local tag = doc:sub(lt + 1, gt - 1)

            if tag:sub(1, 1) == "/" then
                local name = tag:sub(2):match("^%s*([%w:_%-]+)")
                local top = stack[#stack]
                if not top then
                    return false, "closing </" .. tostring(name) .. "> with nothing open"
                end
                if top ~= name then
                    return false, string.format("</%s> closes <%s>",
                        tostring(name), tostring(top))
                end
                stack[#stack] = nil
            else
                local name = tag:match("^([%w:_%-]+)")
                if not name then
                    return false, "unparseable tag: <" .. tag:sub(1, 30) .. ">"
                end
                local self_closing = tag:sub(-1) == "/"

                -- Every attribute value must be quoted. Quoted values are consumed
                -- rather than scanned across, or a `=` inside one (such as the
                -- charset in content="text/html; charset=utf-8") reads as a
                -- second, unquoted attribute.
                local attrs = tag:sub(#name + 1)
                if self_closing then attrs = attrs:sub(1, -2) end
                local ai = 1
                while true do
                    local s, e, attr_name, first = attrs:find("([%w:_%-]+)%s*=%s*(.)", ai)
                    if not s then break end
                    if first ~= '"' and first ~= "'" then
                        return false, string.format("unquoted value for attribute %q in <%s>",
                            attr_name, name)
                    end
                    local close = attrs:find(first, e + 1, true)
                    if not close then
                        return false, string.format("unterminated value for attribute %q in <%s>",
                            attr_name, name)
                    end
                    ai = close + 1
                end

                if not self_closing then
                    if VOID_OK[name] then
                        return false, string.format("<%s> must be self-closed in XHTML", name)
                    end
                    stack[#stack + 1] = name
                end
            end
            pos = gt + 1
        end
    end

    if #stack > 0 then
        return false, "unclosed tag(s): " .. table.concat(stack, ", ")
    end
    return true
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
