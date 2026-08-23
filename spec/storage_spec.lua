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

-- Sync state: the point of this is that editing a page in Notion actually
-- re-downloads it, which it never used to.
describe("syncState", function()
    local tmpdir = (os.getenv("TEMP") or os.getenv("TMPDIR") or "/tmp"):gsub("\\", "/")

    -- No state_path, so state is in memory: these tests are about the decision
    -- logic, not the file format.
    --
    -- The legacy file is removed first because it lives at a path derived from
    -- sync_dir, which is shared with the migration tests below AND persists in the
    -- system temp directory between runs. Without this, a leftover file from an
    -- earlier run gets migrated here and a "new" page reports as already synced --
    -- an intermittent failure that depends on what ran previously.
    local function fresh(existing_files)
        local s = Storage:new(tmpdir)
        os.remove(s.synced_ids_file)
        s:loadState()
        -- outputExists hits the real filesystem; stub it for predictability.
        s.outputExists = function(_, filename)
            return (existing_files or {})[filename] == true
        end
        return s
    end

    it("a_page_never_seen_is_new", function()
        local s = fresh()
        local should, reason = s:shouldSync("p1", "T1", "a.epub", "DB")
        assert_true(should)
        assert_eq(reason, "new")
    end)

    it("an_unchanged_page_is_skipped", function()
        local s = fresh { ["a.epub"] = true }
        s:recordSynced("p1", "T1", "a.epub")
        local should, reason = s:shouldSync("p1", "T1", "a.epub", "DB")
        assert_false(should)
        assert_eq(reason, "unchanged")
    end)

    -- The headline behaviour: a Notion edit changes last_edited_time.
    it("an_edited_page_is_resynced", function()
        local s = fresh { ["a.epub"] = true }
        s:recordSynced("p1", "2026-01-01T00:00:00.000Z", "a.epub")
        local should, reason = s:shouldSync("p1", "2026-02-02T00:00:00.000Z", "a.epub", "DB")
        assert_true(should)
        assert_eq(reason, "edited")
    end)

    -- Checked before the timestamp: a deleted book must come back even if Notion
    -- says nothing changed.
    it("a_deleted_file_is_resynced_even_when_unchanged", function()
        local s = fresh {}
        s:recordSynced("p1", "T1", "a.epub")
        local should, reason = s:shouldSync("p1", "T1", "a.epub", "DB")
        assert_true(should)
        assert_eq(reason, "missing")
    end)

    it("comparison_is_exact_string_equality", function()
        local s = fresh { ["a.epub"] = true }
        s:recordSynced("p1", "2026-01-01T00:00:00.000Z", "a.epub")
        -- Same instant, different serialisation: treated as changed rather than
        -- parsed, which is the deliberate trade for having no date handling.
        local should = s:shouldSync("p1", "2026-01-01T00:00:00Z", "a.epub", "DB")
        assert_true(should)
    end)

    it("counts_recorded_pages", function()
        local s = fresh()
        assert_eq(s:countSyncedPages(), 0)
        s:recordSynced("p1", "T1", "a.epub")
        s:recordSynced("p2", "T2", "b.epub")
        assert_eq(s:countSyncedPages(), 2)
    end)

    -- `nil` must not mean two things. If a recorded page has no timestamp -- the
    -- last sync could not determine one -- adopting it would freeze that page
    -- forever, because every later comparison would take the same branch and
    -- never notice an edit.
    it("a_recorded_page_with_no_timestamp_resyncs_rather_than_freezing", function()
        local s = fresh { ["a.epub"] = true }
        s:recordSynced("p1", nil, "a.epub")
        local should, reason = s:shouldSync("p1", "T1", "a.epub", "DB")
        assert_true(should, "an unknown timestamp must not be treated as up to date")
        assert_eq(reason, "edited")
    end)

    it("only_a_migrated_record_is_adopted", function()
        local s = fresh { ["a.epub"] = true }
        -- Explicit flag, not an absent timestamp.
        s.pages["p1"] = { migrated = true }
        local _, migrated_reason = s:shouldSync("p1", "T1", "a.epub", "DB")
        assert_eq(migrated_reason, "adopted")

        s.pages["p2"] = { last_edited = nil }
        local _, unknown_reason = s:shouldSync("p2", "T1", "a.epub", "DB")
        assert_eq(unknown_reason, "edited")
    end)

    it("clearing_forgets_everything", function()
        local s = fresh { ["a.epub"] = true }
        s:recordSynced("p1", "T1", "a.epub")
        assert_true(s:clearSyncHistory())
        assert_eq(s:countSyncedPages(), 0)
        local should, reason = s:shouldSync("p1", "T1", "a.epub", "DB")
        assert_true(should)
        assert_eq(reason, "new")
    end)
end)

