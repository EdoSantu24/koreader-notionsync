--
-- Notion blocks -> XHTML, rendered directly.
--
-- This replaces the previous route of blocks -> Markdown -> vendored Markdown 1.0.1
-- parser -> HTML. That route was the cause of most of the plugin's known bugs: the
-- parser had no tables, no fenced code blocks and no strikethrough, and its URL
-- escaping silently broke image embedding (it wrote `&amp;` into src="..." while the
-- caller searched for the raw `&`). Emitting XHTML ourselves removes that whole
-- class of problem, because we control the output instead of pattern-matching
-- someone else's.
--
-- Two invariants hold this module together. Break either and the EPUB breaks.
--
--   1. ALL caller-supplied text passes through escapeText or escapeAttr. No other
--      function may place caller data next to a `<` or inside a quoted attribute.
--      An EPUB 2 content document is parsed as XML, and crengine's response to
--      malformed XML is to silently render a truncated page -- which presents to
--      the user as "some content is randomly missing".
--
--   2. Nothing is EVER silently dropped. Every unrecognised block type is logged,
--      counted, and rendered as a visible placeholder, with any rich_text it
--      carries salvaged. The single documented exception is an empty paragraph
--      with no children (Notion's spacer blocks).
--
local logger = require("logger")

local X = {}

--------------------------------------------------------------------------------
-- Escaping: the single chokepoint
--------------------------------------------------------------------------------

-- XML 1.0 forbids most C0 control characters outright; TAB (9), LF (10) and
-- CR (13) are the only legal ones. Notion code blocks and pasted content really
-- do contain others, and one stray 0x0C makes the entire document unparseable.
-- `%z` is the Lua 5.1 / LuaJIT idiom for NUL inside a character class.
local ILLEGAL_CONTROL = "[%z\1-\8\11\12\14-\31]"

-- `&` must be replaced FIRST, or the ampersands introduced by later
-- substitutions get double-escaped into `&amp;lt;`.
--
-- Bytes >= 0x80 are deliberately never inspected, which makes this UTF-8 safe by
-- construction: multi-byte sequences pass through untouched.
function X.escapeText(s)
    if s == nil then return "" end
    s = tostring(s)
    s = s:gsub("&", "&amp;")
    s = s:gsub("<", "&lt;")
    s = s:gsub(">", "&gt;")
    return (s:gsub(ILLEGAL_CONTROL, ""))
end

-- Also escapes both quote characters, so it is safe for any attribute value
-- including URLs. Quotes are intentionally NOT escaped by escapeText: they are
-- harmless in text and escaping them makes code blocks unreadable.
function X.escapeAttr(s)
    if s == nil then return "" end
    s = tostring(s)
    s = s:gsub("&", "&amp;")
    s = s:gsub("<", "&lt;")
    s = s:gsub(">", "&gt;")
    s = s:gsub('"', "&quot;")
    s = s:gsub("'", "&#39;")
    return (s:gsub(ILLEGAL_CONTROL, ""))
end

--------------------------------------------------------------------------------
-- Tunables
--------------------------------------------------------------------------------

-- U+2611/U+2610 are the natural choice, but a Kindle font may lack them and a
-- missing glyph renders as a tofu box or nothing at all. ASCII is the safe
-- default; flip these two lines once the Unicode forms are confirmed on-device.
local CHECKED_MARK = "[x]"
local UNCHECKED_MARK = "[ ]"

local MAX_DEPTH_GUARD = 12 -- structural backstop against a cyclic block tree

X.STYLESHEET = [[
body { font-family: serif; line-height: 1.5; margin: 0.6em; }
h1, h2, h3 { line-height: 1.25; margin: 1.1em 0 0.5em; }
p { margin: 0.6em 0; }
img { max-width: 100%; height: auto; }
figure, .ns-figure { margin: 1em 0; text-align: center; }
.ns-caption { font-size: 0.85em; font-style: italic; text-align: center; margin: 0.3em 0 0; }
code { font-family: monospace; }
pre { font-family: monospace; font-size: 0.85em; white-space: pre-wrap;
      background: #f4f4f4; padding: 0.6em; margin: 0.8em 0; }
pre code { background: transparent; }
blockquote { margin: 0.8em 0 0.8em 1em; padding-left: 0.8em;
             border-left: 3px solid #999; font-style: italic; }
ul, ol { margin: 0.6em 0; padding-left: 1.4em; }
li { margin: 0.25em 0; }
.ns-todo { list-style: none; padding-left: 0.4em; }
hr { border: none; border-top: 1px solid #999; margin: 1.4em 0; }
table { border-collapse: collapse; width: 100%; margin: 0.9em 0; font-size: 0.9em; }
th, td { border: 1px solid #999; padding: 0.3em 0.4em; text-align: left;
         vertical-align: top; }
th { font-weight: bold; background: #eee; }
.ns-callout { border: 1px solid #999; padding: 0.5em 0.7em; margin: 0.8em 0;
              background: #f7f7f7; }
.ns-toggle { margin: 0.8em 0; }
.ns-toggle-summary { font-weight: bold; }
.ns-sub { margin-left: 1em; }
.ns-columns { margin: 0.8em 0; }
.ns-placeholder { font-style: italic; color: #666; }
.ns-u { text-decoration: underline; }
.ns-strike { text-decoration: line-through; }
]]

--------------------------------------------------------------------------------
-- Context
--------------------------------------------------------------------------------

-- Accumulates everything the caller needs to report afterwards. `unsupported`
-- and `missing_images` are what turn "content silently vanished" into a number
-- the sync summary can show.
function X.newContext(image_map)
    return {
        image_map = image_map or {},
        unsupported = {},   -- block type -> count
        unsupported_total = 0,
        missing_images = 0,
        placeholders = 0,
        toc = {},           -- { {level, text, anchor}, ... }
        heading_seq = 0,
    }
end

local function note_placeholder(ctx)
    ctx.placeholders = ctx.placeholders + 1
end

local function placeholder(ctx, text)
    note_placeholder(ctx)
    return "<p class=\"ns-placeholder\">[" .. X.escapeText(text) .. "]</p>\n"
end

--------------------------------------------------------------------------------
-- Rich text
--------------------------------------------------------------------------------

-- Notion rich_text element shape:
--   { type, plain_text, href, annotations = { bold, italic, strikethrough,
--     underline, code, color }, text = { content, link }, equation = {...} }
local function segment_text(segment, ctx)
    if type(segment.plain_text) == "string" then return segment.plain_text end
    if type(segment.text) == "table" and type(segment.text.content) == "string" then
        return segment.text.content
    end
    if type(segment.equation) == "table" and type(segment.equation.expression) == "string" then
        return segment.equation.expression
    end
    -- Never return "" silently: an unreadable segment is content loss.
    logger.warn("NotionXhtml: rich_text segment with no readable text, type:",
        tostring(segment.type))
    if ctx then note_placeholder(ctx) end
    return "[?]"
end

function X.renderRichText(rich_text, ctx)
    if type(rich_text) ~= "table" then return "" end

    local out = {}
    for i = 1, #rich_text do
        local segment = rich_text[i]
        if type(segment) == "table" then
            local content = X.escapeText(segment_text(segment, ctx))
            local ann = segment.annotations

            if type(ann) == "table" then
                -- Innermost first. `code` hugs the text so that a linked inline
                -- code span comes out as <a><code>..</code></a>, not the reverse.
                if ann.code then content = "<code>" .. content .. "</code>" end
                if ann.strikethrough then content = "<del>" .. content .. "</del>" end
                if ann.underline then
                    content = '<span class="ns-u">' .. content .. "</span>"
                end
                if ann.italic then content = "<em>" .. content .. "</em>" end
                if ann.bold then content = "<strong>" .. content .. "</strong>" end
                if type(ann.color) == "string" and ann.color ~= "default" then
                    content = '<span class="ns-c-' .. X.escapeAttr(ann.color) .. '">'
                        .. content .. "</span>"
                end
            end

            if type(segment.href) == "string" and segment.href ~= "" then
                content = '<a href="' .. X.escapeAttr(segment.href) .. '">'
                    .. content .. "</a>"
            end

            out[#out + 1] = content
        end
    end
    return table.concat(out)
end

-- Concatenated plain text, for titles and captions. No markup.
function X.plainText(rich_text)
    if type(rich_text) ~= "table" then return "" end
    local out = {}
    for i = 1, #rich_text do
        local segment = rich_text[i]
        if type(segment) == "table" then
            if type(segment.plain_text) == "string" then
                out[#out + 1] = segment.plain_text
            elseif type(segment.text) == "table"
                and type(segment.text.content) == "string" then
                out[#out + 1] = segment.text.content
            end
        end
    end
    return table.concat(out)
end

--------------------------------------------------------------------------------
-- List grouping
--------------------------------------------------------------------------------

local LIST_TYPES = {
    bulleted_list_item = "ul",
    numbered_list_item = "ol",
    to_do = "todo",
}

-- Consecutive list items become one <ul>/<ol>. A run broken by any other block
-- correctly starts a new list, which is what makes numbered lists restart at 1.
function X.groupRuns(blocks)
    local runs = {}
    if type(blocks) ~= "table" then return runs end

    for i = 1, #blocks do
        local block = blocks[i]
        if type(block) == "table" then
            local kind = LIST_TYPES[block.type]
            local last = runs[#runs]
            if kind and last and last.kind == "list" and last.list_kind == kind then
                last.items[#last.items + 1] = block
            elseif kind then
                runs[#runs + 1] = { kind = "list", list_kind = kind, items = { block } }
            else
                runs[#runs + 1] = { kind = "block", block = block }
            end
        end
    end
    return runs
end

--------------------------------------------------------------------------------
-- Block handlers
--------------------------------------------------------------------------------

local renderBlocks -- forward declaration; handlers recurse through this

-- Renders a block's children, if they have been fetched, inside `wrapper`.
-- Children are attached by the fetch layer as `block.children`; when nothing has
-- attached them this returns "" and the caller decides whether that is a problem.
local function renderChildren(block, ctx, depth, wrapper_class)
    if type(block.children) ~= "table" or #block.children == 0 then return "" end
    local inner = renderBlocks(block.children, ctx, depth + 1)
    if inner == "" then return "" end
    if wrapper_class then
        return '<div class="' .. wrapper_class .. '">\n' .. inner .. "</div>\n"
    end
    return inner
end

-- True when Notion says the block has children but nothing fetched them. That is
-- a real content gap and must be visible, not assumed empty.
local function children_missing(block)
    return block.has_children == true
        and (type(block.children) ~= "table" or #block.children == 0)
end

local function rich(block, ctx)
    local payload = block[block.type]
    if type(payload) ~= "table" then return "" end
    return X.renderRichText(payload.rich_text, ctx)
end

local function caption_of(block, ctx)
    local payload = block[block.type]
    if type(payload) ~= "table" or type(payload.caption) ~= "table" then return "" end
    local text = X.renderRichText(payload.caption, ctx)
    if text == "" then return "" end
    return '<p class="ns-caption">' .. text .. "</p>\n"
end

local H = {}

H.paragraph = function(block, ctx, depth)
    local text = rich(block, ctx)
    local kids = renderChildren(block, ctx, depth, "ns-sub")
    -- The one documented intentional drop: Notion spacer paragraphs.
    if text == "" and kids == "" then return "" end
    if text == "" then return kids end
    return "<p>" .. text .. "</p>\n" .. kids
end

local function heading(level)
    return function(block, ctx, depth)
        local text = rich(block, ctx)
        ctx.heading_seq = ctx.heading_seq + 1
        local anchor = "h" .. ctx.heading_seq
        ctx.toc[#ctx.toc + 1] = {
            level = level,
            text = X.plainText((block[block.type] or {}).rich_text),
            anchor = anchor,
        }
        local tag = "h" .. level
        local out = "<" .. tag .. ' id="' .. anchor .. '">' .. text .. "</" .. tag .. ">\n"
        -- A toggleable heading keeps its body; there is no collapsed state in an
        -- EPUB, so it renders expanded rather than being lost.
        return out .. renderChildren(block, ctx, depth, "ns-sub")
    end
end

H.heading_1 = heading(1)
H.heading_2 = heading(2)
H.heading_3 = heading(3)

H.quote = function(block, ctx, depth)
    local text = rich(block, ctx)
    local inner = (text ~= "" and "<p>" .. text .. "</p>\n" or "")
        .. renderChildren(block, ctx, depth)
    if inner == "" then return "" end
    return "<blockquote>\n" .. inner .. "</blockquote>\n"
end

H.callout = function(block, ctx, depth)
    local icon = ""
    local payload = block.callout
    if type(payload) == "table" and type(payload.icon) == "table"
        and payload.icon.type == "emoji" and type(payload.icon.emoji) == "string" then
        icon = X.escapeText(payload.icon.emoji) .. " "
    end
    local text = rich(block, ctx)
    return '<div class="ns-callout">\n<p>' .. icon .. text .. "</p>\n"
        .. renderChildren(block, ctx, depth) .. "</div>\n"
end

H.toggle = function(block, ctx, depth)
    local text = rich(block, ctx)
    local body = renderChildren(block, ctx, depth)
    if children_missing(block) then
        body = placeholder(ctx, "collapsed content not fetched")
    end
    return '<div class="ns-toggle">\n<p class="ns-toggle-summary">' .. text .. "</p>\n"
        .. body .. "</div>\n"
end

H.code = function(block, ctx)
    local payload = block.code or {}
    -- Deliberately plain text, not renderRichText: annotations inside a code
    -- block are noise, and <strong> inside <pre> reads badly.
    local text = X.escapeText(X.plainText(payload.rich_text))
    local lang = payload.language
    local class = ""
    if type(lang) == "string" and lang ~= "" then
        class = ' class="language-' .. X.escapeAttr(lang) .. '"'
    end
    return "<pre><code" .. class .. ">" .. text .. "</code></pre>\n"
        .. caption_of(block, ctx)
end

H.divider = function()
    return "<hr/>\n"
end

H.equation = function(block, ctx)
    local expr = (block.equation or {}).expression
    if type(expr) ~= "string" or expr == "" then
        return placeholder(ctx, "empty equation")
    end
    -- No LaTeX rendering; showing the source beats dropping the block.
    return '<p class="ns-equation"><code>' .. X.escapeText(expr) .. "</code></p>\n"
end

H.image = function(block, ctx)
    local payload = block.image or {}
    local url
    if payload.type == "external" and type(payload.external) == "table" then
        url = payload.external.url
    elseif payload.type == "file" and type(payload.file) == "table" then
        url = payload.file.url
    end

    local alt = X.escapeAttr(X.plainText(payload.caption))
    local mapped = url and ctx.image_map[url]

    if not mapped then
        -- A Notion `file` URL is pre-signed and expires, so leaving it in an
        -- offline EPUB is strictly worse than saying the image is missing.
        ctx.missing_images = ctx.missing_images + 1
        local why = url and "image failed to download" or "image with no URL"
        local label = (alt ~= "" and (why .. ": " .. X.plainText(payload.caption)) or why)
        return placeholder(ctx, label)
    end

    return '<div class="ns-figure"><img src="' .. X.escapeAttr(mapped)
        .. '" alt="' .. alt .. '"/></div>\n' .. caption_of(block, ctx)
end

-- Notion puts a table's rows in its children, so a table with no fetched
-- children is a gap, not an empty table.
H.table = function(block, ctx)
    local payload = block.table or {}
    local rows = type(block.children) == "table" and block.children or {}
    if #rows == 0 then
        return placeholder(ctx, "table rows not fetched")
    end

    local width = tonumber(payload.table_width) or 0
    for i = 1, #rows do
        local cells = (rows[i] or {}).table_row
        cells = type(cells) == "table" and cells.cells or nil
        if type(cells) == "table" and #cells > width then width = #cells end
    end

    local out = { "<table>\n" }
    for i = 1, #rows do
        local row = rows[i]
        local cells = {}
        if type(row) == "table" and type(row.table_row) == "table"
            and type(row.table_row.cells) == "table" then
            cells = row.table_row.cells
        end

        local is_header_row = payload.has_column_header == true and i == 1
        out[#out + 1] = is_header_row and "<thead>\n<tr>" or "<tr>"

        for c = 1, width do
            -- Short rows are padded and empty cells still emit a tag: omitting
            -- one shifts every later column in the row.
            local content = type(cells[c]) == "table"
                and X.renderRichText(cells[c], ctx) or ""
            local tag = "td"
            if is_header_row then
                tag = "th"
            elseif payload.has_row_header == true and c == 1 then
                tag = "th"
            end
            local attr = (tag == "th" and not is_header_row) and ' scope="row"' or ""
            out[#out + 1] = "<" .. tag .. attr .. ">" .. content .. "</" .. tag .. ">"
        end

        out[#out + 1] = is_header_row and "</tr>\n</thead>\n" or "</tr>\n"
    end
    out[#out + 1] = "</table>\n"
    return table.concat(out) .. caption_of(block, ctx)
end

-- A bare table_row outside a table is malformed input, but its text must survive.
H.table_row = function(block, ctx)
    local cells = (block.table_row or {}).cells
    if type(cells) ~= "table" then return placeholder(ctx, "empty table row") end
    local parts = {}
    for i = 1, #cells do
        local text = type(cells[i]) == "table" and X.renderRichText(cells[i], ctx) or ""
        if text ~= "" then parts[#parts + 1] = text end
    end
    if #parts == 0 then return "" end
    return "<p>" .. table.concat(parts, " | ") .. "</p>\n"
end

-- Columns are flattened into sequential block flow. An e-ink page is too narrow
-- for side-by-side layout, and the requirement is that all text appears, not
-- that the visual arrangement is faithful.
local function passthrough_container(class)
    return function(block, ctx, depth)
        local inner = renderChildren(block, ctx, depth)
        if inner == "" then
            if children_missing(block) then
                return placeholder(ctx, block.type .. " content not fetched")
            end
            return ""
        end
        if class then
            return '<div class="' .. class .. '">\n' .. inner .. "</div>\n"
        end
        return inner
    end
end

H.column_list = passthrough_container("ns-columns")
H.column = passthrough_container(nil)
H.synced_block = passthrough_container(nil)

-- A child page is a whole other Notion page. Recursing would multiply the
-- request count without bound, so it is referenced rather than inlined.
local function page_reference(block, ctx)
    local payload = block[block.type]
    local title = type(payload) == "table" and payload.title or nil
    if type(title) ~= "string" or title == "" then title = "untitled" end
    note_placeholder(ctx)
    return '<p class="ns-placeholder">[' .. X.escapeText(block.type == "child_database"
        and "sub-database: " or "sub-page: ") .. X.escapeText(title) .. "]</p>\n"
end

H.child_page = page_reference
H.child_database = page_reference

local function link_like(block, ctx)
    local payload = block[block.type] or {}
    local url = payload.url
    local label = X.plainText(payload.caption)
    if label == "" then label = url end
    if type(url) ~= "string" or url == "" then
        return placeholder(ctx, block.type .. " with no URL")
    end
    return '<p class="ns-link"><a href="' .. X.escapeAttr(url) .. '">'
        .. X.escapeText(label) .. "</a></p>\n"
end

H.bookmark = link_like
H.embed = link_like
H.link_preview = link_like

-- Media is referenced, never downloaded: a Kindle cannot play video or audio,
-- and a large PDF or file blob would risk exhausting memory mid-sync.
local function media_reference(block, ctx)
    local payload = block[block.type] or {}
    local name = X.plainText(payload.caption)
    if name == "" and type(payload.name) == "string" then name = payload.name end
    local label = block.type .. (name ~= "" and (": " .. name) or "")

    if payload.type == "external" and type(payload.external) == "table"
        and type(payload.external.url) == "string" then
        return '<p class="ns-placeholder">[' .. X.escapeText(label) .. '] <a href="'
            .. X.escapeAttr(payload.external.url) .. '">link</a></p>\n'
    end
    -- A `file`-type URL is pre-signed and will have expired by reading time.
    return placeholder(ctx, label)
end

H.video = media_reference
H.audio = media_reference
H.file = media_reference
H.pdf = media_reference

local function bare_placeholder(block, ctx)
    return placeholder(ctx, block.type)
end

H.table_of_contents = bare_placeholder
H.breadcrumb = bare_placeholder
H.link_to_page = bare_placeholder
H.unsupported = bare_placeholder

--------------------------------------------------------------------------------
-- The mandatory fallback
--------------------------------------------------------------------------------

-- Invariant 2 lives here. An unrecognised type is logged, counted, and has its
-- text salvaged if it carries any -- which means most block types Notion adds in
-- future will render acceptably without a code change, rather than vanishing.
local function renderUnknown(block, ctx, depth)
    local btype = tostring(block.type or "nil")
    ctx.unsupported[btype] = (ctx.unsupported[btype] or 0) + 1
    ctx.unsupported_total = ctx.unsupported_total + 1
    logger.warn("NotionXhtml: unhandled block type", btype, tostring(block.id))

    local out = {}
    local payload = block[block.type]
    local salvaged = ""
    if type(payload) == "table" then
        if type(payload.rich_text) == "table" and #payload.rich_text > 0 then
            salvaged = X.renderRichText(payload.rich_text, ctx)
        elseif type(payload.title) == "string" then
            salvaged = X.escapeText(payload.title)
        elseif type(payload.expression) == "string" then
            salvaged = "<code>" .. X.escapeText(payload.expression) .. "</code>"
        elseif type(payload.caption) == "table" then
            salvaged = X.renderRichText(payload.caption, ctx)
        end
    end

    if salvaged ~= "" then
        out[#out + 1] = "<p>" .. salvaged .. "</p>\n"
    else
        out[#out + 1] = placeholder(ctx, "unsupported Notion block: " .. btype)
    end

    -- Children are rendered regardless of which branch ran above.
    out[#out + 1] = renderChildren(block, ctx, depth, "ns-sub")
    return table.concat(out)
end

--------------------------------------------------------------------------------
-- Block dispatch
--------------------------------------------------------------------------------

local function renderListItem(block, ctx, depth, list_kind)
    local text = X.renderRichText((block[block.type] or {}).rich_text, ctx)

    if list_kind == "todo" then
        local checked = (block.to_do or {}).checked == true
        local mark = checked and CHECKED_MARK or UNCHECKED_MARK
        text = "<code>" .. X.escapeText(mark) .. "</code> " .. text
    end

    -- Nested lists belong INSIDE the <li>, after its own content, or readers
    -- render the sublist as a sibling of the parent item.
    local kids = ""
    if type(block.children) == "table" and #block.children > 0 then
        kids = renderBlocks(block.children, ctx, depth + 1)
    elseif children_missing(block) then
        kids = placeholder(ctx, "nested content not fetched")
    end

    return "<li>" .. text .. (kids ~= "" and ("\n" .. kids) or "") .. "</li>\n"
end

renderBlocks = function(blocks, ctx, depth)
    depth = depth or 0
    if depth > MAX_DEPTH_GUARD then
        logger.warn("NotionXhtml: depth guard hit at", depth)
        return placeholder(ctx, "nesting too deep")
    end

    local out = {}
    for _, run in ipairs(X.groupRuns(blocks)) do
        if run.kind == "list" then
            local tag = run.list_kind == "ol" and "ol" or "ul"
            local class = run.list_kind == "todo" and ' class="ns-todo"' or ""
            out[#out + 1] = "<" .. tag .. class .. ">\n"
            for _, item in ipairs(run.items) do
                out[#out + 1] = renderListItem(item, ctx, depth, run.list_kind)
            end
            out[#out + 1] = "</" .. tag .. ">\n"
        else
            local block = run.block
            local handler = H[block.type]
            if handler then
                out[#out + 1] = handler(block, ctx, depth)
            else
                out[#out + 1] = renderUnknown(block, ctx, depth)
            end
        end
    end
    return table.concat(out)
end

X.renderBlocks = function(blocks, ctx, depth)
    return renderBlocks(blocks, ctx, depth)
end

--------------------------------------------------------------------------------
-- Image discovery
--------------------------------------------------------------------------------

-- Collects image URLs in document order, de-duplicated, recursing into children.
-- Recursion matters: an image inside a toggle, column or table cell is a child
-- block, and the previous top-level-only scan never found those at all.
function X.collectImageURLs(blocks, seen, out, depth)
    seen = seen or {}
    out = out or {}
    depth = depth or 0
    if type(blocks) ~= "table" or depth > MAX_DEPTH_GUARD then return out end

    for _, block in ipairs(blocks) do
        if type(block) == "table" then
            if block.type == "image" and type(block.image) == "table" then
                local payload = block.image
                local url
                if payload.type == "external" and type(payload.external) == "table" then
                    url = payload.external.url
                elseif payload.type == "file" and type(payload.file) == "table" then
                    url = payload.file.url
                end
                if type(url) == "string" and url ~= "" and not seen[url] then
                    seen[url] = true
                    out[#out + 1] = url
                end
            end
            if type(block.children) == "table" then
                X.collectImageURLs(block.children, seen, out, depth + 1)
            end
        end
    end
    return out
end

--------------------------------------------------------------------------------
-- Document
--------------------------------------------------------------------------------

-- opts = { title, blocks, image_map }
-- Returns xhtml, ctx  (ctx.toc drives the NCX; ctx counters drive the report)
function X.renderPage(opts)
    local ctx = X.newContext(opts.image_map)
    local title = opts.title or "Untitled"
    local body = renderBlocks(opts.blocks or {}, ctx, 0)

    -- The XML declaration must be the very first byte of the file. Note that Lua
    -- skips the newline immediately after `[[`, which is what keeps it there.
    local head = [[<?xml version="1.0" encoding="utf-8"?>
<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.1//EN" "http://www.w3.org/TR/xhtml11/DTD/xhtml11.dtd">
<html xmlns="http://www.w3.org/1999/xhtml">
<head>
<title>]] .. X.escapeText(title) .. [[</title>
<meta http-equiv="Content-Type" content="text/html; charset=utf-8"/>
<link rel="stylesheet" type="text/css" href="style.css"/>
</head>
<body>
<h1 class="ns-title">]] .. X.escapeText(title) .. [[</h1>
]]

    return head .. body .. "</body>\n</html>\n", ctx
end

return X
