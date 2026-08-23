local lfs = require("libs/libkoreader-lfs")
local ffiUtil = require("ffi/util")
local util = require("util")
local LuaSettings = require("luasettings")
local logger = require("logger")

local NotionStorage = {}

--------------------------------------------------------------------------------
-- Filenames
--------------------------------------------------------------------------------

-- Characters that genuinely cannot appear in a filename, plus control bytes.
--
-- The previous pattern was the inverse of this -- it kept only `[%w%s-_]` and
-- DELETED everything else. Because Lua patterns are byte-oriented and `%w` is
-- ASCII-only, that deleted every byte >= 0x80: a page titled 读书笔记 became
-- `untitled.epub`, and a second such page overwrote the first while both were
-- recorded as synced. Silent, unrecoverable data loss.
--
-- Bytes >= 0x80 are now never touched, which makes this UTF-8 safe by
-- construction without needing a utf8 library (LuaJIT has none).
local UNSAFE_CHARS = '[/\\:%*%?"<>|%c]'

-- The device's user partition is FAT32 and files get copied off it over USB, so
-- Windows' rules apply even though the plugin runs on Linux.
local RESERVED_NAMES = {
    CON = true, PRN = true, AUX = true, NUL = true,
    COM1 = true, COM2 = true, COM3 = true, COM4 = true, COM5 = true,
    COM6 = true, COM7 = true, COM8 = true, COM9 = true,
    LPT1 = true, LPT2 = true, LPT3 = true, LPT4 = true, LPT5 = true,
    LPT6 = true, LPT7 = true, LPT8 = true, LPT9 = true,
}

-- Byte budget, not a character count: FAT32 limits the name in bytes, and one
-- CJK character costs three. Leaves room for the extension and a collision
-- suffix.
local MAX_NAME_BYTES = 80

