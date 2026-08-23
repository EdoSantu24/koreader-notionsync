local https = require("ssl.https")
local ltn12 = require("ltn12")
local socket = require("socket")
local socketutil = require("socketutil")
local rapidjson = require("rapidjson")
local util = require("util")
local logger = require("logger")

local NotionAPI = {
    API_BASE_URL = "https://api.notion.com",
    NOTION_VERSION = "2022-06-28",
}

function NotionAPI:new(token)
    local o = {
        token = token,
    }
    setmetatable(o, self)
    self.__index = self
    return o
end

-- Notion allows roughly three requests per second. Fetching a page's nested
-- blocks costs one request per parent, so a content-heavy page can breach that
-- easily and a bare failure would silently cost a table or a whole subtree.
NotionAPI.MAX_ATTEMPTS = 3

-- Two ceilings, because the tolerable wait depends entirely on whether the user
-- can escape it.
--
-- With an abort hook installed (a sync, via runSyncLoop) the backoff is sliced
-- and cancellable, so the cap only bounds total slowness and can afford to be
-- generous. Without one the wait is exactly as uninterruptible as it always was,
-- and the original conservative ceiling still applies: getAllDatabases is called
-- from the database picker with no hook and no Trapper widget to dismiss, so
-- using the larger cap there would have TRIPLED the worst-case frozen UI -- the
-- precise thing the 20s value existed to prevent.
NotionAPI.MAX_TOTAL_RETRY_SLEEP = 60
NotionAPI.MAX_TOTAL_RETRY_SLEEP_UNCANCELLABLE = 20

-- socket.sleep blocks KOReader's event loop for its entire duration: nothing
-- repaints, and Trapper never sees a dismiss tap, which on e-ink is
-- indistinguishable from a hang. Sleeping in slices and calling back between
-- them keeps both alive. 0.25s is short enough to feel responsive and long
-- enough that the callback -- a time-throttled repaint -- is not run wastefully.
-- A power of two, so subtracting it from an integer delay cannot accumulate
-- floating-point drift and leave the loop one slice short.
NotionAPI.SLEEP_SLICE = 0.25

-- Whether a failure is worth another attempt. Exposed rather than local so the
-- retry policy is testable: it governs every network call the plugin makes, and
-- none of that can be exercised on a dev machine.
function NotionAPI.isRetryable(code)
    if code == 429 then return true end            -- rate limited
    if type(code) ~= "number" then return true end -- socket-level failure
    return code >= 500 and code < 600              -- transient server error
end

-- Called at the start of each sync so the sleep ceiling is per-sync rather than
-- per plugin session.
function NotionAPI:resetRetryBudget()
    self.retry_sleep_spent = 0
end

-- Sleeps for `seconds` in SLEEP_SLICE chunks, consulting should_abort between
-- them. Returns false if the wait was cut short, so the caller can abandon the
-- retry rather than merely stop waiting for it -- a cancelled sync should not
-- spend another request.
--
-- should_abort is optional by design. Paths with no sync in progress (the
-- database picker) leave it unset and sleep uninterrupted, exactly as before.
function NotionAPI:waitFor(seconds)
    local remaining = seconds or 0
    while remaining > 0 do
        if self.should_abort and self.should_abort() then return false end
        local slice = remaining
        if slice > self.SLEEP_SLICE then slice = self.SLEEP_SLICE end
        socket.sleep(slice)
        remaining = remaining - slice
    end
    -- Checked once more on the way out, so a cancel arriving during the final
    -- slice is not answered with another attempt.
    return not (self.should_abort and self.should_abort())
end

