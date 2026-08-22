local lfs = require("libs/libkoreader-lfs")
local ffiUtil = require("ffi/util")
local logger = require("logger")

local NotionStorage = {}

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

function NotionStorage:sanitizeDatabaseName(database_name)
    -- Sanitize database name for use as a folder name
    local safe = database_name:gsub("[^%w%s-_]", "")
    safe = safe:gsub("%s+", "_")
    if #safe > 100 then
        safe = safe:sub(1, 100)
    end
    if safe == "" then
        safe = "untitled_database"
    end
    return safe
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
    local safe = title:gsub("[^%w%s-_]", "")
    safe = safe:gsub("%s+", "_")
    if #safe > 100 then
        safe = safe:sub(1, 100)
    end
    if safe == "" then
        safe = "untitled"
    end
    return safe .. extension
end

function NotionStorage:fileExists(title, extension, database_name)
    extension = extension or ".epub"
    local filename = self:sanitizeFilename(title, extension)
    local db_dir = database_name and self:getDatabaseDirectory(database_name) or self.sync_dir
    local filepath = ffiUtil.joinPath(db_dir, filename)
    local file = io.open(filepath, "r")
    if file then
        file:close()
        return true
    end
    return false
end

-- Full path a page's EPUB should be written to, creating the per-database
-- directory if needed.
--
-- Writing is the EPUB builder's job, not this module's. It used to `dofile`
-- epub.lua on every single save -- which also re-loaded the 1212-line Markdown
-- parser each time, around 120 compiles for a 60-page sync -- and kept a second,
-- divergent module instance alive alongside the caller's.
function NotionStorage:getOutputPath(title, database_name)
    local db_dir = self:ensureDatabaseDirectory(database_name)
    return ffiUtil.joinPath(db_dir, self:sanitizeFilename(title, ".epub"))
end

return NotionStorage
