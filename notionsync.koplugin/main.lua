local Dispatcher = require "dispatcher"
local InfoMessage = require "ui/widget/infomessage"
local InputDialog = require "ui/widget/inputdialog"
local ButtonDialog = require "ui/widget/buttondialog"
local ConfirmBox = require "ui/widget/confirmbox"
local PathChooser = require "ui/widget/pathchooser"
local UIManager = require "ui/uimanager"
local WidgetContainer = require "ui/widget/container/widgetcontainer"
local NetworkMgr = require "ui/network/manager"
local DataStorage = require "datastorage"
local LuaSettings = require "luasettings"
local logger = require "logger"
local util = require "util"
local _ = require "gettext"
local T = require("ffi/util").template

-- Load plugin modules using dofile for local plugin files
local plugin_dir = debug.getinfo(1).source:match "@?(.*/)" or ""
local NotionAPI = dofile(plugin_dir .. "api.lua")
local NotionStorage = dofile(plugin_dir .. "storage.lua")
local NotionEpub = dofile(plugin_dir .. "epub.lua")
local NotionXhtml = dofile(plugin_dir .. "xhtml.lua")
local NotionBlockTree = dofile(plugin_dir .. "blocktree.lua")
local ImageManager = dofile(plugin_dir .. "imagemanager.lua")

local NotionSync = WidgetContainer:extend {
  name = "notionsync",
  is_doc_only = false,
}

function NotionSync:init()
  self.settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/notionsync.lua")
  self.notion_token = self.settings:readSetting "notion_token"

  self.selected_databases = self.settings:readSetting "selected_databases" or {}
  self.save_dir = self.settings:readSetting "save_dir" or "/mnt/onboard/notion_sync"
  -- Nested-block fetching costs one API request per parent, so these bound how
  -- long a single page can take. Raising the budget fetches more of a deeply
  -- nested page at the cost of sync time and battery.
  self.max_depth = self.settings:readSetting "max_depth"
    or NotionBlockTree.DEFAULT_MAX_DEPTH
  self.request_budget = self.settings:readSetting "request_budget"
    or NotionBlockTree.DEFAULT_REQUEST_BUDGET

  self.api = NotionAPI:new(self.notion_token)
  self.storage = NotionStorage:new(self.save_dir)
  self.storage:initialize()
  self.ui.menu:registerToMainMenu(self)
  self:onDispatcherRegisterActions()
end

function NotionSync:onDispatcherRegisterActions()
  Dispatcher:registerAction("notion_sync_now", {
    category = "none",
    event = "NotionSyncNow",
    title = _ "Notion Sync Now",
    general = true,
  })
end

