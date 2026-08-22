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

-- socket.sleep BLOCKS KOReader's event loop, and there is currently no way to
-- cancel a running sync. Without a ceiling, a rate-limited page could retry 40
-- requests x 3s of backoff and freeze the device for minutes with no escape, so
-- total sleep is capped per sync. Once spent, requests still happen -- they just
-- stop waiting between attempts.
NotionAPI.MAX_TOTAL_RETRY_SLEEP = 20

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

-- Note on retrying POSTs: /v1/search and /v1/databases/{id}/query are POST by
-- API design but are read-only queries, so replaying one has no side effect.
function NotionAPI:apiCall(method, endpoint, body)
    local code, sink

    for attempt = 1, self.MAX_ATTEMPTS do
        code, sink = self:requestOnce(method, endpoint, body)
        if not NotionAPI.isRetryable(code) then break end

        if attempt < self.MAX_ATTEMPTS then
            local spent = self.retry_sleep_spent or 0
            local delay = math.min(attempt, self.MAX_TOTAL_RETRY_SLEEP - spent)
            if delay > 0 then
                self.retry_sleep_spent = spent + delay
                logger.warn("NotionAPI:", tostring(code), "on", endpoint,
                    "-- retrying in", delay, "s")
                -- Notion's Retry-After is deliberately not honoured: it can be
                -- tens of seconds, and blocking an e-reader that long is worse
                -- than reporting the failure. Logged so it is at least visible.
                socket.sleep(delay)
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
    return false, error_msg
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

function NotionAPI:searchDatabases()
    local body = {
        filter = {
            property = "object",
            value = "database",
        },
        page_size = 20,
    }

    return self:apiCall("POST", "/v1/search", body)
end

function NotionAPI:queryDatabase(database_id, page_size)
    local body = {
        page_size = page_size or 20,
    }

    return self:apiCall("POST", "/v1/databases/" .. database_id .. "/query", body)
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

function NotionAPI:getDatabaseTitle(database)
    if database.title and #database.title > 0 and database.title[1].plain_text then
        return database.title[1].plain_text
    end
    return "Untitled"
end

function NotionAPI:getPageTitle(page)
    local title = "Untitled"

    if page.properties then
        for _, prop_value in pairs(page.properties) do
            if prop_value.type == "title" and prop_value.title and #prop_value.title > 0 then
                title = prop_value.title[1].plain_text or title
                break
            end
        end
    end

    return title
end

return NotionAPI
