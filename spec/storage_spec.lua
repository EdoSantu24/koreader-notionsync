--
-- Pins the CURRENT behaviour of filename/directory sanitisation.
--
-- Assertions marked BUG describe real data-loss behaviour that a later PR fixes.
-- They are written as explicit expectations so the fix shows up as a deliberate
-- test change, and so nobody "fixes" the sanitiser by accident and wonders why
-- files moved.
--

local h = require("spec.helper")
local Storage = h.load_plugin("storage")
local S = Storage:new("/tmp/notion_sync")

describe("sanitizeFilename", function()
    it("keeps_ascii_words", function()
        assert_eq(S:sanitizeFilename("Hello World", ".epub"), "Hello_World.epub")
    end)

    -- EPUB is the only output format, so an omitted extension must not produce a
    -- filename that fileExists() could never match against what saveEpub() writes.
    it("defaults_extension_to_epub", function()
        assert_eq(S:sanitizeFilename("Notes"), "Notes.epub")
    end)

    it("collapses_whitespace_runs", function()
        assert_eq(S:sanitizeFilename("a   b", ".epub"), "a_b.epub")
    end)

    it("strips_path_separators", function()
        assert_not_contains(S:sanitizeFilename("a/b", ".epub"), "/")
    end)

    -- BUG: the pattern [^%w%s-_] is byte-oriented, and %w is ASCII-only, so every
    -- byte >= 0x80 is deleted. A page titled entirely in a non-Latin script loses
    -- its whole name. Worse, two such pages both become untitled.epub and the
    -- second silently overwrites the first, with both recorded as synced.
    it("BUG_cjk_title_collapses_to_untitled", function()
        assert_eq(S:sanitizeFilename("读书笔记", ".epub"), "untitled.epub")
    end)

    it("BUG_cyrillic_title_collapses_to_untitled", function()
        assert_eq(S:sanitizeFilename("Проект", ".epub"), "untitled.epub")
    end)

    it("BUG_accents_are_stripped_from_latin", function()
        assert_eq(S:sanitizeFilename("Café", ".epub"), "Caf.epub")
    end)

    -- BUG: punctuation is deleted rather than replaced, so titles that differ
    -- only in punctuation collide on one filename.
    it("BUG_punctuation_only_differences_collide", function()
        local a = S:sanitizeFilename("Report: Q1", ".epub")
        local b = S:sanitizeFilename("Report Q1", ".epub")
        assert_eq(a, b, "distinct titles must not produce the same filename")
        assert_eq(a, "Report_Q1.epub")
    end)

    it("BUG_truncation_can_split_a_utf8_sequence", function()
        -- 60 x 3-byte characters = 180 bytes; a blind :sub(1,100) cuts mid-character.
        local long = string.rep("图", 60)
        local out = S:sanitizeFilename(long, ".epub")
        -- Current code strips all high bytes first, so this collapses instead.
        assert_eq(out, "untitled.epub")
    end)
end)

describe("sanitizeDatabaseName", function()
    it("keeps_ascii_words", function()
        assert_eq(S:sanitizeDatabaseName("Reading List"), "Reading_List")
    end)

    it("BUG_cjk_database_collapses", function()
        assert_eq(S:sanitizeDatabaseName("书库"), "untitled_database")
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

    it("temp_image_dir_is_hidden", function()
        assert_contains(S:getTempImageDir(), ".notion_image_cache")
    end)
end)
