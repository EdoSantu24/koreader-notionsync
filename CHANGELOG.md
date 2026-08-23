# Changelog

All notable changes to the NotionSync KOReader Plugin will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **Editing a page in Notion now re-downloads it.** Sync state records each page's
  `last_edited_time`, so an edit is detected automatically. Previously only the
  page id was stored, so a page fixed in Notion kept its stale copy forever and
  *Clear sync history* -- which re-downloads everything -- was the only lever
- The sync summary now distinguishes **New / Updated / Unchanged**
- Sync state moved to KOReader's settings directory, so changing the save
  directory no longer discards the history. Existing `.synced_ids` records are
  imported automatically; because that format had no timestamps, pages whose files
  are already present are adopted as up to date rather than re-downloaded, so
  upgrading costs nothing. An edit made before upgrading is missed once

- **All databases, and all pages in a database, are now synced.** Nothing followed
  a cursor before, so only the first 20 databases and the first 20 pages of each
  existed as far as the plugin was concerned -- with no indication anything had
  been left behind. Page size is now the API maximum of 100 and every cursor page
  is followed
- Pages are fetched in a **stable order** (`created_time` ascending). Previously
  no sort was sent, so *which* 20 pages you got could differ between runs
- **Pages per database** setting (100 / 200 / 1000 / no limit, default 200), since
  removing the cap changes how long a large database takes. Databases that hit the
  limit are reported in the sync summary
- The database picker now lists every shared database, sorted by name

- **Notion Sync Now** is now usable as a gesture or profile action. The Dispatcher
  action was registered but had no handler, so anything bound to it did nothing
- Starting a sync while one is already running is now refused, rather than the
  second run silently un-cancelling the first and both writing the same files

- **A running sync can now be cancelled.** Tap the progress message and confirm;
  the sync stops at the next checkpoint without leaving a partial file behind.
  Checked between databases, between pages, during nested-block fetching, and
  before each image download
- Progress now shows what a long page is actually doing (`Fetching blocks (12)`,
  `Image 3/9`) instead of appearing frozen

- **Nested content is now fetched.** Notion stores anything nested as a child
  block, reachable only by another API request per parent, so previously table
  rows, sub-bullets, and the bodies of toggles, callouts, columns and synced
  blocks were all unavailable and showed `[... not fetched]` placeholders. New
  `blocktree.lua` walks the tree breadth-first with a depth cap and a per-page
  request budget
- **Nested content limit** setting (20 / 40 / 100 requests per page). Each nested
  parent costs one API call, so this trades completeness against sync time and
  battery. Pages that hit the limit are reported in the sync summary
- API requests now retry on 429 and 5xx with a short bounded backoff. Notion rate
  limits at roughly three requests per second, which one content-heavy page can
  now breach on its own. Total backoff is capped per sync, because the sleep
  blocks the UI and there is currently no way to cancel a running sync

### Fixed

- **Non-Latin page titles no longer collapse into a single `untitled.epub`.** The
  filename sanitiser kept only `[%w%s-_]`, and because Lua patterns are
  byte-oriented and `%w` is ASCII-only, every byte >= 0x80 was deleted: a page
  titled `读书笔记` became `untitled.epub`, and a second such page silently
  overwrote the first while both were recorded as synced. Unrecoverable data loss
- **Two pages whose titles differ only in punctuation no longer overwrite each
  other.** Filenames are now resolved for a whole database at once, so both sides
  of a collision get a short page-id suffix. Resolving as a set makes the result
  independent of the order Notion returns pages in
- Filenames are truncated on a character boundary within a byte budget, so a long
  CJK title can no longer leave half a character in the name. Trailing dots and
  spaces are stripped and reserved Windows names escaped, since the device
  partition is FAT32 and files get copied off it over USB
- **Titles are read in full.** Only the first rich-text segment was used, so
  Notion's split at every formatting or mention boundary truncated the title --
  `Chapter **One**` became `Chapter `

- **The sync summary no longer disappears when something went wrong.** The dialog
  timeout used `cond and nil or 5`, which in Lua always evaluates to `5` -- so the
  intended stay-on-screen behaviour for failures never worked
- Far fewer full-screen e-ink repaints during a sync: progress updates reuse one
  widget with a partial refresh and are throttled to about one per second, instead
  of tearing down and recreating the message with a forced full repaint per page
- A mid-sync error now costs one page instead of escaping unprotected. The sync
  loop is plain nested loops, so the error guard covers every page rather than
  only the first

- **List items no longer render at heading size or escape their list.** An `<li>`
  held inline text directly beside a block sibling, which is mixed content;
  crengine resolves that by restructuring the document. An item's own text is now
  wrapped so the `<li>` contains only blocks. This appeared intermittent because
  it only affected items *with* sub-items, and in Notion that is most often the
  last item of a list
- **Table rows are wrapped in `<thead>`/`<tbody>`.** A bare `<tr>` directly under
  `<table>` is invalid in XHTML 1.1 and triggers the same crengine restructuring
- Image diagnostics: every image now logs its byte count, header bytes and
  resolved media type, and AVIF/HEIC are recognised so an unrenderable format is
  named rather than reported as unidentifiable bytes
- `Sync one page (debug)` now writes `notionsync-debug.xhtml` and a block outline
  next to the synced books, so a rendering problem can be inspected instead of
  guessed at

- **Images now actually appear in EPUBs.** The vendored Markdown parser escaped
  `&` to `&amp;` when writing a URL into `src="..."`, while the code searching for
  that URL used the raw form — so for any Notion pre-signed image URL (which are
  full of `&`) the substitution never matched and every EPUB kept a remote link
  that had already expired. The renderer now emits local image paths directly;
  there is no post-hoc string rewrite left to get wrong
