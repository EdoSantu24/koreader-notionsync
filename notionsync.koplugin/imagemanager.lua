local logger = require("logger")
local socket = require("socket")
local http = require("socket.http")
local ltn12 = require("ltn12")
local socketutil = require("socketutil")
local lfs = require("libs/libkoreader-lfs")
local util = require("util")

local ImageManager = {}

function ImageManager:new(temp_dir)
    local o = {
        temp_dir = temp_dir,
        image_cache = {},
        stats = {
            downloaded = 0,
            failed = 0,
            cached = 0,
        },
        image_counter = 1,
    }
    setmetatable(o, self)
    self.__index = self

    -- Create temp directory if it doesn't exist
    if not util.pathExists(temp_dir) then
        util.makePath(temp_dir)
        logger.info("ImageManager: Created temp directory at", temp_dir)
    end

    -- Clean up any existing files from previous crashed sync
    o:cleanupOldFiles(temp_dir)

    return o
end

function ImageManager:cleanupOldFiles(temp_dir)
    local mode = lfs.attributes(temp_dir, "mode")
    if mode == "directory" then
        logger.dbg("ImageManager: Cleaning up old temp files in", temp_dir)
        for entry in lfs.dir(temp_dir) do
            if entry ~= "." and entry ~= ".." then
                local entry_path = temp_dir .. "/" .. entry
                os.remove(entry_path)
                logger.dbg("ImageManager: Removed old file", entry_path)
            end
        end
    end
end

function ImageManager:downloadImage(url, page_id, image_index)
    -- Check cache first
    if self.image_cache[url] then
        logger.dbg("ImageManager: Using cached image for", url)
        self.stats.cached = self.stats.cached + 1
        return self.image_cache[url]
    end

    -- Detect file extension from URL
    local ext = self:getExtensionFromURL(url)

    -- Generate sequential filename
    local filename = string.format("image%03d.%s", self.image_counter, ext)
    local filepath = self.temp_dir .. "/" .. filename

    logger.info("ImageManager: Downloading image", self.image_counter, "from", url)

    -- Download the image
    local success = self:downloadFile(url, filepath)

    if success then
        self.stats.downloaded = self.stats.downloaded + 1
        self.image_cache[url] = filepath
        self.image_counter = self.image_counter + 1
        logger.info("ImageManager: Successfully downloaded to", filepath)
        return filepath
    else
        self.stats.failed = self.stats.failed + 1
        logger.warn("ImageManager: Failed to download image from", url)
        return nil
    end
end

function ImageManager:getExtensionFromURL(url)
    -- Try to extract extension from URL
    local ext = url:match("%.([^%.%?]+)%??[^/]*$")

    -- Common image extensions
    local valid_exts = {
        jpg = true, jpeg = true, png = true, gif = true,
        webp = true, svg = true, bmp = true, ico = true
    }

    if ext and valid_exts[ext:lower()] then
        return ext:lower()
    end

    -- Default to jpg if we can't determine
    return "jpg"
end

function ImageManager:downloadFile(url, filepath)
    local file = io.open(filepath, "wb")
    if not file then
        logger.err("ImageManager: Cannot open file for writing:", filepath)
        return false
    end

    -- Set reasonable timeout for image downloads (30 seconds)
    socketutil:set_timeout(30, 30)

    local request = {
        url = url,
        method = "GET",
        sink = ltn12.sink.file(file),
    }

    local code, headers, status = socket.skip(1, http.request(request))

    -- Reset timeout
    socketutil:reset_timeout()

    -- Note: ltn12.sink.file() closes the file automatically, no need to close it again

    -- Check if download was successful
    if code == 200 then
        logger.dbg("ImageManager: Download successful, HTTP 200")
        return true
    else
        -- Download failed, remove partial file
        logger.warn("ImageManager: Download failed with HTTP code", code or "nil", status or "")
        os.remove(filepath)
        return false
    end
end

function ImageManager:getImagePath(url)
    return self.image_cache[url]
end

function ImageManager:cleanup()
    logger.info("ImageManager: Cleaning up temp directory", self.temp_dir)

    -- Remove all files in temp directory
    local mode = lfs.attributes(self.temp_dir, "mode")
    if mode == "directory" then
        for entry in lfs.dir(self.temp_dir) do
            if entry ~= "." and entry ~= ".." then
                local entry_path = self.temp_dir .. "/" .. entry
                local success, err = os.remove(entry_path)
                if success then
                    logger.dbg("ImageManager: Removed", entry_path)
                else
                    logger.warn("ImageManager: Failed to remove", entry_path, err)
                end
            end
        end

        -- Try to remove the directory itself
        local success, err = os.remove(self.temp_dir)
        if success then
            logger.info("ImageManager: Removed temp directory")
        else
            logger.warn("ImageManager: Could not remove temp directory:", err)
        end
    end

    -- Clear cache
    self.image_cache = {}
end

function ImageManager:getStats()
    return self.stats
end

return ImageManager