-- Upgrading must not re-download the whole library. The old file had no
-- timestamps, so "unknown" is adopted rather than treated as stale.
describe("legacyMigration", function()
    local tmpdir = (os.getenv("TEMP") or os.getenv("TMPDIR") or "/tmp"):gsub("\\", "/")

    -- Takes a LIST of legacy keys and joins them with newlines here, rather than
    -- embedding escape sequences in each test.
    local function with_legacy(keys, existing_files)
        local s = Storage:new(tmpdir)
        local f = assert(io.open(s.synced_ids_file, "w"))
        for _, key in ipairs(keys) do
            f:write(key)
            f:write(string.char(10))
        end
        f:close()
        s:loadState()
        s.outputExists = function(_, filename)
            return (existing_files or {})[filename] == true
        end
        return s
    end

    it("imports_legacy_ids", function()
        local s = with_legacy { "p1:epub", "p2:epub" }
        assert_eq(s:countSyncedPages(), 2)
    end)

    it("strips_the_format_suffix", function()
        local s = with_legacy({ "p1:epub" }, { ["a.epub"] = true })
        local should = s:shouldSync("p1", "T1", "a.epub", "DB")
        assert_false(should, "the legacy record for p1 should be recognised")
    end)

    it("deduplicates_the_append_only_file", function()
        local s = with_legacy { "p1:epub", "p1:epub", "p1:epub" }
        assert_eq(s:countSyncedPages(), 1)
    end)

    -- The whole point of adoption: an existing book is left alone on upgrade.
    it("adopts_an_existing_file_instead_of_redownloading", function()
        local s = with_legacy({ "p1:epub" }, { ["a.epub"] = true })
        local should, reason = s:shouldSync("p1", "T1", "a.epub", "DB")
        assert_false(should)
        assert_eq(reason, "adopted")
    end)

    -- ...but a legacy record whose file is gone must still be fetched.
    it("does_not_adopt_when_the_file_is_missing", function()
        local s = with_legacy({ "p1:epub" }, {})
        local should, reason = s:shouldSync("p1", "T1", "a.epub", "DB")
        assert_true(should)
        assert_eq(reason, "missing")
    end)

    -- An old Markdown record maps to the same id, but the .epub is absent so it
    -- re-syncs anyway.
    it("a_legacy_markdown_record_still_fetches_the_epub", function()
        local s = with_legacy({ "p1:md" }, {})
        local should = s:shouldSync("p1", "T1", "a.epub", "DB")
        assert_true(should)
    end)

    it("once_adopted_and_stamped_an_edit_is_detected", function()
        local s = with_legacy({ "p1:epub" }, { ["a.epub"] = true })
        -- The sync loop stamps the current time on adoption.
        s:recordSynced("p1", "T1", "a.epub")
        local should, reason = s:shouldSync("p1", "T2", "a.epub", "DB")
        assert_true(should)
        assert_eq(reason, "edited")
    end)

    it("tolerates_no_legacy_file", function()
        local s = Storage:new(tmpdir .. "/nope_" .. tostring(os.time()))
        s:loadState()
        assert_eq(s:countSyncedPages(), 0)
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
