# NotionSync KOReader Plugin

A KOReader plugin that syncs Notion databases to your eReader for offline reading.

## Features

- [x] Sync multiple Notion databases to KOReader folder
- [x] EPUB (.epub) output, for the richest offline reading experience
- [x] Preserve rich text formatting (bold, italic, strikethrough, underline, code, links)
- [x] Embed images in EPUB files for full offline reading
- [x] Code blocks, quotes, callouts, to-do lists and equations
- [x] Working table of contents, built from the page's headings
- [x] Unsupported Notion blocks are reported, never silently dropped
- [x] Automatic sync history tracking to avoid re-syncing unchanged pages
- [x] Table rows, nested lists, and toggle/callout/column contents
- [x] Non-Latin titles (CJK, Cyrillic, accents) preserved in filenames
- [x] All databases and all pages synced, in a stable order (no 20-item caps)
- [x] Re-sync pages edited in Notion automatically
- [ ] Sync highlights and annotations from KOReader back to Notion
- [ ] Automatic synchronization on schedule or other trigger
- [ ] sync reading completion percent to notion
- [ ] set/create custom tag or prop on notion page when 100% read complete

## Prerequisites

- An eReader with KOReader installed (developed and tested on a Kindle Colorsoft; Kobo is supported but untested)
- A Notion account with API access
- Notion Integration set up with appropriate permissions

## Installation

1. Go to the [Releases](../../releases) page
2. Download the latest `notionsync.koplugin-X.X.X.tar.gz`
3. Connect your eReader to your computer
4. Extract the plugin into your KOReader plugins directory. **The path differs by
   device — `.adds` is Kobo-only:**

   ```bash
   # Kindle
   tar -xzf notionsync.koplugin-X.X.X.tar.gz -C /path/to/device/koreader/plugins/

   # Kobo
   tar -xzf notionsync.koplugin-X.X.X.tar.gz -C /path/to/device/.adds/koreader/plugins/
   ```

   Newer Kindles (Colorsoft, Scribe, recent Paperwhites) connect over MTP and get
   no drive letter, so there is no path to extract to directly. Extract locally
   first, then copy the `notionsync.koplugin` folder onto the device in your file
   manager.
5. Eject your eReader safely
6. **Fully restart KOReader** — plugins are only loaded at startup

## Configuration

### Notion API Setup

