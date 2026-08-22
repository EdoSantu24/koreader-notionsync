# Changelog

All notable changes to the NotionSync KOReader Plugin will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

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
