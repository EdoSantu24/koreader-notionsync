local NotionConverter = {}

-- Convert rich text array to markdown with formatting preserved
function NotionConverter:richTextToMarkdown(rich_text)
    local text = ""
    for _, segment in ipairs(rich_text) do
        if segment.plain_text then
            local content = segment.plain_text

            -- Apply formatting based on annotations
            if segment.annotations then
                local ann = segment.annotations

                -- Apply code first (innermost)
                if ann.code then
                    content = "`" .. content .. "`"
                end

                -- Apply bold
                if ann.bold then
                    content = "**" .. content .. "**"
                end

                -- Apply italic
                if ann.italic then
                    content = "*" .. content .. "*"
                end

                -- Apply strikethrough
                if ann.strikethrough then
                    content = "~~" .. content .. "~~"
                end
            end

            -- Handle links
            if segment.href and type(segment.href) == "string" then
                content = "[" .. content .. "](" .. segment.href .. ")"
            end

            text = text .. content
        end
    end
    return text
end

-- Fallback to plain text if needed
function NotionConverter:richTextToPlain(rich_text)
    local text = ""
    for _, segment in ipairs(rich_text) do
        if segment.plain_text then
            text = text .. segment.plain_text
        end
    end
    return text
end

function NotionConverter:blockToMarkdown(block, indent)
    indent = indent or ""
    local md = ""

    if block.type == "paragraph" then
        if block.paragraph and block.paragraph.rich_text then
            local text = self:richTextToMarkdown(block.paragraph.rich_text)
            if text ~= "" then
                md = indent .. text .. "\n\n"
            end
        end
    elseif block.type == "heading_1" then
        if block.heading_1 and block.heading_1.rich_text then
            local text = self:richTextToMarkdown(block.heading_1.rich_text)
            md = "# " .. text .. "\n\n"
        end
    elseif block.type == "heading_2" then
        if block.heading_2 and block.heading_2.rich_text then
            local text = self:richTextToMarkdown(block.heading_2.rich_text)
            md = "## " .. text .. "\n\n"
        end
    elseif block.type == "heading_3" then
        if block.heading_3 and block.heading_3.rich_text then
            local text = self:richTextToMarkdown(block.heading_3.rich_text)
            md = "### " .. text .. "\n\n"
        end
    elseif block.type == "bulleted_list_item" then
        if block.bulleted_list_item and block.bulleted_list_item.rich_text then
            local text = self:richTextToMarkdown(block.bulleted_list_item.rich_text)
            md = indent .. "- " .. text .. "\n"
        end
    elseif block.type == "numbered_list_item" then
        if block.numbered_list_item and block.numbered_list_item.rich_text then
            local text = self:richTextToMarkdown(block.numbered_list_item.rich_text)
            md = indent .. "1. " .. text .. "\n"
        end
    elseif block.type == "code" then
        if block.code and block.code.rich_text then
            local text = self:richTextToPlain(block.code.rich_text)
            local lang = block.code.language or ""
            md = "```" .. lang .. "\n" .. text .. "\n```\n\n"
        end
    elseif block.type == "quote" then
        if block.quote and block.quote.rich_text then
            local text = self:richTextToMarkdown(block.quote.rich_text)
            md = "> " .. text .. "\n\n"
        end
    elseif block.type == "divider" then
        md = "---\n\n"
    elseif block.type == "to_do" then
        if block.to_do and block.to_do.rich_text then
            local text = self:richTextToMarkdown(block.to_do.rich_text)
            local checkbox = block.to_do.checked and "[x]" or "[ ]"
            md = indent .. "- " .. checkbox .. " " .. text .. "\n"
        end
    elseif block.type == "image" then
        -- Handle image blocks (uses external URLs, not downloaded locally)
        local image_url = nil
        local caption = ""

        if block.image then
            -- Get image URL (external or file)
            if block.image.type == "external" and block.image.external then
                image_url = block.image.external.url
            elseif block.image.type == "file" and block.image.file then
                image_url = block.image.file.url
            end

            -- Get caption if available
            if block.image.caption and #block.image.caption > 0 then
                caption = self:richTextToPlain(block.image.caption)
            end
        end

        if image_url then
            md = "![" .. caption .. "](" .. image_url .. ")\n\n"
        end
    end

    return md
end

function NotionConverter:blocksToMarkdown(blocks)
    local markdown = ""

    if blocks then
        for _, block in ipairs(blocks) do
            markdown = markdown .. self:blockToMarkdown(block)
        end
    end

    return markdown
end

function NotionConverter:pageToMarkdown(page, blocks)
    local title = "Untitled"

    -- Get title from page properties
    if page and page.properties then
        for _, prop_value in pairs(page.properties) do
            if prop_value.type == "title" and prop_value.title and #prop_value.title > 0 then
                title = prop_value.title[1].plain_text or title
                break
            end
        end
    end

    local markdown = "# " .. title .. "\n\n"
    markdown = markdown .. self:blocksToMarkdown(blocks)

    return markdown
end

function NotionConverter:extractImageURLs(blocks)
    local image_urls = {}

    if not blocks then return image_urls end

    for _, block in ipairs(blocks) do
        if block.type == "image" and block.image then
            local image_url = nil

            -- Get image URL (external or file)
            if block.image.type == "external" and block.image.external then
                image_url = block.image.external.url
            elseif block.image.type == "file" and block.image.file then
                image_url = block.image.file.url
            end

            if image_url then
                table.insert(image_urls, image_url)
            end
        end
    end

    return image_urls
end

return NotionConverter