-- Note on retrying POSTs: /v1/search and /v1/databases/{id}/query are POST by
-- API design but are read-only queries, so replaying one has no side effect.
function NotionAPI:apiCall(method, endpoint, body)
    local code, sink

    for attempt = 1, self.MAX_ATTEMPTS do
        code, sink = self:requestOnce(method, endpoint, body)
        if not NotionAPI.isRetryable(code) then break end

        if attempt < self.MAX_ATTEMPTS then
            local spent = self.retry_sleep_spent or 0
            -- Written as a statement, not `cond and a or b`: that idiom has
            -- already shipped a bug in this codebase, and it is only safe while
            -- the middle value stays truthy.
            local ceiling = self.MAX_TOTAL_RETRY_SLEEP_UNCANCELLABLE
            if self.should_abort then ceiling = self.MAX_TOTAL_RETRY_SLEEP end
            local delay = math.min(attempt, ceiling - spent)
            if delay > 0 then
                self.retry_sleep_spent = spent + delay
                logger.warn("NotionAPI:", tostring(code), "on", endpoint,
                    "-- retrying in", delay, "s")
                -- Notion's Retry-After is deliberately not honoured: it can be
                -- tens of seconds, and making an e-reader wait that long is
                -- worse than reporting the failure. Logged so it stays visible.
                if not self:waitFor(delay) then
                    logger.info("NotionAPI: cancelled while waiting to retry")
                    break
                end
            else
                logger.warn("NotionAPI:", tostring(code), "on", endpoint,
                    "-- retry sleep budget spent, retrying immediately")
            end
        end
    end

    if code == 200 then
        local content = table.concat(sink)
        local ok, result = pcall(rapidjson.decode, content)
        if ok and result then
            return true, result
        else
            logger.warn("NotionAPI: JSON decode failed", content)
            return false, "Failed to parse response"
        end
    end

    local error_content = table.concat(sink or {})
    logger.warn("NotionAPI: HTTP error", code, error_content)

    local error_msg = "HTTP " .. tostring(code)
    local ok, error_json = pcall(rapidjson.decode, error_content)
    if ok and error_json and error_json.message then
        error_msg = error_json.message
    end
    -- The code is returned as a third value so callers can distinguish a
    -- malformed request from an auth or server problem. Existing two-value call
    -- sites are unaffected.
    return false, error_msg, code
end

