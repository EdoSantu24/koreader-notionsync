# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A KOReader plugin (`notionsync.koplugin/`) that pulls pages from Notion databases onto an eReader as EPUB files. It runs inside KOReader's LuaJIT environment on the device — **the plugin itself cannot be executed on a dev machine.** The unit tests are therefore the only pre-push signal that exists; behavioural verification means deploying to a device and reading KOReader's logs.

The maintainer's target device is a **Kindle Colorsoft**. Kobo is supported but untested by them.

## Commands

```bash
luajit spec/run.lua        # unit tests -- needs ONLY a LuaJIT binary, no luarocks
luajit spec/lint.lua       # luacheck via its pure-Lua core; reads the same .luacheckrc as CI
```

`spec/run.lua` is a hand-rolled runner, not busted. That is deliberate: busted needs luarocks, which needs a C toolchain to build luafilesystem, which is unavailable on the maintainer's Windows machine. A suite nobody can install is worth less than a small runner everybody can run. Don't "upgrade" it to busted without solving that first.

Requires LuaJIT 2.1 (`winget install DEVCOM.LuaJIT` on Windows). For local linting, install `luacheck` with `--deps-mode=none` to skip luafilesystem, and point `LUA_PATH` at it using a **native** path (`C:/Users/...`), not an MSYS `/c/...` path.

## Deploying to a device

**Which script you need depends on how the device presents itself over USB, and picking wrong doesn't degrade — it cannot work at all.**

| Device appears as | Use |
| --- | --- |
| `This PC\<device>\Internal Storage`, **no drive letter** | `.\deploy-mtp.ps1 -Backup` (PowerShell) |
| A drive letter or mounted volume | `DEVICE_MOUNT_PATH=/d ./deploy.sh` |

Newer Kindles — **Colorsoft, Scribe, recent Paperwhites — use MTP** and never get a drive letter. `deploy.sh` cannot reach them, because it copies with `cp` to a filesystem path and MTP provides none. `deploy-mtp.ps1` goes through the Windows shell COM interface, which is the only way to write to MTP without third-party software.

MTP misbehaves in two specific ways the script compensates for, so preserve this if you touch it: it will not overwrite a file in place (hence delete-then-copy per file), and it silently drops transfers when the device sleeps (hence every copy is verified by byte size rather than assumed). `-WhatIf` dry-runs; `-Backup` pulls the installed copy to `~/notionsync-backup-<timestamp>` first.