-- Truncates to at most `budget` BYTES without splitting a UTF-8 sequence. A
-- blind :sub() can leave half a multi-byte character behind, which is invalid on
-- some filesystems and renders as a replacement glyph.
local function truncate_utf8(text, budget)
    if #text <= budget then return text end
    local kept, used = {}, 0
    for _, char in ipairs(util.splitToChars(text)) do
        if used + #char > budget then break end
        kept[#kept + 1] = char
        used = used + #char
    end
    return table.concat(kept)
end

-- Short, stable discriminator for a page. Derived from the Notion id so the same
-- collision always resolves to the same filename, unlike a counter, which would
-- depend on processing order and rename files between runs.
local function id_suffix(page_id, length)
    local hex = tostring(page_id or ""):lower():gsub("[^0-9a-f]", "")
    if hex == "" then return "0" end
    return hex:sub(1, length or 8)
end

-- Suffix length just long enough to tell every page in a colliding group apart.
--
-- Eight hex digits is 32 bits and almost always enough, but "almost always" is
-- not a guarantee -- and two pages sharing a suffix would silently reintroduce
-- the overwrite this whole mechanism exists to prevent. So it is verified rather
-- than assumed, growing the discriminator until the group is distinguishable.
local function unique_suffixes(group)
    for length = 8, 32, 8 do
        local seen, unique = {}, true
        for _, entry in ipairs(group) do
            local suffix = id_suffix(entry.id, length)
            if seen[suffix] then
                unique = false
                break
            end
            seen[suffix] = true
        end
        if unique then
            local out = {}
            for _, entry in ipairs(group) do
                out[entry.id] = id_suffix(entry.id, length)
            end
            return out, length
        end
    end
    -- Two pages with identical ids should be impossible; if it happens, fall back
    -- to the index so the names are at least distinct.
    logger.warn("NotionStorage: page ids are not distinguishable, using positions")
    local out = {}
    for index, entry in ipairs(group) do
        out[entry.id] = tostring(index)
    end
    return out, 8
end

-- state_path is optional; without it sync state is held in memory only, which is
-- what the tests do.
function NotionStorage:new(sync_dir, state_path)
    local o = {
        sync_dir = sync_dir,
        -- The pre-timestamp history file, read once for migration.
        synced_ids_file = ffiUtil.joinPath(sync_dir, ".synced_ids"),
        state_path = state_path,
        pages = {},
        state_dirty = false,
    }
    setmetatable(o, self)
    self.__index = self
    return o
end

--------------------------------------------------------------------------------
-- Sync state
--------------------------------------------------------------------------------
--
-- Keyed by Notion page id, holding the page's last_edited_time so an edit in
-- Notion actually triggers a re-sync. Previously only the id was recorded, so a
-- page fixed in Notion kept its stale copy forever and "Clear sync history" --
-- which re-downloads everything -- was the only lever.
--
-- Lives in KOReader's settings directory rather than in save_dir, so changing the
-- save directory does not throw the history away. A missing output file is still
-- detected separately, so deleting a book always re-syncs it.

-- Reads the state file, migrating the old format on first run.
function NotionStorage:loadState()
    -- Whether a state file already had records is tracked explicitly rather than
    -- inferred from self.pages being nil: new() initialises it to an empty table
    -- so every other method is safe before loadState, which made the nil test
    -- silently never fire and skipped migration entirely.
    local stored = nil
    if self.state_path then
        self.state = LuaSettings:open(self.state_path)
        stored = self.state:readSetting("pages")
    end

    if stored then
        self.pages = stored
    else
        -- No state file yet, so import the pre-timestamp history if one exists.
        self.pages = self:migrateLegacyIds()
        self.state_dirty = true
        self:flushState()
    end
    return self.pages
end

-- The old format was one "<page_id>:<format>" per line, append-only, with no
-- timestamps at all.
--
-- last_edited is deliberately left nil rather than guessed. Treating "unknown" as
-- stale would re-download the entire library on upgrade; instead the first sync
-- ADOPTS whatever Notion currently reports for any page whose file is already
-- present. The cost is that an edit made before upgrading is missed exactly once,
-- which is a far better trade than re-fetching everything.
function NotionStorage:migrateLegacyIds()
    local pages = {}
    local file = io.open(self.synced_ids_file, "r")
    if not file then return pages end

    local count = 0
    for line in file:lines() do
        local trimmed = line:match("^%s*(.-)%s*$")
        if trimmed and trimmed ~= "" then
            -- Legacy keys were "<id>:<format>"; the format is dropped because
            -- EPUB is the only output now. An old ":md" record maps to the same
            -- id, and the missing .epub file makes it re-sync anyway.
            local id = trimmed:match("^([^:]+)")
            if id and id ~= "" and not pages[id] then
                pages[id] = { last_edited = nil }
                count = count + 1
            end
        end
    end
    file:close()

    if count > 0 then
        logger.info("NotionStorage: migrated", count,
            "sync record(s) with no known edit time; they will be adopted on this sync")
    end
    return pages
end

-- Returns should_sync, reason.
function NotionStorage:shouldSync(page_id, last_edited, filename, database_name)
    local record = self.pages[page_id]
    if not record then return true, "new" end

    -- Checked before the timestamp: a deleted book must come back even if Notion
    -- says nothing changed.
    if not self:outputExists(filename, database_name) then
        return true, "missing"
    end

    if record.last_edited == nil then
        return false, "adopted"
    end
    if record.last_edited ~= last_edited then
        return true, "edited"
    end
    return false, "unchanged"
end

-- String comparison, deliberately: Notion returns a canonical ISO 8601 form, so
-- there is nothing to gain from parsing it and no timezone handling to get wrong.
function NotionStorage:recordSynced(page_id, last_edited, filename)
    self.pages[page_id] = {
        last_edited = last_edited,
        path = filename,
        synced_at = os.time(),
    }
    self.state_dirty = true
end

function NotionStorage:flushState()
    if not self.state_dirty then return false end
    if not self.state then
        self.state_dirty = false
        return false
    end
    self.state:saveSetting("pages", self.pages)
    self.state:flush()
    self.state_dirty = false
    return true
end

function NotionStorage:countSyncedPages()
    local count = 0
    for _ in pairs(self.pages) do count = count + 1 end
    return count
end

function NotionStorage:ensureDirectory(path)
    local mode = lfs.attributes(path, "mode")
    if not mode then
        local success = lfs.mkdir(path)
        if not success then
            os.execute("mkdir -p " .. path)
        end
    end
end

function NotionStorage:initialize()
    self:ensureDirectory(self.sync_dir)
end

-- Forgets every record, so the next sync re-downloads everything. The output
-- files themselves are left alone and will simply be overwritten.
function NotionStorage:clearSyncHistory()
    self.pages = {}
    self.state_dirty = true

    if not self.state then return true end

    local ok, err = pcall(function() self:flushState() end)
    if not ok then
        -- Surfaced to the user, so it must also be diagnosable: on-device there is
        -- no way to inspect state interactively, only crash.log after the fact.
        logger.warn("NotionStorage: could not clear sync history:", tostring(err))
        return false, err
    end
    logger.info("NotionStorage: cleared sync history")
    return true
end

-- Turns arbitrary text into a safe filename stem.
--
-- Whitespace and unsafe characters both collapse to a single "_", which keeps
-- existing ASCII filenames byte-identical to what the old sanitiser produced --
-- important, because a changed name means the next sync writes a new file and
-- orphans the old one.
function NotionStorage:sanitizeName(text, fallback)
    local safe = tostring(text or "")
    safe = safe:gsub("%s+", "_")
    safe = safe:gsub(UNSAFE_CHARS, "_")
    safe = safe:gsub("_+", "_")
    -- Leading/trailing dots and underscores are stripped; a trailing dot or space
    -- in particular is invalid on Windows, which matters for USB copies.
    safe = safe:gsub("^[_%.]+", ""):gsub("[_%.%s]+$", "")

    safe = truncate_utf8(safe, MAX_NAME_BYTES)
    -- Truncation can expose a new trailing separator.
    safe = safe:gsub("[_%.%s]+$", "")

    if safe == "" then return fallback end
    if RESERVED_NAMES[safe:upper()] then return "_" .. safe end
    return safe
end

function NotionStorage:sanitizeDatabaseName(database_name)
    return self:sanitizeName(database_name, "untitled_database")
end

function NotionStorage:getDatabaseDirectory(database_name)
    -- Get the path to the database-specific subdirectory
    local safe_name = self:sanitizeDatabaseName(database_name)
    return ffiUtil.joinPath(self.sync_dir, safe_name)
end

function NotionStorage:ensureDatabaseDirectory(database_name)
    -- Create database subdirectory if it doesn't exist
    local db_dir = self:getDatabaseDirectory(database_name)
    self:ensureDirectory(db_dir)
    return db_dir
end

-- Single-name convenience. Prefer resolveFilenames when a whole database is in
-- view, because only that can see -- and resolve -- a collision between two pages.
function NotionStorage:sanitizeFilename(title, extension)
    -- EPUB is the only output format, so an omitted extension must not produce a
    -- name that outputExists() could never match against what the builder writes.
    extension = extension or ".epub"
    return self:sanitizeName(title, "untitled") .. extension
end

-- Assigns a filename to every page in a database, resolving collisions.
--
-- Done for the whole set at once, rather than one page at a time, so the result
-- does not depend on processing order: if two titles sanitise to the same stem,
-- BOTH get an id suffix. Deciding per-page would suffix only whichever happened
-- to come second, so the two files would swap names whenever Notion returned the
-- pages in a different order.
--
-- entries: array of { id = <notion page id>, title = <raw title> }
-- Returns a map of page id -> filename.
--
-- Caveat worth knowing: a name is suffixed only while the collision exists, so
-- removing one of two clashing pages from the database lets the survivor revert
-- to the unsuffixed name on the next sync, orphaning its old file.
function NotionStorage:resolveFilenames(entries, extension)
    extension = extension or ".epub"

    local by_stem = {}
    for _, entry in ipairs(entries or {}) do
        -- An entry with no id cannot be keyed in the result, and indexing a table
        -- with nil would abort the whole sync.
        if type(entry) ~= "table" or entry.id == nil then
            logger.warn("NotionStorage: skipping filename for an entry with no id")
        else
            local stem = self:sanitizeName(entry.title, "untitled")
            by_stem[stem] = by_stem[stem] or {}
            local group = by_stem[stem]
            group[#group + 1] = entry
        end
    end

    local names = {}
    for stem, group in pairs(by_stem) do
        if #group == 1 then
            names[group[1].id] = stem .. extension
        else
            local suffixes, length = unique_suffixes(group)
            logger.info("NotionStorage:", #group, "pages share the name", stem,
                "-- adding", length, "char id suffixes")
            for _, entry in ipairs(group) do
                -- Re-truncate: the suffix must not push the name over the budget.
                local base = truncate_utf8(stem, MAX_NAME_BYTES - (length + 1))
                base = base:gsub("[_%.%s]+$", "")
                names[entry.id] = base .. "_" .. suffixes[entry.id] .. extension
            end
        end
    end
    return names
end


-- Full path a page's EPUB should be written to, creating the per-database
-- directory if needed.
--
-- Writing is the EPUB builder's job, not this module's. It used to `dofile`
-- epub.lua on every single save -- which also re-loaded the 1212-line Markdown
-- parser each time, around 120 compiles for a 60-page sync -- and kept a second,
-- divergent module instance alive alongside the caller's.
-- `filename` is the already-resolved name from resolveFilenames. It is passed in
-- rather than derived here so that collision handling has the whole database in
-- view; deriving it per call could not see the clash.
function NotionStorage:getOutputPath(filename, database_name)
    local db_dir = self:ensureDatabaseDirectory(database_name)
    return ffiUtil.joinPath(db_dir, filename)
end

-- Whether a resolved filename already exists in the database's directory.
function NotionStorage:outputExists(filename, database_name)
    local db_dir = self:getDatabaseDirectory(database_name)
    local file = io.open(ffiUtil.joinPath(db_dir, filename), "r")
    if file then
        file:close()
        return true
    end
    return false
end

return NotionStorage