function NotionSync:addToMainMenu(menu_items)
  menu_items.notionsync = {
    text = _ "Notion Sync",
    sorting_hint = "tools",
    sub_item_table = {
      {
        text = _ "Sync Now",
        callback = function() self:syncNow() end,
      },
      {
        -- On-device iteration is the only way to verify rendering, and a full
        -- sync takes minutes. This does one page so that loop takes seconds, and
        -- dumps the generated markup so a rendering problem can be inspected
        -- rather than guessed at.
        text = _ "Sync one page (debug)",
        callback = function()
          self:syncNow { max_databases = 1, max_pages = 1, dump_xhtml = true }
        end,
      },
      {
        text_func = function()
          if #self.selected_databases == 0 then
            return _ "Select Databases (None selected)"
          elseif #self.selected_databases == 1 then
            return T(_ "Databases (%1)", self.selected_databases[1].name)
          elseif #self.selected_databases <= 3 then
            local names = {}
            for _, db in ipairs(self.selected_databases) do
              table.insert(names, db.name)
            end
            return T(_ "Databases (%1)", table.concat(names, ", "))
          else
            return T(_ "Databases (%1 selected)", #self.selected_databases)
          end
        end,
        callback = function() self:showDatabaseSelector() end,
      },
      {
        -- The plugin skips pages it has already synced and has no
        -- last_edited_time check, so this is the only way to pick up edits made
        -- in Notion or to recover from a bad sync.
        text = _ "Clear sync history",
        callback = function() self:confirmClearSyncHistory() end,
        separator = true,
      },
      {
        text_func = function()
          return T(_ "Nested content limit (%1 requests/page)", self.request_budget)
        end,
        sub_item_table = {
          {
            text = _ "Nested content limit",
            enabled = false,
          },
          {
            text = _ "20 - fastest, least nesting",
            checked_func = function() return self.request_budget == 20 end,
            callback = function() self:setRequestBudget(20) end,
          },
          {
            text = _ "40 - balanced (default)",
            checked_func = function() return self.request_budget == 40 end,
            callback = function() self:setRequestBudget(40) end,
          },
          {
            text = _ "100 - most complete, slowest",
            checked_func = function() return self.request_budget == 100 end,
            callback = function() self:setRequestBudget(100) end,
          },
        },
      },
      {
        text_func = function() return T(_ "Save Directory (%1)", self.save_dir) end,
        callback = function() self:showSaveDirPicker() end,
      },
      {
        text = _ "Set Notion Token",
        callback = function() self:showTokenInput() end,
      },
    },
  }
end

function NotionSync:updateToken(token)
  self.notion_token = token
  self.api = NotionAPI:new(token)
end

function NotionSync:showTokenInput()
  local input_dialog
  input_dialog = InputDialog:new {
    title = _ "Enter Notion Integration Token",
    input = self.notion_token,
    input_type = "string",
    buttons = {
      {
        {
          text = _ "Cancel",
          callback = function() UIManager:close(input_dialog) end,
        },
        {
          text = _ "Save",
          is_enter_default = true,
          callback = function()
            local token = input_dialog:getInputText()
            if token and token ~= "" then
              self:updateToken(token)
              self.settings:saveSetting("notion_token", token)
              self.settings:flush()
              UIManager:show(InfoMessage:new {
                text = _ "Token saved successfully",
                timeout = 2,
              })
            end
            UIManager:close(input_dialog)
          end,
        },
      },
    },
  }
  UIManager:show(input_dialog)
  input_dialog:onShowKeyboard()
end

-- Writes a diagnostic file next to the synced books, where it can be copied off
-- the device over USB.
function NotionSync:writeDebugFile(name, content)
  local path = self.save_dir .. "/" .. name
  local file = io.open(path, "w")
  if not file then
    logger.warn("NotionSync: could not write debug file", path)
    return false
  end
  file:write(content)
  file:close()
  logger.info("NotionSync: wrote debug file", path)
  return true
end

-- A flat outline of what the API actually returned, so a rendering problem can be
-- traced back to the block structure that produced it.
function NotionSync:describeBlocks(blocks, image_map)
  local lines = {}
  local function walk(list, indent)
    for _, block in ipairs(list or {}) do
      local note = ""
      if block.has_children then
        local fetched = type(block.children) == "table" and #block.children or 0
        note = string.format("  has_children=true fetched=%d", fetched)
      end
      lines[#lines + 1] = string.format("%s%s%s", indent, tostring(block.type), note)
      if type(block.children) == "table" then
        walk(block.children, indent .. "  ")
      end
    end
  end
  walk(blocks, "")

  lines[#lines + 1] = ""
  lines[#lines + 1] = "image map:"
  local any = false
  for url, href in pairs(image_map or {}) do
    any = true
    lines[#lines + 1] = "  " .. href .. "  <-  " .. url:sub(1, 120)
  end
  if not any then lines[#lines + 1] = "  (empty: no image was embedded)" end
  return table.concat(lines, "\n") .. "\n"
end

function NotionSync:setRequestBudget(value)
  self.request_budget = value
  self.settings:saveSetting("request_budget", value)
  self.settings:flush()
  UIManager:show(InfoMessage:new {
    text = T(_ "Nested content limit set to %1 requests per page.", value),
    timeout = 2,
  })
end

function NotionSync:confirmClearSyncHistory()
  local count = self.storage:countSyncedIds()
  if count == 0 then
    UIManager:show(InfoMessage:new {
      text = _ "Sync history is already empty.",
      timeout = 2,
    })
    return
  end

  UIManager:show(ConfirmBox:new {
    text = T(
      _ "Forget %1 synced page(s)?\n\nThe next sync will download them all again. Files already on the device are not deleted.",
      count
    ),
    ok_text = _ "Clear",
    ok_callback = function()
      local cleared, err = self.storage:clearSyncHistory()
      if cleared then
        UIManager:show(InfoMessage:new {
          text = _ "Sync history cleared.",
          timeout = 2,
        })
      else
        -- Include the reason: "could not" alone gives the user nothing to act on,
        -- and the usual causes (read-only mount, missing save directory) are fixable.
        UIManager:show(InfoMessage:new {
          text = T(_ "Could not clear sync history: %1", tostring(err)),
          timeout = 5,
        })
      end
    end,
  })
end

function NotionSync:showSaveDirPicker()
  local path_chooser = PathChooser:new {
    title = _ "Select Save Directory",
    path = self.save_dir,
    show_files = false,
    onConfirm = function(path)
      -- Validate path exists or can be created
      if not util.pathExists(path) then
        local ok, err = util.makePath(path)
        if not ok then
          UIManager:show(InfoMessage:new {
            text = T(_ "Failed to create directory: %1", err),
            timeout = 3,
          })
          return
        end
      end

      -- Update settings
      self.save_dir = path
      self.settings:saveSetting("save_dir", path)
      self.settings:flush()

      -- Reinitialize storage with new path
      self.storage = NotionStorage:new(self.save_dir)
      self.storage:initialize()

      UIManager:show(InfoMessage:new {
        text = T(_ "Save directory set to: %1", path),
        timeout = 2,
      })
    end,
  }
  UIManager:show(path_chooser)
end

function NotionSync:showDatabaseSelector()
  NetworkMgr:runWhenOnline(function()
    UIManager:show(InfoMessage:new {
      text = _ "Fetching databases...",
      timeout = 2,
    })

    local success, result = self.api:searchDatabases()
    if not success then
      UIManager:show(InfoMessage:new {
        text = T(_ "Failed to fetch databases: %1", result),
        timeout = 3,
      })
      return
    end
    if not result.results or #result.results == 0 then
      UIManager:show(InfoMessage:new {
        text = _ "No databases found",
        timeout = 3,
      })
      return
    end

    -- Store working copy of selections
    local temp_selections = {}
    for _, db in ipairs(self.selected_databases) do
      table.insert(temp_selections, { id = db.id, name = db.name })
    end

    -- Helper function to check if database is in temp selections
    local function isSelected(db_id)
      for _, sel_db in ipairs(temp_selections) do
        if sel_db.id == db_id then return true end
      end
      return false
    end

    -- Helper function to toggle database in temp selections
    local function toggleDatabase(db_id, db_name)
      for i, sel_db in ipairs(temp_selections) do
        if sel_db.id == db_id then
          table.remove(temp_selections, i)
          return false -- now unchecked
        end
      end
      table.insert(temp_selections, { id = db_id, name = db_name })
      return true -- now checked
    end

    -- Variable to hold current dialog
    local current_dialog

    -- Function to show the selector (needs to be recursive for updates)
    local function showSelector()
      -- Close previous dialog if it exists
      if current_dialog then UIManager:close(current_dialog) end

      -- Build button list (ButtonDialog needs 2D array: each button is a row)
      local buttons = {}

      for _, db in ipairs(result.results) do
        local db_id = db.id
        local db_name = self.api:getDatabaseTitle(db)
        local selected = isSelected(db_id)
        local check_mark = selected and "✓ " or "   "

        -- Each button is wrapped in its own row
        table.insert(buttons, {
          {
            text = check_mark .. db_name,
            callback = function()
              toggleDatabase(db_id, db_name)
              showSelector() -- Refresh the dialog
            end,
          },
        })
      end

      -- Add separator and action buttons
      table.insert(buttons, {
        {
          text = "──────────",
          enabled = false,
        },
      })
      table.insert(buttons, {
        {
          text = T(_ "Save (%1 selected)", #temp_selections),
          callback = function()
            if #temp_selections == 0 then
              UIManager:show(InfoMessage:new {
                text = _ "Please select at least one database",
                timeout = 3,
              })
              return
            end

            -- Close the dialog
            if current_dialog then UIManager:close(current_dialog) end

            -- Save selections
            self.selected_databases = temp_selections
            self.settings:saveSetting("selected_databases", self.selected_databases)
            self.settings:flush()

            UIManager:show(InfoMessage:new {
              text = T(_ "Saved %1 database(s)", #self.selected_databases),
              timeout = 2,
            })
          end,
        },
      })

      current_dialog = ButtonDialog:new {
        title = _ "Select Databases",
        buttons = buttons,
      }
      UIManager:show(current_dialog)
    end

    showSelector()
  end)
end

-- opts.max_pages / opts.max_databases cap the run, which is what the debug
-- single-page sync uses to make on-device iteration take seconds instead of
-- minutes.
function NotionSync:syncNow(opts)
  opts = opts or {}
  NetworkMgr:runWhenOnline(function()
    -- Validate that user has selected databases
    if #self.selected_databases == 0 then
      UIManager:show(InfoMessage:new {
        text = _ "Please select at least one database in Settings",
        timeout = 3,
      })
      return
    end

    local progress_message = InfoMessage:new {
      text = _ "Starting sync...",
    }
    UIManager:show(progress_message)
    UIManager:forceRePaint()

    UIManager:nextTick(function()
      -- Wrap in pcall to catch errors
      local ok, err = pcall(function()
        local image_manager = ImageManager:new()
        -- The retry backoff ceiling is per sync, not per plugin session.
        self.api:resetRetryBudget()

        local total_new = 0
        local total_old = 0
        local total_failed = 0
        local total_truncated = 0
        local total_partial = 0
        local failed_titles = {}
        local unsupported = {}
        local total_databases = #self.selected_databases
        if opts.max_databases and opts.max_databases < total_databases then
          total_databases = opts.max_databases
        end
        local extension = ".epub"
        local synced_ids = self.storage:getSyncedIds()

        logger.info("NotionSync: Syncing", total_databases, "database(s)")

        -- Process each database sequentially
        local function processDatabase(db_index)
          if db_index > total_databases then
            -- All databases done
            UIManager:close(progress_message)

            -- The headline must reflect reality: reporting "complete" while pages
            -- failed is how content loss went unnoticed before.
            local result_lines = {
              total_failed > 0 and string.format("Sync finished with %d problem(s)", total_failed)
                or "Sync complete!",
              string.format("New: %d   Unchanged: %d", total_new, total_old),
            }

            if total_failed > 0 then
              local names = {}
              for i = 1, math.min(3, #failed_titles) do
                names[#names + 1] = failed_titles[i]
              end
              local suffix = #failed_titles > 3
                and string.format(", +%d more", #failed_titles - 3) or ""
              table.insert(result_lines,
                string.format("Failed: %s%s", table.concat(names, ", "), suffix))
            end

            local img_stats = image_manager:getStats()
            if img_stats.downloaded > 0 or img_stats.failed > 0
              or img_stats.skipped_too_large > 0 then
              table.insert(result_lines, string.format(
                "Images: %d embedded, %d failed", img_stats.downloaded, img_stats.failed))
              if img_stats.skipped_too_large > 0 then
                table.insert(result_lines,
                  string.format("%d image(s) too large, skipped", img_stats.skipped_too_large))
              end
            end

            -- Content that exists in Notion but was not retrieved must be
            -- reported: the page still looks complete otherwise.
            if total_truncated > 0 then
              table.insert(result_lines, string.format(
                "%d page(s) hit the request limit (raise it in settings)", total_truncated))
            end
            if total_partial > 0 then
              table.insert(result_lines, string.format(
                "%d page(s) had some nested content unavailable", total_partial))
            end

            -- Blocks the renderer did not recognise are reported rather than
            -- vanishing, so an unhandled Notion feature is discoverable.
            local unsupported_parts = {}
            for btype, count in pairs(unsupported) do
              unsupported_parts[#unsupported_parts + 1] =
                string.format("%s (%d)", btype, count)
            end
            if #unsupported_parts > 0 then
              table.sort(unsupported_parts)
              table.insert(result_lines,
                "Unsupported blocks: " .. table.concat(unsupported_parts, ", "))
            end

            UIManager:show(InfoMessage:new {
              text = table.concat(result_lines, "\n"),
              -- Bad news must not disappear before it can be read.
              timeout = total_failed > 0 and nil or 5,
            })
            return
          end

          local database = self.selected_databases[db_index]
          logger.info(
            string.format(
              "NotionSync: Processing database %d/%d: %s",
              db_index,
              total_databases,
              database.name
            )
          )

          -- Update progress for this database
          UIManager:close(progress_message)
          progress_message = InfoMessage:new {
            text = T(_ "Syncing database %1/%2: %3", db_index, total_databases, database.name),
          }
          UIManager:show(progress_message)
          UIManager:forceRePaint()

          -- Query this database
          local success, result = self.api:queryDatabase(database.id, 20)

          if not success then
            logger.warn(
              string.format(
                "NotionSync: Failed to query database '%s': %s",
                database.name,
                result
              )
            )
            -- A whole database dropping out must be counted, not just logged.
            total_failed = total_failed + 1
            failed_titles[#failed_titles + 1] = database.name
            -- Continue to next database
            UIManager:nextTick(function() processDatabase(db_index + 1) end)
            return
          end

          if not result.results or #result.results == 0 then
            logger.info(
              string.format("NotionSync: No pages in database '%s'", database.name)
            )
            -- Continue to next database
            UIManager:nextTick(function() processDatabase(db_index + 1) end)
            return
          end

          local page_count = #result.results
          if opts.max_pages and opts.max_pages < page_count then
            page_count = opts.max_pages
          end
          logger.info(
            string.format(
              "NotionSync: Database '%s' has %d pages",
              database.name,
              page_count
            )
          )

          -- Process pages in this database
          local function processPage(page_index)
            if page_index > page_count then
              -- All pages in this database done, move to next database
              UIManager:nextTick(function() processDatabase(db_index + 1) end)
              return
            end

            local page = result.results[page_index]
            local title = self.api:getPageTitle(page)
            -- The ":epub" suffix is retained so that pages already recorded by
            -- an earlier version are still recognised as synced. Dropping it
            -- would silently force a full re-download of every page.
            local sync_key = page.id .. ":epub"

            -- Check file existence in this database's directory
            local file_exists = self.storage:fileExists(title, extension, database.name)

            -- Update progress message
            UIManager:close(progress_message)
            progress_message = InfoMessage:new {
              text = T(
                _ "DB %1/%2: %3 - %4/%5: %6",
                db_index,
                total_databases,
                database.name:sub(1, 15),
                page_index,
                page_count,
                title:sub(1, 20)
              ),
            }
            UIManager:show(progress_message)
            UIManager:forceRePaint()

            -- Sync if: not already recorded as synced OR the file is missing
            local should_sync = not synced_ids[sync_key] or not file_exists

            if should_sync then
              -- Fetches nested children too, which is what makes table rows,
              -- sub-bullets and toggle bodies available at all.
              local blocks, tree_meta = NotionBlockTree.fetchPage(self.api, page.id, {
                max_depth = self.max_depth,
                request_budget = self.request_budget,
              })

              if not blocks then
                -- A failed root fetch means the page's entire content is
                -- unavailable. Writing a title-only EPUB and recording it as
                -- synced would freeze that emptiness in place permanently, so
                -- this counts as a failure and will be retried next sync.
                logger.warn("NotionSync: Failed to get blocks for page", page.id,
                  tostring(tree_meta.fatal))
                total_failed = total_failed + 1
                failed_titles[#failed_titles + 1] = title
              else
                if tree_meta.truncated then total_truncated = total_truncated + 1 end
                if #tree_meta.errors > 0 then
                  total_partial = total_partial + 1
                end
                local build_ok, build_err, build_info = NotionEpub:build {
                  title = title,
                  author = database.name,
                  date = page.last_edited_time,
                  page_id = page.id,
                  source = page.url,
                  output_path = self.storage:getOutputPath(title, database.name),
                  image_urls = NotionXhtml.collectImageURLs(blocks),
                  fetch_image = function(url) return image_manager:fetch(url) end,
                  render = function(image_map)
                    local doc, render_ctx = NotionXhtml.renderPage {
                      title = title,
                      blocks = blocks,
                      image_map = image_map,
                    }
                    -- The generated markup is otherwise sealed inside the EPUB,
                    -- which makes a rendering complaint impossible to diagnose
                    -- without unzipping a book off the device.
                    if opts.dump_xhtml then
                      self:writeDebugFile("notionsync-debug.xhtml", doc)
                      self:writeDebugFile("notionsync-debug-blocks.txt",
                        self:describeBlocks(blocks, image_map))
                    end
                    return doc, render_ctx
                  end,
                }

                if build_info and build_info.render_ctx then
                  for btype, count in pairs(build_info.render_ctx.unsupported or {}) do
                    unsupported[btype] = (unsupported[btype] or 0) + count
                  end
                end

                if build_ok then
                  -- Only recorded after the archive was written AND verified.
                  self.storage:markAsSynced(sync_key)
                  synced_ids[sync_key] = true
                  total_new = total_new + 1
                else
                  logger.warn(string.format("NotionSync: build failed for '%s': %s",
                    title, tostring(build_err)))
                  total_failed = total_failed + 1
                  failed_titles[#failed_titles + 1] = title
                end
              end
            else
              total_old = total_old + 1
            end

            -- Schedule next page
            UIManager:nextTick(function() processPage(page_index + 1) end)
          end

          -- Start processing pages in this database
          processPage(1)
        end

        -- Start processing from first database
        processDatabase(1)
      end)

      if not ok then
        logger.err("NotionSync: Sync error:", err)
        UIManager:close(progress_message)
        UIManager:show(InfoMessage:new {
          text = T(_ "Sync error: %1", tostring(err)),
          timeout = 5,
        })
      end
    end)
  end)
end

return NotionSync
