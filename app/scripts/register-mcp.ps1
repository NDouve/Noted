# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

<#
.SYNOPSIS
  Registers Noted's MCP server with Claude Code and prints the
  configuration for the Claude desktop app.

.DESCRIPTION
  Finds noted_mcp.exe (next to this script in the release folder, or in
  the repository's release build), copies it to %LOCALAPPDATA%\Noted\mcp (so a
  running chat holds the copy, not the release folder; the old copy is kept,
  with a message, if a process holds it), adds the copy to Claude Code with
  `claude mcp add` (user scope, so every project sees it; an earlier
  registration with the same name is replaced), and prints the
  "mcpServers" entry to paste into Claude desktop's
  claude_desktop_config.json. See docs/mcp.md.

  The registration holds no secret. To let a chat read a Privileged page or
  use an AI box, give it a code made in Noted (in the AI box, or in the page
  or binder settings); the chat passes the code on each call.

.PARAMETER Exe
  The path of noted_mcp.exe, if not found automatically.

.PARAMETER Name
  The server's name in Claude (default: noted).

.PARAMETER Scope
  Claude Code scope: user (default), local or project.

.PARAMETER NoCopy
  Register the exe where it is, without copying it to %LOCALAPPDATA%.

.PARAMETER PrintOnly
  Only print the Claude desktop configuration; don't touch Claude Code.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File register-mcp.ps1
#>
param(
  [string]$Exe,
  [ValidatePattern('^[A-Za-z0-9_-]+$')][string]$Name = 'noted',
  [ValidateSet('user', 'local', 'project')][string]$Scope = 'user',
  [switch]$NoCopy,
  [switch]$PrintOnly
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

if (-not $Exe) {
  $candidates = @(
    (Join-Path $PSScriptRoot 'noted_mcp.exe'),
    (Join-Path $PSScriptRoot '..\build\windows\x64\runner\Release\noted_mcp.exe')
  )
  $Exe = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
  # package-windows.ps1 compiles to build\noted_mcp.new.exe when a process
  # holds the Release exe; take the newer of the two, never a stale one.
  $held = Join-Path $PSScriptRoot '..\build\noted_mcp.new.exe'
  if ($Exe -and (Test-Path $held) -and $Exe -ne $candidates[0]) {
    if ((Get-Item $held).LastWriteTime -gt (Get-Item $Exe).LastWriteTime) { $Exe = $held }
  } elseif (-not $Exe -and (Test-Path $held)) {
    $Exe = $held
  }
  if (-not $Exe) { throw "noted_mcp.exe not found. Pass -Exe <path>, or build the release first (app\scripts\package-windows.ps1)." }
}
$Exe = (Resolve-Path $Exe).Path
if (-not $NoCopy) {
  $copy = Update-McpCopy $Exe
  if ($copy) { $Exe = $copy } else { Write-Host "Using $Exe in place." }
}

if (-not $PrintOnly) {
  $claude = Get-Command claude -ErrorAction SilentlyContinue
  if ($claude) {
    # Replace an earlier registration with the same name (this also drops a
    # token an older registration held). ("No MCP server named ..." on stderr
    # when there is none: not an error here.)
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
      & claude mcp remove $Name -s $Scope 2>&1 | Out-Null
    } catch {
      # Nothing to remove.
    }
    $ErrorActionPreference = $previous
    & claude mcp add $Name -s $Scope -- $Exe
    if ($LASTEXITCODE -ne 0) { throw "claude mcp add failed ($LASTEXITCODE)" }
    Write-Host "Registered '$Name' with Claude Code ($Scope scope): $Exe"
  } else {
    Write-Host "Claude Code (the 'claude' command) was not found; skipped. Install it, or add the server by hand:"
    Write-Host "  claude mcp add $Name -s $Scope -- `"$Exe`""
  }
}

$entry = [ordered]@{ command = $Exe; args = @() }
$json = [ordered]@{ mcpServers = [ordered]@{ $Name = $entry } } | ConvertTo-Json -Depth 4
Write-Host ''
Write-Host 'Claude desktop: add this to claude_desktop_config.json'
Write-Host '(Settings > Developer > Edit Config; %APPDATA%\Claude\claude_desktop_config.json),'
Write-Host 'merging "mcpServers" with any servers already there, then restart Claude:'
Write-Host ''
Write-Output $json
