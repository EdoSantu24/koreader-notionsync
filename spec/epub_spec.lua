--
-- EPUB assembly tests.
--
-- This file previously documented the image-embedding BUG: a Notion pre-signed URL
-- was never substituted into the generated HTML, so every EPUB shipped an expiring
-- remote link. Those BUG_ assertions are gone because the cause is gone -- the
-- renderer emits local paths directly and there is no post-hoc string rewrite to
-- get wrong. The tests below assert the fixed behaviour instead.
--

local h = require("spec.helper")
local Epub = h.load_plugin("epub")

local tmpdir = (os.getenv("TEMP") or os.getenv("TMPDIR") or "/tmp"):gsub("\\", "/")

local PNG = "\137PNG\13\10\26\10" .. string.rep("x", 60)
local JPEG = "\255\216\255" .. string.rep("x", 60)
local GIF = "GIF89a" .. string.rep("x", 60)
local WEBP = "RIFF" .. "1234" .. "WEBP" .. string.rep("x", 60)
local BMP = "BM" .. string.rep("x", 60)
local SVG = '<?xml version="1.0"?><svg xmlns="http://www.w3.org/2000/svg"></svg>'

--------------------------------------------------------------------------------
-- media types
--------------------------------------------------------------------------------

describe("resolveMime", function()
    it("sniffs_png", function()
        local mime, ext = Epub:resolveMime(PNG, nil)
        assert_eq(mime, "image/png")
        assert_eq(ext, "png")
    end)

    it("sniffs_jpeg", function()
        assert_eq((Epub:resolveMime(JPEG, nil)), "image/jpeg")
    end)

    it("sniffs_gif_webp_bmp_svg", function()
        assert_eq((Epub:resolveMime(GIF, nil)), "image/gif")
        assert_eq((Epub:resolveMime(WEBP, nil)), "image/webp")
        assert_eq((Epub:resolveMime(BMP, nil)), "image/bmp")
        assert_eq((Epub:resolveMime(SVG, nil)), "image/svg+xml")
    end)

    -- The reason this exists: CDNs serve octet-stream, and the previous code
    -- guessed the type from the URL and labelled every image jpg.
    it("magic_bytes_beat_a_useless_content_type", function()
        assert_eq((Epub:resolveMime(PNG, "application/octet-stream")), "image/png")
    end)

    it("magic_bytes_beat_a_wrong_content_type", function()
        assert_eq((Epub:resolveMime(PNG, "image/jpeg")), "image/png")
    end)

    it("falls_back_to_content_type_when_bytes_are_unrecognised", function()
        assert_eq((Epub:resolveMime("not-an-image-at-all", "image/png")), "image/png")
    end)

    it("strips_charset_from_content_type", function()
        assert_eq((Epub:resolveMime("zzzz", "image/png; charset=binary")), "image/png")
    end)

    -- Declining to guess is deliberate: a wrong media-type in the manifest can make
    -- a reader reject the whole package.
    it("returns_nil_when_unidentifiable", function()
        assert_eq(Epub:resolveMime("zzzz", "text/html"), nil)
        assert_eq(Epub:resolveMime("zzzz", nil), nil)
    end)
end)

--------------------------------------------------------------------------------
-- identifiers
--------------------------------------------------------------------------------

describe("makeIdentifier", function()
    -- A stable identifier is why reading position survives a re-sync; the old code
    -- used os.time(), so pages written in the same second shared a UID.
    it("builds_a_urn_uuid_from_a_dashed_id", function()
        assert_eq(Epub:makeIdentifier("1a2b3c4d-5e6f-7a8b-9c0d-1e2f3a4b5c6d"),
            "urn:uuid:1a2b3c4d-5e6f-7a8b-9c0d-1e2f3a4b5c6d")
    end)

    it("normalises_an_undashed_id", function()
        assert_eq(Epub:makeIdentifier("1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d"),
            "urn:uuid:1a2b3c4d-5e6f-7a8b-9c0d-1e2f3a4b5c6d")
    end)

    it("is_stable_across_calls", function()
        local id = "1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d"
        assert_eq(Epub:makeIdentifier(id), Epub:makeIdentifier(id))
    end)

    it("falls_back_for_a_non_uuid", function()
        assert_eq(Epub:makeIdentifier("weird-id"), "notion:weird-id")
    end)

    it("returns_nil_for_nothing_usable", function()
        assert_eq(Epub:makeIdentifier(nil), nil)
        assert_eq(Epub:makeIdentifier(""), nil)
    end)
end)

--------------------------------------------------------------------------------
-- archive verification
--------------------------------------------------------------------------------

