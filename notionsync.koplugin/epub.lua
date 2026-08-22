--
-- EPUB 2 assembly.
--
-- Images are streamed: fetched one at a time and written straight into the archive,
-- so peak memory is one image rather than a whole page's worth. The previous design
-- staged them in a shared directory and archived the whole directory per page, which
-- meant every EPUB contained every image downloaded so far in the sync.
--
-- The archive is built at `<path>.part` and only renamed into place after it has been
-- verified, so the user's library can never contain a truncated .epub. That matters
-- because the caller records a page as synced on success and never retries it.
--
local Archiver = require("ffi/archiver")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")

local plugin_dir = debug.getinfo(1).source:match "@?(.*/)" or ""
local Xhtml = dofile(plugin_dir .. "xhtml.lua")

local NotionEpub = {}

--------------------------------------------------------------------------------
-- Media types
--------------------------------------------------------------------------------

local MIME_TO_EXT = {
    ["image/jpeg"] = "jpg",
    ["image/jpg"] = "jpg",
    ["image/png"] = "png",
    ["image/gif"] = "gif",
    ["image/webp"] = "webp",
    ["image/svg+xml"] = "svg",
    ["image/bmp"] = "bmp",
    ["image/avif"] = "avif",
    ["image/heic"] = "heic",
}

-- Formats to reject rather than embed, because embedding one yields an empty
-- bordered box on the device -- indistinguishable from a plugin fault -- whereas
-- a text placeholder explains itself.
--
-- Deliberately EMPTY. WebP is the obvious candidate, but recent KOReader bundles
-- libwebp, so disabling it on a hunch could break images that currently work.
-- The per-image logging below identifies the real format first; add an entry here
-- only once a format is confirmed unrenderable on the device.
local UNRENDERABLE_MIME = {}

