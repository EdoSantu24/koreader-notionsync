--
-- Child-block fetching.
--
-- Driven entirely by a fake api table, which is why blocktree.lua takes `api` as
-- a parameter instead of requiring it. No network, no KOReader.
--

local h = require("spec.helper")
local BlockTree = h.load_plugin("blocktree")

--------------------------------------------------------------------------------
-- fake api
--------------------------------------------------------------------------------

-- responses = { [block_id] = { {results=..., has_more=..., next_cursor=...}, ... } }
-- Each entry is the list of cursor pages returned for that parent, in order.
local function fake_api(responses, opts)
    opts = opts or {}
    return {
        calls = {},
        cursors = {},
        getBlockChildren = function(self, block_id, start_cursor)
            self.calls[#self.calls + 1] = block_id
            -- Keyed by call number, and `false` rather than nil for "no cursor":
            -- `t[#t + 1] = nil` is a no-op in Lua, which would silently shift
            -- every later index and make this record useless.
            self.cursors[#self.calls] = start_cursor or false

            if opts.fail_on and opts.fail_on[block_id] then
                return false, opts.fail_on[block_id]
            end

            local pages = responses[block_id]
            if not pages then
                return true, { results = {}, has_more = false }
            end

            -- Nth request for this parent returns its Nth cursor page.
            local n = 0
            for _, seen in ipairs(self.calls) do
                if seen == block_id then n = n + 1 end
            end
            return true, pages[math.min(n, #pages)]
        end,
    }
end

local function blk(id, btype, has_children)
    return { id = id, type = btype or "paragraph", has_children = has_children or false }
end

--------------------------------------------------------------------------------

describe("blocktree", function()
    it("returns_top_level_blocks", function()
        local api = fake_api {
            page = { { results = { blk("a"), blk("b") }, has_more = false } },
        }
        local blocks, meta = BlockTree.fetchPage(api, "page")
        assert_eq(#blocks, 2)
        assert_eq(meta.requests, 1)
        assert_false(meta.truncated)
    end)

    it("attaches_children_in_place", function()
        local api = fake_api {
            page = { { results = { blk("p1", "bulleted_list_item", true) }, has_more = false } },
            p1 = { { results = { blk("c1"), blk("c2") }, has_more = false } },
        }
        local blocks = BlockTree.fetchPage(api, "page")
        assert_eq(#blocks[1].children, 2)
        assert_eq(blocks[1].children[1].id, "c1")
    end)

    it("does_not_request_children_when_has_children_is_false", function()
        local api = fake_api {
            page = { { results = { blk("a", "paragraph", false) }, has_more = false } },
        }
        BlockTree.fetchPage(api, "page")
        assert_eq(#api.calls, 1, "only the page itself should be requested")
    end)

    it("recurses_to_multiple_levels", function()
        local api = fake_api {
            page = { { results = { blk("l1", "bulleted_list_item", true) }, has_more = false } },
            l1 = { { results = { blk("l2", "bulleted_list_item", true) }, has_more = false } },
            l2 = { { results = { blk("l3", "bulleted_list_item", false) }, has_more = false } },
        }
        local blocks = BlockTree.fetchPage(api, "page", { max_depth = 3 })
        assert_eq(blocks[1].children[1].id, "l2")
        assert_eq(blocks[1].children[1].children[1].id, "l3")
    end)
end)

describe("blocktree_pagination", function()
    it("follows_next_cursor", function()
        local api = fake_api {
            page = {
                { results = { blk("a") }, has_more = true, next_cursor = "cur1" },
                { results = { blk("b") }, has_more = false },
            },
        }
        local blocks, meta = BlockTree.fetchPage(api, "page")
        assert_eq(#blocks, 2)
        assert_eq(meta.requests, 2)
        assert_eq(api.cursors[2], "cur1", "the cursor must be passed on the second call")
    end)

    -- KOReader's rapidjson decodes JSON null to a lightuserdata sentinel, not nil,
    -- so a truthiness test on next_cursor is TRUE on the last page and spins until
    -- the budget runs out. This fixture reproduces that exact shape.
    it("stops_on_a_null_sentinel_cursor", function()
        -- rapidjson's real sentinel is lightuserdata; any non-string value
        -- exercises the same guard, and a table avoids a deprecated API here.
        local NULL = setmetatable({}, { __tostring = function() return "null" end })
        local api = fake_api {
            page = {
                { results = { blk("a") }, has_more = false, next_cursor = NULL },
            },
        }
        local blocks, meta = BlockTree.fetchPage(api, "page")
        assert_eq(#blocks, 1)
        assert_eq(meta.requests, 1, "a non-string cursor must end pagination")
        assert_false(meta.truncated)
    end)

    it("stops_when_has_more_is_false_even_with_a_cursor", function()
        local api = fake_api {
            page = { { results = { blk("a") }, has_more = false, next_cursor = "cur1" } },
        }
        local _, meta = BlockTree.fetchPage(api, "page")
        assert_eq(meta.requests, 1)
    end)
end)

describe("blocktree_limits", function()
    it("respects_the_request_budget", function()
        local responses = { page = { { results = {}, has_more = false } } }
        local kids = {}
        for i = 1, 20 do
            local id = "p" .. i
            kids[#kids + 1] = blk(id, "bulleted_list_item", true)
            responses[id] = { { results = { blk("leaf" .. i) }, has_more = false } }
        end
        responses.page = { { results = kids, has_more = false } }

        local api = fake_api(responses)
        local blocks, meta = BlockTree.fetchPage(api, "page", { request_budget = 5 })
        assert_true(blocks ~= nil)
        assert_true(meta.requests <= 5, "budget exceeded: " .. meta.requests)
        assert_true(meta.truncated, "hitting the budget must be reported")
    end)

    it("caps_depth_and_reports_it", function()
        local api = fake_api {
            page = { { results = { blk("l1", "bulleted_list_item", true) }, has_more = false } },
            l1 = { { results = { blk("l2", "bulleted_list_item", true) }, has_more = false } },
            l2 = { { results = { blk("l3", "bulleted_list_item", true) }, has_more = false } },
        }
        local blocks, meta = BlockTree.fetchPage(api, "page", { max_depth = 1 })
        assert_eq(blocks[1].children[1].id, "l2")
        assert_eq(blocks[1].children[1].children, nil, "depth 2 must not be fetched")
        assert_true(meta.depth_capped)
    end)

    -- A table would otherwise spend its whole depth allowance on structure and
    -- arrive with no rows, which is the entire point of fetching children.
    it("structural_containers_do_not_consume_depth", function()
        local api = fake_api {
            page = { { results = { blk("t", "table", true) }, has_more = false } },
            t = { { results = { blk("r1", "table_row", false) }, has_more = false } },
        }
        local blocks, meta = BlockTree.fetchPage(api, "page", { max_depth = 1 })
        assert_eq(#blocks[1].children, 1, "table rows must be fetched at max_depth 1")
        assert_eq(blocks[1].children[1].type, "table_row")
        assert_false(meta.depth_capped)
    end)

    it("column_list_to_column_to_content_survives_depth_one", function()
        local api = fake_api {
            page = { { results = { blk("cl", "column_list", true) }, has_more = false } },
            cl = { { results = { blk("c1", "column", true) }, has_more = false } },
            c1 = { { results = { blk("txt", "paragraph", false) }, has_more = false } },
        }
        local blocks = BlockTree.fetchPage(api, "page", { max_depth = 1 })
        assert_eq(blocks[1].children[1].children[1].id, "txt")
    end)

    -- A child page is a separate document; recursing would pull an unbounded
    -- subtree into one book.
    it("never_recurses_into_a_child_page", function()
        local api = fake_api {
            page = { { results = { blk("cp", "child_page", true) }, has_more = false } },
            cp = { { results = { blk("deep") }, has_more = false } },
        }
        local blocks = BlockTree.fetchPage(api, "page")
        assert_eq(blocks[1].children, nil)
        assert_eq(#api.calls, 1)
    end)
end)

describe("blocktree_failures", function()
    -- The page must still be usable: one unreachable parent costs its own subtree,
    -- not the whole document.
    it("a_child_fetch_failure_is_recorded_not_fatal", function()
        local api = fake_api({
            page = {
                { results = {
                    blk("good", "bulleted_list_item", true),
                    blk("bad", "bulleted_list_item", true),
                }, has_more = false },
            },
            good = { { results = { blk("g1") }, has_more = false } },
        }, { fail_on = { bad = "HTTP 500" } })

        local blocks, meta = BlockTree.fetchPage(api, "page")
        assert_true(blocks ~= nil, "the page must survive one failed subtree")
        assert_eq(#blocks[1].children, 1)
        assert_eq(blocks[2].children, nil)
        assert_eq(#meta.errors, 1)
        assert_eq(meta.errors[1].id, "bad")
        assert_contains(meta.errors[1].reason, "500")
    end)

    -- The opposite case: if the page's own blocks cannot be read there is no
    -- content at all, and writing a title-only book would freeze that emptiness
    -- in place because the caller records success permanently.
    it("a_root_fetch_failure_is_fatal", function()
        local api = fake_api({}, { fail_on = { page = "unauthorized" } })
        local blocks, meta = BlockTree.fetchPage(api, "page")
        assert_eq(blocks, nil)
        assert_contains(meta.fatal, "unauthorized")
    end)

    it("aborts_when_asked", function()
        local responses = {}
        local kids = {}
        for i = 1, 10 do
            local id = "p" .. i
            kids[#kids + 1] = blk(id, "bulleted_list_item", true)
            responses[id] = { { results = { blk("leaf" .. i) }, has_more = false } }
        end
        responses.page = { { results = kids, has_more = false } }

        local api = fake_api(responses)
        local _, meta = BlockTree.fetchPage(api, "page", {
            should_abort = function() return true end,
        })
        assert_true(meta.aborted)
        assert_eq(meta.requests, 1, "abort must be checked before any child request")
    end)

    it("reports_progress", function()
        local api = fake_api {
            page = { { results = { blk("p1", "bulleted_list_item", true) }, has_more = false } },
            p1 = { { results = { blk("c") }, has_more = false } },
        }
        local seen = 0
        BlockTree.fetchPage(api, "page", {
            progress = function() seen = seen + 1 end,
        })
        assert_true(seen > 0)
    end)
end)

--------------------------------------------------------------------------------
-- integration with the renderer
--------------------------------------------------------------------------------

describe("blocktree_renders", function()
    local X = h.load_plugin("xhtml")

    -- The end-to-end point of this change: a table fetched through blocktree must
    -- render as a real table, where before it showed a placeholder.
    it("a_fetched_table_renders_rows_instead_of_a_placeholder", function()
        local function cell(text) return { { plain_text = text } } end
        local api = fake_api {
            page = { { results = {
                { id = "t", type = "table", has_children = true,
                  table = { table_width = 2, has_column_header = true } },
            }, has_more = false } },
            t = { { results = {
                { id = "r1", type = "table_row",
                  table_row = { cells = { cell("H1"), cell("H2") } } },
                { id = "r2", type = "table_row",
                  table_row = { cells = { cell("v1"), cell("v2") } } },
            }, has_more = false } },
        }

        local blocks = BlockTree.fetchPage(api, "page")
        local ctx = X.newContext()
        local out = X.renderBlocks(blocks, ctx, 0)

        assert_contains(out, "<th>H1</th>")
        assert_contains(out, "<td>v1</td>")
        assert_not_contains(out, "table rows not fetched")
        assert_eq(ctx.placeholders, 0)
    end)

    it("a_fetched_sublist_renders_nested", function()
        local api = fake_api {
            page = { { results = {
                { id = "b1", type = "bulleted_list_item", has_children = true,
                  bulleted_list_item = { rich_text = { { plain_text = "outer" } } } },
            }, has_more = false } },
            b1 = { { results = {
                { id = "b2", type = "bulleted_list_item", has_children = false,
                  bulleted_list_item = { rich_text = { { plain_text = "inner" } } } },
            }, has_more = false } },
        }

        local blocks = BlockTree.fetchPage(api, "page")
        local ctx = X.newContext()
        local out = X.renderBlocks(blocks, ctx, 0)

        assert_contains(out, "outer")
        assert_contains(out, "inner")
        assert_not_contains(out, "nested content not fetched")
        local ok, err = h.check_xml("<body>" .. out .. "</body>")
        assert_true(ok, tostring(err))
    end)

    -- Images inside nested blocks were previously invisible to the downloader.
    it("images_inside_children_are_discovered", function()
        local api = fake_api {
            page = { { results = {
                { id = "tg", type = "toggle", has_children = true,
                  toggle = { rich_text = { { plain_text = "t" } } } },
            }, has_more = false } },
            tg = { { results = {
                { id = "im", type = "image",
                  image = { type = "file", file = { url = "https://s3/nested.png" } } },
            }, has_more = false } },
        }
        local blocks = BlockTree.fetchPage(api, "page")
        local urls = X.collectImageURLs(blocks)
        assert_eq(#urls, 1)
        assert_eq(urls[1], "https://s3/nested.png")
    end)
end)
