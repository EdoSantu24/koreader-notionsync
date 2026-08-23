# Release Process

This document describes how to create a new release of the NotionSync KOReader Plugin.

## Overview

The GitHub Actions workflow runs on every push to `main` and on version tags:

### On Push to Main:
1. Lints all Lua code using luacheck
2. Creates a development tarball (e.g., `notionsync.koplugin-dev-a1b2c3d.tar.gz`)
3. Uploads as a workflow artifact (available for 30 days)
4. **Does NOT create a GitHub release**

### On Version Tag (v*):
1. Lints all Lua code using luacheck
2. Creates a release tarball (e.g., `notionsync.koplugin-1.0.0.tar.gz`)
3. Uploads as a workflow artifact
4. **Creates a GitHub release** with tarball attached

## Creating a Release

### 1. Update the CHANGELOG

Edit `CHANGELOG.md` and add a new version section:

```markdown
## [1.0.0] - 2026-01-25

### Added
- New feature description

### Changed
- Changed feature description

### Fixed
- Bug fix description
```

### 2. Commit Your Changes

```bash
git add .
git commit -m "Prepare release v1.0.0"
git push origin main
```

### 3. Create and Push a Version Tag

```bash
# Create a tag (must start with 'v')
git tag -a v1.0.0 -m "Release version 1.0.0"

# Push the tag to GitHub
git push origin v1.0.0
```

### 4. Wait for the Workflow

The GitHub Actions workflow will automatically:
- Trigger when the tag is pushed
- Run luacheck on all Lua files
- Create a tarball named `notionsync.koplugin-1.0.0.tar.gz`
- Create a GitHub release with the tarball attached
- Extract changelog entries from CHANGELOG.md

### 5. Verify the Release

1. Go to your repository on GitHub
2. Click on "Releases"
3. Verify the new release appears with:
   - Correct version number
   - Attached tarball
   - Installation instructions
   - Changelog entries

## Development Builds

Every push to `main` creates a development build:

### Accessing Development Builds

1. Go to your repository on GitHub
2. Click on "Actions"
3. Click on the latest workflow run
4. Scroll down to "Artifacts"
5. Download the tarball (e.g., `notionsync.koplugin-dev-a1b2c3d.tar.gz`)

### Development Build Naming

- Format: `notionsync.koplugin-dev-{commit-sha}.tar.gz`
- Example: `notionsync.koplugin-dev-a1b2c3d.tar.gz`
- Artifacts are kept for 30 days

### Installing Development Builds

The plugins directory differs by device; `.adds` is Kobo-only.

```bash
# Kindle
tar -xzf notionsync.koplugin-dev-a1b2c3d.tar.gz -C /path/to/device/koreader/plugins/

# Kobo
tar -xzf notionsync.koplugin-dev-a1b2c3d.tar.gz -C /path/to/device/.adds/koreader/plugins/
```

For development, prefer the deploy scripts over extracting by hand — `deploy.sh`
for a device with a drive letter, `deploy-mtp.ps1` for an MTP Kindle. See the
README's Development section.

## Version Numbering

This project follows [Semantic Versioning](https://semver.org/):

- **MAJOR** version (v1.0.0 → v2.0.0): Breaking changes
- **MINOR** version (v1.0.0 → v1.1.0): New features, backwards compatible
- **PATCH** version (v1.0.0 → v1.0.1): Bug fixes, backwards compatible

## Troubleshooting

### Workflow Fails on Lint Step

If luacheck finds issues:

1. Check the workflow logs on GitHub Actions
2. Fix the reported issues locally
3. Run luacheck locally to verify:
   ```bash
   luarocks install luacheck
   luacheck notionsync.koplugin/
   ```
4. Commit fixes and re-tag:
   ```bash
   git tag -d v1.0.0                    # Delete local tag
   git push origin :refs/tags/v1.0.0    # Delete remote tag
   git tag -a v1.0.0 -m "Release 1.0.0" # Recreate tag
   git push origin v1.0.0               # Push new tag
   ```

### Changelog Not Appearing in Release

Ensure your CHANGELOG.md follows this format:

```markdown
## [1.0.0] - 2026-01-25

Your changes here...

## [0.9.0] - 2026-01-20
```

The workflow extracts content between version headers.

### Release Not Created

Check that:
- Tag starts with 'v' (v1.0.0, not 1.0.0)
- You have push access to the repository
- GitHub Actions is enabled in repository settings

## Manual Release (Alternative)

If you prefer manual releases:

1. Create the tarball locally:
   ```bash
   tar -czf notionsync.koplugin-1.0.0.tar.gz -C . notionsync.koplugin/
   ```

2. Go to GitHub → Releases → Draft a new release
3. Create a new tag or select existing
4. Upload the tarball
5. Add release notes
6. Publish release