describe("verifyArchive", function()
    local function write(name, bytes)
        local path = tmpdir .. "/" .. name
        local f = assert(io.open(path, "wb"))
        f:write(bytes)
        f:close()
        return path
    end

    local function valid_bytes()
        return "PK\003\004" .. string.rep("\0", 26) .. "mimetype"
            .. string.rep("\0", 240) .. "PK\005\006" .. string.rep("\0", 18)
    end

    it("accepts_a_well_formed_archive", function()
        local ok = Epub:verifyArchive(write("ok.epub", valid_bytes()))
        assert_true(ok)
    end)

    -- The exact failure the old code could not detect: io.open() succeeds on this.
    it("rejects_an_empty_file", function()
        local ok, why = Epub:verifyArchive(write("empty.epub", ""))
        assert_false(ok)
        assert_contains(why, "small")
    end)

    it("rejects_a_missing_file", function()
        local ok, why = Epub:verifyArchive(tmpdir .. "/definitely_absent.epub")
        assert_false(ok)
        assert_contains(why, "missing")
    end)

    it("rejects_a_non_zip", function()
        local ok, why = Epub:verifyArchive(write("plain.epub", string.rep("A", 400)))
        assert_false(ok)
        assert_contains(why, "not a zip")
    end)

    it("rejects_an_archive_whose_first_entry_is_not_mimetype", function()
        local bytes = "PK\003\004" .. string.rep("\0", 26) .. "OEBPS/xx"
            .. string.rep("\0", 240) .. "PK\005\006" .. string.rep("\0", 18)
        local ok, why = Epub:verifyArchive(write("badfirst.epub", bytes))
        assert_false(ok)
        assert_contains(why, "mimetype")
    end)

    -- A zip whose central directory was never written, i.e. close() was skipped
    -- or failed. This is what makes a .epub unopenable.
    it("rejects_a_truncated_archive", function()
        local bytes = "PK\003\004" .. string.rep("\0", 26) .. "mimetype"
            .. string.rep("\0", 300)
        local ok, why = Epub:verifyArchive(write("trunc.epub", bytes))
        assert_false(ok)
        assert_contains(why, "central directory")
    end)
end)

--------------------------------------------------------------------------------
-- build
--------------------------------------------------------------------------------

