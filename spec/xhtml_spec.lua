--
-- Tests for the direct Notion-blocks -> XHTML renderer.
--
-- The two tests that matter most are at the bottom:
--
--   completeness.* -- every plain_text in the input must appear in the output.
--     This is the executable form of "all text must reach the EPUB", and it is
--     what would have caught the vanishing tables, callouts and toggles.
--
--   wellformed.*   -- the output must parse as XML. crengine silently truncates
--     a malformed document, which presents as "content randomly missing".
--

local h = require("spec.helper")
local X = h.load_plugin("xhtml")

--------------------------------------------------------------------------------
-- helpers
--------------------------------------------------------------------------------

local function rt(text, annotations, href)
    return { { plain_text = text, annotations = annotations, href = href } }
end

local function block(btype, payload, extra)
    local b = { type = btype, id = btype .. "-id" }
    b[btype] = payload
    if extra then
        for k, v in pairs(extra) do b[k] = v end
    end
    return b
end

local function render(blocks, image_map)
    local ctx = X.newContext(image_map)
    return X.renderBlocks(blocks, ctx, 0), ctx
end

--------------------------------------------------------------------------------
-- escaping
--------------------------------------------------------------------------------

describe("escape", function()
    it("ampersand_first_no_double_escape", function()
        assert_eq(X.escapeText("a & b < c"), "a &amp; b &lt; c")
        assert_not_contains(X.escapeText("<"), "&amp;lt;")
    end)

    it("text_leaves_quotes_alone", function()
        assert_eq(X.escapeText('say "hi"'), 'say "hi"')
    end)

    it("attr_escapes_both_quote_kinds", function()
        assert_eq(X.escapeAttr([[a"b'c]]), "a&quot;b&#39;c")
    end)

    it("strips_xml_illegal_control_bytes", function()
        local out = X.escapeText("a\0b\12c")
        assert_eq(out, "abc")
    end)

    it("keeps_tab_and_newline", function()
        assert_eq(X.escapeText("a\tb\nc"), "a\tb\nc")
    end)

    it("passes_utf8_through_untouched", function()
        assert_eq(X.escapeText("读书笔记 Café"), "读书笔记 Café")
    end)

    it("handles_nil", function()
        assert_eq(X.escapeText(nil), "")
        assert_eq(X.escapeAttr(nil), "")
    end)

    -- The exact failure that made images never embed: a Notion pre-signed URL
    -- must survive into an attribute with its ampersands escaped ONCE.
    it("presigned_url_survives_as_attribute", function()
        local url = "https://s3/x.png?X-Amz-Algorithm=AWS4&X-Amz-Signature=abc%2Fdef"
        local out = X.escapeAttr(url)
        assert_contains(out, "&amp;X-Amz-Signature")
        assert_not_contains(out, "&amp;amp;")
        assert_contains(out, "%2Fdef", "percent-encoding must not be mangled")
    end)
end)

--------------------------------------------------------------------------------
-- rich text
--------------------------------------------------------------------------------

describe("richtext", function()
    it("plain", function()
        assert_eq(X.renderRichText(rt("hello")), "hello")
    end)

    it("bold_italic_nest_bold_outermost", function()
        local out = X.renderRichText(rt("x", { bold = true, italic = true }))
        assert_eq(out, "<strong><em>x</em></strong>")
    end)

    it("strikethrough_is_real_markup", function()
        assert_eq(X.renderRichText(rt("gone", { strikethrough = true })), "<del>gone</del>")
    end)

    it("underline_uses_a_class", function()
        assert_contains(X.renderRichText(rt("u", { underline = true })), 'class="ns-u"')
    end)

    it("code_hugs_the_text_inside_a_link", function()
        local out = X.renderRichText(rt("f()", { code = true }, "https://e.com"))
        assert_eq(out, '<a href="https://e.com"><code>f()</code></a>')
    end)

    it("escapes_text_content", function()
        assert_eq(X.renderRichText(rt("a < b & c")), "a &lt; b &amp; c")
    end)

    it("escapes_href", function()
        local out = X.renderRichText(rt("x", nil, 'https://e.com/?a=1&b="2"'))
        assert_contains(out, "a=1&amp;b=&quot;2&quot;")
    end)

    it("concatenates_all_segments", function()
        local out = X.renderRichText({
            { plain_text = "Chapter " },
            { plain_text = "One", annotations = { bold = true } },
        })
        assert_eq(out, "Chapter <strong>One</strong>")
    end)

    it("falls_back_to_text_content", function()
        assert_eq(X.renderRichText({ { text = { content = "inner" } } }), "inner")
    end)

    it("unreadable_segment_becomes_visible_not_dropped", function()
        local ctx = X.newContext()
        local out = X.renderRichText({ { type = "mystery" } }, ctx)
        assert_contains(out, "[?]")
    end)

    it("plainText_strips_markup", function()
        assert_eq(X.plainText(rt("a", { bold = true })), "a")
    end)
end)

--------------------------------------------------------------------------------
-- blocks
--------------------------------------------------------------------------------

describe("blocks", function()
    it("paragraph", function()
        local out = render({ block("paragraph", { rich_text = rt("text") }) })
        assert_eq(out, "<p>text</p>\n")
    end)

    it("empty_paragraph_is_the_one_intentional_drop", function()
        local out = render({ block("paragraph", { rich_text = {} }) })
        assert_eq(out, "")
    end)

    it("headings_get_toc_anchors", function()
        local out, ctx = render({
            block("heading_1", { rich_text = rt("One") }),
            block("heading_2", { rich_text = rt("Two") }),
        })
        assert_contains(out, '<h1 id="h1">One</h1>')
        assert_contains(out, '<h2 id="h2">Two</h2>')
        assert_eq(#ctx.toc, 2)
        assert_eq(ctx.toc[1].text, "One")
        assert_eq(ctx.toc[2].level, 2)
        assert_eq(ctx.toc[2].anchor, "h2")
    end)

    it("code_becomes_pre_code_with_language", function()
        local out = render({
            block("code", { rich_text = rt("print(1)"), language = "lua" }),
        })
        assert_contains(out, '<pre><code class="language-lua">print(1)</code></pre>')
    end)

    it("code_escapes_its_body", function()
        local out = render({ block("code", { rich_text = rt("a < b && c") }) })
        assert_contains(out, "a &lt; b &amp;&amp; c")
    end)

    it("divider", function()
        assert_eq(render({ { type = "divider", divider = {} } }), "<hr/>\n")
    end)

    it("quote", function()
        local out = render({ block("quote", { rich_text = rt("said") }) })
        assert_contains(out, "<blockquote>\n<p>said</p>")
    end)

    it("callout_keeps_emoji_icon", function()
        local out = render({
            block("callout", { rich_text = rt("note"), icon = { type = "emoji", emoji = "!" } }),
        })
        assert_contains(out, 'class="ns-callout"')
        assert_contains(out, "! note")
    end)

    it("equation_shows_its_source", function()
        local out = render({ block("equation", { expression = "x^2 < y" }) })
        assert_contains(out, "x^2 &lt; y")
    end)
end)

--------------------------------------------------------------------------------
-- lists
--------------------------------------------------------------------------------

describe("lists", function()
    it("consecutive_items_share_one_ul", function()
        local out = render({
            block("bulleted_list_item", { rich_text = rt("a") }),
            block("bulleted_list_item", { rich_text = rt("b") }),
        })
        assert_eq(out, "<ul>\n<li>a</li>\n<li>b</li>\n</ul>\n")
    end)

    it("numbered_items_use_ol", function()
        local out = render({ block("numbered_list_item", { rich_text = rt("a") }) })
        assert_contains(out, "<ol>\n<li>a</li>")
    end)

    it("a_non_list_block_breaks_the_run", function()
        local out = render({
            block("numbered_list_item", { rich_text = rt("a") }),
            block("paragraph", { rich_text = rt("break") }),
            block("numbered_list_item", { rich_text = rt("b") }),
        })
        -- Two separate <ol>s, so the second list restarts at 1.
        local _, count = out:gsub("<ol>", "")
        assert_eq(count, 2)
    end)

    it("todo_renders_a_checkbox_marker", function()
        local out = render({
            block("to_do", { rich_text = rt("done"), checked = true }),
            block("to_do", { rich_text = rt("open"), checked = false }),
        })
        assert_contains(out, 'class="ns-todo"')
        assert_contains(out, "[x]")
        assert_contains(out, "[ ]")
    end)

    it("nested_children_render_inside_the_li", function()
        local parent = block("bulleted_list_item", { rich_text = rt("outer") }, {
            has_children = true,
            children = { block("bulleted_list_item", { rich_text = rt("inner") }) },
        })
        local out = render({ parent })
        -- The nested <ul> must appear before the parent's </li>.
        local li_close = out:find("</li>", 1, true)
        local nested = out:find("inner", 1, true)
        assert_true(nested < li_close, "nested list must be inside the parent <li>")
    end)

    it("unfetched_children_are_visible_not_silent", function()
        local parent = block("bulleted_list_item", { rich_text = rt("outer") },
            { has_children = true })
        local out, ctx = render({ parent })
        assert_contains(out, "nested content not fetched")
        assert_true(ctx.placeholders > 0)
    end)
end)

--------------------------------------------------------------------------------
-- images
--------------------------------------------------------------------------------

describe("images", function()
    local URL = "https://s3/x.png?X-Amz-Algorithm=AWS4&X-Amz-Signature=abc"

    it("mapped_image_uses_the_local_path", function()
        local out = render(
            { block("image", { type = "file", file = { url = URL } }) },
            { [URL] = "images/img00001.png" }
        )
        assert_contains(out, 'src="images/img00001.png"')
    end)

    -- The whole point of the rewrite: a real Notion URL must never survive into
    -- the EPUB, because it is pre-signed and expires.
    it("never_leaves_a_remote_url_in_the_document", function()
        local out = render(
            { block("image", { type = "file", file = { url = URL } }) },
            { [URL] = "images/img00001.png" }
        )
        assert_not_contains(out, "X-Amz-Signature")
        assert_not_contains(out, "s3/x.png")
    end)

    it("failed_download_becomes_a_visible_placeholder", function()
        local out, ctx = render({ block("image", { type = "file", file = { url = URL } }) }, {})
        assert_contains(out, "image failed to download")
        assert_not_contains(out, "X-Amz-Signature")
        assert_eq(ctx.missing_images, 1)
    end)

    it("external_images_are_mapped_too", function()
        local u = "https://e.com/a.png"
        local out = render(
            { block("image", { type = "external", external = { url = u } }) },
            { [u] = "images/img00002.png" }
        )
        assert_contains(out, 'src="images/img00002.png"')
    end)

    it("caption_is_rendered_and_escaped", function()
        local u = "https://e.com/a.png"
        local out = render(
            { block("image", {
                type = "external", external = { url = u },
                caption = rt("a & b"),
            }) },
            { [u] = "images/i.png" }
        )
        assert_contains(out, "a &amp; b")
    end)
end)

--------------------------------------------------------------------------------
-- tables
--------------------------------------------------------------------------------

describe("tables", function()
    local function table_block(rows, opts)
        opts = opts or {}
        local children = {}
        for _, cells in ipairs(rows) do
            local converted = {}
            for _, cell in ipairs(cells) do converted[#converted + 1] = rt(cell) end
            children[#children + 1] = {
                type = "table_row",
                table_row = { cells = converted },
            }
        end
        return {
            type = "table",
            id = "t1",
            has_children = true,
            children = children,
            table = {
                table_width = opts.width or #(rows[1] or {}),
                has_column_header = opts.column_header,
                has_row_header = opts.row_header,
            },
        }
    end

    it("renders_rows_and_cells", function()
        local out = render({ table_block({ { "a", "b" }, { "c", "d" } }) })
        assert_contains(out, "<table>")
        assert_contains(out, "<td>a</td><td>b</td>")
        assert_contains(out, "<td>c</td><td>d</td>")
    end)

    it("column_header_uses_thead_and_th", function()
        local out = render({
            table_block({ { "H1", "H2" }, { "v1", "v2" } }, { column_header = true }),
        })
        assert_contains(out, "<thead>")
        assert_contains(out, "<th>H1</th>")
        assert_contains(out, "<td>v1</td>")
    end)

    it("row_header_marks_first_cell_with_scope", function()
        local out = render({
            table_block({ { "name", "value" } }, { row_header = true }),
        })
        assert_contains(out, '<th scope="row">name</th>')
    end)

    -- Column alignment depends on this: omitting an empty cell shifts the rest.
    it("empty_cells_still_emit_a_tag", function()
        local out = render({ table_block({ { "a", "" }, { "", "d" } }) })
        assert_contains(out, "<td>a</td><td></td>")
        assert_contains(out, "<td></td><td>d</td>")
    end)

    it("short_rows_are_padded_to_table_width", function()
        local out = render({ table_block({ { "a" } }, { width = 3 }) })
        assert_contains(out, "<td>a</td><td></td><td></td>")
    end)

    it("unfetched_rows_are_reported_not_treated_as_empty", function()
        local out, ctx = render({
            { type = "table", id = "t", has_children = true, table = { table_width = 2 } },
        })
        assert_contains(out, "table rows not fetched")
        assert_true(ctx.placeholders > 0)
    end)

    it("cell_content_is_escaped", function()
        local out = render({ table_block({ { "a < b" } }) })
        assert_contains(out, "a &lt; b")
    end)
end)

--------------------------------------------------------------------------------
-- containers and references
--------------------------------------------------------------------------------

describe("containers", function()
    it("columns_are_flattened_into_block_flow", function()
        local col = function(text)
            return { type = "column", id = "c", has_children = true,
                     column = {}, children = { block("paragraph", { rich_text = rt(text) }) } }
        end
        local out = render({
            { type = "column_list", id = "cl", has_children = true, column_list = {},
              children = { col("left"), col("right") } },
        })
        assert_contains(out, "left")
        assert_contains(out, "right")
    end)

    it("toggle_body_is_expanded", function()
        local out = render({
            block("toggle", { rich_text = rt("summary") }, {
                has_children = true,
                children = { block("paragraph", { rich_text = rt("hidden body") }) },
            }),
        })
        assert_contains(out, "summary")
        assert_contains(out, "hidden body")
    end)

    it("synced_block_renders_its_children", function()
        local out = render({
            { type = "synced_block", id = "s", has_children = true, synced_block = {},
              children = { block("paragraph", { rich_text = rt("shared") }) } },
        })
        assert_contains(out, "shared")
    end)

    it("child_page_is_referenced_not_inlined", function()
        local out = render({ block("child_page", { title = "Other Page" }) })
        assert_contains(out, "sub-page: Other Page")
    end)

    it("bookmark_becomes_a_link", function()
        local out = render({ block("bookmark", { url = "https://e.com?a=1&b=2" }) })
        assert_contains(out, 'href="https://e.com?a=1&amp;b=2"')
    end)

    it("video_is_referenced_never_downloaded", function()
        local out = render({
            block("video", { type = "external", external = { url = "https://e.com/v.mp4" } }),
        })
        assert_contains(out, "video")
        assert_contains(out, "https://e.com/v.mp4")
    end)
end)

--------------------------------------------------------------------------------
-- the mandatory fallback
--------------------------------------------------------------------------------

describe("unknown_blocks", function()
    it("salvages_rich_text_from_an_unrecognised_type", function()
        h.logger.reset()
        local out, ctx = render({
            block("some_future_notion_block", { rich_text = rt("important text") }),
        })
        assert_contains(out, "important text")
        assert_eq(ctx.unsupported["some_future_notion_block"], 1)
        assert_eq(ctx.unsupported_total, 1)
        assert_true(h.logger.logged("warn", "some_future_notion_block"),
            "an unhandled type must be logged")
    end)

    it("emits_a_visible_placeholder_when_there_is_no_text", function()
        local out, ctx = render({ block("weird_thing", {}) })
        assert_contains(out, "unsupported Notion block: weird_thing")
        assert_true(ctx.placeholders > 0)
    end)

    it("still_renders_children_of_an_unknown_block", function()
        local out = render({
            block("weird_container", {}, {
                has_children = true,
                children = { block("paragraph", { rich_text = rt("nested survives") }) },
            }),
        })
        assert_contains(out, "nested survives")
    end)

    it("nothing_returns_empty_string_silently", function()
        local out = render({ block("mystery", {}) })
        assert_true(#out > 0, "an unknown block must never render as nothing")
    end)
end)

--------------------------------------------------------------------------------
-- document
--------------------------------------------------------------------------------

describe("renderPage", function()
    it("xml_declaration_is_the_very_first_byte", function()
        local doc = X.renderPage { title = "T", blocks = {} }
        assert_eq(doc:sub(1, 5), "<?xml", "a leading newline breaks XML parsing")
    end)

    it("uses_xhtml_doctype_and_namespace", function()
        local doc = X.renderPage { title = "T", blocks = {} }
        assert_contains(doc, "XHTML 1.1")
        assert_contains(doc, 'xmlns="http://www.w3.org/1999/xhtml"')
    end)

    it("escapes_the_title_in_both_places", function()
        local doc = X.renderPage { title = "A & B", blocks = {} }
        assert_contains(doc, "<title>A &amp; B</title>")
        assert_contains(doc, "A &amp; B</h1>")
        assert_not_contains(doc, "A & B")
    end)

    it("links_the_external_stylesheet", function()
        local doc = X.renderPage { title = "T", blocks = {} }
        assert_contains(doc, 'href="style.css"')
    end)

    it("returns_context_with_toc", function()
        local _, ctx = X.renderPage {
            title = "T",
            blocks = { block("heading_1", { rich_text = rt("Chapter") }) },
        }
        assert_eq(#ctx.toc, 1)
        assert_eq(ctx.toc[1].text, "Chapter")
    end)
end)

--------------------------------------------------------------------------------
-- the two load-bearing property tests
--------------------------------------------------------------------------------

-- A representative page exercising every block category at once.
local function kitchen_sink()
    return {
        block("heading_1", { rich_text = rt("Heading text") }),
        block("paragraph", { rich_text = rt("Paragraph text") }),
        block("bulleted_list_item", { rich_text = rt("Bullet text") }),
        block("numbered_list_item", { rich_text = rt("Numbered text") }),
        block("to_do", { rich_text = rt("Todo text"), checked = true }),
        block("quote", { rich_text = rt("Quote text") }),
        block("callout", { rich_text = rt("Callout text") }),
        block("code", { rich_text = rt("Code text"), language = "lua" }),
        block("equation", { expression = "Equation text" }),
        { type = "divider", divider = {} },
        block("toggle", { rich_text = rt("Toggle text") }, {
            has_children = true,
            children = { block("paragraph", { rich_text = rt("Toggle body text") }) },
        }),
        {
            type = "table", id = "t", has_children = true,
            table = { table_width = 2, has_column_header = true },
            children = {
                { type = "table_row", table_row = { cells = { rt("Header A"), rt("Header B") } } },
                { type = "table_row", table_row = { cells = { rt("Cell C"), rt("Cell D") } } },
            },
        },
        block("some_unknown_type", { rich_text = rt("Unknown block text") }),
        block("child_page", { title = "Child page text" }),
    }
end

-- Walks the input collecting every plain_text value, then asserts each one
-- survives into the output. This is the direct executable form of the project's
-- hard requirement, and the test that would have caught the vanishing tables.
local function collect_plain_text(node, found)
    found = found or {}
    if type(node) ~= "table" then return found end
    for key, value in pairs(node) do
        if key == "plain_text" and type(value) == "string" and value ~= "" then
            found[#found + 1] = value
        elseif key == "title" and type(value) == "string" and value ~= "" then
            found[#found + 1] = value
        elseif key == "expression" and type(value) == "string" and value ~= "" then
            found[#found + 1] = value
        elseif type(value) == "table" then
            collect_plain_text(value, found)
        end
    end
    return found
end

describe("completeness", function()
    it("every_plain_text_reaches_the_output", function()
        local blocks = kitchen_sink()
        local out = render(blocks)
        local expected = collect_plain_text(blocks)
        assert_true(#expected >= 15, "fixture should be substantial, got " .. #expected)
        for _, text in ipairs(expected) do
            assert_contains(out, text, "text vanished from the rendered output")
        end
    end)

    it("holds_for_the_full_page_document_too", function()
        local blocks = kitchen_sink()
        local doc = X.renderPage { title = "Doc title text", blocks = blocks }
        for _, text in ipairs(collect_plain_text(blocks)) do
            assert_contains(doc, text)
        end
        assert_contains(doc, "Doc title text")
    end)
end)

describe("wellformed", function()
    it("kitchen_sink_page_parses_as_xml", function()
        local doc = X.renderPage { title = "T", blocks = kitchen_sink() }
        local ok, err = h.check_xml(doc)
        assert_true(ok, "generated XHTML is malformed: " .. tostring(err))
    end)

    it("hostile_text_does_not_break_the_document", function()
        local nasty = [[<script>alert("x")</script> & ' " ]] .. "\12 \0"
        local doc = X.renderPage {
            title = nasty,
            blocks = {
                block("paragraph", { rich_text = rt(nasty) }),
                block("code", { rich_text = rt(nasty) }),
                block("bookmark", { url = "https://e.com/?a=1&b=2<x>", caption = rt(nasty) }),
            },
        }
        local ok, err = h.check_xml(doc)
        assert_true(ok, "hostile input produced malformed XHTML: " .. tostring(err))
        assert_not_contains(doc, "<script>")
    end)

    it("unmapped_image_page_parses", function()
        local doc = X.renderPage {
            title = "T",
            blocks = { block("image", { type = "file", file = { url = "https://s3/a.png?x=1&y=2" } }) },
        }
        local ok, err = h.check_xml(doc)
        assert_true(ok, tostring(err))
    end)

    it("checker_itself_rejects_known_bad_input", function()
        -- Guards against the well-formedness test passing because the checker is broken.
        assert_false((h.check_xml("<p>unclosed")))
        assert_false((h.check_xml("<p></div>")))
        assert_false((h.check_xml("<p>a & b</p>")))
        assert_false((h.check_xml('<img src=unquoted/>')))
        assert_true((h.check_xml("<p>a &amp; b</p>")))
    end)
end)
