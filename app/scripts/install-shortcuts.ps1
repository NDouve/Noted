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
  Running it again replaces the shortcuts.

.PARAMETER ExePath
  The noted.exe to point to. Defaults as described above.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File install-shortcuts.ps1
#>
param(
  [string]$ExePath
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
  $s = $shell.CreateShortcut($lnk)
  $s.TargetPath = $ExePath
  $s.WorkingDirectory = Split-Path $ExePath
  $s.IconLocation = "$ExePath,0"
  $s.Description = 'Noted'
  $s.Save()
  Write-Host "Created $lnk -> $ExePath"
}