describe("build", function()
    local URL_A = "https://s3/a.png?X-Amz-Algorithm=AWS4&X-Amz-Signature=aaa"
    local URL_B = "https://s3/b.jpg?X-Amz-Signature=bbb"

    local function setup(opts)
        opts = opts or {}
        h.archives = {}
        h.archiver_fail_on = opts.fail_on
        h.archiver_write_valid = opts.write_valid ~= false
        h.logger.reset()

        local out_path = tmpdir .. "/build_test.epub"
        os.remove(out_path)

        local captured = {}
        local result = {}
        result.ok, result.reason, result.info = Epub:build {
            title = opts.title or "My Page",
            author = opts.author or "Reading List",
            date = opts.date or "2026-08-22T10:00:00.000Z",
            page_id = opts.page_id or "1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d",
            source = opts.source,
            output_path = out_path,
            image_urls = opts.image_urls or {},
            fetch_image = opts.fetch_image or function() return PNG, "image/png" end,
            render = opts.render or function(image_map)
                captured.image_map = image_map
                return "<?xml version=\"1.0\"?><html><body>x</body></html>",
                    { toc = opts.toc or {} }
            end,
            on_progress = opts.on_progress,
        }
        result.writer = h.archives[1]
        result.captured = captured
        result.path = out_path
        return result
    end

    it("succeeds_and_produces_the_final_file", function()
        local r = setup()
        assert_true(r.ok, "build failed: " .. tostring(r.reason))
        assert_true(h.util.pathExists(r.path), "final .epub should exist")
        assert_false(h.util.pathExists(r.path .. ".part"), ".part should be gone")
    end)

    -- OCF requires mimetype first and uncompressed, or readers reject the file.
    it("mimetype_is_first_and_stored", function()
        local r = setup()
        local first = r.writer.entries[1]
        assert_eq(first.path, "mimetype")
        assert_eq(first.content, "application/epub+zip")
        assert_eq(first.compression, "store")
    end)

    it("everything_after_mimetype_is_deflated", function()
        local r = setup { image_urls = { URL_A } }
        for i = 2, #r.writer.entries do
            assert_eq(r.writer.entries[i].compression, "deflate",
                r.writer.entries[i].path .. " should be deflated")
        end
    end)

    it("writes_all_required_package_files", function()
        local r = setup()
        local paths = table.concat(r.writer:entryPaths(), " ")
        assert_contains(paths, "META-INF/container.xml")
        assert_contains(paths, "OEBPS/content.opf")
        assert_contains(paths, "OEBPS/content.xhtml")
        assert_contains(paths, "OEBPS/toc.ncx")
        assert_contains(paths, "OEBPS/style.css")
    end)

    -- The OPF must come after the images so its manifest can only list what was
    -- actually embedded; a manifest entry for a missing file is an invalid package.
    it("opf_is_written_after_the_content_and_images", function()
        local r = setup { image_urls = { URL_A } }
        local paths = r.writer:entryPaths()
        local opf_index, xhtml_index, img_index
        for i, p in ipairs(paths) do
            if p == "OEBPS/content.opf" then opf_index = i end
            if p == "OEBPS/content.xhtml" then xhtml_index = i end
            if p:find("images/", 1, true) then img_index = i end
        end
        assert_true(opf_index > xhtml_index, "OPF must follow content.xhtml")
        assert_true(opf_index > img_index, "OPF must follow the images")
    end)

    it("embeds_images_and_maps_urls_to_local_paths", function()
        local r = setup {
            image_urls = { URL_A, URL_B },
            fetch_image = function(url)
                if url == URL_A then return PNG, "image/png" end
                return JPEG, "image/jpeg"
            end,
        }
        assert_eq(r.info.images_embedded, 2)
        assert_eq(r.captured.image_map[URL_A], "images/img00001.png")
        assert_eq(r.captured.image_map[URL_B], "images/img00002.jpg")
        assert_true(r.writer:entry("OEBPS/images/img00001.png") ~= nil)
        assert_true(r.writer:entry("OEBPS/images/img00002.jpg") ~= nil)
    end)

    it("manifest_lists_embedded_images_with_correct_media_types", function()
        local r = setup {
            image_urls = { URL_A, URL_B },
            fetch_image = function(url)
                if url == URL_A then return PNG, "image/png" end
                return JPEG, nil
            end,
        }
        local opf = r.writer:entry("OEBPS/content.opf").content
        assert_contains(opf, 'href="images/img00001.png" media-type="image/png"')
        assert_contains(opf, 'href="images/img00002.jpg" media-type="image/jpeg"')
    end)

    it("a_failed_image_is_counted_and_left_out_of_the_manifest", function()
        local r = setup {
            image_urls = { URL_A, URL_B },
            fetch_image = function(url)
                if url == URL_A then return nil, "http 403" end
                return PNG, "image/png"
            end,
        }
        assert_eq(r.info.images_failed, 1)
        assert_eq(r.info.images_embedded, 1)
        assert_eq(r.captured.image_map[URL_A], nil)
        -- The surviving image is renumbered from 1, so no gap is left behind.
        assert_eq(r.captured.image_map[URL_B], "images/img00001.png")
        local opf = r.writer:entry("OEBPS/content.opf").content
        local _, count = opf:gsub('href="images/', "")
        assert_eq(count, 1)
    end)

    it("unidentifiable_image_bytes_are_skipped_not_mislabelled", function()
        local r = setup {
            image_urls = { URL_A },
            fetch_image = function() return "this is not an image", "text/html" end,
        }
        assert_eq(r.info.images_failed, 1)
        assert_eq(r.info.images_embedded, 0)
    end)

    -- No Notion URL may ever reach the archive: it is pre-signed and expires.
    it("no_remote_url_appears_anywhere_in_the_package", function()
        local r = setup { image_urls = { URL_A } }
        for _, e in ipairs(r.writer.entries) do
            if type(e.content) == "string" then
                assert_not_contains(e.content, "X-Amz-Signature",
                    "a pre-signed URL leaked into " .. e.path)
            end
        end
    end)

    it("uses_a_stable_identifier_from_the_page_id", function()
        local r = setup { page_id = "1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d" }
        local opf = r.writer:entry("OEBPS/content.opf").content
        assert_contains(opf, "urn:uuid:1a2b3c4d-5e6f-7a8b-9c0d-1e2f3a4b5c6d")
        local ncx = r.writer:entry("OEBPS/toc.ncx").content
        -- dtb:uid must match the OPF identifier exactly or epubcheck complains.
        assert_contains(ncx, 'content="urn:uuid:1a2b3c4d-5e6f-7a8b-9c0d-1e2f3a4b5c6d"')
    end)

    it("spine_references_the_ncx", function()
        local r = setup()
        local opf = r.writer:entry("OEBPS/content.opf").content
        assert_contains(opf, '<spine toc="ncx">')
        assert_contains(opf, 'media-type="application/x-dtbncx+xml"')
    end)

    it("ncx_gets_a_navpoint_per_top_level_heading", function()
        local r = setup {
            toc = {
                { level = 1, text = "Alpha", anchor = "h1" },
                { level = 2, text = "Beta", anchor = "h2" },
                { level = 3, text = "Deep", anchor = "h3" },
            },
        }
        local ncx = r.writer:entry("OEBPS/toc.ncx").content
        assert_contains(ncx, "Alpha")
        assert_contains(ncx, "content.xhtml#h1")
        assert_contains(ncx, "Beta")
        -- Level 3 is intentionally excluded; a deep NCX is unhelpful on a small screen.
        assert_not_contains(ncx, "Deep")
    end)

    it("escapes_metadata", function()
        local r = setup { title = "A & B <c>", author = "X & Y" }
        local opf = r.writer:entry("OEBPS/content.opf").content
        assert_contains(opf, "A &amp; B &lt;c&gt;")
        assert_contains(opf, "X &amp; Y")
        local ok, err = h.check_xml(opf)
        assert_true(ok, "generated OPF is malformed: " .. tostring(err))
    end)

    it("generated_ncx_is_well_formed", function()
        local r = setup { toc = { { level = 1, text = "A & B", anchor = "h1" } } }
        local ok, err = h.check_xml(r.writer:entry("OEBPS/toc.ncx").content)
        assert_true(ok, tostring(err))
    end)

    it("includes_author_and_date_when_given", function()
        local r = setup { author = "Reading List", date = "2026-08-22T10:00:00.000Z" }
        local opf = r.writer:entry("OEBPS/content.opf").content
        assert_contains(opf, "<dc:creator>Reading List</dc:creator>")
        assert_contains(opf, "<dc:date>2026-08-22T10:00:00.000Z</dc:date>")
    end)
end)

