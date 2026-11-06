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
  app-local deployment from this machine's System32), the MCP
  server (noted_mcp.exe, compiled from packages\noted_mcp), the shortcut
  and MCP registration scripts and a README, and writes
  app\build\Noted-windows-x64.zip.

  It also copies noted_mcp.exe to %LOCALAPPDATA%\Noted\mcp, the copy that
  register-mcp.ps1 registers with Claude, so sessions do not hold the build
  output. If a process holds that copy, it is left as it is (with a message)
  and the zip is still built. If a process holds the exe in the build output,
  the server is compiled to app\build\noted_mcp.new.exe instead and the held
  file is left alone.
.EXAMPLE
  powershell -ExecutionPolicy Bypass -File app\scripts\package-windows.ps1
#>
param(
  [switch]$SkipBuild
)

$ErrorActionPreference = 'Stop'

# Copies noted_mcp.exe to $env:LOCALAPPDATA\Noted\mcp, which is what Claude
# sessions should run: they keep the exe open, and a held exe in the build
# output blocks rebuilding. Returns the path of the copy (the existing one if
# it could not be refreshed), or $null when there is no LOCALAPPDATA or no
# copy exists. Never throws. The copy is written to a .tmp file, checked by
# hash and swapped in, so a failed copy leaves the existing one untouched.
# NOTE: this function is duplicated in package-windows.ps1 and
# register-mcp.ps1 (which ships alone in the zip); keep the two identical.
function Update-McpCopy([string]$Source, [string]$Root = $env:LOCALAPPDATA) {
  if (-not $Root) { return $null }
  $dir = Join-Path $Root 'Noted\mcp'
  $dest = Join-Path $dir 'noted_mcp.exe'
  $tmp = "$dest.tmp"
  try {
    New-Item -ItemType Directory -Force $dir | Out-Null
    # A leftover from an interrupted run.
    Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    # Replace renames a running exe aside as noted_mcp.exe~RF<hex>.TMP; drop
    # those left by earlier runs, skipping any still held.
    foreach ($old in @(Get-ChildItem -LiteralPath $dir -Filter 'noted_mcp.exe~RF*.TMP' -ErrorAction SilentlyContinue)) {
      try { Remove-Item -LiteralPath $old.FullName -Force } catch { }
    }
    $hash = (Get-FileHash $Source).Hash
    if (Test-Path $dest) {
      if ((Get-FileHash $dest).Hash -eq $hash) {
        Write-Host "MCP copy is up to date: $dest"
        return $dest
      }
      try {
        # Opening for write with no sharing fails while a process runs or
        # has the file open.
        [IO.File]::Open($dest, 'Open', 'Write', 'None').Dispose()
      } catch {
        Write-Host "The MCP copy was NOT refreshed because a process holds it (usually a Claude session running noted_mcp.exe): $dest"
        Write-Host "The old copy is kept and still works. To refresh it, close the Claude sessions using it and run this script again."
        return $dest
      }
    }
    Copy-Item $Source $tmp -Force
    if ((Get-FileHash $tmp).Hash -ne $hash) { throw 'the copy does not match the source' }
    if (Test-Path $dest) {
      [IO.File]::Replace($tmp, $dest, [NullString]::Value)
    } else {
      Move-Item $tmp $dest
    }
  } catch {
    Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    if (Test-Path $dest) {
      Write-Host "The MCP copy was NOT refreshed ($($_.Exception.Message)); the existing copy is untouched. Close the Claude sessions using it and run this script again."
      return $dest
    }
    Write-Host "Could not copy noted_mcp.exe to ${dest}: $($_.Exception.Message)"
    return $null
  }
  Write-Host "Copied noted_mcp.exe to $dest"
  return $dest
}

$app = Resolve-Path (Join-Path $PSScriptRoot '..')
$release = Join-Path $app 'build\windows\x64\runner\Release'
$stage = Join-Path $app 'build\package\Noted'
$zip = Join-Path $app 'build\Noted-windows-x64.zip'

