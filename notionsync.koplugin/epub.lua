local logger = require("logger")
local Archiver = require("ffi/archiver")

-- Load the markdown parser library
local plugin_dir = debug.getinfo(1).source:match "@?(.*/)" or ""
local markdown_parser = dofile(plugin_dir .. "markdown.lua")

local NotionEpub = {}

-- Generate a simple HTML structure from markdown content
function NotionEpub:markdownToHtml(title, markdown_content, image_mappings)
    -- Use the markdown library to convert markdown to HTML
    local body_html = markdown_parser(markdown_content)
    
    -- If image_mappings provided, rewrite image URLs in HTML
    if image_mappings then
        for original_url, local_path in pairs(image_mappings) do
            -- Escape special regex characters in URL
            local escaped_url = original_url:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1")
            -- Replace src="original_url" with src="local_path"
            body_html = body_html:gsub('src="' .. escaped_url .. '"', 'src="' .. local_path .. '"')
            -- Also try single quotes
            body_html = body_html:gsub("src='" .. escaped_url .. "'", "src='" .. local_path .. "'")
        end
        logger.dbg("NotionEpub: Rewrote", #image_mappings, "image URLs in HTML")
    end
    
    -- Wrap in full HTML document with styling
    local html = [[
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml">
<head>
    <meta charset="UTF-8"/>
    <title>]] .. self:escapeHtml(title) .. [[</title>
    <style>
        body { 
            font-family: serif; 
            line-height: 1.6; 
            margin: 2em; 
        }
        h1, h2, h3 { 
            margin-top: 1.5em; 
        }
        img { 
            max-width: 100%; 
            height: auto; 
        }
        code { 
            background: #f4f4f4; 
            padding: 2px 6px; 
            border-radius: 3px; 
            font-family: monospace;
        }
        pre { 
            background: #f4f4f4; 
            padding: 1em; 
            overflow-x: auto; 
            border-radius: 5px;
        }
        pre code {
            background: transparent;
            padding: 0;
        }
        blockquote { 
            border-left: 4px solid #ddd; 
            margin: 1em 0; 
            padding-left: 1em; 
            color: #666; 
        }
        ul, ol { 
            margin: 1em 0; 
        }
        li {
            margin: 0.5em 0;
        }
        a {
            color: #0066cc;
            text-decoration: none;
        }
        a:hover {
            text-decoration: underline;
        }
        hr {
            border: none;
            border-top: 2px solid #ddd;
            margin: 2em 0;
        }
    </style>
</head>
<body>
]] .. body_html .. [[
</body>
</html>
]]
    return html
end

function NotionEpub:escapeHtml(text)
    if not text then return "" end
    text = text:gsub("&", "&amp;")
    text = text:gsub("<", "&lt;")
    text = text:gsub(">", "&gt;")
    text = text:gsub('"', "&quot;")
    text = text:gsub("'", "&#39;")
    return text
end

-- Get MIME type for image file extension
function NotionEpub:getMimeType(ext)
    if not ext then return "application/octet-stream" end
    local mimes = {
        jpg = "image/jpeg",
        jpeg = "image/jpeg",
        png = "image/png",
        gif = "image/gif",
        webp = "image/webp",
        svg = "image/svg+xml",
        bmp = "image/bmp",
        ico = "image/x-icon",
    }
    return mimes[ext:lower()] or "application/octet-stream"
end

-- Create EPUB structure using Lua-based archiver (no external dependencies)
function NotionEpub:createEpub(title, html_content, output_path, images_dir)
    logger.info(string.format("NotionEpub: Starting EPUB creation for '%s' at '%s'", title, output_path))
    
    -- Prepare mimetype content (must be uncompressed and first in zip)
    local mimetype_content = "application/epub+zip"
    
    -- Prepare container.xml
    local container_xml = [[<?xml version="1.0"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>]]
    
    -- Build image manifest entries
    local image_manifest = ""
    if images_dir then
        local lfs = require("libs/libkoreader-lfs")
        local mode = lfs.attributes(images_dir, "mode")
        if mode == "directory" then
            local image_count = 1
            for file in lfs.dir(images_dir) do
                if file ~= "." and file ~= ".." then
                    local ext = file:match("%.([^%.]+)$")
                    local media_type = self:getMimeType(ext)
                    image_manifest = image_manifest .. string.format(
                        '    <item id="img%d" href="images/%s" media-type="%s"/>\n',
                        image_count, file, media_type
                    )
                    image_count = image_count + 1
                end
            end
            logger.dbg(string.format("NotionEpub: Generated manifest for %d images", image_count - 1))
        end
    end
    
    -- Prepare content.opf
    local content_opf = [[<?xml version="1.0"?>
<package version="2.0" xmlns="http://www.idpf.org/2007/opf" unique-identifier="BookId">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:title>]] .. self:escapeHtml(title) .. [[</dc:title>
    <dc:language>en</dc:language>
    <dc:identifier id="BookId">notion-]] .. os.time() .. [[</dc:identifier>
  </metadata>
  <manifest>
    <item id="content" href="content.xhtml" media-type="application/xhtml+xml"/>
]] .. image_manifest .. [[  </manifest>
  <spine>
    <itemref idref="content"/>
  </spine>
</package>]]
    
    -- Create the archive writer
    local writer = Archiver.Writer:new()
    
    if not writer:open(output_path, "zip") then
        logger.err(string.format("NotionEpub: Failed to open archive for writing: %s", tostring(writer.err)))
        return false
    end
    
    -- Add mimetype (uncompressed, MUST be first and uncompressed for valid EPUB)
    if not writer:setZipCompression("store") then
        logger.err(string.format("NotionEpub: Failed to set store compression: %s", tostring(writer.err)))
        writer:close()
        return false
    end
    
    if not writer:addFileFromMemory("mimetype", mimetype_content, os.time()) then
        logger.err(string.format("NotionEpub: Failed to add mimetype: %s", tostring(writer.err)))
        writer:close()
        return false
    end
    
    -- Switch to deflate compression for remaining files
    if not writer:setZipCompression("deflate") then
        logger.err(string.format("NotionEpub: Failed to set deflate compression: %s", tostring(writer.err)))
        writer:close()
        return false
    end
    
    -- Add META-INF/container.xml
    if not writer:addFileFromMemory("META-INF/container.xml", container_xml, os.time()) then
        logger.err(string.format("NotionEpub: Failed to add container.xml: %s", tostring(writer.err)))
        writer:close()
        return false
    end
    
    -- Add OEBPS/content.opf
    if not writer:addFileFromMemory("OEBPS/content.opf", content_opf, os.time()) then
        logger.err(string.format("NotionEpub: Failed to add content.opf: %s", tostring(writer.err)))
        writer:close()
        return false
    end
    
    -- Add OEBPS/content.xhtml
    if not writer:addFileFromMemory("OEBPS/content.xhtml", html_content, os.time()) then
        logger.err(string.format("NotionEpub: Failed to add content.xhtml: %s", tostring(writer.err)))
        writer:close()
        return false
    end
    
    -- Add images if directory provided
    if images_dir then
        local lfs = require("libs/libkoreader-lfs")
        local mode = lfs.attributes(images_dir, "mode")
        if mode == "directory" then
            -- Add the entire images directory
            if not writer:addPath("OEBPS/images", images_dir, true, os.time()) then
                logger.warn(string.format("NotionEpub: Failed to add images directory: %s", tostring(writer.err)))
                -- Don't fail the whole EPUB creation if images fail
            end
        end
    end
    
    -- Close the archive
    writer:close()
    
    -- Verify the EPUB was created
    local f = io.open(output_path, "r")
    if f then
        f:close()
        logger.info(string.format("NotionEpub: Successfully created EPUB at %s", output_path))
        return true
    else
        logger.err(string.format("NotionEpub: EPUB file not found after creation: %s", output_path))
        return false
    end
end

return NotionEpub
