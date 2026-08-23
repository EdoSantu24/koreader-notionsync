local Dispatcher = require "dispatcher"
local InfoMessage = require "ui/widget/infomessage"
local InputDialog = require "ui/widget/inputdialog"
local ButtonDialog = require "ui/widget/buttondialog"
local ConfirmBox = require "ui/widget/confirmbox"
local PathChooser = require "ui/widget/pathchooser"
local UIManager = require "ui/uimanager"
local WidgetContainer = require "ui/widget/container/widgetcontainer"
local NetworkMgr = require "ui/network/manager"
local Trapper = require "ui/trapper"
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
  -- Every cursor page is now followed, so a large database is no longer silently
  -- capped at 20 pages. This bounds how long one database can take; 0 means no
  -- limit beyond the API request backstop.
  self.max_pages_per_database = self.settings:readSetting "max_pages_per_database"
    or 200

  self.api = NotionAPI:new(self.notion_token)
  -- Sync state lives in the settings directory, not save_dir, so changing the
  -- save directory does not throw the history away.
  self.storage = NotionStorage:new(self.save_dir,
    DataStorage:getSettingsDir() .. "/notionsync_state.lua")
  self.storage:initialize()
  self.storage:loadState()
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
        -- Edits in Notion are picked up automatically now, so this is for
        -- forcing a full rebuild -- after changing something about how pages are
        -- rendered, or to recover from a bad sync.
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
        text_func = function()
          if self.max_pages_per_database == 0 then
            return _ "Pages per database (no limit)"
          end
          return T(_ "Pages per database (%1)", self.max_pages_per_database)
        end,
        sub_item_table = {
          {
            text = _ "Maximum pages fetched per database",
            enabled = false,
          },
          {
            text = _ "100",
            checked_func = function() return self.max_pages_per_database == 100 end,
            callback = function() self:setMaxPages(100) end,
          },
          {
            text = _ "200 (default)",
            checked_func = function() return self.max_pages_per_database == 200 end,
            callback = function() self:setMaxPages(200) end,
          },
          {
            text = _ "1000",
            checked_func = function() return self.max_pages_per_database == 1000 end,
            callback = function() self:setMaxPages(1000) end,
          },
          {
            text = _ "No limit",
            checked_func = function() return self.max_pages_per_database == 0 end,
            callback = function() self:setMaxPages(0) end,
          },
        },
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

function NotionSync:setMaxPages(value)
  self.max_pages_per_database = value
  self.settings:saveSetting("max_pages_per_database", value)
  self.settings:flush()
  UIManager:show(InfoMessage:new {
    text = value == 0
      and _ "No page limit per database."
      or T(_ "Fetching at most %1 pages per database.", value),
    timeout = 2,
  })
end

function NotionSync:confirmClearSyncHistory()
  local count = self.storage:countSyncedPages()
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

      -- Reinitialize storage with the new path, keeping the same state file.
      self.storage = NotionStorage:new(self.save_dir,
        DataStorage:getSettingsDir() .. "/notionsync_state.lua")
      self.storage:initialize()
      self.storage:loadState()

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

    local success, databases = self.api:getAllDatabases()
    if not success then
      UIManager:show(InfoMessage:new {
        text = T(_ "Failed to fetch databases: %1", databases),
        timeout = 3,
      })
      return
    end
    if #databases == 0 then
      UIManager:show(InfoMessage:new {
        text = _ "No databases found",
        timeout = 3,
      })
      return
    end

    -- Sorted here rather than by the API: /v1/search's sort options are narrow
    -- and a wrong key is a 400 that would break the picker outright. Sorting by
    -- name costs nothing and is more useful for choosing from a list anyway.
    table.sort(databases, function(a, b)
      return self.api:getDatabaseTitle(a) < self.api:getDatabaseTitle(b)
    end)

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

      for _, db in ipairs(databases) do
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
--------------------------------------------------------------------------------
-- Sync
--------------------------------------------------------------------------------

-- Progress messages are kept to a FIXED shape so Trapper's fast_refresh can reuse
-- the widget. Trapper repaints only the new widget's own rectangle, so a message
-- that shrinks leaves ghost pixels behind on e-ink. A constant line count plus a
-- padded, fixed-width title keeps the geometry stable.
local PROGRESS_TITLE_WIDTH = 22
local PROGRESS_DETAIL_WIDTH = 26

