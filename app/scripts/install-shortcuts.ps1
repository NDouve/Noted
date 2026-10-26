# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

<#
.SYNOPSIS
  Creates "Noted" shortcuts on the Desktop and in the Start menu.

.DESCRIPTION
  The shortcuts point to noted.exe and use its icon. Run it from an unzipped
  Noted package (noted.exe next to this script) or from the repository
  (it then uses the release build in app\build\windows\x64\runner\Release).
  Running it again deletes and recreates the shortcuts and asks Explorer to
  refresh its icons.

.PARAMETER ExePath
  The noted.exe to point to. Defaults as described above.

.PARAMETER ResetIconCache
  Also restarts Explorer and deletes its icon cache files, for when an
  updated exe still shows its old icon. The taskbar disappears for a moment.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File install-shortcuts.ps1

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File install-shortcuts.ps1 -ResetIconCache
#>
param(
  [string]$ExePath,
  [switch]$ResetIconCache
)

$ErrorActionPreference = 'Stop'

if (-not $ExePath) {
  $candidates = @(
    (Join-Path $PSScriptRoot 'noted.exe'),
    (Join-Path $PSScriptRoot '..\build\windows\x64\runner\Release\noted.exe')
  )
  $ExePath = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
  if (-not $ExePath) {
    throw "noted.exe not found next to this script or in the release build. Pass -ExePath."
  }
}
$ExePath = (Resolve-Path $ExePath).Path

$shell = New-Object -ComObject WScript.Shell
$links = @(
  (Join-Path ([Environment]::GetFolderPath('Desktop')) 'Noted.lnk'),
  (Join-Path ([Environment]::GetFolderPath('Programs')) 'Noted.lnk')
)
foreach ($lnk in $links) {
  # Deleting first makes Explorer treat it as a new shortcut, so it reads the
  # icon again instead of reusing what it cached for the old one.
  if (Test-Path $lnk) { Remove-Item $lnk -Force -Confirm:$false }
  $s = $shell.CreateShortcut($lnk)
  $s.TargetPath = $ExePath
  $s.WorkingDirectory = Split-Path $ExePath
  $s.IconLocation = "$ExePath,0"
  $s.Description = 'Noted'
  $s.Save()
  Write-Host "Created $lnk -> $ExePath"
}

# Ask Explorer to refresh the icons it shows.
& "$env:SystemRoot\System32\ie4uinit.exe" -show

if ($ResetIconCache) {
  # Explorer keeps icons in memory and in iconcache_*.db, so an updated exe
  # can keep its old icon on the Desktop, in the Start menu and on the
  # taskbar. Stop Explorer, delete the cache files and start it again; it
  # rebuilds them from the files.
  Write-Host 'Restarting Explorer to clear the icon cache...'
  Stop-Process -Name explorer -Force -Confirm:$false
  Start-Sleep -Seconds 2
  $cache = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Explorer'
  Get-ChildItem $cache -Filter 'iconcache*.db' -ErrorAction SilentlyContinue |
    Remove-Item -Force -Confirm:$false -ErrorAction SilentlyContinue
  Remove-Item (Join-Path $env:LOCALAPPDATA 'IconCache.db') -Force -Confirm:$false -ErrorAction SilentlyContinue
  if (-not (Get-Process explorer -ErrorAction SilentlyContinue)) { Start-Process explorer.exe }
  Write-Host 'Icon cache cleared.'
} else {
  Write-Host 'If Explorer still shows an old icon, run again with -ResetIconCache.'
}
