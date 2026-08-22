# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A KOReader plugin (`notionsync.koplugin/`) that pulls pages from Notion databases onto an eReader as EPUB or Markdown files. It runs inside KOReader's LuaJIT environment on the device — there is no way to execute it on a dev machine, and there is no test suite. The only local verification is linting; behavioural verification means deploying to a device and reading KOReader's logs.

## Commands

```bash
luarocks install luacheck
luacheck notionsync.koplugin/      # the only local check; CI runs exactly this

export KOBO_MOUNT_PATH="/path/to/mounted/device"
./deploy.sh                        # wipes and re-copies *.lua to $KOBO_MOUNT_PATH/.adds/koreader/plugins/notionsync.koplugin/
```

After deploying, restart KOReader to reload the plugin — it is not hot-reloaded.

Releases: push to `main` produces a dev artifact; pushing a `v*` tag produces a GitHub release. The release body is extracted from `CHANGELOG.md` by a `sed` range on `## [VERSION]` headers, so the changelog heading must match the tag version exactly or release notes come out empty. See `RELEASE.md`.

## Architecture

`main.lua` is the KOReader `WidgetContainer` — settings, menu, and the sync driver. Everything else is a stateless-ish module it orchestrates:

- `api.lua` — Notion REST client (`ssl.https` + `rapidjson`). Pinned to Notion-Version `2022-06-28`.
- `converter.lua` — Notion block JSON → Markdown, plus `extractImageURLs` for the EPUB path.
- `epub.lua` — Markdown → styled XHTML, then EPUB 2 zip assembly via KOReader's `ffi/archiver`.
- `imagemanager.lua` — downloads images to a temp dir, dedupes by URL, tracks download/cache/fail stats.
- `storage.lua` — filesystem layout, filename sanitisation, sync-history file.
- `markdown.lua` — **vendored third-party Markdown parser.** Excluded from luacheck in `.luacheckrc`; don't reformat or lint-fix it.

### Sync data flow

For each selected database → each page: `queryDatabase` → `getBlockChildren` → (EPUB only: `extractImageURLs` → `ImageManager:downloadImage` per URL) → `pageToMarkdown` → either `saveMarkdown`, or `markdownToHtml` + `saveEpub`.

Images are downloaded *before* Markdown conversion. The URL→local-path map is applied by `epub.lua:markdownToHtml`, which string-substitutes `src="<notion url>"` for `src="images/<file>"` in the generated HTML. Notion's `file`-type image URLs are pre-signed and expire, which is why EPUB embeds them and Markdown output just links out.

### Non-blocking sync loop

`syncNow` must never block KOReader's event loop. Database and page iteration are written as mutually recursive continuations (`processDatabase` → `processPage`) that re-schedule themselves through `UIManager:nextTick`, closing and re-showing the `InfoMessage` each step to render progress. Do not rewrite these as `for` loops — the UI would freeze for the whole sync and progress would never paint. The whole body is wrapped in `pcall` so a mid-sync error surfaces as a dialog rather than killing KOReader.

### Sync history

`<save_dir>/.synced_ids` is an append-only newline-delimited file of keys shaped `<page_id>:<output_format>`. A page is re-fetched if its key is absent *or* the expected output file is missing. The format is part of the key, and switching output format additionally calls `clearSyncHistory()` — hence a full re-sync on format change. There is no content-hash or `last_edited_time` check, so edits in Notion do not trigger a re-sync of an already-synced page.

### On-device layout

```
<save_dir>/                        # default /mnt/onboard/notion_sync (Kobo-specific)
  .synced_ids
  .notion_image_cache/             # created per sync, deleted after
  <Sanitized_Database_Name>/<Sanitized_Page_Title>.epub
```

Settings live elsewhere — `DataStorage:getSettingsDir()/notionsync.lua` via `LuaSettings`, not in `save_dir`. Sanitisation strips everything outside `[%w%s-_]` and truncates to 100 chars, so two Notion pages with titles differing only in punctuation collide on one file.

## Conventions and traps

**Module loading.** KOReader framework modules use `require`; plugin-local files must use `dofile(plugin_dir .. "x.lua")` where `plugin_dir` comes from `debug.getinfo(1).source:match "@?(.*/)"`. `require` cannot resolve files inside the plugin directory. Note `storage.lua` re-`dofile`s `epub.lua` on every save.

**Objects.** Hand-rolled prototypes: `Module:new()` sets `setmetatable(o, self); self.__index = self` and returns `o`. There is no inheritance beyond KOReader's `WidgetContainer:extend`.

**`_` is gettext, and it gets shadowed.** All user-facing strings go through `_ "..."`, with `T` (`require("ffi/util").template`) for `%1`-style interpolation. But `for _, v in ipairs(...)` is used throughout, which shadows gettext inside the loop body. Inside such a loop, use a named loop variable if you need `_()`.

**Style is per-file, not global.** `main.lua` and `epub.lua` use 2-space indent and paren-less calls (`require "logger"`, `_ "Sync Now"`); `api.lua`, `converter.lua`, `storage.lua`, `imagemanager.lua` use 4-space indent and parenthesised calls. Match the file you are editing. `.luacheckrc` silences unused locals/args and undefined globals, so it will not catch style drift or typo'd globals.

**No pagination.** `searchDatabases` caps at 20 databases, `queryDatabase` at 20 pages per database, `getBlockChildren` at 100 blocks per page, and no `next_cursor` is followed anywhere. Long pages are silently truncated.

**Block coverage is a whitelist.** `converter.lua:blockToMarkdown` handles paragraph, heading_1–3, bulleted/numbered list items, code, quote, divider, to_do, and image. Anything else (tables, callouts, toggles, child pages, embeds) yields an empty string and vanishes. Nested block children are never fetched — the `indent` parameter exists but nothing recurses.

**Network access.** Wrap anything hitting the network in `NetworkMgr:runWhenOnline(...)`, as `syncNow` and `showDatabaseSelector` do.

Update `CHANGELOG.md` under `## [Unreleased]` as part of any user-visible change.
