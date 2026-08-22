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

    # MTP will not overwrite in place, so remove the old file first. The plugin
    # is fully replaced on every deploy, so a stale leftover is worse than a gap.
    $old = Get-ShellChild $existing $file.Name
    if (-not $old) {
        $old = Get-ShellChild $existing $file.BaseName
    }
    if ($old) {
        try { $old.InvokeVerb('delete') } catch { }
        $gone = (Get-Date).AddSeconds(10)
        while ((Get-Date) -lt $gone) {
            if (-not (Get-ShellChild $existing $file.Name) -and
                -not (Get-ShellChild $existing $file.BaseName)) { break }
            Start-Sleep -Milliseconds 300
        }
    }

    $targetFolder.CopyHere($file.FullName, $COPY_FLAGS)

    if (Wait-ForFile $existing $file.Name $file.Length) {
        Write-Step "$($file.Name)  ($($file.Length) bytes)"
        $copied++
    } else {
        Write-Fail "$($file.Name) -- copy not confirmed"
        $failed += $file.Name
    }
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
