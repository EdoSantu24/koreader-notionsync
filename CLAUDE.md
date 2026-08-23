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
- `blocktree.lua` — fetches a page's block tree, recursing into children. Takes `api` as a parameter rather than requiring it, which is what makes it testable with a fake and no network.
- `xhtml.lua` — Notion block JSON → XHTML, plus `collectImageURLs`. Owns the escaping chokepoint and the stylesheet. Depends on `logger` only, which is what keeps it unit-testable off-device.
- `epub.lua` — EPUB 2 assembly via KOReader's `ffi/archiver`: streams images, writes the package documents, verifies the archive.
- `imagemanager.lua` — fetches image bytes into memory (`fetch(url) -> content, content_type`). Deliberately knows nothing about the filesystem.
- `storage.lua` — filesystem layout, filename sanitisation, sync-history file. It does **not** write EPUBs; that is `epub.lua`'s job.

There is no Markdown anywhere in the pipeline any more. `converter.lua` and the vendored `markdown.lua` were deleted: routing through a Markdown 1.0.1 parser was the cause of most known bugs, and it cost 1212 lines to keep.

### Sync data flow

For each selected database → each page: `queryDatabase` → `blocktree.fetchPage` (which fans out into many `getBlockChildren` calls) → `xhtml.collectImageURLs` → `epub.build{...}`.

`epub.build` drives the rest through two callbacks the caller supplies, which is what keeps `epub.lua` free of any Notion knowledge and independently testable:

1. `fetch_image(url)` → `ImageManager:fetch`, one image at a time.
2. `render(image_map)` → `xhtml.renderPage`, called *after* the images so it knows which ones succeeded.

Order matters and is load-bearing. Images are written first so the map is complete; the XHTML is rendered next so placeholders for failed downloads are accurate; the OPF is written **last** so its manifest can only list images that actually made it into the archive. A manifest entry for a missing file is an invalid package.

Images never carry a remote URL into the document — `src` is always a local `images/imgNNNNN.ext` path, and a failed download becomes a visible placeholder. A Notion `file` URL is pre-signed and expires, so leaving one in an offline EPUB is worse than admitting the image is gone.

Peak memory is one image, not a page's worth: each is fetched, written, and dropped before the next. There is deliberately no temp directory — the previous staging directory was archived wholesale per page, so every EPUB ended up containing every image downloaded so far in the sync.

### Sync loop

`syncNow` hands off to `Trapper:wrap`, and `runSync` is then **plain nested `for` loops**. This replaced a chain of mutually recursive `UIManager:nextTick` continuations, which was not just hard to follow: it caused a real bug, because the `pcall` wrapped only the first page while every later page ran in a fresh closure outside it. The `pcall` now sits inside the page loop, so a page that throws costs one page.

`Trapper:wrap` must be the **last** thing in its handler — it returns as soon as the coroutine first yields, so anything after it would run mid-sync.

All progress and cancellation goes through `NotionSync:tick(text, force)`. It is throttled by *time* (~1s), so an unchanged page causes no repaint while a slow page still shows movement; cancellation latency is therefore bounded by the throttle interval plus the in-flight network timeout. Cancellation is checked between databases, between pages, inside `blocktree` (via `should_abort`, because one page can make dozens of requests) and before each image download.

**Progress text must keep a fixed shape.** `Trapper:info(text, fast_refresh)` with `fast_refresh` repaints only the *new* widget's rectangle, so a message that shrinks leaves ghost pixels on e-ink. `progressText` therefore always emits three lines with a padded, fixed-width title, and there is a test asserting the line count. Forced ticks (database boundaries) use a full refresh because the layout can change shape.

### Pagination

`api.collectAll(fetch, max_items)` walks every cursor page, and is used for the
database list and for a database's pages.

`blocktree.lua` deliberately has its **own** cursor loop rather than calling it:
child fetching counts every request against a shared per-page budget and has to be
able to abort mid-walk, neither of which `collectAll` models. The duplication is
small and intentional — but both copies need the same cursor guard, so if you
change one, check the other.

