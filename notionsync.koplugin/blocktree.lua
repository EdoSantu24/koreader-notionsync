--
-- Fetches a page's full block tree from Notion.
--
-- Notion stores nested content as *child blocks*, reachable only by another
-- request per parent. Without this, table rows, nested list levels and the bodies
-- of toggles, callouts, columns and synced blocks are all simply unavailable --
-- which is why the renderer had to show "[... not fetched]" placeholders.
--
-- The cost is real and is the reason for the caps below: a page goes from one
-- request to potentially dozens, over e-reader WiFi, against an API that rate
-- limits at roughly three requests per second.
--
-- Takes `api` as a parameter rather than requiring it, so the whole module can be
-- driven by a fake in tests with no network.
--
local logger = require("logger")

local BlockTree = {}

BlockTree.DEFAULT_MAX_DEPTH = 3
BlockTree.DEFAULT_REQUEST_BUDGET = 40

-- Containers that exist purely to hold other blocks. They must NOT consume a
-- depth level: a table would otherwise spend the whole allowance on structure and
-- arrive at max depth with no rows, and column_list -> column -> content would
-- burn two of three levels before reaching any text.
local STRUCTURAL = {
    table = true,
    column_list = true,
    column = true,
    synced_block = true,
}

-- A child page is a separate Notion page, not nested content. Recursing into one
-- would pull in an unbounded subtree, so these are referenced instead.
local NO_RECURSE = {
    child_page = true,
    child_database = true,
    link_to_page = true,
}

-- Collects every cursor page of one parent's children.
--
-- The cursor check is `type(cursor) == "string"`, not a truthiness test, and that
-- is load-bearing: KOReader's rapidjson decodes JSON `null` to a lightuserdata
-- sentinel rather than nil, so `if res.next_cursor then` is TRUE on the last page
-- and loops until the budget runs out.
local function fetch_children(api, block_id, meta, budget)
    local out = {}
    local cursor = nil

    while true do
        if meta.requests >= budget then
            meta.truncated = true
            return nil, "request budget exhausted"
        end

        meta.requests = meta.requests + 1
        local ok, res = api:getBlockChildren(block_id, cursor)
        if not ok then
            return nil, tostring(res)
        end

        for _, block in ipairs(res.results or {}) do
            out[#out + 1] = block
        end

        cursor = res.next_cursor
        if type(cursor) ~= "string" or cursor == "" then cursor = nil end
        if not res.has_more or not cursor then break end
    end

    return out
end

-- fetchPage(api, page_id, opts) -> blocks, meta
--
-- opts = {
--   max_depth       = 3,    how many levels of genuine nesting to follow
--   request_budget  = 40,   hard cap on API calls for this page
--   progress        = function(requests, queued) end,
--   should_abort    = function() return bool end,
-- }
--
-- On success, blocks is the top-level array with `children` attached in place, and
-- meta reports what was and was not reached. On a root-level failure blocks is
-- nil and meta.fatal explains why -- the caller must treat that as a failed page
-- rather than an empty one, or it would record an empty book as synced forever.
function BlockTree.fetchPage(api, page_id, opts)
    opts = opts or {}
    local max_depth = opts.max_depth or BlockTree.DEFAULT_MAX_DEPTH
    local budget = opts.request_budget or BlockTree.DEFAULT_REQUEST_BUDGET

    local meta = {
        requests = 0,
        truncated = false,     -- budget ran out; some children were not fetched
        depth_capped = false,  -- nesting deeper than max_depth was not followed
        aborted = false,
        errors = {},           -- per-block fetch failures; page still usable
        fatal = nil,
    }

    local root, err = fetch_children(api, page_id, meta, budget)
    if not root then
        meta.fatal = err
        return nil, meta
    end

    -- Breadth-first, with an explicit queue rather than recursion. Breadth-first
    -- matters when the budget runs out: it loses the DEEPEST content rather than
    -- everything after some arbitrary point in the page, so a long page degrades
    -- by flattening rather than by truncating.
    local queue = {}

    local function enqueue(blocks, depth)
        for _, block in ipairs(blocks) do
            if type(block) == "table" and block.has_children == true
                and not NO_RECURSE[block.type] then
                local next_depth = depth + (STRUCTURAL[block.type] and 0 or 1)
                if next_depth <= max_depth then
                    queue[#queue + 1] = { block = block, depth = next_depth }
                else
                    meta.depth_capped = true
                end
            end
        end
    end

    enqueue(root, 0)

    local expanded = 0
    local index = 1
    while index <= #queue do
        if opts.should_abort and opts.should_abort() then
            meta.aborted = true
            break
        end
        if meta.requests >= budget then
            meta.truncated = true
            break
        end

        local item = queue[index]
        index = index + 1

        expanded = expanded + 1
        local kids, ferr = fetch_children(api, item.block.id, meta, budget)
        if kids then
            item.block.children = kids
            enqueue(kids, item.depth)
        else
            -- One failed parent costs its own subtree, not the page. The block
            -- renders a visible placeholder and the count reaches the summary.
            meta.errors[#meta.errors + 1] = {
                id = item.block.id,
                type = item.block.type,
                reason = ferr,
            }
            logger.warn("NotionBlockTree: children unavailable for",
                tostring(item.block.type), tostring(item.block.id), "--", tostring(ferr))
        end

        if opts.progress then opts.progress(meta.requests, #queue) end
    end

    -- `expanded`, not #queue: the queue keeps growing as children are discovered,
    -- so reporting its length would claim parents were expanded that were never
    -- reached when the budget ran out. On a device where the log is the only
    -- diagnostic, a misleading count costs real debugging time.
    meta.expanded = expanded
    meta.queued = #queue

    logger.info(string.format(
        "NotionBlockTree: %d request(s), %d/%d parent(s) expanded%s%s",
        meta.requests, expanded, #queue,
        meta.truncated and ", BUDGET EXHAUSTED" or "",
        meta.depth_capped and ", depth capped" or ""))

    return root, meta
end

return BlockTree
