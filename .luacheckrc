-- Luacheck configuration for NotionSync KOReader Plugin

-- KOReader runs on LuaJIT (Lua 5.1 semantics), so that is what we must lint against.
--
-- This was previously `std = "max"`, which is the permissive *union* of every Lua
-- standard library from 5.1 to 5.4. Under "max", a call to `utf8.char`, `math.type`
-- or `table.move` lints perfectly clean and then fails at runtime on the device --
-- which is the worst possible outcome for a codebase that cannot be executed
-- off-device. "luajit" is the whole point of this file.
--
-- (The old comment above that setting claimed it disabled the line-length check.
-- It never did; `max_line_length` is the setting for that, and it is set below.)
std = "luajit"
codes = true
cache = true
max_line_length = false

-- A method declared with `:` that does not use `self` is idiomatic here (these
-- modules are called as `Module:fn()` for consistency even when stateless), so
-- an unused `self` is noise rather than signal. KOReader's own .luacheckrc does
-- the same. Every OTHER unused argument is still reported -- see 212 below.
self = false

-- koreader-base patches LuaJIT to provide table.pack/table.unpack, and KOReader
-- exposes these two globals to plugins. Note that a *stock* LuaJIT (such as one
-- installed locally for running the test suite) does NOT have table.pack/unpack,
-- so plugin code should prefer the 5.1 `unpack` or avoid it altogether.
read_globals = {
    "table.pack",
    "table.unpack",
    "G_reader_settings",
    "G_defaults",
}

-- Deliberately NOT ignored, and why:
--
--   111/112/113 (undefined global read/write) -- this is the single highest-value
--     check available here. A typo'd `UIManger:show(...)` is a crash on the Kindle
--     and nothing else in this project can catch it.
--   212 (unused argument) -- not cosmetic. It is what points at
--     `ImageManager:downloadImage(url, page_id, image_index)` ignoring two of its
--     three arguments, which is the every-EPUB-contains-every-image bug.
--   211/213 (unused local / loop variable) -- cheap, and catches dead code.
--
-- Nothing is ignored at present. Add entries here only with a comment explaining
-- why the warning is wrong rather than inconvenient.
ignore = {}

-- The test suite runs under a plain LuaJIT with no KOReader present. Its runner
-- (spec/run.lua) intentionally publishes the describe/it/assert_* harness as
-- globals, so both writing and reading them has to be permitted -- hence
-- `globals` rather than `read_globals`. Scoped to spec/ so plugin code cannot
-- accidentally rely on them.
files = {
    ["spec/"] = {
        globals = {
            "describe", "it",
            "assert_eq", "assert_true", "assert_false",
            "assert_match", "assert_contains", "assert_not_contains",
        },
    },
}
