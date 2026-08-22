#!/usr/bin/env luajit
--
-- Dependency-free test runner.
--
-- Run from the repository root:
--     luajit spec/run.lua          (or: lua spec/run.lua)
--
-- Why not busted? This plugin cannot be executed off-device at all, so the test
-- suite is the only pre-push signal a developer has. busted needs luarocks, and
-- luarocks needs a C toolchain to build luafilesystem, which is not a reasonable
-- prerequisite on a Windows dev machine. A ~100-line runner that needs nothing
-- but a LuaJIT binary is worth more than a standard framework nobody can install.
--
-- Exits non-zero if any test fails, so CI can gate on it.

package.path = "./?.lua;./?/init.lua;" .. package.path

local passed, failed, failures = 0, 0, {}
local current_group = ""

-- Every spec file lives here. Listed explicitly rather than globbed, because
-- directory listing needs lfs, which is exactly the dependency we are avoiding.
local SPEC_FILES = {
    "spec/syntax_spec.lua",
    "spec/converter_spec.lua",
    "spec/xhtml_spec.lua",
    "spec/storage_spec.lua",
    "spec/epub_spec.lua",
}

--------------------------------------------------------------------------------
-- Assertion helpers, exposed as globals to spec files
--------------------------------------------------------------------------------

local function fmt(v)
    if type(v) == "string" then return string.format("%q", v) end
    return tostring(v)
end

function assert_eq(actual, expected, msg)
    if actual ~= expected then
        error(string.format("%sexpected %s, got %s",
            msg and (msg .. ": ") or "", fmt(expected), fmt(actual)), 2)
    end
end

function assert_true(value, msg)
    if not value then
        error((msg or "expected truthy") .. ", got " .. fmt(value), 2)
    end
end

function assert_false(value, msg)
    if value then
        error((msg or "expected falsy") .. ", got " .. fmt(value), 2)
    end
end

-- `pattern` is a Lua pattern. Use assert_contains for literal substrings.
function assert_match(subject, pattern, msg)
    if type(subject) ~= "string" or not subject:find(pattern) then
        error(string.format("%sexpected match for %s in %s",
            msg and (msg .. ": ") or "", fmt(pattern), fmt(subject)), 2)
    end
end

function assert_contains(subject, literal, msg)
    if type(subject) ~= "string" or not subject:find(literal, 1, true) then
        error(string.format("%sexpected to find %s in %s",
            msg and (msg .. ": ") or "", fmt(literal), fmt(subject)), 2)
    end
end

function assert_not_contains(subject, literal, msg)
    if type(subject) == "string" and subject:find(literal, 1, true) then
        error(string.format("%sexpected NOT to find %s in %s",
            msg and (msg .. ": ") or "", fmt(literal), fmt(subject)), 2)
    end
end

--------------------------------------------------------------------------------
-- describe / it
--------------------------------------------------------------------------------

function describe(name, fn)
    current_group = name
    fn()
    current_group = ""
end

function it(name, fn)
    local label = (current_group ~= "" and (current_group .. ".") or "") .. name
    local ok, err = pcall(fn)
    local dots = string.rep(".", math.max(2, 46 - #label))
    if ok then
        passed = passed + 1
        print(string.format("  %s %s ok", label, dots))
    else
        failed = failed + 1
        failures[#failures + 1] = { label = label, err = tostring(err) }
        print(string.format("  %s %s FAIL", label, dots))
    end
end

--------------------------------------------------------------------------------
-- Run
--------------------------------------------------------------------------------

require("spec.helper")

for _, path in ipairs(SPEC_FILES) do
    local chunk, err = loadfile(path)
    if not chunk then
        failed = failed + 1
        failures[#failures + 1] = { label = path, err = "could not load: " .. tostring(err) }
        print(string.format("  %s -- LOAD FAILED", path))
    else
        chunk()
    end
end

print("")
if failed > 0 then
    print("Failures:")
    for _, f in ipairs(failures) do
        print("  " .. f.label)
        print("    " .. f.err:gsub("\n", "\n    "))
    end
    print("")
end
print(string.format("%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
