# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

<#
.SYNOPSIS
  Packages the Windows release build as a zip that runs on another PC by
  copying it over.

.DESCRIPTION
  Builds the release (unless -SkipBuild), copies it into
  app\build\package\Noted, adds the Visual C++ runtime DLLs the exe and
  plugins import (msvcp140.dll, vcruntime140.dll, vcruntime140_1.dll,
  app-local deployment from this machine's System32), the shortcut script
  and a README, and writes app\build\Noted-windows-x64.zip.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File app\scripts\package-windows.ps1
#>
param(
  [switch]$SkipBuild
)

$ErrorActionPreference = 'Stop'

$app = Resolve-Path (Join-Path $PSScriptRoot '..')
$release = Join-Path $app 'build\windows\x64\runner\Release'
$stage = Join-Path $app 'build\package\Noted'
$zip = Join-Path $app 'build\Noted-windows-x64.zip'

if (-not $SkipBuild) {
  Push-Location $app
  try {
    flutter build windows --release
    if ($LASTEXITCODE -ne 0) { throw "flutter build failed ($LASTEXITCODE)" }
  } finally {
    Pop-Location
  }
}
if (-not (Test-Path (Join-Path $release 'noted.exe'))) {
  throw "No release build at $release"
}

if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
New-Item -ItemType Directory -Force $stage | Out-Null
Copy-Item (Join-Path $release '*') $stage -Recurse

# The exe and the plugin DLLs import these; a PC without the Visual C++
# 2015-2022 runtime would not start the app without them.
$runtime = 'msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll'
foreach ($dll in $runtime) {
  $src = Join-Path $env:WINDIR "System32\$dll"
  if (-not (Test-Path $src)) { throw "Missing ${src}: install the VC++ 2015-2022 x64 redistributable on this machine" }
  Copy-Item $src $stage
}

Copy-Item (Join-Path $PSScriptRoot 'install-shortcuts.ps1') $stage

$version = (Select-String -Path (Join-Path $app 'pubspec.yaml') -Pattern '^version:\s*(.+)$').Matches[0].Groups[1].Value
$commit = (git -C $app rev-parse --short HEAD) 2>$null
@"
Noted $version ($commit) for Windows x64

Run
  1. Copy this folder anywhere (for example C:\Users\<you>\Apps\Noted).
  2. Double-click noted.exe.

Shortcuts
  Right-click install-shortcuts.ps1 > Run with PowerShell, or run:
    powershell -ExecutionPolicy Bypass -File install-shortcuts.ps1
  It creates "Noted" on the Desktop and in the Start menu, pointing to
  noted.exe in this folder. Run it again after moving the folder.

Runtime
  The Visual C++ runtime DLLs the app needs (msvcp140.dll,
  vcruntime140.dll, vcruntime140_1.dll) are included next to noted.exe.
  If Windows still reports a missing DLL, install the Microsoft Visual C++
  2015-2022 Redistributable (x64) from Microsoft and start again.

Data
  Pages are stored in %APPDATA%\Noted\pages unless you choose another
  folder; binders.json, settings.json and templates are in %APPDATA%\Noted.
  Nothing is copied from the machine that built this package.
"@ | Set-Content -Encoding utf8 (Join-Path $stage 'README.txt')

if (Test-Path $zip) { Remove-Item $zip -Force }
Compress-Archive -Path $stage -DestinationPath $zip
Write-Host "Wrote $zip"
