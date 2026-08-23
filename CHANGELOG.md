# Changelog

All notable changes to the NotionSync KOReader Plugin will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

- The Notion token is no longer displayed in clear text when you open **Set Notion
  Token**. It is an account credential with read access to every database shared
  with the integration, and it was rendered in full on a screen that tends to be
  read over people's shoulders. The field is masked now, with KOReader's own
  *Show password* toggle to reveal it deliberately; an existing token stays
  pre-filled so it does not have to be retyped.

## [2.0.0] - 2026-08-23

A rebuild of the EPUB pipeline. Synced books previously arrived with no images, no
tables, and parts of the page silently missing; all three are fixed at the source
rather than patched around. Along the way this release removes several caps that
quietly limited what got synced at all, and adds the ability to cancel a sync.

### The three problems this release fixes

**Images never appeared.** Pages were converted to Markdown, run through a bundled
Markdown parser, and turned into HTML. That parser escaped `&` to `&amp;` when
writing an image URL into `src="..."`, while the code substituting the local file
path searched for the raw URL. Notion image links are full of `&`, so the
substitution never matched and every book shipped a link to a Notion URL that had
already expired. Notion blocks are now rendered directly to XHTML, so there is no
text substitution left to get wrong.

**Tables were empty.** Notion stores table rows as *child blocks*, fetched with a
separate request per parent, and the plugin never made those requests. The same
was true of nested bullet levels and the contents of toggles, callouts and
columns. All of it is now fetched, within a configurable request budget.

**Content went missing without warning.** Only the first 20 databases and the first
20 pages of each were ever read, in an order that could change between runs. Any
Notion block the converter did not recognise was dropped with no trace. Every one
of those limits is now either removed or reported in the sync summary.

### Upgrading

Nothing needs doing, but three things change:

- **Markdown output is gone.** EPUB is the only format. If you used `.md` output,
  those files stay on the device and each page re-downloads once as EPUB.
- **Sync history is imported automatically.** Books already on the device are
  recognised and *not* re-downloaded. The old format had no timestamps, so an edit
  made in Notion before upgrading is missed once; after that, edits are detected.
- **A few filenames may change.** Pages whose titles collide, or use non-Latin
  characters, are named correctly now — so the old file is left behind and a
  correctly named one appears. Safe to delete the leftovers.

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
- `Sync one page (debug)` menu item, which syncs a single page so that on-device
  verification takes seconds rather than minutes
- Images larger than 8 MB are skipped and reported rather than risking memory
  exhaustion mid-sync
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

- Install instructions now give the correct path per device. `.adds` is Kobo-only,
  so every Kindle user following the README, `RELEASE.md`, or the **published
  release notes** was told a directory that does not exist. The MTP case (newer
  Kindles get no drive letter, so there is nothing to extract *to*) is now
  explained rather than left as a dead end
- `deploy-mtp.ps1` gained `-Prune`, which moves files no longer in the source tree
  off the device. Opt-in, because the plugin directory belongs to the user. Uses
  `MoveHere` rather than the modal delete verb that used to hang the script
- CI actions bumped: `actions/checkout` v4 → v5 and `actions/upload-artifact`
  v4 → v5 (both cleared a Node 20 deprecation warning on the runner), and
  `softprops/action-gh-release` v1 → v3.0.2 **pinned to a commit** — a mutable tag
  on the action that publishes releases is where supply-chain drift matters most
- README no longer claims the plugin is only tested on Kobo; it is developed and
  tested on a Kindle Colorsoft, with Kobo supported but untested
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

- Releasing with a `CHANGELOG.md` heading that does not match the tag now **fails
  loudly instead of publishing a release with empty notes**. The extraction also no
  longer drops the last line of a section that runs to end-of-file
- The **Full Changelog** link in published releases pointed at
  `github.event.before`, which is all zeros on a tag push, so every release shipped
  a broken compare link
- **The default save directory now works on a Kindle.** It was the literal Kobo
  path `/mnt/onboard/notion_sync`, which does not exist there; directory creation
  then fell through to a shell `mkdir -p` which, on a device with a writable
  rootfs, *succeeded* -- putting the library on the root filesystem, invisible over
  USB and liable to be wiped by a firmware update. Now derived from
  `Device.home_dir`. **Only the default changed:** a save directory you chose
  explicitly is never overridden. If you never set one, books will now appear under
  `/mnt/us/notion_sync` on Kindle; the old directory is left in place to delete
- Directory creation no longer shells out. `os.execute("mkdir -p " .. path)` was
  unquoted, so any save directory containing a space created two wrong directories
  instead of one, and its result was discarded so the failure was invisible
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
- Discarded unused HTTP response values in `api.lua` and `imagemanager.lua` that
  were masking the response headers needed to determine image content types

### Removed

- `converter.lua` and the vendored `markdown.lua` (1212 lines). Rendering Notion
  blocks straight to XHTML removed the need for both, along with the entire class
  of bug that came from pattern-matching another tool's HTML output
- **The Markdown (.md) output format.** EPUB is now the only output. The format
  setting and its menu are gone, along with `storage:saveMarkdown`. Markdown
  output shared all of the EPUB path's block-coverage gaps and would have needed
  a parallel rewrite; dropping it removes an entire duplicate code path

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
