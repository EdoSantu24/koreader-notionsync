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

--------------------------------------------------------------------------------
-- pagination
--------------------------------------------------------------------------------

-- Builds a fetch function returning the given cursor pages in order, recording
-- the cursor it was called with each time.
local function paged(pages)
    local calls = {}
    local n = 0
    local fetch = function(cursor)
        n = n + 1
        calls[n] = cursor or false
        local page = pages[math.min(n, #pages)]
        if page.fail then return false, page.fail end
        return true, page
    end
    return fetch, calls
end

local function items(count, offset)
    local out = {}
    for i = 1, count do out[i] = { id = "id" .. ((offset or 0) + i) } end
    return out
end

describe("collectAll", function()
    it("returns_a_single_page_unchanged", function()
        local fetch = paged { { results = items(3), has_more = false } }
        local ok, out, truncated = API.collectAll(fetch)
        assert_true(ok)
        assert_eq(#out, 3)
        assert_false(truncated)
    end)

    it("follows_cursors_and_concatenates", function()
        local fetch, calls = paged {
            { results = items(2), has_more = true, next_cursor = "c1" },
            { results = items(2, 2), has_more = true, next_cursor = "c2" },
            { results = items(1, 4), has_more = false },
        }
        local ok, out = API.collectAll(fetch)
        assert_true(ok)
        assert_eq(#out, 5)
        assert_eq(calls[1], false, "first call takes no cursor")
        assert_eq(calls[2], "c1")
        assert_eq(calls[3], "c2")
    end)

    -- THE trap: rapidjson decodes JSON null to a lightuserdata sentinel, not nil,
    -- so a truthiness test on next_cursor is TRUE on the last page and spins until
    -- a cap stops it.
    it("stops_on_a_non_string_cursor", function()
        local NULL = setmetatable({}, {})
        local fetch, calls = paged {
            { results = items(2), has_more = false, next_cursor = NULL },
        }
        local ok, out, truncated = API.collectAll(fetch)
        assert_true(ok)
        assert_eq(#out, 2)
        assert_eq(#calls, 1, "a non-string cursor must end pagination")
        assert_false(truncated)
    end)

    it("stops_when_has_more_is_false_despite_a_cursor", function()
        local fetch, calls = paged {
            { results = items(1), has_more = false, next_cursor = "c1" },
        }
        API.collectAll(fetch)
        assert_eq(#calls, 1)
    end)

    it("stops_on_an_empty_string_cursor", function()
        local fetch, calls = paged {
            { results = items(1), has_more = true, next_cursor = "" },
        }
        API.collectAll(fetch)
        assert_eq(#calls, 1)
    end)

    -- A server that kept returning has_more with a fresh cursor would otherwise
    -- run until the battery died.
    it("has_an_absolute_request_backstop", function()
        local n = 0
        local ok, out, truncated = API.collectAll(function()
            n = n + 1
            return true, { results = items(1), has_more = true, next_cursor = "always" .. n }
        end)
        assert_true(ok)
        assert_eq(n, API.MAX_PAGINATION_REQUESTS)
        assert_true(truncated, "hitting the backstop must be reported")
        assert_true(#out > 0)
    end)

    it("respects_max_items_and_trims", function()
        local fetch = paged {
            { results = items(100), has_more = true, next_cursor = "c1" },
            { results = items(100, 100), has_more = true, next_cursor = "c2" },
        }
        local ok, out, truncated = API.collectAll(fetch, 150)
        assert_true(ok)
        assert_eq(#out, 150)
        assert_true(truncated)
    end)

    -- Reaching the cap exactly with nothing left is not truncation.
    it("does_not_claim_truncation_when_the_data_simply_ended", function()
        local fetch = paged { { results = items(50), has_more = false } }
        local ok, out, truncated = API.collectAll(fetch, 50)
        assert_true(ok)
        assert_eq(#out, 50)
        assert_false(truncated)
    end)

    it("treats_zero_max_items_as_unlimited", function()
        local fetch = paged {
            { results = items(10), has_more = true, next_cursor = "c1" },
            { results = items(10, 10), has_more = false },
        }
        local ok, out = API.collectAll(fetch, 0)
        assert_true(ok)
        assert_eq(#out, 20)
    end)

    it("propagates_a_failure", function()
        local fetch = paged { { fail = "unauthorized" } }
        local ok, err = API.collectAll(fetch)
        assert_false(ok)
        assert_contains(err, "unauthorized")
    end)

    it("propagates_a_failure_on_a_later_cursor_page", function()
        local fetch = paged {
            { results = items(1), has_more = true, next_cursor = "c1" },
            { fail = "HTTP 500" },
        }
        local ok, err = API.collectAll(fetch)
        assert_false(ok)
        assert_contains(err, "500")
    end)

    it("tolerates_a_page_with_no_results_field", function()
        local fetch = paged { { has_more = false } }
        local ok, out = API.collectAll(fetch)
        assert_true(ok)
        assert_eq(#out, 0)
    end)
end)

describe("query_body", function()
    local function capture_body(fn)
        local api = API:new("token")
        local seen
        api.apiCall = function(_, _, _, body) seen = body return true, { results = {} } end
        fn(api)
        return seen
    end

    it("requests_the_api_maximum_page_size", function()
        local body = capture_body(function(api) api:queryDatabase("db") end)
        assert_eq(body.page_size, 100)
    end)

    -- created_time, not last_edited_time: sorting on a mutable field while
    -- paginating lets a page edited mid-walk move between cursor pages and be
    -- skipped or returned twice.
    it("sorts_by_an_immutable_timestamp", function()
        local body = capture_body(function(api) api:queryDatabase("db") end)
        assert_eq(body.sorts[1].timestamp, "created_time")
        assert_eq(body.sorts[1].direction, "ascending")
    end)

    it("can_omit_the_sort", function()
        local body = capture_body(function(api)
            api:queryDatabase("db", nil, { no_sort = true })
        end)
        assert_eq(body.sorts, nil)
    end)

    it("passes_a_string_cursor", function()
        local body = capture_body(function(api) api:queryDatabase("db", "cur1") end)
        assert_eq(body.start_cursor, "cur1")
    end)

    it("ignores_a_non_string_cursor", function()
        local body = capture_body(function(api)
            api:queryDatabase("db", setmetatable({}, {}))
        end)
        assert_eq(body.start_cursor, nil)
    end)

    -- /v1/search's sort options are narrow and a wrong key is a 400 that would
    -- break the database picker outright, so no sort is sent.
    it("search_sends_no_sort", function()
        local body = capture_body(function(api) api:searchDatabases() end)
        assert_eq(body.sort, nil)
        assert_eq(body.sorts, nil)
        assert_eq(body.page_size, 100)
    end)
end)

describe("getAllPages_sort_fallback", function()
    -- The sort key is an assumption about the API. A rejected sort must not cost
    -- the entire database.
    it("retries_without_sorts_when_the_query_fails", function()
        local api = API:new("token")
        local bodies = {}
        api.apiCall = function(_, _, _, body)
            bodies[#bodies + 1] = body
            if body.sorts then return false, "sort is not valid" end
            return true, { results = { { id = "p1" } }, has_more = false }
        end

        local ok, pages = api:getAllPages("db")
        assert_true(ok, "a rejected sort must not fail the database")
        assert_eq(#pages, 1)
        assert_true(bodies[1].sorts ~= nil, "first attempt sorts")
        assert_eq(bodies[2].sorts, nil, "retry omits the sort")
    end)

    it("reports_the_original_error_when_the_retry_also_fails", function()
        local api = API:new("token")
        api.apiCall = function() return false, "unauthorized" end
        local ok, err = api:getAllPages("db")
        assert_false(ok)
        assert_contains(err, "unauthorized")
    end)

    it("does_not_retry_when_the_first_attempt_succeeds", function()
        local api = API:new("token")
        local calls = 0
        api.apiCall = function()
            calls = calls + 1
            return true, { results = {}, has_more = false }
        end
        api:getAllPages("db")
        assert_eq(calls, 1)
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