--------------------------------------------------------------------------------
-- build failure paths
--------------------------------------------------------------------------------

describe("build_failures", function()
    local function attempt(opts)
        h.archives = {}
        h.archiver_fail_on = opts.fail_on
        h.archiver_write_valid = opts.write_valid ~= false
        local out_path = tmpdir .. "/fail_test.epub"
        os.remove(out_path)
        os.remove(out_path .. ".part")
        local ok, reason = Epub:build {
            title = "T",
            page_id = "1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d",
            output_path = out_path,
            image_urls = opts.image_urls or {},
            fetch_image = function() return PNG, "image/png" end,
            render = opts.render or function()
                return "<html><body>x</body></html>", { toc = {} }
            end,
            on_progress = opts.on_progress,
        }
        return ok, reason, out_path
    end

    -- Regression, and the most expensive bug in this project so far: the real
    -- Writer:close() returns nothing on success, so testing its return value
    -- treated every page as a failure and deleted its .part file. No EPUB was
    -- ever written on-device even though the whole suite was green.
    it("succeeds_even_though_close_returns_no_value", function()
        h.archives = {}
        h.archiver_fail_on = nil
        h.archiver_write_valid = true
        local out_path = tmpdir .. "/close_nil_test.epub"
        os.remove(out_path)

        local writer_close_returned
        local ok, reason = Epub:build {
            title = "T",
            page_id = "1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d",
            output_path = out_path,
            image_urls = {},
            fetch_image = function() return PNG, "image/png" end,
            render = function() return "<html><body>x</body></html>", { toc = {} } end,
        }
        writer_close_returned = h.archives[1]:close()

        assert_eq(writer_close_returned, nil,
            "the fake must mirror the real API and return nothing")
        assert_true(ok, "build must not treat a nil close() as failure: " .. tostring(reason))
        assert_true(h.util.pathExists(out_path))
    end)

    -- A failed build must never leave a file behind, because the caller would
    -- otherwise record the page as synced and the user would find an unopenable
    -- book in their library.
    it("leaves_no_file_when_verification_fails", function()
        local ok, reason, path = attempt { write_valid = false }
        assert_false(ok)
        assert_false(h.util.pathExists(path))
        assert_false(h.util.pathExists(path .. ".part"))
        assert_true(reason ~= nil)
    end)

    it("fails_when_open_fails", function()
        local ok, reason = attempt { fail_on = "open" }
        assert_false(ok)
        assert_contains(reason, "open")
    end)

    it("fails_when_an_entry_cannot_be_added", function()
        local ok, reason, path = attempt { fail_on = "addFileFromMemory" }
        assert_false(ok)
        assert_contains(reason, "could not add")
        assert_false(h.util.pathExists(path .. ".part"))
    end)

    it("fails_when_the_renderer_produces_nothing", function()
        local ok, reason = attempt { render = function() return "", {} end }
        assert_false(ok)
        assert_contains(reason, "no content")
    end)

    it("cancels_cleanly_via_on_progress", function()
        local ok, reason, path = attempt {
            image_urls = { "https://s3/a.png" },
            on_progress = function() return false end,
        }
        assert_false(ok)
        assert_eq(reason, "cancelled")
        assert_false(h.util.pathExists(path))
    end)
end)
