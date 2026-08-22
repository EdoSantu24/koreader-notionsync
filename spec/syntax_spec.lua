--
-- Every plugin file must compile under LuaJIT (Lua 5.1 semantics).
--
-- This is cheap but genuinely load-bearing: the device runtime is LuaJIT, and a
-- Lua 5.2+/5.3+ construct (`goto` aside, LuaJIT has that) such as integer
-- division `//` or a bitwise operator is a *parse* error there. Since the plugin
-- cannot be run off-device, a file that fails to compile would otherwise only be
-- discovered as a silent "plugin does not appear in the menu" on the Kindle.
--
-- Note this only compiles; it does not execute. That is deliberate -- executing
-- main.lua would require the whole KOReader widget stack.
--

local h = require("spec.helper")

describe("syntax", function()
    for _, name in ipairs(h.PLUGIN_MODULES) do
        it(name, function()
            local path = h.PLUGIN_DIR .. name .. ".lua"
            local chunk, err = loadfile(path)
            assert_true(chunk, "failed to compile " .. path .. ": " .. tostring(err))
        end)
    end

    -- Vendored, excluded from luacheck, but it still has to compile.
    it("markdown_vendored", function()
        local chunk, err = loadfile(h.PLUGIN_DIR .. "markdown.lua")
        assert_true(chunk, "failed to compile markdown.lua: " .. tostring(err))
    end)
end)

describe("runtime", function()
    -- Guards against writing code against a stdlib the device does not have.
    -- rawget rather than a bare `utf8` so this test does not itself trip the
    -- undefined-global check it exists to justify.
    it("has_no_utf8_library", function()
        assert_eq(type(rawget(_G, "utf8")), "nil",
            "LuaJIT has no utf8 library; string handling must be byte-oriented")
    end)

    it("has_lua51_unpack", function()
        assert_eq(type(unpack), "function", "Lua 5.1 global unpack should exist")
    end)
end)
