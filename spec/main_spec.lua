--
-- Progress formatting and the sync report.
--
-- The sync loop itself needs a device, but these two are pure and both encode
-- requirements that have already gone wrong once:
--
--   progressText must always produce the SAME NUMBER OF LINES. Trapper's
--   fast_refresh repaints only the new widget's rectangle, so a message that
--   shrinks leaves ghost pixels on e-ink. Fixed geometry is what makes the cheap
--   partial refresh safe.
--
--   showSyncReport must never claim success when something failed. Reporting
--   "Sync complete!" over dropped content is how the original bugs stayed hidden.
--

local h = require("spec.helper")
local Sync = h.load_plugin("main")

local function fake_stats(over)
    local s = {
        new = 0, updated = 0, unchanged = 0, failed = 0, truncated = 0, partial = 0,
        page_limited = 0,
        failed_titles = {}, unsupported = {}, cancelled = false,
    }
    for k, v in pairs(over or {}) do s[k] = v end
    return s
end

local function fake_images(over)
    local s = { downloaded = 0, failed = 0, skipped_too_large = 0, bytes = 0 }
    for k, v in pairs(over or {}) do s[k] = v end
    return { getStats = function() return s end }
end

local function report(stats, images)
    h.shown = {}
    Sync:showSyncReport(stats, images or fake_images())
    return h.shown[#h.shown].text
end

--------------------------------------------------------------------------------

-- The old default was the literal Kobo path "/mnt/onboard/notion_sync", which
-- does not exist on a Kindle. Directory creation then fell through to
-- `mkdir -p` and, on a writable rootfs, succeeded -- putting the library
-- somewhere invisible over USB and liable to be wiped by a firmware update.
describe("defaultSaveDir", function()
    local original = h.device.home_dir
    local function with_home(value, fn)
        h.device.home_dir = value
        local ok, err = pcall(fn)
        h.device.home_dir = original
        if not ok then error(err, 0) end
    end

    -- The branch every real user takes, and the reason this change exists.
    it("uses_the_kindle_home_directory", function()
        with_home("/mnt/us", function()
            assert_eq(Sync.defaultSaveDir(), "/mnt/us/notion_sync")
        end)
    end)

    it("uses_the_kobo_home_directory", function()
        with_home("/mnt/onboard", function()
            assert_eq(Sync.defaultSaveDir(), "/mnt/onboard/notion_sync")
        end)
    end)

    -- generic/device.lua sets home_dir = nil, which is what a desktop build looks
    -- like. The path must still be absolute and usable.
    it("falls_back_when_the_device_reports_no_home", function()
        with_home(nil, function()
            local dir = Sync.defaultSaveDir()
            assert_match(dir, "^/")
            assert_match(dir, "notion_sync$")
        end)
    end)

    it("falls_back_on_an_empty_home", function()
        with_home("", function()
            assert_match(Sync.defaultSaveDir(), "notion_sync$")
        end)
    end)

    -- The bug: a Kobo path baked in regardless of the device it runs on.
    it("is_not_hardcoded_to_one_platform", function()
        local kindle, kobo
        with_home("/mnt/us", function() kindle = Sync.defaultSaveDir() end)
        with_home("/mnt/onboard", function() kobo = Sync.defaultSaveDir() end)
        assert_true(kindle ~= kobo, "the default must follow the device")
    end)
end)

-- The Notion integration token is an account credential with read access to every
-- database shared with the integration. This dialog used to render it in clear on a
-- screen that gets read over people's shoulders.
describe("showTokenInput", function()
    local function open(token)
        h.shown = {}
        local s = setmetatable({ notion_token = token }, { __index = Sync })
        s:showTokenInput()
        return h.shown[#h.shown]
    end

    it("masks_the_token_field", function()
        assert_eq(open("secret_abc123").text_type, "password")
    end)

    -- Masking must not make an existing token unrecoverable: it stays pre-filled
    -- so it need not be retyped, and InputText adds its own "Show password"
    -- toggle so the value can still be checked deliberately.
    it("still_prefills_the_existing_token", function()
        assert_eq(open("secret_abc123").input, "secret_abc123")
    end)

    -- Asserts both actions are reachable, not that there are exactly two
    -- buttons: adding a third would be a valid change and must not fail here.
    it("still_offers_cancel_and_save", function()
        local labels = {}
        for _, row in ipairs(open("t").buttons or {}) do
            for _, b in ipairs(row) do labels[#labels + 1] = b.text end
        end
        local joined = table.concat(labels, ",")
        assert_contains(joined, "Save")
        assert_contains(joined, "Cancel")
    end)

    it("opens_with_no_token_set", function()
        assert_eq(open(nil).text_type, "password")
    end)
end)

describe("progressText", function()
    -- The invariant fast_refresh depends on.
    it("always_produces_three_lines", function()
        local cases = {
            { 1, 1, 1, 1, "short", "" },
            { 12, 34, 567, 890, "a much longer page title than fits", "Fetching blocks (12)" },
            { 0, 0, 0, 0, "", "" },
            { 1, 2, 3, 4, "读书笔记 with mixed CJK and latin text", "Image 3/9" },
        }
        for _, c in ipairs(cases) do
            local text = Sync:progressText(c[1], c[2], c[3], c[4], c[5], c[6])
            local _, newlines = text:gsub("\n", "")
            assert_eq(newlines, 2, "expected 3 lines for title " .. tostring(c[5]))
        end
    end)

    it("includes_the_counters", function()
        local text = Sync:progressText(2, 5, 7, 9, "Title", "detail")
        assert_contains(text, "2/5")
        assert_contains(text, "7/9")
        assert_contains(text, "Title")
        assert_contains(text, "detail")
    end)

    -- A byte-wise :sub() would cut a multi-byte character in half, which renders
    -- as a replacement glyph and could corrupt the message width.
    it("truncates_cjk_without_splitting_a_character", function()
        local long_cjk = string.rep("读", 60)
        local text = Sync:progressText(1, 1, 1, 1, long_cjk, "")
        -- Every byte sequence in the output must still be valid UTF-8.
        local rebuilt = table.concat(h.util.splitToChars(text))
        assert_eq(rebuilt, text, "output contains an invalid UTF-8 sequence")
    end)

    it("pads_short_titles_so_the_geometry_is_stable", function()
        local short = Sync:progressText(1, 1, 1, 1, "ab", "x")
        local longer = Sync:progressText(1, 1, 1, 1, "abcdefgh", "x")
        -- Line 2 holds the title; both must be the same character length.
        local function line2(s) return (select(2, s:match("([^\n]*)\n([^\n]*)"))) end
        assert_eq(#h.util.splitToChars(line2(short)),
            #h.util.splitToChars(line2(longer)),
            "title line length must not vary with title length")
    end)
end)

describe("showSyncReport", function()
    it("says_complete_only_when_nothing_failed", function()
        local text = report(fake_stats { new = 3, unchanged = 7 })
        assert_contains(text, "Sync complete!")
        assert_contains(text, "New: 3")
        assert_contains(text, "Unchanged: 7")
    end)

    -- The regression that mattered: a summary claiming success over lost content.
    it("never_says_complete_when_a_page_failed", function()
        local text = report(fake_stats { new = 1, failed = 2,
            failed_titles = { "Page A", "Page B" } })
        assert_not_contains(text, "Sync complete!")
        assert_contains(text, "2 problem(s)")
        assert_contains(text, "Page A")
    end)

    it("reports_cancellation_distinctly_from_failure", function()
        local text = report(fake_stats { cancelled = true, new = 1 })
        assert_contains(text, "cancelled")
        assert_not_contains(text, "Sync complete!")
        assert_not_contains(text, "problem")
    end)

    it("abbreviates_a_long_failure_list", function()
        local text = report(fake_stats { failed = 5,
            failed_titles = { "A", "B", "C", "D", "E" } })
        assert_contains(text, "+2 more")
    end)

    it("reports_image_outcomes", function()
        local text = report(fake_stats { new = 1 },
            fake_images { downloaded = 4, failed = 1 })
        assert_contains(text, "4 embedded")
        assert_contains(text, "1 failed")
    end)

    it("reports_oversized_images_separately", function()
        local text = report(fake_stats { new = 1 },
            fake_images { downloaded = 1, skipped_too_large = 2 })
        assert_contains(text, "too large")
    end)

    it("omits_the_image_line_when_there_were_none", function()
        assert_not_contains(report(fake_stats { new = 1 }), "Images")
    end)

    -- Content that exists in Notion but was not retrieved must be visible in the
    -- summary, or the page looks complete when it is not.
    it("reports_pages_that_hit_the_request_limit", function()
        local text = report(fake_stats { new = 2, truncated = 1 })
        assert_contains(text, "request limit")
    end)

    it("reports_pages_with_unavailable_nested_content", function()
        local text = report(fake_stats { new = 2, partial = 3 })
        assert_contains(text, "nested content unavailable")
    end)

    it("lists_unsupported_block_types_with_counts", function()
        local text = report(fake_stats { new = 1,
            unsupported = { video = 2, template = 1 } })
        assert_contains(text, "Unsupported blocks:")
        assert_contains(text, "template (1)")
        assert_contains(text, "video (2)")
    end)

    -- A five-second timeout on bad news is the same as no message at all.
    it("stays_on_screen_when_something_went_wrong", function()
        h.shown = {}
        Sync:showSyncReport(fake_stats { failed = 1, failed_titles = { "X" } }, fake_images())
        assert_eq(h.shown[#h.shown].timeout, nil)

        h.shown = {}
        Sync:showSyncReport(fake_stats { new = 1 }, fake_images())
        assert_eq(h.shown[#h.shown].timeout, 5)
    end)
end)

describe("sync_entry", function()
    local function instance(over)
        local o = setmetatable({
            selected_databases = { { id = "db", name = "DB" } },
        }, { __index = Sync })
        for k, v in pairs(over or {}) do o[k] = v end
        return o
    end

    -- There are two entry points (the menu and the Dispatcher action) and a sync
    -- can run for minutes. A second start would reset sync_alive, silently
    -- un-cancelling the first, and both would write the same .part paths.
    it("refuses_to_start_a_second_sync", function()
        h.shown = {}
        local s = instance { sync_running = true }
        s:syncNow()
        assert_eq(#h.shown, 1)
        assert_contains(h.shown[1].text, "already running")
    end)

    it("still_refuses_with_no_databases_selected", function()
        h.shown = {}
        local s = instance { selected_databases = {} }
        s:syncNow()
        assert_contains(h.shown[1].text, "at least one database")
    end)

    -- The Dispatcher action registers event NotionSyncNow; with no handler a
    -- gesture bound to it does nothing at all.
    it("has_a_dispatcher_event_handler", function()
        assert_eq(type(Sync.onNotionSyncNow), "function")
    end)

    it("the_handler_reports_it_consumed_the_event", function()
        local s = instance { sync_running = true }
        assert_true(s:onNotionSyncNow())
    end)
end)

describe("runSync_teardown", function()
    -- Trapper:wrap logs an error and returns WITHOUT clearing its widget, so an
    -- error outside the per-page guard would leave a progress message on screen
    -- forever, produce no report, and leave sync_running stuck true -- blocking
    -- every later sync.
    local function run_with_failing_loop()
        h.shown = {}
        local s = setmetatable({
            selected_databases = {},
            runSyncLoop = function() error("boom") end,
        }, { __index = Sync })
        s:runSync {}
        return s
    end

    it("still_shows_a_report_when_the_loop_throws", function()
        run_with_failing_loop()
        assert_true(#h.shown > 0, "a report must be shown even on a fatal error")
        assert_contains(h.shown[#h.shown].text, "Stopped by an error")
    end)

    it("clears_the_running_flag_so_the_next_sync_is_not_blocked", function()
        local s = run_with_failing_loop()
        assert_false(s.sync_running)
    end)

    it("counts_the_fatal_error_as_a_failure", function()
        run_with_failing_loop()
        local text = h.shown[#h.shown].text
        assert_not_contains(text, "Sync complete!")
    end)

    it("keeps_the_report_on_screen_after_a_fatal_error", function()
        run_with_failing_loop()
        assert_eq(h.shown[#h.shown].timeout, nil)
    end)

    -- The teardown exists to run when things went wrong, so it must not itself
    -- throw. It clears api.should_abort, and a sync can die before an api exists.
    it("survives_a_teardown_with_no_api", function()
        local s = run_with_failing_loop()
        assert_eq(s.api, nil)
    end)

    -- A stale hook left on the api would see sync_alive false from the finished
    -- sync and abort the next network call -- the database picker, with no sync
    -- running at all.
    it("clears_the_retry_abort_hook_even_when_the_loop_throws", function()
        h.shown = {}
        local api = { should_abort = function() return false end }
        local s = setmetatable({
            selected_databases = {},
            api = api,
            runSyncLoop = function() error("boom") end,
        }, { __index = Sync })
        s:runSync {}
        assert_eq(api.should_abort, nil,
            "a stale abort hook would break the next non-sync request")
    end)
end)

describe("tick", function()
    local function fresh()
        h.Trapper.resetRecorder()
        local o = setmetatable({ sync_alive = true, last_tick = nil }, { __index = Sync })
        return o
    end

    it("uses_a_full_refresh_when_forced_and_fast_otherwise", function()
        local s = fresh()
        s:tick("first", true)
        assert_eq(h.Trapper.infos[1].fast, false, "forced tick must not use fast_refresh")
    end)

    -- Throttling is what keeps e-ink repaints down; without it every request
    -- would repaint the screen.
    it("throttles_unforced_ticks_within_the_same_second", function()
        local s = fresh()
        s:tick("a", true)
        local after_forced = #h.Trapper.infos
        s:tick("b", false)
        s:tick("c", false)
        assert_eq(#h.Trapper.infos, after_forced,
            "rapid unforced ticks must not each repaint")
    end)

    it("a_forced_tick_always_displays", function()
        local s = fresh()
        s:tick("a", true)
        s:tick("b", true)
        assert_eq(#h.Trapper.infos, 2)
    end)

    it("latches_cancellation_and_stays_cancelled", function()
        local s = fresh()
        h.Trapper.cancel_after = 1
        assert_false(s:tick("a", true))
        assert_false(s.sync_alive)
        -- Once cancelled it must stop reporting alive even for a forced tick.
        h.Trapper.cancel_after = nil
        assert_false(s:tick("b", true))
    end)

    it("remembers_the_last_text_so_a_retry_wait_can_repaint_it", function()
        local s = fresh()
        s:tick("three lines", true)
        assert_eq(s.last_tick_text, "three lines")
    end)
end)

--------------------------------------------------------------------------------
-- retry abort hook
--------------------------------------------------------------------------------

-- api.lua slices its backoff and calls should_abort between slices. That hook
-- has to go through tick, not read sync_alive directly: Trapper:info is BOTH the
-- repaint and the dismiss check, so a hook that only read the flag would leave
-- the sync interruptible in principle while never noticing the interruption.
describe("retry_abort_hook", function()
    local function wired()
        h.Trapper.resetRecorder()
        local api = { resetRetryBudget = function() end }
        local s = setmetatable({
            api = api,
            selected_databases = {},
        }, { __index = Sync })
        -- runSyncLoop wires the hook before touching the database list, so an
        -- empty list is enough to reach it.
        s:runSyncLoop({}, { failed = 0 }, nil)
        return s, api
    end

    it("is_installed_by_the_sync_loop", function()
        local _, api = wired()
        assert_eq(type(api.should_abort), "function")
    end)

    it("reports_no_abort_while_the_sync_is_alive", function()
        local s, api = wired()
        s.sync_alive = true
        s:tick("progress", true)
        assert_false(api.should_abort())
    end)

    it("reports_abort_once_the_sync_is_cancelled", function()
        local s, api = wired()
        s.sync_alive = false
        assert_true(api.should_abort())
    end)

    -- Before the first tick there is no text to repaint. Ticking with an empty
    -- string would change the widget's shape and ghost on e-ink, so the hook
    -- falls back to reading the flag.
    it("does_not_repaint_before_the_first_tick", function()
        local s, api = wired()
        s.sync_alive = true
        s.last_tick_text = nil
        local before = #h.Trapper.infos
        assert_false(api.should_abort())
        assert_eq(#h.Trapper.infos, before,
            "must not paint a widget with no text to paint")
    end)

    -- The hook goes through tick, so a dismiss during a retry wait is seen and
    -- latches, exactly as it does between pages.
    it("notices_a_dismiss_arriving_during_a_wait", function()
        local s, api = wired()
        s.sync_alive = true
        s:tick("progress", true)
        s.last_tick = nil            -- let the next tick through the throttle
        h.Trapper.cancel_after = 1
        assert_true(api.should_abort())
        assert_false(s.sync_alive, "the cancellation must latch")
        h.Trapper.cancel_after = nil
    end)
end)