if (-not $SkipBuild) {
  Push-Location $app
  try {
    # Microsoft sign-in is built in only when NOTED_MS_CLIENT_ID is set (the
    # id is never committed); without it the build hides sign-in.
    $defines = @()
    if ($env:NOTED_MS_CLIENT_ID) { $defines += "--dart-define=NOTED_MS_CLIENT_ID=$env:NOTED_MS_CLIENT_ID" }
    flutter build windows --release @defines
    if ($LASTEXITCODE -ne 0) { throw "flutter build failed ($LASTEXITCODE)" }
  } finally {
    Pop-Location
  }
}
if (-not (Test-Path (Join-Path $release 'noted.exe'))) {
  throw "No release build at $release"
}

# The MCP server (invariant 4): a separate executable next to
# noted.exe, so a registration made from the release folder keeps working.
$mcpSource = Join-Path $app '..\packages\noted_mcp\bin\noted_mcp.dart'
$mcpRelease = Join-Path $release 'noted_mcp.exe'
$mcpBuilt = $mcpRelease
if (Test-Path $mcpRelease) {
  try {
    [IO.File]::Open($mcpRelease, 'Open', 'Write', 'None').Dispose()
  } catch {
    # Something runs the build-output exe. Compile elsewhere so the build
    # and the zip still work; the held file stays as it is.
    $mcpBuilt = Join-Path $app 'build\noted_mcp.new.exe'
    Write-Host "A process holds $mcpRelease (a Claude session registered to it?). Compiling to $mcpBuilt instead. Register the copy in %LOCALAPPDATA%\Noted\mcp (register-mcp.ps1) so sessions stop holding the build output."
  }
}
dart compile exe $mcpSource -o $mcpBuilt
if ($LASTEXITCODE -ne 0) { throw "dart compile exe failed ($LASTEXITCODE)" }

if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
New-Item -ItemType Directory -Force $stage | Out-Null
Copy-Item (Join-Path $release '*') $stage -Recurse
if ($mcpBuilt -ne $mcpRelease) { Copy-Item $mcpBuilt (Join-Path $stage 'noted_mcp.exe') -Force }

# The copy Claude sessions run (a self-contained `dart compile exe` output;
# nothing else is needed beside it). Not refreshing it is not a failure.
try {
  Update-McpCopy (Join-Path $stage 'noted_mcp.exe') | Out-Null
} catch {
  Write-Host "MCP copy not refreshed: $($_.Exception.Message)"
}

# The exe and the plugin DLLs import these; a PC without the Visual C++
# 2015-2022 runtime would not start the app without them.
$runtime = 'msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll'
foreach ($dll in $runtime) {
  $src = Join-Path $env:WINDIR "System32\$dll"
  if (-not (Test-Path $src)) { throw "Missing ${src}: install the VC++ 2015-2022 x64 redistributable on this machine" }
  Copy-Item $src $stage
}

Copy-Item (Join-Path $PSScriptRoot 'install-shortcuts.ps1') $stage
Copy-Item (Join-Path $PSScriptRoot 'register-mcp.ps1') $stage

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
  If a shortcut or the taskbar still shows an old icon after an update, run
  it with -ResetIconCache (Explorer restarts and rebuilds its icon cache).

AI (MCP server)
  noted_mcp.exe lets an AI app read your pages. A page whose AI access is
  Open (page settings) can be read by any AI using this server, with no
  code. Privileged pages need a code for the page or its binder; Guarded
  pages (the default) are closed to every AI. An AI writes only into an AI
  box it holds the Writer code for, within the box's Writer permission
  (Append only, Edit or Full): through Noted while Noted is running, and,
  only if you turned on "Allow writes while Noted is closed" for that box,
  straight into the page file while it is closed. The server's only other
  file is its own access log (ai-mcp-log.jsonl) beside the code store.
  Codes are made in Noted (in the AI box, "Connect a chat", or in the page
  or binder settings); give the code to the chat, which passes it on each
  call. You approve each code once, the first time it is used; if that is
  while Noted is closed, the chat is told to open Noted and Noted asks you
  then. There is no token: add the server to
  Claude Code and print the Claude desktop configuration from PowerShell:
    powershell -ExecutionPolicy Bypass -File register-mcp.ps1
  It registers a copy of noted_mcp.exe in %LOCALAPPDATA%\Noted\mcp, so
  updating this folder is not blocked by a chat that is using the server.
  Run it again after an update to refresh the copy (close the chats using
  the server first if it says the copy was not refreshed).
  See docs/mcp.md in the source.

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