-- First bytes as hex, for diagnosing what actually came down the wire.
local function hex_prefix(s, count)
    count = count or 12
    local out = {}
    for i = 1, math.min(count, #s) do
        out[#out + 1] = string.format("%02X", s:byte(i))
    end
    return table.concat(out, " ")
end

local function normalize_mime(ct)
    if type(ct) ~= "string" then return nil end
    ct = ct:lower():gsub(";.*$", ""):gsub("%s", "")
    return MIME_TO_EXT[ct] and ct or nil
end

-- Magic bytes are more trustworthy than the header: CDNs serve
-- application/octet-stream, and a wrong media-type in the OPF manifest is exactly
-- the sort of thing that makes a reader discard the image (or the document).
local function sniff_mime(content)
    if type(content) ~= "string" or #content < 4 then return nil end
    if content:sub(1, 3) == "\255\216\255" then return "image/jpeg" end
    if content:sub(1, 8) == "\137PNG\13\10\26\10" then return "image/png" end
    if content:sub(1, 4) == "GIF8" then return "image/gif" end
    if content:sub(1, 4) == "RIFF" and content:sub(9, 12) == "WEBP" then return "image/webp" end
    if content:sub(1, 2) == "BM" then return "image/bmp" end
    -- ISO-BMFF container: bytes 5-8 are "ftyp", the brand follows. Recognised so
    -- that a modern format is named in the log rather than reported as
    -- unidentifiable bytes.
    if content:sub(5, 8) == "ftyp" then
        local brand = content:sub(9, 12)
        if brand == "avif" or brand == "avis" then return "image/avif" end
        if brand == "heic" or brand == "heix" or brand == "mif1" then return "image/heic" end
    end
    local head = content:sub(1, 300):lower()
    if head:find("<svg", 1, true) then return "image/svg+xml" end
    return nil
end

-- Returns mime, ext, or nil when the bytes cannot be identified as an image at all.
-- Declining to guess is deliberate: a placeholder in the text beats a broken image
-- box or, worse, a manifest entry the reader rejects.
function NotionEpub:resolveMime(content, content_type)
    local mime = sniff_mime(content) or normalize_mime(content_type)
    if not mime then return nil end
    local ext = MIME_TO_EXT[mime]
    -- Both are required. Returning a mime with no extension would reach
    -- string.format("img%05d.%s", seq, nil) and abort the whole page.
    if not ext then return nil end
    return mime, ext
end

--------------------------------------------------------------------------------
-- Identifiers
--------------------------------------------------------------------------------

-- A *stable* identifier means a re-synced file is recognised as the same book, so
-- reading position and bookmarks survive a re-sync. The previous code used
-- os.time(), so every page written in the same second shared a UID.
function NotionEpub:makeIdentifier(page_id)
    if type(page_id) == "string" then
        local hex = page_id:lower():gsub("[^0-9a-f]", "")
        if #hex == 32 then
            return "urn:uuid:" .. hex:sub(1, 8) .. "-" .. hex:sub(9, 12) .. "-"
                .. hex:sub(13, 16) .. "-" .. hex:sub(17, 20) .. "-" .. hex:sub(21, 32)
        end
        if page_id ~= "" then return "notion:" .. page_id end
    end
    return nil
end

--------------------------------------------------------------------------------
-- Package documents
--------------------------------------------------------------------------------

local function container_xml()
    return [[<?xml version="1.0" encoding="utf-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>
]]
end

-- EPUB 2.0.1 requires an NCX and a spine `toc` attribute; without them epubcheck
-- rejects the file and KOReader's table-of-contents button does nothing.
local function toc_ncx(title, identifier, toc)
    local E = Xhtml.escapeText
    local A = Xhtml.escapeAttr
    local out = {
        [[<?xml version="1.0" encoding="utf-8"?>
<ncx version="2005-1" xmlns="http://www.daisy.org/z3986/2005/ncx/">
<head>
<meta name="dtb:uid" content="]] .. A(identifier) .. [["/>
<meta name="dtb:depth" content="2"/>
<meta name="dtb:totalPageCount" content="0"/>
<meta name="dtb:maxPageNumber" content="0"/>
</head>
<docTitle><text>]] .. E(title) .. [[</text></docTitle>
<navMap>
]],
    }

    local order = 1
    out[#out + 1] = '<navPoint id="nav0" playOrder="' .. order .. '">'
        .. "<navLabel><text>" .. E(title) .. "</text></navLabel>"
        .. '<content src="content.xhtml"/></navPoint>\n'

    for _, entry in ipairs(toc or {}) do
        -- Only top two heading levels: a deep NCX is unhelpful on a small screen.
        if entry.level and entry.level <= 2 and entry.text and entry.text ~= "" then
            order = order + 1
            out[#out + 1] = '<navPoint id="nav' .. order .. '" playOrder="' .. order .. '">'
                .. "<navLabel><text>" .. E(entry.text) .. "</text></navLabel>"
                .. '<content src="content.xhtml#' .. A(entry.anchor) .. '"/></navPoint>\n'
        end
    end

    out[#out + 1] = "</navMap>\n</ncx>\n"
    return table.concat(out)
end

local function content_opf(meta, images)
    local E = Xhtml.escapeText
    local A = Xhtml.escapeAttr

    local manifest = {
        '    <item id="content" href="content.xhtml" media-type="application/xhtml+xml"/>\n',
        '    <item id="css" href="style.css" media-type="text/css"/>\n',
        '    <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>\n',
    }
    -- Built from the images that actually succeeded, which is why the OPF is
    -- written last: a manifest entry for a missing file makes the package invalid.
    for _, img in ipairs(images) do
        manifest[#manifest + 1] = string.format(
            '    <item id="%s" href="%s" media-type="%s"/>\n',
            A(img.id), A(img.href), A(img.mime))
    end

    local extra = {}
    if meta.author and meta.author ~= "" then
        extra[#extra + 1] = "    <dc:creator>" .. E(meta.author) .. "</dc:creator>\n"
    end
    if meta.date and meta.date ~= "" then
        extra[#extra + 1] = "    <dc:date>" .. E(meta.date) .. "</dc:date>\n"
    end
    if meta.source and meta.source ~= "" then
        extra[#extra + 1] = "    <dc:source>" .. E(meta.source) .. "</dc:source>\n"
    end

    return [[<?xml version="1.0" encoding="utf-8"?>
<package version="2.0" xmlns="http://www.idpf.org/2007/opf" unique-identifier="BookId">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/"
            xmlns:opf="http://www.idpf.org/2007/opf">
    <dc:title>]] .. E(meta.title) .. [[</dc:title>
    <dc:language>]] .. E(meta.language or "en") .. [[</dc:language>
    <dc:identifier id="BookId">]] .. E(meta.identifier) .. [[</dc:identifier>
]] .. table.concat(extra) .. [[  </metadata>
  <manifest>
]] .. table.concat(manifest) .. [[  </manifest>
  <spine toc="ncx">
    <itemref idref="content"/>
  </spine>
  <guide>
    <reference type="text" title="Start" href="content.xhtml"/>
  </guide>
</package>
]]
end

--------------------------------------------------------------------------------
-- Verification
--------------------------------------------------------------------------------

-- io.open() succeeding is not proof of a valid archive -- it is true for a 0-byte
-- file and for a zip whose central directory was never written. These three checks
-- catch every truncation mode seen in practice, with no extra dependency.
function NotionEpub:verifyArchive(path)
    local size = lfs.attributes(path, "size")
    if not size then return false, "archive missing after write" end
    if size < 200 then return false, "archive suspiciously small (" .. size .. " bytes)" end

    local f = io.open(path, "rb")
    if not f then return false, "archive could not be reopened" end
    local head = f:read(38) or ""
    -- Look in the tail rather than at exactly -22: an archive comment, if any,
    -- sits after the end-of-central-directory record.
    f:seek("end", -math.min(size, 512))
    local tail = f:read(512) or ""
    f:close()

    if head:sub(1, 4) ~= "PK\003\004" then
        return false, "not a zip archive"
    end
    -- OCF requires `mimetype` to be the first entry, uncompressed.
    if head:sub(31, 38) ~= "mimetype" then
        return false, "mimetype is not the first archive entry"
    end
    if not tail:find("PK\005\006", 1, true) then
        return false, "end of central directory missing (archive truncated)"
    end
    return true
end

--------------------------------------------------------------------------------
-- Build
--------------------------------------------------------------------------------

-- opts = {
--   title, author, date, language, page_id, source,
--   output_path,
--   image_urls  = { url, ... }          ordered, already de-duplicated
--   fetch_image = function(url) -> content, content_type | nil, reason
--   render      = function(image_map) -> xhtml_string, render_ctx
--   on_progress = function(text) -> false to cancel
-- }
--
-- Returns ok, reason_or_nil, info
--   info = { images_embedded, images_failed, render_ctx }
function NotionEpub:build(opts)
    local output_path = opts.output_path
    local part_path = output_path .. ".part"
    local mtime = os.time()

    -- Any leftover from an interrupted previous run would otherwise be appended to.
    os.remove(part_path)

    local writer = Archiver.Writer:new()
    if not writer:open(part_path, "zip") then
        return false, "could not open archive: " .. tostring(writer.err)
    end

    local info = { images_embedded = 0, images_failed = 0 }

    local function fail(reason)
        writer:close()
        os.remove(part_path)
        logger.warn("NotionEpub:", reason)
        return false, reason, info
    end

    local function add(path, content)
        if not writer:addFileFromMemory(path, content, mtime) then
            return false, "could not add " .. path .. ": " .. tostring(writer.err)
        end
        return true
    end

    -- mimetype must be first and stored uncompressed, per the OCF spec.
    if not writer:setZipCompression("store") then
        return fail("could not select store compression: " .. tostring(writer.err))
    end
    local ok, err = add("mimetype", "application/epub+zip")
    if not ok then return fail(err) end

    if not writer:setZipCompression("deflate") then
        return fail("could not select deflate compression: " .. tostring(writer.err))
    end

    ok, err = add("META-INF/container.xml", container_xml())
    if not ok then return fail(err) end

    -- Images, streamed one at a time. Peak memory is a single image because the
    -- reference is dropped before the next fetch.
    local image_map = {}
    local manifest_images = {}
    local seq = 0

    for _, url in ipairs(opts.image_urls or {}) do
        if opts.on_progress and opts.on_progress("image") == false then
            return fail("cancelled")
        end

        local content, content_type = opts.fetch_image(url)
        if not content then
            -- content_type carries the failure reason in this branch.
            info.images_failed = info.images_failed + 1
            logger.warn("NotionEpub: image fetch failed:", tostring(content_type))
        else
            local mime, ext = self:resolveMime(content, content_type)

            -- Logged for every image, because a broken-image box on the device
            -- gives no clue whether the bytes were truncated, HTML, compressed,
            -- or a format the reader cannot decode. The byte prefix answers that
            -- immediately from crash.log.
            logger.info(string.format(
                "NotionEpub: image %d bytes, header %q, declared %s, resolved %s",
                #content, hex_prefix(content), tostring(content_type), tostring(mime)))

            if mime and UNRENDERABLE_MIME[mime] then
                -- Embedding these produces an empty bordered box rather than a
                -- picture, which looks like a plugin fault. Saying so is better.
                info.images_failed = info.images_failed + 1
                info.unrenderable = (info.unrenderable or 0) + 1
                logger.warn("NotionEpub: format not renderable by the reader:", mime, url)
                mime = nil
            end

            if not mime then
                info.images_failed = info.images_failed + 1
                logger.warn("NotionEpub: unusable image, skipping:", url)
            else
                seq = seq + 1
                local name = string.format("img%05d.%s", seq, ext)
                local href = "images/" .. name
                ok, err = add("OEBPS/" .. href, content)
                if not ok then return fail(err) end

                manifest_images[#manifest_images + 1] = {
                    id = string.format("img%05d", seq),
                    href = href,
                    mime = mime,
                }
                image_map[url] = href
                info.images_embedded = info.images_embedded + 1
            end
        end
        content = nil -- luacheck: ignore content
    end

    -- Rendered after the images so the placeholders for failed downloads are
    -- accurate, and before the OPF so the manifest matches what was embedded.
    local xhtml, render_ctx = opts.render(image_map)
    info.render_ctx = render_ctx
    if type(xhtml) ~= "string" or xhtml == "" then
        return fail("renderer produced no content")
    end

    ok, err = add("OEBPS/style.css", Xhtml.STYLESHEET)
    if not ok then return fail(err) end

    ok, err = add("OEBPS/content.xhtml", xhtml)
    if not ok then return fail(err) end

    local identifier = self:makeIdentifier(opts.page_id) or ("notion:" .. tostring(output_path))
    local toc = render_ctx and render_ctx.toc or {}

    ok, err = add("OEBPS/toc.ncx", toc_ncx(opts.title or "Untitled", identifier, toc))
    if not ok then return fail(err) end

    ok, err = add("OEBPS/content.opf", content_opf({
        title = opts.title or "Untitled",
        author = opts.author,
        date = opts.date,
        language = opts.language,
        source = opts.source,
        identifier = identifier,
    }, manifest_images))
    if not ok then return fail(err) end

    -- Writer:close() returns NOTHING on success -- unlike open(),
    -- setZipCompression() and addFileFromMemory(), which all return true. The
    -- binding does not surface archive_write_close's status at all, so there is
    -- no return value to test. Treating nil as failure here made every single
    -- page fail with "archive close failed: nil" and deleted its .part file, so
    -- no EPUB was ever written. The verification below is the real check.
    writer:close()

    local verified, why = self:verifyArchive(part_path)
    if not verified then
        os.remove(part_path)
        logger.warn("NotionEpub: verification failed:", why)
        return false, why, info
    end

    -- os.rename cannot overwrite on some platforms, so clear the target first.
    os.remove(output_path)
    local renamed, rename_err = os.rename(part_path, output_path)
    if not renamed then
        os.remove(part_path)
        return false, "could not move archive into place: " .. tostring(rename_err), info
    end

    logger.info("NotionEpub: wrote", output_path, "with", info.images_embedded, "image(s)")
    return true, nil, info
end

return NotionEpub