Two rules in it are load-bearing. The cursor check is `type(cursor) == "string"`,
**not** a truthiness test: KOReader's `rapidjson` decodes JSON `null` to a
lightuserdata sentinel rather than `nil`, so `if res.next_cursor then` is *true*
on the last page and spins until a cap stops it. And there is an absolute
request backstop independent of any user setting, because a server that kept
returning `has_more` with a fresh cursor would otherwise run until the battery
died.

`queryDatabase` sorts by **`created_time` ascending, not `last_edited_time`**.
Sorting on a mutable field while paginating is unstable — a page edited between
two cursor requests moves within the result set and is then skipped or returned
twice. Change detection reads each page's own `last_edited_time` instead.

If the API rejects the sort, `getAllPages` retries once without it rather than
losing the whole database: the sort key is an assumption, and it should not be
fatal. `/v1/search` gets no sort at all — its options are narrow and a wrong key
is a 400 that would break the database picker, so the picker sorts by name
client-side.

### Sync state

`<settings dir>/notionsync_state.lua` (a `LuaSettings` file), keyed by Notion page
id: `{ last_edited, path, synced_at }`.

It lives in the settings directory, **not** in `save_dir`, so changing the save
directory does not throw the history away. A missing output file is detected
separately, so deleting a book always re-syncs it regardless of timestamps.

`storage:shouldSync(page_id, last_edited, filename, database_name)` returns
`should_sync, reason` where reason is one of `new`, `missing`, `edited`,
`unchanged`, `adopted`. Comparison is **exact string equality** on
`last_edited_time` — Notion returns a canonical ISO 8601 form, so there is nothing
to gain from parsing it and no timezone handling to get wrong. The trade is that
the same instant serialised differently reads as changed, which costs one
re-download and is tested.

**Migration from the old format.** The previous `<save_dir>/.synced_ids` was
append-only and recorded ids only, with no timestamps. Those records import with
`last_edited = nil`, and `shouldSync` returns `adopted` for them when the file
exists — the sync loop then stamps the current timestamp. Treating "unknown" as
stale instead would re-download the entire library on upgrade. The cost is that an
edit made *before* upgrading is missed exactly once.

State is flushed **per database**, not per page and not only at the end: a sync
that dies mid-run loses at most one database's records rather than all of them,
without writing to flash on every page.

### On-device layout

```
<save_dir>/                        # default /mnt/onboard/notion_sync (Kobo-specific)
  .synced_ids
  <Sanitized_Database_Name>/<Sanitized_Page_Title>.epub
```

An EPUB is built at `<name>.epub.part` and renamed into place only after the
archive verifies, so the library can never contain a truncated book. A stray
`.part` file means a sync died mid-write; it is safe to delete.

Settings live elsewhere — `DataStorage:getSettingsDir()/notionsync.lua` via `LuaSettings`, not in `save_dir`.

**Filenames** are produced by `storage:resolveFilenames(entries, ext)`, which takes the whole database at once rather than one page at a time. That is deliberate: if two titles sanitise to the same stem, **both** get a short page-id suffix, so the result does not depend on the order Notion returns pages in. Deciding per page would suffix only whichever arrived second, and the two files would swap names between runs.

`sanitizeName` never touches bytes ≥ 0x80, which is what makes it UTF-8 safe without a `utf8` library. It replaces only genuinely unsafe characters, collapses runs to a single `_`, truncates on a character boundary within a **byte** budget (FAT32 counts bytes; one CJK character costs three), strips trailing dots and spaces, and escapes reserved Windows names — the user partition is FAT32 and files get copied off it over USB.

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

**Nested content is bounded, not complete.** `blocktree.lua` fetches child blocks
breadth-first, but with a depth cap (3) and a per-page request budget (40),
because each parent costs one API call. Exceeding either is reported in the sync
summary and renders a visible placeholder; it is never silent. Two rules in there
are load-bearing: structural containers (`table`, `column_list`, `column`,
`synced_block`) must **not** consume a depth level, or a table spends its whole
allowance on structure and arrives with no rows; and `child_page` is never
recursed into, since that is a separate document and would pull in an unbounded
subtree.

**Lua trap worth knowing.** `cond and nil or 5` always evaluates to `5`, because
`and nil` is falsy and falls through to the `or`. This shipped twice in the sync
report's dialog timeout, silently defeating the sticky-on-failure behaviour. Write
it as a statement.
