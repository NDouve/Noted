# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

<#
.SYNOPSIS
  Registers Noted's MCP server with Claude Code and prints the
  configuration for the Claude desktop app.

.DESCRIPTION
  Finds noted_mcp.exe (next to this script in the release folder, or in
  the repository's release build), adds it to Claude Code with
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

.PARAMETER PrintOnly
  Only print the Claude desktop configuration; don't touch Claude Code.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File register-mcp.ps1
#>
param(
  [string]$Exe,
  [ValidatePattern('^[A-Za-z0-9_-]+$')][string]$Name = 'noted',
  [ValidateSet('user', 'local', 'project')][string]$Scope = 'user',
  [switch]$PrintOnly
)

$ErrorActionPreference = 'Stop'

if (-not $Exe) {
  $candidates = @(
    (Join-Path $PSScriptRoot 'noted_mcp.exe'),
    (Join-Path $PSScriptRoot '..\build\windows\x64\runner\Release\noted_mcp.exe')
  )
  $Exe = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
  if (-not $Exe) { throw "noted_mcp.exe not found. Pass -Exe <path>, or build the release first (app\scripts\package-windows.ps1)." }
}
$Exe = (Resolve-Path $Exe).Path

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
