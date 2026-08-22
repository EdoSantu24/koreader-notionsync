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
local NotionConverter = dofile(plugin_dir .. "converter.lua")
local NotionStorage = dofile(plugin_dir .. "storage.lua")
local NotionEpub = dofile(plugin_dir .. "epub.lua")
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
  self.api = NotionAPI:new(self.notion_token)
  self.converter = NotionConverter
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
        -- Until now the only way to force a re-sync was the side effect of
        -- switching output format, which cleared the history. With Markdown
        -- output gone, this is the replacement for that capability.
        text = _ "Clear sync history",
        callback = function() self:confirmClearSyncHistory() end,
        separator = true,
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
      if self.storage:clearSyncHistory() then
        UIManager:show(InfoMessage:new {
          text = _ "Sync history cleared.",
          timeout = 2,
        })
      else
        UIManager:show(InfoMessage:new {
          text = _ "Could not clear sync history.",
          timeout = 3,
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

function NotionSync:syncNow()
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
        -- Cleanup old temp images from previous sync
        self.storage:cleanupTempImages()

        local temp_dir = self.storage:ensureTempImageDir()
        local image_manager = ImageManager:new(temp_dir)
        logger.info "NotionSync: ImageManager initialized"

        local total_new = 0
        local total_old = 0
        local total_databases = #self.selected_databases
        local extension = ".epub"
        local synced_ids = self.storage:getSyncedIds()

        logger.info("NotionSync: Syncing", total_databases, "database(s)")

        -- Process each database sequentially
        local function processDatabase(db_index)
          if db_index > total_databases then
            -- All databases done
            UIManager:close(progress_message)

            -- Cleanup and get image stats
            local result_lines = {
              string.format "Sync complete!",
              string.format("New: %d", total_new),
              string.format("Old: %d", total_old),
              string.format("Databases: %d", total_databases),
            }

            local img_stats = image_manager:getStats()
            if img_stats.downloaded > 0 or img_stats.failed > 0 then
              table.insert(
                result_lines,
                string.format(
                  "Images: %d downloaded, %d cached, %d failed",
                  img_stats.downloaded,
                  img_stats.cached,
                  img_stats.failed
                )
              )
            end
            image_manager:cleanup()

            UIManager:show(InfoMessage:new {
              text = table.concat(result_lines, "\n"),
              timeout = 5,
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
              local blocks_success, blocks_result = self.api:getBlockChildren(page.id)
              if blocks_success and blocks_result.results then
                -- Image URLs must be collected before conversion, so the local
                -- paths are known by the time the HTML is generated.
                local image_urls = self.converter:extractImageURLs(blocks_result.results)

                local image_mappings = {}
                for img_idx, url in ipairs(image_urls) do
                  local local_path = image_manager:downloadImage(url, page.id, img_idx)
                  if local_path then
                    -- Map original URL to EPUB-relative path
                    local filename = local_path:match "([^/]+)$"
                    image_mappings[url] = "images/" .. filename
                  end
                end

                local markdown = self.converter:pageToMarkdown(page, blocks_result.results)
                local html_content = NotionEpub:markdownToHtml(title, markdown, image_mappings)
                local save_success = self.storage:saveEpub(
                  title,
                  html_content,
                  database.name,
                  self.storage:getTempImageDir()
                )

                if save_success then
                  self.storage:markAsSynced(sync_key)
                  synced_ids[sync_key] = true
                  total_new = total_new + 1
                else
                  logger.warn(string.format("NotionSync: Save failed for '%s'", title))
                end
              else
                logger.warn("NotionSync: Failed to get blocks for page", page.id)
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
