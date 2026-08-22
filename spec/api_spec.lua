--
-- Retry policy.
--
-- api.lua cannot be exercised end to end off-device (it needs ssl.https), but the
-- predicate deciding what gets retried governs every network call the plugin
-- makes, so it is worth testing on its own. Getting it wrong is expensive in both
-- directions: retrying a 401 wastes the user's time on a failure that will never
-- resolve, and not retrying a 429 silently loses a table or a whole subtree.
--

local h = require("spec.helper")
local API = h.load_plugin("api")

describe("isRetryable", function()
    it("retries_rate_limiting", function()
        assert_true(API.isRetryable(429))
    end)

    it("retries_server_errors", function()
        assert_true(API.isRetryable(500))
        assert_true(API.isRetryable(502))
        assert_true(API.isRetryable(503))
        assert_true(API.isRetryable(599))
    end)

    -- LuaSocket returns an error string rather than a number for socket-level
    -- failures, which is the "Operation already in progress" class seen against
    -- Notion's S3 host.
    it("retries_socket_level_failures", function()
        assert_true(API.isRetryable("Operation already in progress"))
        assert_true(API.isRetryable("timeout"))
        assert_true(API.isRetryable(nil))
    end)

    it("does_not_retry_success", function()
        assert_false(API.isRetryable(200))
    end)

    -- These will never resolve by retrying, and retrying them would make a wrong
    -- token or a deleted page take three times as long to report.
    it("does_not_retry_client_errors", function()
        assert_false(API.isRetryable(400))
        assert_false(API.isRetryable(401))
        assert_false(API.isRetryable(403))
        assert_false(API.isRetryable(404))
    end)

    it("does_not_retry_above_the_5xx_range", function()
        assert_false(API.isRetryable(600))
    end)
end)

describe("retry_budget", function()
    -- socket.sleep blocks KOReader's event loop and there is no way to cancel a
    -- running sync, so the total backoff has to be bounded. Without the cap, a
    -- rate-limited page could sleep 40 requests x 3s and freeze the device.
    it("is_reset_per_sync", function()
        local api = API:new("token")
        api.retry_sleep_spent = 15
        api:resetRetryBudget()
        assert_eq(api.retry_sleep_spent, 0)
    end)

    it("has_a_ceiling_low_enough_to_stay_usable", function()
        assert_true(API.MAX_TOTAL_RETRY_SLEEP <= 30,
            "a blocking sleep budget above ~30s is not acceptable with no cancel")
        assert_true(API.MAX_TOTAL_RETRY_SLEEP > 0)
    end)

    it("attempts_are_bounded", function()
        assert_true(API.MAX_ATTEMPTS >= 2 and API.MAX_ATTEMPTS <= 4)
    end)
end)

-- Notion splits a title into a separate rich-text object at every formatting or
-- mention boundary, so reading only [1] truncated the title there.
describe("titles", function()
    local function title_prop(segments)
        return { properties = { Name = { type = "title", title = segments } } }
    end

    it("concatenates_all_segments", function()
        local page = title_prop {
            { plain_text = "Chapter " },
            { plain_text = "One", annotations = { bold = true } },
        }
        assert_eq(API:getPageTitle(page), "Chapter One")
    end)

    it("survives_a_mention_in_the_middle", function()
        local page = title_prop {
            { plain_text = "Meeting with " },
            { plain_text = "Alice", type = "mention" },
            { plain_text = " on Monday" },
        }
        assert_eq(API:getPageTitle(page), "Meeting with Alice on Monday")
    end)

    it("keeps_non_ascii_intact", function()
        assert_eq(API:getPageTitle(title_prop { { plain_text = "读书笔记" } }), "读书笔记")
    end)

    it("falls_back_to_text_content", function()
        local page = title_prop { { text = { content = "inner" } } }
        assert_eq(API:getPageTitle(page), "inner")
    end)

    it("finds_the_title_property_whatever_it_is_named", function()
        local page = { properties = {
            Tags = { type = "multi_select" },
            ["My Heading"] = { type = "title", title = { { plain_text = "Found" } } },
        } }
        assert_eq(API:getPageTitle(page), "Found")
    end)

    it("returns_untitled_when_there_is_nothing_usable", function()
        assert_eq(API:getPageTitle({ properties = {} }), "Untitled")
        assert_eq(API:getPageTitle({}), "Untitled")
        assert_eq(API:getPageTitle(nil), "Untitled")
        assert_eq(API:getPageTitle(title_prop {}), "Untitled")
    end)

    it("database_titles_concatenate_too", function()
        local db = { title = { { plain_text = "Reading " }, { plain_text = "List" } } }
        assert_eq(API:getDatabaseTitle(db), "Reading List")
    end)

    it("database_title_falls_back", function()
        assert_eq(API:getDatabaseTitle({}), "Untitled")
        assert_eq(API:getDatabaseTitle(nil), "Untitled")
    end)
end)

describe("getBlockChildren_endpoint", function()
    -- Verifies the request URL without any network: apiCall is replaced with a
    -- recorder, which is enough to pin cursor handling.
    local function capture(block_id, cursor)
        local api = API:new("token")
        local seen
        api.apiCall = function(_, method, endpoint) seen = { method, endpoint } return true, {} end
        api:getBlockChildren(block_id, cursor)
        return seen
    end

    it("requests_the_max_page_size", function()
        local seen = capture("abc")
        assert_eq(seen[1], "GET")
        assert_contains(seen[2], "/v1/blocks/abc/children")
        assert_contains(seen[2], "page_size=100")
    end)

    it("omits_the_cursor_when_absent", function()
        assert_not_contains(capture("abc")[2], "start_cursor")
    end)

    it("includes_and_encodes_a_cursor", function()
        local seen = capture("abc", "cur/with+special=chars")
        assert_contains(seen[2], "start_cursor=")
        -- Raw '/' and '+' in a query value would be misparsed by the server.
        assert_not_contains(seen[2], "cur/with+special=chars")
        assert_contains(seen[2], "%2F")
    end)

    -- rapidjson decodes JSON null to a sentinel, so a non-string must be treated
    -- as "no cursor" rather than concatenated into the URL.
    it("ignores_a_non_string_cursor", function()
        local seen = capture("abc", setmetatable({}, {}))
        assert_not_contains(seen[2], "start_cursor")
    end)

    it("ignores_an_empty_cursor", function()
        assert_not_contains(capture("abc", "")[2], "start_cursor")
    end)
end)
