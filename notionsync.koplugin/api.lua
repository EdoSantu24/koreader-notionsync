local https = require("ssl.https")
local ltn12 = require("ltn12")
local socket = require("socket")
local socketutil = require("socketutil")
local rapidjson = require("rapidjson")
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

function NotionAPI:apiCall(method, endpoint, body)
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

    if code == 200 then
        local content = table.concat(sink)
        local ok, result = pcall(rapidjson.decode, content)
        if ok and result then
            return true, result
        else
            logger.warn("NotionAPI: JSON decode failed", content)
            return false, "Failed to parse response"
        end
    else
        local error_content = table.concat(sink)
        logger.warn("NotionAPI: HTTP error", code, error_content)

        -- Try to parse error message from Notion API
        local error_msg = "HTTP " .. tostring(code)
        local ok, error_json = pcall(rapidjson.decode, error_content)
        if ok and error_json and error_json.message then
            error_msg = error_json.message
        end

        return false, error_msg
    end
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

function NotionAPI:getBlockChildren(block_id)
    return self:apiCall("GET", "/v1/blocks/" .. block_id .. "/children?page_size=100")
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
