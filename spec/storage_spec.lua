--
-- Filename sanitisation and sync history.
--
-- The filename tests used to pin real data loss: the old pattern kept only
-- `[%w%s-_]` and, because Lua patterns are byte-oriented and `%w` is ASCII-only,
-- DELETED every byte >= 0x80. A page titled 读书笔记 became `untitled.epub`, and a
-- second such page silently overwrote the first while both were recorded as
-- synced. Those assertions now describe the fixed behaviour.
--

local h = require("spec.helper")
local Storage = h.load_plugin("storage")
local S = Storage:new("/tmp/notion_sync")

describe("sanitizeFilename", function()
    it("keeps_ascii_words", function()
        assert_eq(S:sanitizeFilename("Hello World", ".epub"), "Hello_World.epub")
    end)

    -- EPUB is the only output format, so an omitted extension must not produce a
    -- filename that outputExists() could never match against what is written.
    it("defaults_extension_to_epub", function()
        assert_eq(S:sanitizeFilename("Notes"), "Notes.epub")
    end)

    it("collapses_whitespace_runs", function()
        assert_eq(S:sanitizeFilename("a   b", ".epub"), "a_b.epub")
    end)

    it("strips_path_separators", function()
        assert_not_contains(S:sanitizeFilename("a/b", ".epub"), "/")
        assert_not_contains(S:sanitizeFilename("a\\b", ".epub"), "\\")
    end)

    it("preserves_cjk_titles", function()
        assert_eq(S:sanitizeFilename("读书笔记", ".epub"), "读书笔记.epub")
    end)

    it("preserves_cyrillic_titles", function()
        assert_eq(S:sanitizeFilename("Проект", ".epub"), "Проект.epub")
    end)

    it("preserves_accented_latin", function()
        assert_eq(S:sanitizeFilename("Café", ".epub"), "Café.epub")
    end)

    it("preserves_mixed_scripts", function()
        assert_eq(S:sanitizeFilename("読書 notes", ".epub"), "読書_notes.epub")
    end)

    it("falls_back_only_when_nothing_usable_remains", function()
        assert_eq(S:sanitizeFilename("", ".epub"), "untitled.epub")
        assert_eq(S:sanitizeFilename("///", ".epub"), "untitled.epub")
        assert_eq(S:sanitizeFilename(nil, ".epub"), "untitled.epub")
    end)

    -- The device partition is FAT32 and files get copied off it over USB, so
    -- Windows' rules apply even though the plugin runs on Linux.
    it("strips_trailing_dots_and_spaces", function()
        assert_eq(S:sanitizeFilename("Notes.", ".epub"), "Notes.epub")
        assert_eq(S:sanitizeFilename("Notes ", ".epub"), "Notes.epub")
    end)

    it("escapes_reserved_windows_names", function()
        assert_eq(S:sanitizeFilename("CON", ".epub"), "_CON.epub")
        assert_eq(S:sanitizeFilename("com1", ".epub"), "_com1.epub")
    end)

    it("removes_control_characters", function()
        assert_eq(S:sanitizeFilename("a\1b", ".epub"), "a_b.epub")
    end)

    it("truncates_long_names_by_bytes", function()
        local out = S:sanitizeFilename(string.rep("a", 300), ".epub")
        assert_true(#out <= 90, "name should be bounded, got " .. #out)
    end)

    -- A blind :sub() would cut a 3-byte character in half, which is invalid on
    -- some filesystems and renders as a replacement glyph.
    it("truncation_never_splits_a_utf8_character", function()
        local out = S:sanitizeFilename(string.rep("图", 100), ".epub")
        local stem = out:gsub("%.epub$", "")
        assert_eq(table.concat(h.util.splitToChars(stem)), stem,
            "truncated name contains an invalid UTF-8 sequence")
        assert_true(#out <= 90)
    end)
end)

-- Collisions are resolved across the whole database at once, so the outcome does
-- not depend on the order Notion happens to return pages in.
describe("resolveFilenames", function()
    it("leaves_unique_names_alone", function()
        local names = S:resolveFilenames({
            { id = "aaaaaaaa1111", title = "Alpha" },
            { id = "bbbbbbbb2222", title = "Beta" },
        }, ".epub")
        assert_eq(names["aaaaaaaa1111"], "Alpha.epub")
        assert_eq(names["bbbbbbbb2222"], "Beta.epub")
    end)

    -- Previously both became Report_Q1.epub and the second silently overwrote the
    -- first, with both recorded as synced.
    it("suffixes_both_sides_of_a_collision", function()
        local names = S:resolveFilenames({
            { id = "aaaaaaaa1111", title = "Report: Q1" },
            { id = "bbbbbbbb2222", title = "Report Q1" },
        }, ".epub")
        assert_true(names["aaaaaaaa1111"] ~= names["bbbbbbbb2222"],
            "colliding pages must get distinct filenames")
        assert_contains(names["aaaaaaaa1111"], "aaaaaaaa")
        assert_contains(names["bbbbbbbb2222"], "bbbbbbbb")
    end)

    it("distinguishes_cjk_pages_that_both_used_to_be_untitled", function()
        local names = S:resolveFilenames({
            { id = "aaaaaaaa1111", title = "读书笔记" },
            { id = "bbbbbbbb2222", title = "日記" },
        }, ".epub")
        assert_eq(names["aaaaaaaa1111"], "读书笔记.epub")
        assert_eq(names["bbbbbbbb2222"], "日記.epub")
    end)

    -- Order independence is the whole reason names are resolved as a set.
    it("is_independent_of_input_order", function()
        local a = { id = "aaaaaaaa1111", title = "Same" }
        local b = { id = "bbbbbbbb2222", title = "Same" }
        local forward = S:resolveFilenames({ a, b }, ".epub")
        local backward = S:resolveFilenames({ b, a }, ".epub")
        assert_eq(forward["aaaaaaaa1111"], backward["aaaaaaaa1111"])
        assert_eq(forward["bbbbbbbb2222"], backward["bbbbbbbb2222"])
    end)

    it("is_stable_across_runs", function()
        local entries = {
            { id = "aaaaaaaa1111", title = "Same" },
            { id = "bbbbbbbb2222", title = "Same" },
        }
        local first = S:resolveFilenames(entries, ".epub")
        local second = S:resolveFilenames(entries, ".epub")
        assert_eq(first["aaaaaaaa1111"], second["aaaaaaaa1111"])
    end)

    it("keeps_suffixed_names_within_the_byte_budget", function()
        local long = string.rep("x", 200)
        local names = S:resolveFilenames({
            { id = "aaaaaaaa1111", title = long },
            { id = "bbbbbbbb2222", title = long },
        }, ".epub")
        assert_true(#names["aaaaaaaa1111"] <= 90, tostring(#names["aaaaaaaa1111"]))
        assert_true(names["aaaaaaaa1111"] ~= names["bbbbbbbb2222"])
    end)

    it("handles_three_way_collisions", function()
        local names = S:resolveFilenames({
            { id = "aaaaaaaa1111", title = "X!" },
            { id = "bbbbbbbb2222", title = "X?" },
            { id = "cccccccc3333", title = "X*" },
        }, ".epub")
        local seen = {}
        local count = 0
        for _, name in pairs(names) do
            assert_eq(seen[name], nil, "duplicate filename: " .. name)
            seen[name] = true
            count = count + 1
        end
        assert_eq(count, 3)
    end)

    it("handles_an_empty_list", function()
        assert_eq(next(S:resolveFilenames({}, ".epub")), nil)
    end)

    -- Eight hex digits is almost always enough to tell pages apart, but "almost"
    -- would silently reintroduce the overwrite this function exists to prevent.
    it("extends_the_suffix_when_ids_share_a_prefix", function()
        local names = S:resolveFilenames({
            { id = "aaaaaaaa1111bbbb", title = "Same" },
            { id = "aaaaaaaa2222cccc", title = "Same" },
        }, ".epub")
        assert_true(names["aaaaaaaa1111bbbb"] ~= names["aaaaaaaa2222cccc"],
            "pages sharing the first 8 hex digits must still get distinct names")
    end)

    it("stays_within_budget_even_with_an_extended_suffix", function()
        local long = string.rep("y", 200)
        local names = S:resolveFilenames({
            { id = "aaaaaaaa1111bbbb", title = long },
            { id = "aaaaaaaa2222cccc", title = long },
        }, ".epub")
        for _, name in pairs(names) do
            assert_true(#name <= 95, "name too long: " .. #name)
        end
    end)

    it("skips_entries_with_no_id_instead_of_erroring", function()
        h.logger.reset()
        local names = S:resolveFilenames({
            { id = "aaaaaaaa1111", title = "Good" },
            { title = "No id at all" },
        }, ".epub")
        assert_eq(names["aaaaaaaa1111"], "Good.epub")
        assert_true(h.logger.logged("warn", "no id"))
    end)
end)

describe("sanitizeDatabaseName", function()
    it("keeps_ascii_words", function()
        assert_eq(S:sanitizeDatabaseName("Reading List"), "Reading_List")
    end)

    it("preserves_cjk_database_names", function()
        assert_eq(S:sanitizeDatabaseName("书库"), "书库")
    end)

    it("falls_back_when_empty", function()
        assert_eq(S:sanitizeDatabaseName(""), "untitled_database")
    end)
end)

-- countSyncedIds was dead code until the "Clear sync history" menu item started
-- reporting how many pages would be forgotten. The history file is append-only
-- and legitimately contains repeated ids, so de-duplication is the real contract.
describe("syncHistory", function()
    local tmpdir = os.getenv("TEMP") or os.getenv("TMPDIR") or "/tmp"
    tmpdir = tmpdir:gsub("\\", "/")

    -- sync_dir points straight at the temp directory: the stubbed lfs.mkdir only
    -- records intent, so a subdirectory would never actually exist on disk.
    local function storage_with_history(lines)
        local s = Storage:new(tmpdir)
        local f = assert(io.open(s.synced_ids_file, "w"))
        f:write(lines)
        f:close()
        return s
    end

    it("counts_unique_ids", function()
        local s = storage_with_history("aaa:epub\nbbb:epub\nccc:epub\n")
        assert_eq(s:countSyncedIds(), 3)
    end)

    it("deduplicates_repeated_appends", function()
        local s = storage_with_history("aaa:epub\naaa:epub\naaa:epub\nbbb:epub\n")
        assert_eq(s:countSyncedIds(), 2, "append-only file must collapse duplicates")
    end)

    it("ignores_blank_lines_and_whitespace", function()
        local s = storage_with_history("aaa:epub\n\n  bbb:epub  \n\n")
        assert_eq(s:countSyncedIds(), 2)
    end)

    it("reports_zero_for_missing_file", function()
        local s = Storage:new(tmpdir .. "/definitely_does_not_exist_" .. tostring(os.time()))
        assert_eq(s:countSyncedIds(), 0)
    end)

    it("clearSyncHistory_empties_it", function()
        local s = storage_with_history("aaa:epub\nbbb:epub\n")
        assert_true(s:clearSyncHistory())
        assert_eq(s:countSyncedIds(), 0)
    end)

    it("getSyncedIds_returns_a_set_keyed_by_id", function()
        local s = storage_with_history("aaa:epub\nbbb:epub\n")
        local set = s:getSyncedIds()
        assert_true(set["aaa:epub"])
        assert_true(set["bbb:epub"])
        assert_eq(set["ccc:epub"], nil)
    end)
end)

describe("paths", function()
    it("database_directory_is_under_sync_dir", function()
        assert_eq(S:getDatabaseDirectory("Reading List"),
            "/tmp/notion_sync/Reading_List")
    end)

    -- getOutputPath takes an already-resolved filename, not a title: collision
    -- handling needs the whole database in view and cannot happen here.
    it("output_path_joins_the_database_dir_and_the_given_filename", function()
        assert_eq(S:getOutputPath("My_Page.epub", "Reading List"),
            "/tmp/notion_sync/Reading_List/My_Page.epub")
    end)

    it("output_path_preserves_a_non_ascii_filename", function()
        assert_eq(S:getOutputPath("读书笔记.epub", "书库"),
            "/tmp/notion_sync/书库/读书笔记.epub")
    end)

    -- Images now stream straight into the archive from memory, so there is no
    -- temp image directory -- which is what made every EPUB contain every image
    -- downloaded so far in the sync.
    it("no_temp_image_directory_exists", function()
        assert_eq(S.getTempImageDir, nil)
        assert_eq(S.cleanupTempImages, nil)
    end)

    -- saveEpub used to dofile epub.lua on every save, which also reloaded the
    -- 1212-line Markdown parser each time. Writing is the builder's job now.
    it("storage_no_longer_writes_epubs_itself", function()
        assert_eq(S.saveEpub, nil)
        assert_eq(S.saveMarkdown, nil)
    end)
end)