-- One HTTP attempt. Returns code, sink_table.
function NotionAPI:requestOnce(method, endpoint, body)
    local url = self.API_BASE_URL .. endpoint
    local headers = {
        ["Authorization"] = "Bearer " .. self.token,
        ["Notion-Version"] = self.NOTION_VERSION,
        ["Content-Type"] = "application/json",
    }

    local request_body = body and rapidjson.encode(body) or nil
    local sink = {}

    local request = {
        method = method,
        url = url,
        headers = headers,
        sink = ltn12.sink.table(sink),
        protocol = "tlsv1_2",
    }

    if request_body then
        request.source = ltn12.source.string(request_body)
        request.headers["Content-Length"] = tostring(#request_body)
    end

    socketutil:set_timeout(socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT)

    local code = socket.skip(1, https.request(request))

    socketutil:reset_timeout()

    return code, sink
end

-- 100 is the API maximum. The previous value of 20 was also a hard stop, because
-- no cursor was ever followed: only the first 20 databases and the first 20 pages
-- of each existed as far as the plugin was concerned.
NotionAPI.PAGE_SIZE = 100

-- Absolute backstop on one pagination walk, independent of any user setting. A
-- server that kept returning has_more with a fresh cursor would otherwise loop
-- until the device ran out of battery.
NotionAPI.MAX_PAGINATION_REQUESTS = 50

function NotionAPI:searchDatabases(start_cursor)
    local body = {
        filter = {
            property = "object",
            value = "database",
        },
        page_size = self.PAGE_SIZE,
    }
    if type(start_cursor) == "string" and start_cursor ~= "" then
        body.start_cursor = start_cursor
    end
    -- Deliberately no sort. /v1/search takes `sort` (singular) with a restricted
    -- set of timestamps, and getting that wrong is a 400 that would break the
    -- database picker entirely. The picker sorts by name client-side instead,
    -- which costs nothing and cannot fail.
    return self:apiCall("POST", "/v1/search", body)
end

function NotionAPI:queryDatabase(database_id, start_cursor, opts)
    opts = opts or {}
    local body = {
        page_size = self.PAGE_SIZE,
    }
    if type(start_cursor) == "string" and start_cursor ~= "" then
        body.start_cursor = start_cursor
    end
    if not opts.no_sort then
        -- created_time, NOT last_edited_time. Sorting on a mutable field while
        -- paginating is unstable: a page edited between two cursor requests moves
        -- within the result set and is then skipped or returned twice. Change
        -- detection reads each page's own last_edited_time instead.
        body.sorts = { { timestamp = "created_time", direction = "ascending" } }
    end
    return self:apiCall("POST", "/v1/databases/" .. database_id .. "/query", body)
end

-- Walks every cursor page of a paginated endpoint.
--
-- fetch(cursor) -> ok, result, code
-- Returns ok, items, truncated  (or false, error_message, nil, code)
--
-- The cursor guard is `type(cursor) == "string"`, not a truthiness test, and that
-- is the whole reason this is a shared function: KOReader's rapidjson decodes JSON
-- `null` to a lightuserdata sentinel rather than nil, so `if res.next_cursor then`
-- is TRUE on the last page and spins until a cap stops it.
function NotionAPI.collectAll(fetch, max_items)
    local out = {}
    local cursor = nil
    local requests = 0
    local truncated = false

    while true do
        if requests >= NotionAPI.MAX_PAGINATION_REQUESTS then
            logger.warn("NotionAPI: pagination hit the request backstop")
            truncated = true
            break
        end
        requests = requests + 1

        local ok, res, code = fetch(cursor)
        if not ok then return false, res, nil, code end

        for _, item in ipairs(res.results or {}) do
            out[#out + 1] = item
        end

        local had_more = res.has_more == true

        if max_items and max_items > 0 and #out >= max_items then
            local trimmed = #out > max_items
            for i = #out, max_items + 1, -1 do
                out[i] = nil
            end
            truncated = trimmed or had_more
            break
        end

        cursor = res.next_cursor
        if type(cursor) ~= "string" or cursor == "" then cursor = nil end
        if not had_more or not cursor then break end
    end

    return true, out, truncated
end

function NotionAPI:getAllDatabases(max_items)
    return NotionAPI.collectAll(function(cursor)
        return self:searchDatabases(cursor)
    end, max_items)
end

-- max_items of nil or 0 means "no limit beyond the request backstop".
function NotionAPI:getAllPages(database_id, max_items)
    local ok, items, truncated, code = NotionAPI.collectAll(function(cursor)
        return self:queryDatabase(database_id, cursor)
    end, max_items)

    if ok then return ok, items, truncated end

    -- The sort key is an assumption about the API, and a rejected sort would
    -- otherwise cost the entire database -- so it is retried without one.
    --
    -- Only for a 400 though. Retrying an auth or server error would double the
    -- request count for no possible benefit, and it compounds: apiCall already
    -- makes up to three attempts with backoff for retryable codes, so a blanket
    -- retry here could mean six requests and twice the sleep budget per database.
    if code ~= 400 then return false, items end

    local first_error = items
    logger.warn("NotionAPI: request rejected, retrying without sorts:", tostring(first_error))

    local retry_ok, retry_items, retry_truncated = NotionAPI.collectAll(function(cursor)
        return self:queryDatabase(database_id, cursor, { no_sort = true })
    end, max_items)

    if retry_ok then
        logger.warn("NotionAPI: the API rejected the sort; page order is now unstable")
        return true, retry_items, retry_truncated
    end
    return false, first_error
end

function NotionAPI:getBlockChildren(block_id, start_cursor)
    local endpoint = "/v1/blocks/" .. block_id .. "/children?page_size=100"
    if type(start_cursor) == "string" and start_cursor ~= "" then
        -- Notion's cursors are opaque and can contain characters that are not
        -- safe in a query string, so they must be encoded.
        endpoint = endpoint .. "&start_cursor=" .. util.urlEncode(start_cursor)
    end
    return self:apiCall("GET", endpoint)
end

-- Notion splits a title into a separate rich-text object at every formatting or
-- mention boundary, so reading only [1] truncated at the first one: a page titled
-- "Chapter **One**" came back as "Chapter ".
function NotionAPI.plainText(rich_text)
    if type(rich_text) ~= "table" then return "" end
    local parts = {}
    for i = 1, #rich_text do
        local segment = rich_text[i]
        if type(segment) == "table" then
            if type(segment.plain_text) == "string" then
                parts[#parts + 1] = segment.plain_text
            elseif type(segment.text) == "table"
                and type(segment.text.content) == "string" then
                parts[#parts + 1] = segment.text.content
            end
        end
    end
    return table.concat(parts)
end

function NotionAPI:getDatabaseTitle(database)
    local title = NotionAPI.plainText(database and database.title)
    if title ~= "" then return title end
    return "Untitled"
end

function NotionAPI:getPageTitle(page)
    if page and type(page.properties) == "table" then
        for _, prop_value in pairs(page.properties) do
            if type(prop_value) == "table" and prop_value.type == "title" then
                local title = NotionAPI.plainText(prop_value.title)
                if title ~= "" then return title end
            end
        end
    end
    return "Untitled"
end

return NotionAPI
