--
-- Pins the CURRENT behaviour of converter.lua (Notion blocks -> Markdown).
--
-- Several assertions below deliberately assert *buggy* behaviour, each marked
-- with BUG. They exist so that the fix is visible as an intentional change to a
-- test rather than an unnoticed change in output. When the direct block -> XHTML
-- renderer lands, these move to the new renderer's spec and flip to the correct
-- expectation.
--

local h = require("spec.helper")
local C = h.load_plugin("converter")

local function rich(text, annotations, href)
    return { {
        plain_text = text,
        annotations = annotations,
        href = href,
    } }
end

describe("richtext", function()
    it("plain", function()
        assert_eq(C:richTextToMarkdown(rich("hello")), "hello")
    end)

    it("bold", function()
        assert_eq(C:richTextToMarkdown(rich("hi", { bold = true })), "**hi**")
    end)

    it("italic", function()
        assert_eq(C:richTextToMarkdown(rich("hi", { italic = true })), "*hi*")
    end)

    it("inline_code", function()
        assert_eq(C:richTextToMarkdown(rich("x", { code = true })), "`x`")
    end)

    it("link", function()
        assert_eq(C:richTextToMarkdown(rich("site", nil, "https://example.com")),
            "[site](https://example.com)")
    end)

    -- BUG: the vendored Markdown 1.0.1 parser has no `~~` handling at all, so
    -- this renders as literal tildes in the EPUB. README advertises it as working.
    it("strikethrough_emits_unsupported_syntax", function()
        assert_eq(C:richTextToMarkdown(rich("gone", { strikethrough = true })),
            "~~gone~~")
    end)

    it("concatenates_all_segments", function()
        local rt = {
            { plain_text = "Chapter " },
            { plain_text = "One", annotations = { bold = true } },
        }
        assert_eq(C:richTextToMarkdown(rt), "Chapter **One**")
    end)
end)

describe("blocks", function()
    it("paragraph", function()
        local b = { type = "paragraph", paragraph = { rich_text = rich("text") } }
        assert_eq(C:blockToMarkdown(b), "text\n\n")
    end)

    it("heading_1", function()
        local b = { type = "heading_1", heading_1 = { rich_text = rich("Title") } }
        assert_eq(C:blockToMarkdown(b), "# Title\n\n")
    end)

    it("bulleted_list_item", function()
        local b = {
            type = "bulleted_list_item",
            bulleted_list_item = { rich_text = rich("item") },
        }
        assert_eq(C:blockToMarkdown(b), "- item\n")
    end)

    it("divider", function()
        assert_eq(C:blockToMarkdown({ type = "divider" }), "---\n\n")
    end)

    it("quote", function()
        local b = { type = "quote", quote = { rich_text = rich("said") } }
        assert_eq(C:blockToMarkdown(b), "> said\n\n")
    end)

    -- BUG: emits a fenced code block, but the vendored parser only understands
    -- 4-space-indented code. The fence leaks into the EPUB as literal text and
    -- the body gets span-transformed as a paragraph.
    it("code_emits_unsupported_fence", function()
        local b = {
            type = "code",
            code = { rich_text = rich("print(1)"), language = "lua" },
        }
        assert_eq(C:blockToMarkdown(b), "```lua\nprint(1)\n```\n\n")
    end)

    -- BUG: emits literal [x]/[ ], which the parser renders as visible brackets.
    it("to_do_emits_literal_brackets", function()
        local b = { type = "to_do", to_do = { rich_text = rich("task"), checked = true } }
        assert_eq(C:blockToMarkdown(b), "- [x] task\n")
    end)

    it("image_external", function()
        local b = {
            type = "image",
            image = { type = "external", external = { url = "https://e.com/a.png" } },
        }
        assert_eq(C:blockToMarkdown(b), "![](https://e.com/a.png)\n\n")
    end)
end)

-- The headline content-loss bug: blockToMarkdown is a whitelist with no `else`,
-- so any type it does not know about returns "" and vanishes without a trace.
describe("silent_drops", function()
    local function assert_dropped(block)
        assert_eq(C:blockToMarkdown(block), "",
            block.type .. " is silently dropped")
    end

    it("table_vanishes", function()
        assert_dropped({ type = "table", table = { table_width = 2 } })
    end)

    it("table_row_vanishes", function()
        assert_dropped({ type = "table_row", table_row = { cells = { {}, {} } } })
    end)

    it("callout_vanishes_with_its_text", function()
        assert_dropped({ type = "callout", callout = { rich_text = rich("important") } })
    end)

    it("toggle_vanishes_with_its_text", function()
        assert_dropped({ type = "toggle", toggle = { rich_text = rich("details") } })
    end)

    it("column_list_vanishes", function()
        assert_dropped({ type = "column_list", column_list = {} })
    end)

    it("equation_vanishes", function()
        assert_dropped({ type = "equation", equation = { expression = "x^2" } })
    end)

    it("unknown_future_type_vanishes", function()
        assert_dropped({ type = "some_new_notion_block", some_new_notion_block = {} })
    end)

    it("nothing_is_logged_when_dropping", function()
        h.logger.reset()
        C:blockToMarkdown({ type = "callout", callout = { rich_text = rich("x") } })
        assert_eq(#h.logger.records, 0,
            "dropping a block currently produces no diagnostic at all")
    end)
end)

describe("images", function()
    it("extracts_external_and_file_urls", function()
        local blocks = {
            { type = "image", image = { type = "external", external = { url = "https://a/1.png" } } },
            { type = "paragraph", paragraph = { rich_text = rich("x") } },
            { type = "image", image = { type = "file", file = { url = "https://b/2.jpg" } } },
        }
        local urls = C:extractImageURLs(blocks)
        assert_eq(#urls, 2)
        assert_eq(urls[1], "https://a/1.png")
        assert_eq(urls[2], "https://b/2.jpg")
    end)

    -- Table rows, toggle bodies and column contents are *children* in the Notion
    -- API. Nothing in the plugin reads has_children, so images nested inside any
    -- container are never even discovered.
    it("does_not_find_images_nested_in_children", function()
        local blocks = { {
            type = "toggle",
            has_children = true,
            toggle = { rich_text = rich("open me") },
            children = {
                { type = "image", image = { type = "external", external = { url = "https://c/3.png" } } },
            },
        } }
        assert_eq(#C:extractImageURLs(blocks), 0)
    end)
end)
