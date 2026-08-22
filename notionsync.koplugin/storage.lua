local lfs = require("libs/libkoreader-lfs")
local ffiUtil = require("ffi/util")
local util = require("util")
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
local function id_suffix(page_id)
    local hex = tostring(page_id or ""):lower():gsub("[^0-9a-f]", "")
    if hex == "" then return "0" end
    return hex:sub(1, 8)
end

function NotionStorage:new(sync_dir)
    local o = {
        sync_dir = sync_dir,
        synced_ids_file = ffiUtil.joinPath(sync_dir, ".synced_ids"),
    }
    setmetatable(o, self)
    self.__index = self
    return o
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

function NotionStorage:getSyncedIds()
    local synced = {}
    local file = io.open(self.synced_ids_file, "r")
    if file then
        for line in file:lines() do
            local trimmed = line:match("^%s*(.-)%s*$") -- Trim whitespace
            if trimmed and trimmed ~= "" then
                synced[trimmed] = true
            end
        end
        file:close()
    end
    return synced
end

function NotionStorage:countSyncedIds()
    local count = 0
    for _ in pairs(self:getSyncedIds()) do
        count = count + 1
    end
    return count
end

function NotionStorage:markAsSynced(page_id)
    local file = io.open(self.synced_ids_file, "a")
    if file then
        file:write(page_id .. "\n")
        file:close()
    end
end

function NotionStorage:clearSyncHistory()
    local file, err = io.open(self.synced_ids_file, "w")
    if not file then
        -- Surfaced to the user, so it must also be diagnosable: on-device there
        -- is no way to inspect state interactively, only crash.log after the fact.
        logger.warn("NotionStorage: Could not clear sync history at",
            self.synced_ids_file, "--", tostring(err))
        return false, err
    end
    file:close()
    logger.info("NotionStorage: Cleared sync history at", self.synced_ids_file)
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

function NotionStorage:sanitizeFilename(title, extension)
    -- EPUB is the only output format. A ".md" default used to live here, which
    -- no caller reaches any more but would silently produce a filename that
    -- fileExists() could never match against what saveEpub() actually writes.
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
        local stem = self:sanitizeName(entry.title, "untitled")
        by_stem[stem] = by_stem[stem] or {}
        local group = by_stem[stem]
        group[#group + 1] = entry
    end

    local names = {}
    for stem, group in pairs(by_stem) do
        if #group == 1 then
            names[group[1].id] = stem .. extension
        else
            logger.info("NotionStorage:", #group, "pages share the name", stem,
                "-- adding id suffixes")
            for _, entry in ipairs(group) do
                -- Re-truncate: the suffix must not push the name over the budget.
                local base = truncate_utf8(stem, MAX_NAME_BYTES - 9)
                base = base:gsub("[_%.%s]+$", "")
                names[entry.id] = base .. "_" .. id_suffix(entry.id) .. extension
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
