<#
.SYNOPSIS
    Deploy notionsync.koplugin to a Kindle (or any MTP e-reader) from Windows.

.DESCRIPTION
    Newer Kindles -- Colorsoft, Scribe, recent Paperwhites -- expose their storage
    over MTP rather than as USB mass storage. They therefore get NO drive letter,
    and appear only as "This PC\<device name>\Internal Storage" in Explorer.

    That means deploy.sh cannot be used with them at all: it copies with `cp` to a
    filesystem path, and an MTP device has none. This script does the same job
    through the Windows shell COM interface, which is the only way to write to an
    MTP device without third-party software.

    Use deploy.sh for older mass-storage devices (which do get a drive letter),
    and this script for MTP devices.

    Files are overwritten in place. An earlier version deleted each file first,
    which made the script hang: InvokeVerb('delete') raises a shell confirmation
    dialog that a non-interactive PowerShell session cannot dismiss. Overwriting
    works fine over MTP -- do not reintroduce a delete step. Nothing in this
    script may call InvokeVerb.

.PARAMETER DeviceName
    Wildcard matched against the portable device name. Defaults to 'Kindle*'.

.PARAMETER KoreaderPath
    Path segments to the KOReader directory inside the device's storage root.
    Defaults to 'koreader' (the Kindle layout).

.PARAMETER Backup
    Copy the currently installed plugin off the device before overwriting it.

.PARAMETER WhatIf
    Show what would happen without writing to the device.

.EXAMPLE
    .\deploy-mtp.ps1 -Backup

.EXAMPLE
    .\deploy-mtp.ps1 -DeviceName 'Kindle Colorsoft*'
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$DeviceName = 'Kindle*',
    [string]$KoreaderPath = 'koreader',
    [switch]$Backup
)

$ErrorActionPreference = 'Stop'

$PLUGIN_NAME = 'notionsync.koplugin'
$SourceDir = Join-Path $PSScriptRoot $PLUGIN_NAME

# Shell namespace constant for "This PC".
$SSF_DRIVES = 17

# CopyHere flags: silent + yes-to-all + no mkdir confirm + no error UI.
# MTP providers honour these inconsistently, which is why every copy is verified
# afterwards rather than trusted.
$COPY_FLAGS = 4 + 16 + 512 + 1024

function Write-Step  ($m) { Write-Host "  $m" -ForegroundColor Cyan }
function Write-Ok    ($m) { Write-Host "  $m" -ForegroundColor Green }
function Write-Warn2 ($m) { Write-Host "  $m" -ForegroundColor Yellow }
function Write-Fail  ($m) { Write-Host "  $m" -ForegroundColor Red }

function Get-ShellChild($parent, $name) {
    $parent.GetFolder.Items() | Where-Object { $_.Name -eq $name } | Select-Object -First 1
}

# Resolves a '/'-separated path underneath a shell folder item, one level at a
# time, because the MTP namespace cannot be addressed by a whole path string.
function Resolve-ShellPath($root, [string]$path) {
    $current = $root
    foreach ($segment in ($path -split '[/\\]' | Where-Object { $_ })) {
        $next = Get-ShellChild $current $segment
        if (-not $next) { return $null }
        $current = $next
    }
    return $current
}

# Waits for an asynchronous MTP copy to land, checking name and byte size.
function Wait-ForFile($folderItem, [string]$name, [int64]$expectedSize, [int]$timeoutSec = 30) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        $found = Get-ShellChild $folderItem $name
        if (-not $found) {
            # Windows hides known extensions in the MTP namespace, so a file may
            # show up as 'main' rather than 'main.lua'.
            $stem = [System.IO.Path]::GetFileNameWithoutExtension($name)
            $found = Get-ShellChild $folderItem $stem
        }
        if ($found) {
            $size = $found.ExtendedProperty('Size')
            if (-not $expectedSize -or $size -eq $expectedSize) { return $true }
        }
        Start-Sleep -Milliseconds 400
    }
    return $false
}

