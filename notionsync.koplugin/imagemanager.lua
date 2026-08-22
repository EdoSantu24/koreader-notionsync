--
-- Fetches image bytes for embedding into an EPUB.
--
-- This is deliberately stateless about the filesystem. It used to download to a
-- shared temp directory, which caused every generated EPUB to contain every image
-- downloaded so far in the sync (page 60 of a run carried all 120 prior images).
-- Images now go straight into the archive from memory, one at a time, so there is
-- no directory to over-enumerate and the bug cannot recur.
--
-- `socket.http` handles https:// correctly in KOReader -- the bundled LuaSocket
-- dispatches to ssl.https for port 443 and follows redirects -- so this is the
-- same module every bundled KOReader plugin uses. Do not "fix" it to ssl.https.
--
local socket = require("socket")
local http = require("socket.http")
local socketutil = require("socketutil")
local logger = require("logger")

local ImageManager = {}

-- Notion images run from a few KB to a couple of MB. The cap exists so that one
-- pathological attachment cannot exhaust memory mid-sync on a device with no swap;
-- exceeding it is reported, not silently skipped.
ImageManager.MAX_IMAGE_BYTES = 8 * 1024 * 1024

function ImageManager:new()
    local o = {
        stats = {
            downloaded = 0,
            failed = 0,
            skipped_too_large = 0,
            bytes = 0,
        },
    }
    setmetatable(o, self)
    self.__index = self
    return o
end

-- An ltn12 sink that accumulates into `chunks` and aborts past `limit`.
--
-- Wrapping socketutil.table_sink rather than a raw ltn12 sink matters: only the
-- socketutil sinks enforce the *total* timeout, so a raw sink would let a slow
-- trickle hang for the whole block timeout per chunk indefinitely.
local function capped_sink(chunks, limit, state)
    local inner = socketutil.table_sink(chunks)
    return function(chunk, err)
        if chunk and #chunk > 0 then
            state.size = state.size + #chunk
            if state.size > limit then
                state.too_large = true
                return nil, "response exceeds size cap"
            end
        end
        return inner(chunk, err)
    end
end

-- Transient socket-level failures seen against Notion's S3 host when several
-- images are fetched back to back -- "Operation already in progress" (EALREADY)
-- being the common one. These succeed on a retry, so a single failed attempt
-- must not cost the image.
ImageManager.MAX_ATTEMPTS = 3

-- Returns content, content_type on success; nil, reason on failure.
function ImageManager:fetch(url)
    if type(url) ~= "string" or url == "" then
        self.stats.failed = self.stats.failed + 1
        return nil, "empty url"
    end

    local content, reason
    for attempt = 1, self.MAX_ATTEMPTS do
        content, reason = self:fetchOnce(url)
        if content then
            if attempt > 1 then
                logger.info("ImageManager: succeeded on attempt", attempt)
            end
            self.stats.downloaded = self.stats.downloaded + 1
            self.stats.bytes = self.stats.bytes + #content
            return content, reason -- reason carries content_type on success
        end
        if reason == "image too large" then break end -- retrying cannot help
        if attempt < self.MAX_ATTEMPTS then
            logger.warn("ImageManager: attempt", attempt, "failed:", tostring(reason),
                "-- retrying")
            -- A short pause lets a half-open connection clear; without it the
            -- retry tends to hit the same error immediately.
            socket.sleep(attempt)
        end
    end

    self.stats.failed = self.stats.failed + 1
    logger.warn("ImageManager: giving up after", self.MAX_ATTEMPTS, "attempts:", url)
    return nil, reason
end

-- One attempt. Returns content, content_type on success; nil, reason on failure.
function ImageManager:fetchOnce(url)
    local chunks = {}
    local state = { size = 0, too_large = false }

    -- FILE_* rather than the LARGE_* constants used for API calls: an image is a
    -- file download and needs a longer total budget than a small JSON response.
    socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)

    local code, headers = socket.skip(1, http.request {
        url = url,
        method = "GET",
        sink = capped_sink(chunks, self.MAX_IMAGE_BYTES, state),
    })

    socketutil:reset_timeout()

    if state.too_large then
        self.stats.skipped_too_large = self.stats.skipped_too_large + 1
        logger.warn("ImageManager: image exceeds", self.MAX_IMAGE_BYTES, "bytes, skipped:", url)
        return nil, "image too large"
    end

    -- Stat counters live in fetch(), not here: incrementing per attempt would
    -- count one image as several failures.
    if code ~= 200 then
        logger.warn("ImageManager: download failed, code:", tostring(code), "url:", url)
        return nil, "http " .. tostring(code)
    end

    local content = table.concat(chunks)
    if #content == 0 then
        -- A 200 with no body is a failure, not an empty image. Treating it as
        -- success would put a zero-byte entry in the EPUB manifest.
        logger.warn("ImageManager: empty body for", url)
        return nil, "empty response body"
    end

    -- Content-Type is the authoritative source for the media type. The previous
    -- code guessed from the URL, which fails on Notion pre-signed URLs because
    -- they contain '/' inside the query string -- so every image was labelled jpg.
    local content_type
    if type(headers) == "table" then
        content_type = headers["content-type"] or headers["Content-Type"]
    end

    logger.dbg("ImageManager: fetched", #content, "bytes,", tostring(content_type))
    return content, content_type
end

function ImageManager:getStats()
    return self.stats
end

return ImageManager
