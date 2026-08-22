--
-- Regression tests for the image-embedding bug.
--
-- This is the executable statement of the user's headline complaint: images from
-- Notion never appear in the generated EPUB.
--
-- Root cause, pinned below: the vendored parser's encode_alt() escapes `&` to
-- `&amp;` when it writes a URL into src="...", but epub.lua builds its search
-- pattern from the RAW url. Notion's pre-signed S3 image URLs are full of `&`,
-- so the rewrite never matches and the EPUB keeps an expiring remote link.
--
-- The discriminating pair is url_without_ampersand vs. notion_presigned_url:
-- the first rewrites correctly, the second does not. That difference is the
-- entire bug, and it is why the fix must not be "escape harder" but "never
-- string-rewrite generated HTML in the first place".
--

local h = require("spec.helper")
local Epub = h.load_plugin("epub")

-- A realistic Notion `file`-type image URL.
local PRESIGNED = "https://prod-files-secure.s3.us-west-2.amazonaws.com/abc/img.png"
    .. "?X-Amz-Algorithm=AWS4-HMAC-SHA256"
    .. "&X-Amz-Credential=ASIA123%2F20260822%2Fus-west-2%2Fs3%2Faws4_request"
    .. "&X-Amz-Signature=deadbeef"

describe("markdownToHtml", function()
    it("wraps_content_in_xhtml", function()
        local html = Epub:markdownToHtml("Title", "hello", nil)
        assert_contains(html, "<html xmlns=\"http://www.w3.org/1999/xhtml\">")
        assert_contains(html, "<title>Title</title>")
    end)

    it("escapes_title", function()
        local html = Epub:markdownToHtml("A & B", "x", nil)
        assert_contains(html, "<title>A &amp; B</title>")
    end)

    -- Confirms the substitution mechanism itself is wired up correctly: with a
    -- URL containing no ampersand, the local path IS substituted.
    it("rewrites_url_without_ampersand", function()
        local url = "https://example.com/plain.png"
        local html = Epub:markdownToHtml("T", "![alt](" .. url .. ")",
            { [url] = "images/img001.png" })
        assert_contains(html, 'src="images/img001.png"')
        assert_not_contains(html, url)
    end)

    -- BUG: the same operation on a real Notion URL fails.
    it("BUG_fails_to_rewrite_notion_presigned_url", function()
        local html = Epub:markdownToHtml("T", "![alt](" .. PRESIGNED .. ")",
            { [PRESIGNED] = "images/img001.png" })

        assert_not_contains(html, 'src="images/img001.png"',
            "local image path should have been substituted but was not")
        assert_contains(html, "X-Amz-Signature",
            "the expiring remote URL is still in the EPUB")
    end)

    -- The mechanism of the failure, asserted directly.
    it("BUG_parser_escapes_ampersands_in_src", function()
        local html = Epub:markdownToHtml("T", "![alt](" .. PRESIGNED .. ")", nil)
        assert_contains(html, "&amp;X-Amz-Credential",
            "parser writes &amp; into src, which is what breaks the raw-URL match")
        assert_not_contains(html, "png?X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz",
            "the raw single-& form does not appear in the output")
    end)

    it("emits_double_quoted_attributes_only", function()
        local html = Epub:markdownToHtml("T", "![a](https://e.com/x.png)", nil)
        assert_contains(html, 'src="')
        assert_not_contains(html, "src='")
    end)
end)

-- Markdown constructs the converter emits that this parser cannot represent.
describe("parser_gaps", function()
    it("BUG_fenced_code_is_not_a_code_block", function()
        local html = Epub:markdownToHtml("T", "```lua\nprint(1)\n```\n", nil)
        assert_not_contains(html, "<pre>",
            "Markdown 1.0.1 only supports 4-space-indented code blocks")
    end)

    it("indented_code_does_produce_a_code_block", function()
        local html = Epub:markdownToHtml("T", "    print(1)\n", nil)
        assert_contains(html, "<pre>")
    end)

    it("BUG_strikethrough_renders_as_literal_tildes", function()
        local html = Epub:markdownToHtml("T", "~~gone~~\n", nil)
        assert_contains(html, "~~gone~~")
        assert_not_contains(html, "<del>")
    end)

    it("BUG_pipe_table_is_not_a_table", function()
        local html = Epub:markdownToHtml("T", "| a | b |\n|---|---|\n| 1 | 2 |\n", nil)
        assert_not_contains(html, "<table")
    end)
end)