# Used when the new file is the same length as the old one, so a size check cannot
# tell whether the overwrite happened.
#
# An earlier version watched the modification timestamp instead, but MTP does not
# reliably advance it when the content is unchanged -- so deploying a file that was
# already correct was reported as a FAILURE. Reading the bytes back is slower but
# it actually answers the question, and it only runs for the ambiguous same-size
# case.
function Test-DeviceContentMatches($folderItem, [string]$name, [string]$localPath) {
    $shell = New-Object -ComObject Shell.Application
    $temp = Join-Path $env:TEMP ("ns-verify-" + [System.Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $temp -Force | Out-Null
    try {
        $stem = [System.IO.Path]::GetFileNameWithoutExtension($name)
        $item = Get-ShellChild $folderItem $name
        if (-not $item) { $item = Get-ShellChild $folderItem $stem }
        if (-not $item) { return $false }

        $shell.NameSpace($temp).CopyHere($item, $COPY_FLAGS)
        $deadline = (Get-Date).AddSeconds(20)
        while ((Get-Date) -lt $deadline) {
            if (@(Get-ChildItem $temp -File).Count -ge 1) { break }
            Start-Sleep -Milliseconds 300
        }
        $pulled = Get-ChildItem $temp -File | Select-Object -First 1
        if (-not $pulled) { return $false }

        $local = Get-FileHash -Path $localPath -Algorithm MD5
        $remote = Get-FileHash -Path $pulled.FullName -Algorithm MD5
        return $local.Hash -eq $remote.Hash
    } finally {
        Remove-Item $temp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host ""
Write-Host "Deploying $PLUGIN_NAME over MTP" -ForegroundColor White
Write-Host ""

# --- Source ------------------------------------------------------------------

if (-not (Test-Path $SourceDir)) {
    Write-Fail "Source directory not found: $SourceDir"
    exit 1
}
$sourceFiles = @(Get-ChildItem -Path $SourceDir -Filter '*.lua' -File)
if ($sourceFiles.Count -eq 0) {
    Write-Fail "No .lua files in $SourceDir"
    exit 1
}
Write-Ok "Found $($sourceFiles.Count) Lua file(s) to deploy"

# --- Device ------------------------------------------------------------------

$shell = New-Object -ComObject Shell.Application
$device = $shell.NameSpace($SSF_DRIVES).Items() |
    Where-Object { $_.Name -like $DeviceName -and $_.IsFolder } |
    Select-Object -First 1

if (-not $device) {
    Write-Fail "No portable device matching '$DeviceName' found."
    Write-Host ""
    Write-Warn2 "Devices currently visible under This PC:"
    $shell.NameSpace($SSF_DRIVES).Items() |
        ForEach-Object { Write-Host "      $($_.Name)" }
    Write-Host ""
    Write-Warn2 "Make sure the device is connected, unlocked and awake."
    Write-Warn2 "If it has a drive letter instead, use ./deploy.sh."
    exit 1
}
Write-Ok "Device: $($device.Name)"

# The storage root is usually 'Internal Storage', but the name is localised and
# varies by model, so fall back to the first folder if it is absent.
$storage = Get-ShellChild $device 'Internal Storage'
if (-not $storage) {
    $storage = $device.GetFolder.Items() | Where-Object { $_.IsFolder } | Select-Object -First 1
}
if (-not $storage) {
    Write-Fail "Could not find a storage volume on $($device.Name)."
    exit 1
}
Write-Ok "Storage: $($storage.Name)"

$koreader = Resolve-ShellPath $storage $KoreaderPath
if (-not $koreader) {
    Write-Fail "KOReader not found at '$KoreaderPath' on the device."
    Write-Warn2 "Top-level folders in $($storage.Name):"
    $storage.GetFolder.Items() |
        Where-Object { $_.IsFolder } |
        ForEach-Object { Write-Host "      $($_.Name)" }
    exit 1
}

$plugins = Get-ShellChild $koreader 'plugins'
if (-not $plugins) {
    Write-Fail "No 'plugins' directory inside '$KoreaderPath'. Is KOReader installed?"
    exit 1
}
Write-Ok "KOReader plugins: $KoreaderPath/plugins"

# --- Backup ------------------------------------------------------------------

$existing = Get-ShellChild $plugins $PLUGIN_NAME

if ($Backup) {
    if ($existing) {
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $backupDir = Join-Path $env:USERPROFILE "notionsync-backup-$stamp"
        if ($PSCmdlet.ShouldProcess($backupDir, 'Back up installed plugin')) {
            New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
            $dest = $shell.NameSpace($backupDir)
            $items = @($existing.GetFolder.Items())
            foreach ($item in $items) { $dest.CopyHere($item, $COPY_FLAGS) }

            $deadline = (Get-Date).AddSeconds(60)
            while ((Get-Date) -lt $deadline) {
                if (@(Get-ChildItem $backupDir -File).Count -ge $items.Count) { break }
                Start-Sleep -Milliseconds 400
            }
            $got = @(Get-ChildItem $backupDir -File).Count
            if ($got -lt $items.Count) {
                Write-Fail "Backup incomplete ($got of $($items.Count) files). Aborting."
                exit 1
            }
            Write-Ok "Backed up $got file(s) to $backupDir"
        }
    } else {
        Write-Warn2 "Nothing installed yet, skipping backup"
    }
}

# --- Deploy ------------------------------------------------------------------

if (-not $existing) {
    if ($PSCmdlet.ShouldProcess($PLUGIN_NAME, 'Create plugin directory on device')) {
        $plugins.GetFolder.NewFolder($PLUGIN_NAME)
        $existing = Get-ShellChild $plugins $PLUGIN_NAME
        if (-not $existing) {
            Write-Fail "Could not create $PLUGIN_NAME on the device."
            exit 1
        }
        Write-Ok "Created $PLUGIN_NAME"
    }
}

$targetFolder = $existing.GetFolder
$copied = 0
$failed = @()

foreach ($file in $sourceFiles) {
    if (-not $PSCmdlet.ShouldProcess($file.Name, 'Copy to device')) { continue }

    # Copy straight over the existing file.
    #
    # This used to delete the old file first, on the assumption that MTP cannot
    # overwrite in place. That assumption was wrong, and the delete was actively
    # harmful: InvokeVerb('delete') raises a shell confirmation dialog that a
    # non-interactive PowerShell session cannot answer, so the script would hang.
    # Overwriting with the flags below is silent and reliable -- do not reintroduce
    # a delete step here.
    $existingSize = $null
    $old = Get-ShellChild $existing $file.Name
    if (-not $old) { $old = Get-ShellChild $existing $file.BaseName }
    if ($old) {
        $existingSize = $old.ExtendedProperty('Size')
    }

    $targetFolder.CopyHere($file.FullName, $COPY_FLAGS)

    # A size match normally proves the copy landed, because a changed file has a
    # different length. When the length is identical the size proves nothing, so
    # the bytes are compared instead.
    $confirmed = Wait-ForFile $existing $file.Name $file.Length
    if ($confirmed -and $existingSize -eq $file.Length) {
        $confirmed = Test-DeviceContentMatches $existing $file.Name $file.FullName
    }

    if ($confirmed) {
        Write-Step "$($file.Name)  ($($file.Length) bytes)"
        $copied++
    } else {
        Write-Fail "$($file.Name) -- copy not confirmed"
        $failed += $file.Name
    }
}

# Files on the device that no longer exist in the source tree. These are NOT
# removed automatically: deleting over MTP needs InvokeVerb('delete'), which is
# what used to hang this script. They are inert (main.lua only loads the modules
# it names), so reporting them is enough.
$sourceNames = @{}
foreach ($f in $sourceFiles) { $sourceNames[$f.BaseName] = $true }
$stale = @()
foreach ($item in $existing.GetFolder.Items()) {
    if (-not $item.IsFolder -and -not $sourceNames[[System.IO.Path]::GetFileNameWithoutExtension($item.Name)]) {
        $stale += $item.Name
    }
}
if ($stale.Count -gt 0) {
    Write-Host ""
    Write-Warn2 "Stale file(s) left over from an older version: $($stale -join ', ')"
    Write-Warn2 "They are unused and harmless. Delete them in File Explorer if you want."
}

Write-Host ""
if ($failed.Count -gt 0) {
    Write-Fail "$copied copied, $($failed.Count) failed: $($failed -join ', ')"
    Write-Warn2 "MTP copies can fail if the device sleeps. Wake it and re-run."
    exit 1
}

Write-Ok "Deployed $copied file(s) to $($device.Name)"
Write-Host ""
Write-Warn2 "Next: eject the device from Windows, then FULLY RESTART KOReader"
Write-Warn2 "(plugins are only loaded at startup)."
Write-Host ""