- **Fenced code blocks, strikethrough and to-do checkboxes render properly.** They
  were previously emitted in Markdown syntax the vendored Markdown 1.0.1 parser
  did not support, so they appeared as literal backticks, tildes and brackets
- **Unrecognised Notion blocks no longer vanish silently.** Any block type the
  renderer does not know is logged, counted, reported in the sync summary, and
  rendered as a visible placeholder with its text salvaged where possible
- **A page whose content could not be fetched is no longer recorded as synced**,
  so it is retried instead of being frozen as permanently empty
- **A failed or truncated EPUB is never left in the library.** Archives are built
  as `.part` and renamed only after verification; previously an empty file passed
  the check, and the page was then marked synced and never retried
- **Image media types are correct.** They were guessed from the URL, which fails
  on Notion pre-signed URLs (they contain `/` inside the query string), so every
  image was labelled JPEG. Now taken from the response and validated against the
  file's magic bytes
- **Each EPUB contains only its own images.** Images were staged in one shared
  directory that was archived wholesale per page, so page 60 of a sync embedded
  all 120 images downloaded before it
- **EPUBs are valid EPUB 2.** Added the XML declaration, `toc.ncx` and
  `<spine toc="ncx">` (so KOReader's table of contents works), plus a stable
  `dc:identifier` derived from the Notion page id — previously `os.time()`, so
  every book written in the same second shared an identifier. A stable id also
  means reading position survives a re-sync
- Sync failures are now counted and shown, and the summary no longer claims
  "Sync complete!" when pages failed. The dialog stays on screen when something
  went wrong instead of vanishing after five seconds

### Added

- `Sync one page (debug)` menu item, which syncs a single page so that on-device
  verification takes seconds rather than minutes
- Images larger than 8 MB are skipped and reported rather than risking memory
  exhaustion mid-sync

### Removed

- `converter.lua` and the vendored `markdown.lua` (1212 lines). Rendering Notion
  blocks straight to XHTML removed the need for both, along with the entire class
  of bug that came from pattern-matching another tool's HTML output

- **The Markdown (.md) output format.** EPUB is now the only output. The format
  setting and its menu are gone, along with `storage:saveMarkdown`. Markdown
  output shared all of the EPUB path's block-coverage gaps and would have needed
  a parallel rewrite; dropping it removes an entire duplicate code path

  If you were using Markdown output: every page will re-download once as EPUB
  (sync history is keyed per format, so previous `.md` entries no longer match),
  and your existing `.md` files are left on the device untouched. Delete them by
  hand if you don't want them.

### Added

- **Tools → Notion Sync → Clear sync history**, with a confirmation showing how
  many pages will be forgotten. Previously the only way to force a re-sync was
  the side effect of switching output format, so removing that format would
  otherwise have removed the capability entirely

- Dependency-free unit test suite (`luajit spec/run.lua`) with KOReader module
  stubs, runnable without luarocks or a C compiler
- Local luacheck driver (`luajit spec/lint.lua`) that reads the same
  `.luacheckrc` as CI, for machines where luafilesystem cannot be built
- CI now runs on pull requests, and in a separate test job, so branch work is
  actually checked
- `CLAUDE.md` with architecture notes and platform gotchas

- `deploy-mtp.ps1`, a PowerShell deployment script for MTP devices. Newer Kindles
  (Colorsoft, Scribe, recent Paperwhites) expose storage over MTP and never get a
  drive letter, so `deploy.sh` cannot reach them at all. Verifies every copied
  file's size, supports `-Backup` and `-WhatIf`

### Changed

- `deploy.sh` now supports Kindle as well as Kobo, detecting whether KOReader
  lives at `<mount>/koreader` or `<mount>/.adds/koreader`, and points at
  `deploy-mtp.ps1` when no drive letter is available
- `deploy.sh` environment variable renamed to `DEVICE_MOUNT_PATH`
  (`KOBO_MOUNT_PATH` still accepted)
- Linting now runs against LuaJIT (`std = "luajit"`) instead of the permissive
  `std = "max"`, so use of Lua 5.2+/5.3+ stdlib functions that would fail on the
  device is now caught. CI installs LuaJIT rather than Lua 5.4 for the same reason
- Undefined-global and unused-argument checks are no longer suppressed, as these
  are the highest-value checks for code that cannot be executed off-device

### Fixed

- Discarded unused HTTP response values in `api.lua` and `imagemanager.lua` that
  were masking the response headers needed to determine image content types

## [1.0.0] - 2026-01-25

### Added

- Multi-database selection support - sync multiple Notion databases at once
- EPUB and Markdown output formats (EPUB is default)
- Rich text formatting preservation (bold, italic, strikethrough, inline code, links)
- Image embedding in EPUB files for full offline reading
- Image download caching to avoid redundant downloads within a sync session
- Automatic temp image cleanup after sync
- Sync history tracking to avoid re-syncing unchanged pages
- Format-specific sync tracking (switching formats triggers re-sync)
- Configurable save directory
- Network-aware sync (only runs when device is online)
- Progress indicators during sync with page-by-page updates
- Detailed sync statistics (new/old pages, image download counts)

### Features

- Sync Notion database pages to eReader for offline reading
- Support for multiple Notion databases simultaneously
- Automatic database discovery via Notion API
- Clean, simple UI integrated into KOReader's Tools menu
- Preserves Notion page structure and formatting
- Handles various Notion block types (headings, paragraphs, lists, quotes, code blocks, images)

<!--
## [1.1.0] - YYYY-MM-DD

### Added
- New feature description

### Changed
- Changed feature description

### Fixed
- Bug fix description

### Removed
- Removed feature description
-->
