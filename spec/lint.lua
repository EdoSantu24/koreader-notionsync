#!/usr/bin/env luajit
--
-- Local luacheck driver that does not need luafilesystem.
--
-- Run from the repository root:
--     luajit spec/lint.lua
--
-- Why this exists: the `luacheck` command-line tool needs luafilesystem to walk
-- directories, and luafilesystem is a C module -- so on a Windows dev machine
-- without a compiler you cannot install it. luacheck's actual linter is pure
-- Lua, though, so this reads the files itself and calls the library directly.
--
-- Install the pure-Lua part once with:
--     luarocks --lua-version 5.1 --lua-dir <luajit-dir> install --deps-mode=none luacheck
--
-- CI runs the real `luacheck` binary on Linux, where lfs builds fine. This is a
-- convenience for local pre-push checks, and it reads the same .luacheckrc, so
-- the two cannot drift.
--

local ok, luacheck = pcall(require, "luacheck")
if not ok then
    io.stderr:write([[
luacheck library not found.

Install it (pure-Lua parts only, no C compiler needed):
  luarocks --lua-version 5.1 --lua-dir <luajit-dir> install --deps-mode=none luacheck

And point LUA_PATH at it, e.g.:
  export LUA_PATH="$HOME/.luarocks/share/lua/5.1/?.lua;$HOME/.luarocks/share/lua/5.1/?/init.lua;;"

Note: on Windows use a native path (C:/Users/you/...), not an MSYS /c/... path.
]])
    os.exit(2)
end

local format = require("luacheck.format")

--------------------------------------------------------------------------------
-- Files to lint. Explicit, because globbing needs lfs.
--------------------------------------------------------------------------------

local FILES = {
    "notionsync.koplugin/_meta.lua",
    "notionsync.koplugin/api.lua",
    "notionsync.koplugin/converter.lua",
    "notionsync.koplugin/epub.lua",
    "notionsync.koplugin/imagemanager.lua",
    "notionsync.koplugin/main.lua",
    "notionsync.koplugin/storage.lua",
    "spec/run.lua",
    "spec/lint.lua",
    "spec/helper.lua",
    "spec/syntax_spec.lua",
    "spec/converter_spec.lua",
    "spec/storage_spec.lua",
    "spec/epub_spec.lua",
}

--------------------------------------------------------------------------------
-- Read options out of .luacheckrc so this driver and CI stay in agreement.
--------------------------------------------------------------------------------

local function load_luacheckrc(path)
    local chunk = loadfile(path)
    if not chunk then return {} end
    local env = {}
    -- .luacheckrc is a plain Lua file assigning globals; run it in a bare
    -- environment and harvest what it set.
    if setfenv then
        setfenv(chunk, env)
    end
    local run_ok, err = pcall(chunk)
    if not run_ok then
        io.stderr:write("warning: could not evaluate .luacheckrc: " .. tostring(err) .. "\n")
        return {}
    end
    return env
end

local rc = load_luacheckrc(".luacheckrc")

local base_opts = {
    std = rc.std or "luajit",
    read_globals = rc.read_globals,
    globals = rc.globals,
    ignore = rc.ignore,
    max_line_length = rc.max_line_length,
    self = rc.self,
    unused_args = rc.unused_args,
}

-- Per-file overrides from the `files` table in .luacheckrc, matched by prefix.
local function opts_for(filename)
    if type(rc.files) ~= "table" then return base_opts end
    local merged = nil
    for pattern, overrides in pairs(rc.files) do
        if filename:sub(1, #pattern) == pattern then
            merged = merged or {}
            for k, v in pairs(base_opts) do merged[k] = v end
            for k, v in pairs(overrides) do
                -- read_globals in an override should add to, not replace, the base.
                if k == "read_globals" and base_opts.read_globals then
                    local combined = {}
                    for _, g in ipairs(base_opts.read_globals) do combined[#combined + 1] = g end
                    for _, g in ipairs(v) do combined[#combined + 1] = g end
                    merged[k] = combined
                else
                    merged[k] = v
                end
            end
        end
    end
    return merged or base_opts
end

--------------------------------------------------------------------------------
-- Lint
--------------------------------------------------------------------------------

local excluded = {}
for _, p in ipairs(rc.exclude_files or {}) do excluded[p] = true end

local total, checked = 0, 0

for _, path in ipairs(FILES) do
    if not excluded[path] then
        local f = io.open(path, "r")
        if not f then
            io.stderr:write("missing file: " .. path .. "\n")
            total = total + 1
        else
            local src = f:read("*a")
            f:close()
            checked = checked + 1

            local report = luacheck.check_strings({ src }, opts_for(path))
            local issues = report[1] or {}

            if issues.error then
                print(string.format("%s:%d:%d: %s error: %s",
                    path, issues.line or 0, issues.column or 0,
                    issues.error, tostring(issues.msg)))
                total = total + 1
            else
                for _, issue in ipairs(issues) do
                    print(string.format("%s:%d:%d: (%s) %s",
                        path, issue.line or 0, issue.column or 0,
                        issue.code, format.get_message(issue)))
                    total = total + 1
                end
            end
        end
    end
end

print("")
print(string.format("%d file(s) checked, %d issue(s)", checked, total))
os.exit(total == 0 and 0 or 1)