1. Go to [Notion Integrations](https://www.notion.so/my-integrations)
2. Create a new integration
3. Copy your Integration Token (Internal Integration Secret)
4. Share your target Notion databases with your integration
   - Only shared databases will appear in the plugin's database selector

### Plugin Configuration

1. Open KOReader on your eReader
2. Go to **Tools** → **NotionSync**
3. Tap **Set Notion Token** and enter your Integration Token
4. Tap **Select Databases** and choose which databases to sync
5. (Optional) Change **Save Directory** to customize where files are saved

## Usage

1. Open KOReader
2. Navigate to **Tools** → **NotionSync**
3. Tap **Sync Now**
4. Wait for the sync to complete
5. Your Notion pages will be saved to the configured directory (default:
   `/mnt/us/notion_sync/` on Kindle, `/mnt/onboard/notion_sync/` on Kobo)

### Output Format

Pages are saved as **EPUB (.epub)** — formatted ebooks with images embedded for
offline reading, one file per Notion page, grouped into a folder per database.

### Forcing a Re-sync

Pages edited in Notion are re-downloaded automatically, so this is rarely needed.
To rebuild everything from scratch anyway, use **Tools → Notion Sync → Clear sync
history**. That only forgets the history; files already on the device are left
alone and will be overwritten on the next sync.

## Development

### Setting Up Development Environment

**Note:** The deployment scripts are for development only — end users should
install from releases. Development and testing happen on a Kindle Colorsoft; the
Kobo paths are implemented but untested.

#### 0. Which deployment script do I need?

It depends on how your device presents itself over USB:

| Your device shows up as | Use |
| --- | --- |
| A drive letter / mounted volume (`D:`, `/Volumes/Kindle`, `/media/...`) | `./deploy.sh` |
| `This PC\<device>\Internal Storage` with **no** drive letter | `./deploy-mtp.ps1` (Windows) |

**Newer Kindles — Colorsoft, Scribe, recent Paperwhites — use MTP** and never get
a drive letter. `deploy.sh` cannot reach them at all, because it copies with `cp`
to a filesystem path and MTP does not provide one. Use the PowerShell script:

```powershell
# From the repository root, in PowerShell:
.\deploy-mtp.ps1 -Backup          # -Backup saves the installed copy first
.\deploy-mtp.ps1 -Prune           # also move files no longer in the source tree off
.\deploy-mtp.ps1 -WhatIf          # dry run, touches nothing
```

It finds the device, verifies every copied file's byte size, and tells you if a
copy silently failed (which MTP does if the device falls asleep mid-transfer).
Older mass-storage Kindles and all Kobos can use `deploy.sh` below.

#### 1. Set Up Environment Variable (`deploy.sh` only)

The deployment script requires you to set the path to your mounted device. It
detects whether KOReader is installed in the Kobo layout (`<mount>/.adds/koreader`)
or the Kindle layout (`<mount>/koreader`), so the same variable works for both.

**Bash/Zsh:**

```bash
# For current session:
export DEVICE_MOUNT_PATH="/path/to/your/ereader"

# Permanent (add to ~/.bashrc or ~/.zshrc):
echo 'export DEVICE_MOUNT_PATH="/path/to/your/ereader"' >> ~/.bashrc
source ~/.bashrc
```

**Fish:**

```fish
# For current session:
set -x DEVICE_MOUNT_PATH "/path/to/your/ereader"

# Permanent (add to ~/.config/fish/config.fish):
echo 'set -x DEVICE_MOUNT_PATH "/path/to/your/ereader"' >> ~/.config/fish/config.fish
```

**Common paths:**

| Device | Linux | macOS | Windows (Git Bash / WSL) |
| --- | --- | --- | --- |
| Kindle | `/run/media/$USER/Kindle` | `/Volumes/Kindle` | `/d` or `/mnt/d` |
| Kobo | `/run/media/$USER/KOBOeReader` | `/Volumes/KOBOeReader` | `/d` or `/mnt/d` |

`KOBO_MOUNT_PATH` is still accepted as a legacy alias.

#### 2. Deploy to Device

1. Connect your device to your computer
2. Wait for it to mount
3. Run the deployment script:
   ```bash
   ./deploy.sh
   ```
4. The script will:
   - ✓ Verify your device is connected
   - ✓ Check for KOReader installation
   - ✓ Copy plugin files to the correct location
   - ✓ Sync the filesystem
5. Eject your device safely
6. Restart KOReader to load the updated plugin

### Testing

The plugin itself cannot run off-device, so the unit tests are the only feedback
you get without deploying. They cover the pure logic (block conversion, filename
sanitisation, HTML generation) and need **nothing but a LuaJIT binary** — no
luarocks, no C compiler.

```bash
# Install LuaJIT 2.1, the same runtime KOReader uses.
#   Windows:  winget install DEVCOM.LuaJIT
#   macOS:    brew install luajit
#   Debian:   sudo apt install luajit

luajit spec/run.lua        # run the test suite
```

Linting is optional locally and enforced in CI. If you want it locally, note that
the `luacheck` CLI needs luafilesystem (a C module), so on a machine without a
compiler install only the pure-Lua parts and use the bundled driver:

```bash
luarocks --lua-version 5.1 --lua-dir <luajit-dir> install --deps-mode=none luacheck
export LUA_PATH="$HOME/.luarocks/share/lua/5.1/?.lua;$HOME/.luarocks/share/lua/5.1/?/init.lua;;"

luajit spec/lint.lua       # reads the same .luacheckrc as CI
```

On Windows, `LUA_PATH` must use a native path (`C:/Users/you/...`), not an MSYS
`/c/...` path.

### Development Workflow

1. Branch off an up-to-date `main` — never commit to `main` directly
2. Make your changes to the plugin code
3. Run the tests: `luajit spec/run.lua`
4. Deploy to your device and verify: `./deploy.sh`
5. Update `CHANGELOG.md` under `## [Unreleased]`
6. Push the branch and open a pull request (CI runs lint + tests on PRs)

### Creating a Release

See [RELEASE.md](RELEASE.md) for detailed instructions on creating releases.

## Troubleshooting

### Plugin Not Appearing in KOReader

1. Verify KOReader is properly installed on your device
2. Check that the plugin files are in the correct location for your device:
   ```
   /path/to/device/koreader/plugins/notionsync.koplugin/         # Kindle
   /path/to/device/.adds/koreader/plugins/notionsync.koplugin/   # Kobo
   ```
3. Ensure all `.lua` files are present in the plugin directory
4. Fully restart KOReader — plugins are only loaded at startup, and a plugin with
   a Lua error does not appear in the menu rather than reporting anything. Errors
   are written to `<koreader>/crash.log` on the device

### Sync Errors

1. Verify your Notion API token is correct
2. Ensure your target databases are shared with your integration
3. Check your internet connection (plugin requires network access)
4. Review KOReader logs for detailed error messages

### Images Not Appearing in EPUB

Images are embedded as of the latest version. If one is missing you will see a
`[image failed to download]` placeholder where it should be, and the sync summary
will report how many failed — images are never silently omitted.

Check that the device had network access for the whole sync, and note that images
over 8 MB are skipped deliberately.

### Some Nested Content Is Missing

Notion stores nested content as *child blocks*, each needing its own API request.
To keep a sync from taking forever, there is a limit on how many requests one
page may use (**Tools → Notion Sync → Nested content limit**, default 40).

A page that hits the limit is reported in the sync summary, and anything not
retrieved shows a visible placeholder rather than disappearing. If a deeply
nested page is missing content, raise the limit to 100 — at the cost of a slower
sync. Nesting deeper than three levels is not followed.

### "DEVICE_MOUNT_PATH is not set" Error (Developers)

This error only affects developers using the deployment script. End users should install from releases and won't encounter this error.

Make sure you've set the environment variable correctly for your shell. See the [Development](#development) section.

### "KOReader plugins directory not found" (Developers)

`deploy.sh` looks for both supported layouts and prints which paths it tried:

- Kobo: `<mount>/.adds/koreader/plugins`
- Kindle: `<mount>/koreader/plugins`

If neither exists, either KOReader is not installed on the device or
`DEVICE_MOUNT_PATH` points at the wrong volume.

## Requirements

- **KOReader:** Must be installed on your eReader
- **Internet Connection:** Required during sync to fetch Notion data
- **Notion Integration:** API token with access to your databases

## Contributing

Contributions are welcome! Please feel free to submit pull requests or open issues.

See the [Development](#development) section for information on setting up your development environment.
