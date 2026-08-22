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
- `converter.lua` — Notion block JSON → Markdown, plus `extractImageURLs` for the EPUB path.
- `epub.lua` — Markdown → styled XHTML, then EPUB 2 zip assembly via KOReader's `ffi/archiver`.
- `imagemanager.lua` — downloads images to a temp dir, dedupes by URL, tracks download/cache/fail stats.
- `storage.lua` — filesystem layout, filename sanitisation, sync-history file.
- `markdown.lua` — **vendored third-party Markdown parser.** Excluded from luacheck in `.luacheckrc`; don't reformat or lint-fix it.

### Sync data flow

For each selected database → each page: `queryDatabase` → `getBlockChildren` → `extractImageURLs` → `ImageManager:downloadImage` per URL → `pageToMarkdown` → `markdownToHtml` → `saveEpub`.

Markdown is only an *internal intermediate* on the way to XHTML — there is no Markdown output format. It is also the source of most known bugs (see below) and is slated for removal in favour of rendering blocks straight to XHTML.

Images are downloaded *before* Markdown conversion. The URL→local-path map is applied by `epub.lua:markdownToHtml`, which string-substitutes `src="<notion url>"` for `src="images/<file>"` in the generated HTML. **This substitution does not work** — see the known bugs below.

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
  .notion_image_cache/             # created per sync, deleted after
  <Sanitized_Database_Name>/<Sanitized_Page_Title>.epub
```

Settings live elsewhere — `DataStorage:getSettingsDir()/notionsync.lua` via `LuaSettings`, not in `save_dir`. Sanitisation strips everything outside `[%w%s-_]` and truncates to 100 chars, so two Notion pages with titles differing only in punctuation collide on one file.

## Conventions and traps

**Module loading.** KOReader framework modules use `require`; plugin-local files must use `dofile(plugin_dir .. "x.lua")` where `plugin_dir` comes from `debug.getinfo(1).source:match "@?(.*/)"`. `require` cannot resolve files inside the plugin directory. Note `storage.lua` re-`dofile`s `epub.lua` on every save.

**Objects.** Hand-rolled prototypes: `Module:new()` sets `setmetatable(o, self); self.__index = self` and returns `o`. There is no inheritance beyond KOReader's `WidgetContainer:extend`.

**`_` is gettext, and it gets shadowed.** All user-facing strings go through `_ "..."`, with `T` (`require("ffi/util").template`) for `%1`-style interpolation. But `for _, v in ipairs(...)` is used throughout, which shadows gettext inside the loop body. Inside such a loop, use a named loop variable if you need `_()`.

**Style is per-file, not global.** `main.lua` and `epub.lua` use 2-space indent and paren-less calls (`require "logger"`, `_ "Sync Now"`); `api.lua`, `converter.lua`, `storage.lua`, `imagemanager.lua` use 4-space indent and parenthesised calls. Match the file you are editing — luacheck will not catch style drift.

It *will* catch a typo'd global, though: `.luacheckrc` uses `std = "luajit"` and deliberately does **not** suppress 111/112/113 (undefined globals) or 212 (unused arguments). Both were previously ignored, which is how `ImageManager:downloadImage` came to accept and ignore its `page_id` argument. If a new warning appears, fix the code rather than re-adding an ignore, and if an ignore is genuinely warranted, comment why it is wrong rather than merely inconvenient.

**Network access.** Wrap anything hitting the network in `NetworkMgr:runWhenOnline(...)`, as `syncNow` and `showDatabaseSelector` do.

Update `CHANGELOG.md` under `## [Unreleased]` as part of any user-visible change.

## Known bugs

These are confirmed and reproduced, not suspicions. Each is **pinned by a test**
named `BUG_*` in `spec/`, so the fix shows up as a deliberate test change rather
than an unnoticed shift in output. Don't be surprised by a test that asserts
broken behaviour — that is the point, and flipping one is how you prove a fix.

**Images never embed** (`spec/epub_spec.lua`). `markdown.lua`'s `encode_alt`
escapes `&` → `&amp;` when writing a URL into `src="..."`, but
`epub.lua:markdownToHtml` builds its search pattern from the *raw* URL. Notion
pre-signed S3 URLs are full of `&`, so the substitution never matches and the
EPUB keeps an already-expired remote link. The discriminating pair of tests: a
URL *without* an ampersand rewrites fine; a real Notion URL does not. Separately,
`imagemanager.lua:getExtensionFromURL` mis-parses those URLs (they contain `/`
inside the query string) so every image is labelled `jpg`.

**Tables are impossible**, for three independent reasons (`spec/converter_spec.lua`).
`converter.lua:blockToMarkdown` is a whitelist with no `else`, and `table`/
`table_row` are absent, so they return `""` and vanish. Table rows are *children*
in the Notion API and nothing reads `has_children` or recurses — the `indent`
parameter exists but no caller passes it. And the vendored parser has no
pipe-table support at all (`|` appears nowhere in its 1212 lines).

**Silent content loss.** Unhandled block types (callout, toggle, column,
synced_block, equation, child_page, embed, …) vanish with no log line at all.
Fenced code blocks are emitted but the parser only understands 4-space-indented
code, so they leak as literal backticks. `~~strikethrough~~` and `[x]` checkboxes
render as literal punctuation.

**No pagination.** `searchDatabases` caps at 20 databases, `queryDatabase` at 20
pages per database, `getBlockChildren` at 100 blocks per page, and no
`next_cursor` is followed anywhere. No `sorts` is sent either, so *which* 20
pages sync is not stable between runs.

**Failures are invisible.** Database-query, block-fetch and save failures are all
log-only; the final dialog has no failure counter and always says "Sync
complete!". `epub.lua` treats `io.open(path, "r")` as proof of success — true for
a 0-byte file — and discards `writer:close()`'s return value, so a corrupt EPUB
gets recorded as synced and is never retried.

**Non-ASCII titles collapse.** `storage.lua:sanitizeFilename` is byte-oriented
with an ASCII-only `%w`, so `读书笔记` becomes `untitled.epub`. Distinct pages
overwrite each other while each is recorded as synced.

**The `pcall` in `syncNow` covers only the first page.** Every later page runs in
a fresh `UIManager:nextTick` closure outside it.
