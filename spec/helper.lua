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

-- Forward declaration: util.pathExists below is defined in terms of lfs, which is
-- built further down. Without this the name would resolve to a nil global.
local lfs

local util = {}

-- Mirrors frontend/util.lua: both of these are defined in terms of lfs, not
-- io.open. io.open on a directory succeeds on Linux and fails on Windows, so a
-- stub built on it would behave differently per platform.
function util.pathExists(path)
    return lfs.attributes(path, "mode") ~= nil
end

-- The real one is recursive and returns truthy on success, or nil plus a message.
-- Note `err` can be nil even on failure, so callers must not assume a message.
function util.makePath(path)
    M.made_paths[#M.made_paths + 1] = path
    M.fake_fs[path] = "directory"
    return true
end

function util.urlEncode(s)
    return (tostring(s):gsub("[^%w%-%._~]", function(c)
        return string.format("%%%02X", string.byte(c))
    end))
end

-- Mirrors frontend/util.lua exactly. A previous version of this stub exposed a
-- `getUtf8CharSize` helper that DOES NOT EXIST in KOReader -- a stub advertising
-- an API the real module lacks is worse than no stub, because code written
-- against it passes every test and then crashes on the device. Only stub things
-- that actually exist upstream.
util.UTF8_CHAR_PATTERN = '[%z\1-\127\194-\253][\128-\191]*'

function util.splitToChars(text)
    local tab = {}
    if text ~= nil then
        for uchar in text:gmatch(util.UTF8_CHAR_PATTERN) do
            tab[#tab + 1] = uchar
        end
    end
    return tab
end

M.util = util
M.made_paths = {}

-- Device.home_dir is /mnt/us on Kindle, /mnt/onboard on Kobo, and nil on generic
-- desktop builds. Defaults to the Kindle value because that is the target device;
-- tests set M.device.home_dir directly to exercise the other branches.
M.device = { home_dir = "/mnt/us" }

--------------------------------------------------------------------------------
-- lfs: no real luafilesystem available locally, so this is a programmable fake.
-- Tests set M.fake_fs = { ["/some/path"] = "directory", ... } as needed.
--------------------------------------------------------------------------------

M.fake_fs = {}

lfs = {}

function lfs.attributes(path, what)
    local mode = M.fake_fs[path]
    local real_size = nil

    if not mode then
        -- Fall back to a real existence check so tests can point at real files.
        local f = io.open(path, "rb")
        if f then
            real_size = f:seek("end")
            f:close()
            mode = "file"
        end
    end

    if not mode then return nil end
    if what == "mode" then return mode end
    if what == "size" then
        -- Prefer the real on-disk size: epub.lua's archive verification depends on
        -- it, and stubbing it to 0 would make that check untestable.
        if M.fake_sizes and M.fake_sizes[path] then return M.fake_sizes[path] end
        return real_size or 0
    end
    return { mode = mode, size = real_size or 0 }
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

-- Set to a method name ("open", "addFileFromMemory", "close", ...) to make that
-- call fail once, so error paths can be exercised.
M.archiver_fail_on = nil

-- Set false to make close() skip writing a verifiable file, simulating a
-- truncated archive.
M.archiver_write_valid = true

local function should_fail(name)
    if M.archiver_fail_on == name then
        M.archiver_fail_on = nil
        return true
    end
    return false
end

-- A byte sequence that satisfies epub.lua's verifyArchive: local file header
-- signature, `mimetype` as the first entry name at offset 30, an
-- end-of-central-directory signature, and enough length to clear the size floor.
-- Building a real-looking file means the verification logic is genuinely tested
-- rather than stubbed away.
local function verifiable_zip_bytes()
    return "PK\003\004"
        .. string.rep("\0", 26)
        .. "mimetype"
        .. "application/epub+zip"
        .. string.rep("\0", 220)
        .. "PK\005\006"
        .. string.rep("\0", 18)
end

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
    if should_fail("open") then
        self.err = "simulated open failure"
        return nil
    end
    self.opened = path
    self.format = format
    return true
end

function Archiver.Writer:setZipCompression(method)
    if should_fail("setZipCompression") then
        self.err = "simulated compression failure"
        return nil
    end
    self.compression = method
    return true
end

function Archiver.Writer:addFileFromMemory(entry_path, content, mtime)
    if should_fail("addFileFromMemory") then
        self.err = "simulated add failure"
        return nil
    end
    self.entries[#self.entries + 1] = {
        path = entry_path,
        content = content,
        compression = self.compression,
        mtime = mtime,
        from = "memory",
    }
    return true
end

-- Convenience for assertions: entry paths in write order.
function Archiver.Writer:entryPaths()
    local paths = {}
    for _, e in ipairs(self.entries) do paths[#paths + 1] = e.path end
    return paths
end

function Archiver.Writer:entry(path)
    for _, e in ipairs(self.entries) do
        if e.path == path then return e end
    end
    return nil
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

-- Returns NOTHING, exactly like the real koreader-base Writer:close(), which is
-- inconsistent with open()/setZipCompression()/addFileFromMemory() (all of which
-- return true).
--
-- This fake previously returned `true`, and that single discrepancy is why the
-- whole suite passed while EVERY real sync failed with "archive close failed:
-- nil". A test double that is more generous than reality hides exactly the bug it
-- should catch. Do not make this return a value.
function Archiver.Writer:close()
    self.closed = true
    -- Materialise a real file so that the caller's archive verification and the
    -- .part -> final rename both run against something that actually exists.
    if self.opened and M.archiver_write_valid then
        local f = io.open(self.opened, "wb")
        if f then
            f:write(verifiable_zip_bytes())
            f:close()
        end
    end
    -- No return value, matching the real API. See the comment above.
end

M.Archiver = Archiver

--------------------------------------------------------------------------------
-- Network modules
--------------------------------------------------------------------------------
--
-- Present so that api.lua and imagemanager.lua can be LOADED off-device; they do
-- not simulate HTTP. Tests that need request behaviour replace the method under
-- test (see api_spec's apiCall recorder) rather than driving these.
--
-- Without them, requiring api.lua throws at spec load time -- which previously
-- took the whole suite down with no summary, because the runner did not wrap
-- spec-file execution. Both halves of that are fixed.

local ltn12 = {
    sink = { table = function(t) return function(chunk)
        if chunk then t[#t + 1] = chunk end
        return 1
    end end },
    source = { string = function(s) return function() return s end end },
}

local socket = {
    -- Mirrors LuaSocket: drops the first n return values.
    skip = function(n, ...) return select(n + 1, ...) end,
    sleep = function(seconds) M.slept = (M.slept or 0) + (seconds or 0) end,
}

local https = { request = function() return nil, "no network in tests" end }
local http = { request = function() return nil, "no network in tests" end }

-- Values match frontend/socketutil.lua so that a test asserting on timeout
-- choice is meaningful.
local socketutil = {
    LARGE_BLOCK_TIMEOUT = 10,
    LARGE_TOTAL_TIMEOUT = 30,
    FILE_BLOCK_TIMEOUT = 15,
    FILE_TOTAL_TIMEOUT = 60,
    -- Called as socketutil:set_timeout(...), so the receiver arrives positionally.
    set_timeout = function(_, block, total)
        M.last_timeout = { block = block, total = total }
    end,
    reset_timeout = function() M.last_timeout = nil end,
    table_sink = function(t)
        return function(chunk)
            if chunk then t[#t + 1] = chunk end
            return 1
        end
    end,
}

local rapidjson = {
    encode = function() return "{}" end,
    decode = function() return {} end,
}

M.socket = socket
M.socketutil = socketutil

--------------------------------------------------------------------------------
-- KOReader UI, enough for main.lua to be LOADED
--------------------------------------------------------------------------------
--
-- These do not simulate the UI. They exist so main.lua's module-level requires
-- resolve, which makes its pure helpers (progress formatting, the sync report)
-- testable. main.lua is the largest surface in the plugin and the one where
-- device-only bugs keep surfacing, so being able to reach into it matters.
--
-- Widgets shown are recorded in M.shown for assertions.

M.shown = {}

local function widget_stub()
    return {
        new = function(_, opts)
            local w = opts or {}
            w.is_stub_widget = true
            -- Real widgets answer these, and code under test calls them right
            -- after constructing a dialog. Defaulted rather than assigned so a
            -- caller passing its own implementation still wins. A stub must not
            -- be *more* generous than reality, but it must not be less capable
            -- either, or a test cannot reach the code path at all.
            w.onShowKeyboard = w.onShowKeyboard or function() end
            w.onCloseKeyboard = w.onCloseKeyboard or function() end
            return w
        end,
    }
end

local UIManager = {
    show = function(_, widget) M.shown[#M.shown + 1] = widget end,
    close = function() end,
    forceRePaint = function() end,
    nextTick = function(_, fn) if fn then fn() end end,
    scheduleIn = function() end,
    unschedule = function() end,
    preventStandby = function() end,
    allowStandby = function() end,
}

-- Records progress text and can be told to report a cancellation.
local Trapper = {
    infos = {},
    cancel_after = nil, -- set to N to have the Nth info() return false
    wrap = function(_, fn) return fn() end,
    info = function(self, text, fast_refresh)
        self.infos[#self.infos + 1] = { text = text, fast = fast_refresh }
        if self.cancel_after and #self.infos >= self.cancel_after then
            return false
        end
        return true
    end,
    reset = function() return true end,
    clear = function() return true end,
}

function Trapper.resetRecorder()
    Trapper.infos = {}
    Trapper.cancel_after = nil
end

M.UIManager = UIManager
M.Trapper = Trapper

local WidgetContainer = {
    extend = function(self, tbl)
        tbl = tbl or {}
        return setmetatable(tbl, { __index = self })
    end,
}

local LuaSettings = {
    open = function()
        local store = {}
        return {
            readSetting = function(_, key) return store[key] end,
            saveSetting = function(_, key, value) store[key] = value end,
            flush = function() end,
            has = function(_, key) return store[key] ~= nil end,
        }
    end,
}

--------------------------------------------------------------------------------
-- Install stubs
--------------------------------------------------------------------------------

package.preload["logger"] = function() return logger end
package.preload["device"] = function() return M.device end
package.preload["ltn12"] = function() return ltn12 end
package.preload["socket"] = function() return socket end
package.preload["socket.http"] = function() return http end
package.preload["ssl.https"] = function() return https end
package.preload["socketutil"] = function() return socketutil end
package.preload["rapidjson"] = function() return rapidjson end
package.preload["ui/uimanager"] = function() return UIManager end
package.preload["ui/trapper"] = function() return Trapper end
package.preload["ui/widget/container/widgetcontainer"] = function() return WidgetContainer end
package.preload["luasettings"] = function() return LuaSettings end
package.preload["dispatcher"] = function()
    return { registerAction = function() end }
end
package.preload["datastorage"] = function()
    return {
        getSettingsDir = function() return "/tmp" end,
        getFullDataDir = function() return "/tmp/koreader" end,
    }
end
package.preload["ui/network/manager"] = function()
    return { runWhenOnline = function(_, fn) if fn then fn() end end }
end
for _, widget in ipairs({
    "ui/widget/infomessage", "ui/widget/inputdialog", "ui/widget/buttondialog",
    "ui/widget/confirmbox", "ui/widget/pathchooser",
}) do
    package.preload[widget] = function() return widget_stub() end
end
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

-- Loads a plugin module by name, e.g. load_plugin("xhtml").
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
    "_meta", "api", "blocktree", "epub", "imagemanager", "main", "storage", "xhtml",
}

_G.helper = M
return M