`deploy.sh` auto-detects `<mount>/koreader` (Kindle) vs `<mount>/.adds/koreader` (Kobo). Its variable is `DEVICE_MOUNT_PATH`, with `KOBO_MOUNT_PATH` kept as a legacy alias. In Git Bash a drive is `/d`, not `/mnt/d` (that's WSL).

After deploying: eject from the OS, then **fully restart KOReader** — plugins load only at startup, and there is no hot reload. A plugin with a Lua error silently fails to appear in the menu rather than reporting anything, so "Tools → Notion Sync is present" is the smoke test. Errors go to `<koreader>/crash.log` on the device, which can be read back over MTP.

Releases: push to `main` produces a dev artifact; pushing a `v*` tag produces a GitHub release. The release body is extracted from `CHANGELOG.md` by a `sed` range on `## [VERSION]` headers, so the changelog heading must match the tag version exactly or release notes come out empty. See `RELEASE.md`.

## Architecture

`main.lua` is the KOReader `WidgetContainer` — settings, menu, and the sync driver. Everything else is a stateless-ish module it orchestrates:

- `api.lua` — Notion REST client (`ssl.https` + `rapidjson`). Pinned to Notion-Version `2022-06-28`.
- `xhtml.lua` — Notion block JSON → XHTML, plus `collectImageURLs`. Owns the escaping chokepoint and the stylesheet. Depends on `logger` only, which is what keeps it unit-testable off-device.
- `epub.lua` — EPUB 2 assembly via KOReader's `ffi/archiver`: streams images, writes the package documents, verifies the archive.
- `imagemanager.lua` — fetches image bytes into memory (`fetch(url) -> content, content_type`). Deliberately knows nothing about the filesystem.
- `storage.lua` — filesystem layout, filename sanitisation, sync-history file. It does **not** write EPUBs; that is `epub.lua`'s job.

There is no Markdown anywhere in the pipeline any more. `converter.lua` and the vendored `markdown.lua` were deleted: routing through a Markdown 1.0.1 parser was the cause of most known bugs, and it cost 1212 lines to keep.

### Sync data flow

For each selected database → each page: `queryDatabase` → `getBlockChildren` → `xhtml.collectImageURLs` → `epub.build{...}`.

`epub.build` drives the rest through two callbacks the caller supplies, which is what keeps `epub.lua` free of any Notion knowledge and independently testable:

1. `fetch_image(url)` → `ImageManager:fetch`, one image at a time.
2. `render(image_map)` → `xhtml.renderPage`, called *after* the images so it knows which ones succeeded.

Order matters and is load-bearing. Images are written first so the map is complete; the XHTML is rendered next so placeholders for failed downloads are accurate; the OPF is written **last** so its manifest can only list images that actually made it into the archive. A manifest entry for a missing file is an invalid package.

Images never carry a remote URL into the document — `src` is always a local `images/imgNNNNN.ext` path, and a failed download becomes a visible placeholder. A Notion `file` URL is pre-signed and expires, so leaving one in an offline EPUB is worse than admitting the image is gone.

Peak memory is one image, not a page's worth: each is fetched, written, and dropped before the next. There is deliberately no temp directory — the previous staging directory was archived wholesale per page, so every EPUB ended up containing every image downloaded so far in the sync.

### Non-blocking sync loop

`syncNow` must never block KOReader's event loop. Database and page iteration are written as mutually recursive continuations (`processDatabase` → `processPage`) that re-schedule themselves through `UIManager:nextTick`, closing and re-showing the `InfoMessage` each step to render progress. Do not rewrite these as `for` loops — the UI would freeze for the whole sync and progress would never paint. The whole body is wrapped in `pcall` so a mid-sync error surfaces as a dialog rather than killing KOReader.

### Sync history

`<save_dir>/.synced_ids` is an append-only newline-delimited file of keys shaped `<page_id>:epub`. A page is re-fetched if its key is absent *or* the expected output file is missing.

The `:epub` suffix is now a constant, kept only so that pages recorded by an earlier version (which put the output format there) are still recognised. Don't "tidy" it away without a migration — dropping it silently forces a full re-download of every page.

There is no content-hash or `last_edited_time` check, so **edits in Notion never trigger a re-sync**. `Clear sync history` in the menu is the only way to force one.

### On-device layout

```
<save_dir>/                        # default /mnt/onboard/notion_sync (Kobo-specific)
  .synced_ids
  <Sanitized_Database_Name>/<Sanitized_Page_Title>.epub
```

An EPUB is built at `<name>.epub.part` and renamed into place only after the
archive verifies, so the library can never contain a truncated book. A stray
`.part` file means a sync died mid-write; it is safe to delete.

Settings live elsewhere — `DataStorage:getSettingsDir()/notionsync.lua` via `LuaSettings`, not in `save_dir`. Sanitisation strips everything outside `[%w%s-_]` and truncates to 100 chars, so two Notion pages with titles differing only in punctuation collide on one file.

## Conventions and traps

**Module loading.** KOReader framework modules use `require`; plugin-local files must use `dofile(plugin_dir .. "x.lua")` where `plugin_dir` comes from `debug.getinfo(1).source:match "@?(.*/)"`. `require` cannot resolve files inside the plugin directory. Each module is `dofile`d **once** at load; don't reintroduce a per-call `dofile` (`storage.lua` used to do this on every save, reloading a 1212-line parser each time and keeping two divergent module instances alive).

**Escaping has exactly one home.** `xhtml.escapeText` and `xhtml.escapeAttr` are the only functions permitted to prepare caller data for output, and `epub.lua` reuses them for the OPF and NCX. `&` must be substituted first, or later substitutions get double-escaped. Bytes ≥ 0x80 are never inspected, which is what makes the whole thing UTF-8 safe without a `utf8` library.

**Objects.** Hand-rolled prototypes: `Module:new()` sets `setmetatable(o, self); self.__index = self` and returns `o`. There is no inheritance beyond KOReader's `WidgetContainer:extend`.

**`_` is gettext, and it gets shadowed.** All user-facing strings go through `_ "..."`, with `T` (`require("ffi/util").template`) for `%1`-style interpolation. But `for _, v in ipairs(...)` is used throughout, which shadows gettext inside the loop body. Inside such a loop, use a named loop variable if you need `_()`.

**Style is per-file, not global.** `main.lua` and `epub.lua` use 2-space indent and paren-less calls (`require "logger"`, `_ "Sync Now"`); `api.lua`, `converter.lua`, `storage.lua`, `imagemanager.lua` use 4-space indent and parenthesised calls. Match the file you are editing — luacheck will not catch style drift.

It *will* catch a typo'd global, though: `.luacheckrc` uses `std = "luajit"` and deliberately does **not** suppress 111/112/113 (undefined globals) or 212 (unused arguments). Both were previously ignored, which is how `ImageManager:downloadImage` came to accept and ignore its `page_id` argument. If a new warning appears, fix the code rather than re-adding an ignore, and if an ignore is genuinely warranted, comment why it is wrong rather than merely inconvenient.

**Network access.** Wrap anything hitting the network in `NetworkMgr:runWhenOnline(...)`, as `syncNow` and `showDatabaseSelector` do.

Update `CHANGELOG.md` under `## [Unreleased]` as part of any user-visible change.

## Known bugs

These are confirmed and reproduced, not suspicions. Each is **pinned by a test**
in `spec/`, so the fix shows up as a deliberate test change rather than an
unnoticed shift in output.

**Child blocks are never fetched.** `getBlockChildren` is called once per page and
nothing recurses, so anything Notion stores as a child is unavailable: **table
rows**, nested list levels, and the bodies of toggles, callouts, columns and
synced blocks. The renderer handles all of these correctly *when children are
present* and emits a visible placeholder when they are not, so this shows up as
`[table rows not fetched]` rather than as silence. Fixing it means recursive
fetching with a depth cap and a request budget.

**No pagination.** `searchDatabases` caps at 20 databases, `queryDatabase` at 20
pages per database, `getBlockChildren` at 100 blocks per page, and no
`next_cursor` is followed anywhere. No `sorts` is sent either, so *which* 20 pages
sync is not stable between runs. When adding this, note that KOReader's
`rapidjson` decodes JSON `null` to a lightuserdata sentinel, **not** `nil` — so
`if res.next_cursor then` is truthy on the last page and loops forever. Test
`type(cursor) == "string"`. Sort by `created_time` ascending, not
`last_edited_time`: sorting by a mutable field while paginating lets pages
reorder between cursor requests, which silently skips or duplicates them.

**Edits in Notion never re-sync.** Sync state is keyed on page id alone, with no
`last_edited_time` comparison, so a page fixed in Notion keeps its stale copy
forever. `Clear sync history` in the menu is the only way to force a refresh.

**Non-ASCII titles collapse.** `storage.lua:sanitizeFilename` is byte-oriented
with an ASCII-only `%w`, so `读书笔记` becomes `untitled.epub`. Distinct pages
overwrite each other while each is recorded as synced. Titles differing only in
punctuation collide the same way.

**Only the first rich-text segment of a title is read.** `api.lua:getPageTitle`
takes `title[1].plain_text`, so `Chapter **One**` truncates to `"Chapter "`.

**The `pcall` in `syncNow` covers only the first page.** Every later page runs in
a fresh `UIManager:nextTick` closure outside it, so a mid-sync error escapes
unprotected. There is also no way to cancel a running sync, and each page forces
a blocking full-screen e-ink repaint.