-- Truncate to `width` characters and pad to exactly that, without splitting a
-- UTF-8 sequence. A byte-wise :sub() would cut a multi-byte character in half.
local function fixed_width(text, width)
  text = tostring(text or ""):gsub("%s+", " ")
  local chars = util.splitToChars(text)
  if #chars > width then
    local kept = {}
    for i = 1, width - 1 do
      kept[i] = chars[i]
    end
    return table.concat(kept) .. "\226\128\166" -- U+2026 ellipsis
  end
  return text .. string.rep(" ", width - #chars)
end

function NotionSync:progressText(db, dbs, page, pages, title, detail)
  return table.concat({
    T(_ "Database %1/%2", db, dbs),
    T(_ "Page %1/%2  %3", page, pages, fixed_width(title, PROGRESS_TITLE_WIDTH)),
    fixed_width(detail, PROGRESS_DETAIL_WIDTH),
  }, "\n")
end

-- The single chokepoint for progress display AND cancellation.
--
-- Throttled by TIME, not by page count: an unchanged page produces no repaint at
-- all, while a slow page still shows movement. The cost is that cancellation
-- latency is bounded by the throttle interval plus the in-flight network timeout
-- -- the right trade against repainting e-ink on every request.
function NotionSync:tick(text, force)
  if not self.sync_alive then return false end
  local now = os.time()
  if force or not self.last_tick or now - self.last_tick >= 1 then
    self.last_tick = now
    -- fast_refresh everywhere except forced boundaries, where the layout can
    -- change shape and a full widget replace is safer.
    if Trapper:info(text, not force) == false then
      self.sync_alive = false
      logger.info "NotionSync: cancelled by user"
    end
  end
  return self.sync_alive
end

-- The Dispatcher action registered in onDispatcherRegisterActions dispatches this
-- event. Without a handler the registered action silently does nothing, so a
-- gesture or profile bound to "Notion Sync Now" appears broken.
function NotionSync:onNotionSyncNow()
  self:syncNow()
  return true
end

function NotionSync:syncNow(opts)
  opts = opts or {}

  -- There are two entry points (the menu and the Dispatcher action), and a sync
  -- can take minutes. Without this guard a second sync would reset sync_alive,
  -- silently un-cancelling the first, and both would write the same .part paths.
  if self.sync_running then
    UIManager:show(InfoMessage:new {
      text = _ "A sync is already running.",
      timeout = 2,
    })
    return
  end

  if #self.selected_databases == 0 then
    UIManager:show(InfoMessage:new {
      text = _ "Please select at least one database in Settings",
      timeout = 3,
    })
    return
  end

  NetworkMgr:runWhenOnline(function()
    -- Trapper:wrap must be the LAST thing in the handler: it returns as soon as
    -- the coroutine first yields, so anything after it would run while the sync
    -- is only partway through. The nextTick lets runWhenOnline's own dialogs
    -- settle before Trapper takes over the screen.
    UIManager:nextTick(function()
      Trapper:wrap(function() self:runSync(opts) end)
    end)
  end)
end

-- Plain nested loops.
--
-- This replaces a chain of mutually recursive UIManager:nextTick continuations.
-- Besides being hard to follow, that structure caused a real bug: the pcall
-- wrapped only the first page, because every later page ran in a fresh closure
-- outside it. Here the pcall sits INSIDE the page loop, so a page that throws
-- costs one page -- and there are no escaping closures for the problem to return
-- through.
function NotionSync:runSync(opts)
  local stats = {
    new = 0,
    updated = 0,
    unchanged = 0,
    failed = 0,
    truncated = 0,
    partial = 0,
    page_limited = 0,
    failed_titles = {},
    unsupported = {},
    cancelled = false,
  }

  local image_manager = ImageManager:new()
  self.sync_running = true

  -- Teardown must happen even if the loop throws. The per-page pcall covers page
  -- errors, but anything outside it -- a failed query, a formatting slip -- would
  -- otherwise escape to Trapper:wrap, which logs the error and returns WITHOUT
  -- clearing its widget. The result would be a progress message stuck on screen
  -- forever, no report, and a sync_running flag that blocks every later sync.
  local ok, err = pcall(function()
    self:runSyncLoop(opts, stats, image_manager)
  end)

  self.sync_running = false
  Trapper:reset()

  if not ok then
    logger.err("NotionSync: sync aborted by error:", tostring(err))
    stats.failed = stats.failed + 1
    stats.fatal = tostring(err)
  end

  self:showSyncReport(stats, image_manager)
end

function NotionSync:runSyncLoop(opts, stats, image_manager)
  self.api:resetRetryBudget()

  self.sync_alive = true
  self.last_tick = nil

  local db_count = #self.selected_databases
  if opts.max_databases and opts.max_databases < db_count then
    db_count = opts.max_databases
  end

  self:tick(self:progressText(0, db_count, 0, 0, "", _ "Starting..."), true)

  for db_index = 1, db_count do
    local database = self.selected_databases[db_index]

    if not self:tick(self:progressText(db_index, db_count, 0, 0,
      database.name, _ "Querying database..."), true) then
      stats.cancelled = true
      break
    end

    -- Follows every cursor page. Previously only the first 20 pages of a
    -- database existed as far as the plugin was concerned, with no indication
    -- that anything had been left behind.
    -- opts.max_pages (the debug single-page sync) must also bound the FETCH, not
    -- just trim afterwards: paging through 200 pages to then use one defeats the
    -- point of a debug path that is supposed to take seconds.
    local fetch_limit = opts.max_pages or self.max_pages_per_database
    local ok_query, pages, query_truncated =
      self.api:getAllPages(database.id, fetch_limit)

    if not ok_query then
      -- A whole database dropping out is counted, not merely logged.
      logger.warn("NotionSync: query failed for", database.name, tostring(pages))
      stats.failed = stats.failed + 1
      stats.failed_titles[#stats.failed_titles + 1] = database.name
    else
      if query_truncated then
        stats.page_limited = stats.page_limited + 1
      end

      local page_count = #pages
      if opts.max_pages and opts.max_pages < page_count then
        page_count = opts.max_pages
      end

      -- Filenames are resolved for the whole database up front so that two pages
      -- whose titles sanitise to the same stem both get an id suffix, rather than
      -- whichever happened to be processed second silently overwriting the first.
      local titles = {}
      for i = 1, page_count do
        titles[i] = self.api:getPageTitle(pages[i])
      end
      local entries = {}
      for i = 1, page_count do
        entries[i] = { id = pages[i].id, title = titles[i] }
      end
      local filenames = self.storage:resolveFilenames(entries, ".epub")

      for page_index = 1, page_count do
        local page = pages[page_index]
        local title = titles[page_index]
        -- Fallback covers a page with no id, which resolveFilenames cannot key.
        local filename = filenames[page.id]
          or self.storage:sanitizeFilename(title, ".epub")

        if not self:tick(self:progressText(db_index, db_count,
          page_index, page_count, title, ""), false) then
          stats.cancelled = true
          break
        end

        local ok_page, err = pcall(function()
          self:syncOnePage {
            page = page,
            title = title,
            filename = filename,
            database = database,
            image_manager = image_manager,
            stats = stats,
            opts = opts,
            db_index = db_index,
            db_count = db_count,
            page_index = page_index,
            page_count = page_count,
          }
        end)

        if not ok_page then
          logger.err("NotionSync: error syncing", title, err)
          stats.failed = stats.failed + 1
          stats.failed_titles[#stats.failed_titles + 1] = title
        end
      end
    end

    -- Flushed per database rather than per page or only at the end: a sync that
    -- dies mid-run then loses at most one database's records instead of all of
    -- them, without writing to flash on every single page.
    self.storage:flushState()

    if stats.cancelled then break end
  end
end

function NotionSync:syncOnePage(ctx)
  local page, title = ctx.page, ctx.title
  local database, stats = ctx.database, ctx.stats

  local last_edited = page.last_edited_time
  local should_sync, reason = self.storage:shouldSync(
    page.id, last_edited, ctx.filename, database.name)

  if not should_sync then
    stats.unchanged = stats.unchanged + 1
    if reason == "adopted" then
      -- A record migrated from the old format has no known edit time. Stamp the
      -- current one now, or it would stay unknown forever and an edit would never
      -- be detected.
      self.storage:recordSynced(page.id, last_edited, ctx.filename)
    end
    return
  end

  local is_update = reason == "edited"

  local function detail(text)
    return self:progressText(ctx.db_index, ctx.db_count,
      ctx.page_index, ctx.page_count, title, text)
  end

  -- Cancellation is checked inside the fetch too: a single page can make dozens
  -- of requests and would otherwise be uninterruptible for its whole duration.
  local blocks, tree_meta = NotionBlockTree.fetchPage(self.api, page.id, {
    max_depth = self.max_depth,
    request_budget = self.request_budget,
    should_abort = function() return not self.sync_alive end,
    progress = function(requests)
      self:tick(detail(T(_ "Fetching blocks (%1)", requests)), false)
    end,
  })

  if not blocks then
    -- A failed root fetch means the page's content is unavailable. Writing a
    -- title-only EPUB and recording it as synced would freeze that emptiness in
    -- place permanently, so this is a failure and will be retried next sync.
    logger.warn("NotionSync: no blocks for", page.id, tostring(tree_meta.fatal))
    stats.failed = stats.failed + 1
    stats.failed_titles[#stats.failed_titles + 1] = title
    return
  end

  if tree_meta.aborted then
    stats.cancelled = true
    return
  end
  if tree_meta.truncated then stats.truncated = stats.truncated + 1 end
  if #tree_meta.errors > 0 then stats.partial = stats.partial + 1 end

  local image_urls = NotionXhtml.collectImageURLs(blocks)
  local image_index = 0

  local build_ok, build_err, build_info = NotionEpub:build {
    title = title,
    author = database.name,
    date = page.last_edited_time,
    page_id = page.id,
    source = page.url,
    output_path = self.storage:getOutputPath(ctx.filename, database.name),
    image_urls = image_urls,
    fetch_image = function(url) return ctx.image_manager:fetch(url) end,
    on_progress = function()
      image_index = image_index + 1
      return self:tick(detail(T(_ "Image %1/%2", image_index, #image_urls)), false)
    end,
    render = function(image_map)
      local doc, render_ctx = NotionXhtml.renderPage {
        title = title,
        blocks = blocks,
        image_map = image_map,
      }
      if ctx.opts.dump_xhtml then
        self:writeDebugFile("notionsync-debug.xhtml", doc)
        self:writeDebugFile("notionsync-debug-blocks.txt",
          self:describeBlocks(blocks, image_map))
      end
      return doc, render_ctx
    end,
  }

  if build_info and build_info.render_ctx then
    for btype, count in pairs(build_info.render_ctx.unsupported or {}) do
      stats.unsupported[btype] = (stats.unsupported[btype] or 0) + count
    end
  end

  if build_ok then
    -- Recorded only after the archive was written AND verified.
    self.storage:recordSynced(page.id, last_edited, ctx.filename)
    if is_update then
      stats.updated = stats.updated + 1
    else
      stats.new = stats.new + 1
    end
  elseif build_err == "cancelled" then
    stats.cancelled = true
  else
    logger.warn("NotionSync: build failed for", title, tostring(build_err))
    stats.failed = stats.failed + 1
    stats.failed_titles[#stats.failed_titles + 1] = title
  end
end

function NotionSync:showSyncReport(stats, image_manager)
  local lines = {}

  -- The headline must reflect reality: reporting "complete" while pages failed is
  -- how content loss went unnoticed before.
  if stats.cancelled then
    lines[#lines + 1] = _ "Sync cancelled"
  elseif stats.failed > 0 then
    lines[#lines + 1] = T(_ "Sync finished with %1 problem(s)", stats.failed)
  else
    lines[#lines + 1] = _ "Sync complete!"
  end

  lines[#lines + 1] = T(_ "New: %1   Updated: %2   Unchanged: %3",
    stats.new, stats.updated, stats.unchanged)

  -- An error that escaped the per-page guard aborted the run; say so rather than
  -- letting the counts imply the sync simply finished early.
  if stats.fatal then
    lines[#lines + 1] = T(_ "Stopped by an error: %1", stats.fatal)
  end

  if stats.failed > 0 then
    local names = {}
    for i = 1, math.min(3, #stats.failed_titles) do
      names[#names + 1] = stats.failed_titles[i]
    end
    local suffix = #stats.failed_titles > 3
      and T(_ ", +%1 more", #stats.failed_titles - 3) or ""
    lines[#lines + 1] = T(_ "Failed: %1%2", table.concat(names, ", "), suffix)
  end

  local img = image_manager:getStats()
  if img.downloaded > 0 or img.failed > 0 or img.skipped_too_large > 0 then
    lines[#lines + 1] = T(_ "Images: %1 embedded, %2 failed", img.downloaded, img.failed)
    if img.skipped_too_large > 0 then
      lines[#lines + 1] = T(_ "%1 image(s) too large, skipped", img.skipped_too_large)
    end
  end

  -- Content that exists in Notion but was not retrieved must be reported: the
  -- page would otherwise look complete.
  if stats.truncated > 0 then
    lines[#lines + 1] = T(_ "%1 page(s) hit the request limit", stats.truncated)
  end
  if stats.partial > 0 then
    lines[#lines + 1] = T(_ "%1 page(s) had nested content unavailable", stats.partial)
  end
  if stats.page_limited > 0 then
    lines[#lines + 1] = T(_ "%1 database(s) hit the page limit", stats.page_limited)
  end

  local unsupported = {}
  for btype, count in pairs(stats.unsupported) do
    unsupported[#unsupported + 1] = string.format("%s (%d)", btype, count)
  end
  if #unsupported > 0 then
    table.sort(unsupported)
    lines[#lines + 1] = _ "Unsupported blocks: " .. table.concat(unsupported, ", ")
  end

  -- Bad news must not disappear before it can be read.
  --
  -- Written as a statement, NOT as `cond and nil or 5`: that idiom always yields
  -- 5, because `and nil` is falsy and falls through to the `or`. This shipped
  -- broken twice, so the timeout now has a test.
  local timeout = 5
  if stats.failed > 0 or stats.cancelled then
    timeout = nil
  end

  UIManager:show(InfoMessage:new {
    text = table.concat(lines, "\n"),
    timeout = timeout,
  })
end

return NotionSync
