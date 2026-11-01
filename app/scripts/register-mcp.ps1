# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

<#
.SYNOPSIS
  Registers Noted's read-only MCP server with Claude Code and prints the
  configuration for the Claude desktop app.

.DESCRIPTION
  Finds noted_mcp.exe (next to this script in the release folder, or in
  the repository's release build), adds it to Claude Code with
  `claude mcp add` (user scope, so every project sees it; an earlier
  registration with the same name is replaced), and prints the
  "mcpServers" entry to paste into Claude desktop's
  claude_desktop_config.json. See docs/mcp.md.

.PARAMETER Exe
  The path of noted_mcp.exe, if not found automatically.

.PARAMETER Name
  The server's name in Claude (default: noted).

.PARAMETER Scope
  Claude Code scope: user (default), local or project.

.PARAMETER PrintOnly
  Only print the Claude desktop configuration; don't touch Claude Code.

.PARAMETER Token
  An AI connection token made in Noted (gear menu > AI connections). When
  given, the registration passes it to the server as NOTED_TOKEN, which
  lets the AI have its own AI boxes. It is a secret: Claude's configuration
  will hold it. Without it the server reads only (no AI boxes of its own).

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File register-mcp.ps1

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File register-mcp.ps1 -Token noted_...
#>
param(
  [string]$Exe,
  [ValidatePattern('^[A-Za-z0-9_-]+$')][string]$Name = 'noted',
  [ValidateSet('user', 'local', 'project')][string]$Scope = 'user',
  [ValidatePattern('^noted_[0-9a-f]{16}_[A-Za-z0-9_-]{43}$')][string]$Token,
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
    # Replace an earlier registration with the same name. ("No MCP server
    # named ..." on stderr when there is none: not an error here.)
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
      & claude mcp remove $Name -s $Scope 2>&1 | Out-Null
    } catch {
      # Nothing to remove.
    }
    $ErrorActionPreference = $previous
    if ($Token) {
      & claude mcp add $Name -s $Scope -e "NOTED_TOKEN=$Token" -- $Exe
    } else {
      & claude mcp add $Name -s $Scope -- $Exe
    }
    if ($LASTEXITCODE -ne 0) { throw "claude mcp add failed ($LASTEXITCODE)" }
    Write-Host "Registered '$Name' with Claude Code ($Scope scope): $Exe$(if ($Token) { ' (with the AI connection token)' })"
  } else {
    Write-Host "Claude Code (the 'claude' command) was not found; skipped. Install it, or add the server by hand:"
    $tokenArg = if ($Token) { ' -e NOTED_TOKEN=<your token>' } else { '' }
    Write-Host "  claude mcp add $Name -s $Scope$tokenArg -- `"$Exe`""
  }
}

$entry = [ordered]@{ command = $Exe; args = @() }
# The token is a secret: print it only when it was passed in.
$entry['env'] = [ordered]@{ NOTED_TOKEN = $(if ($Token) { $Token } else { 'PASTE_YOUR_AI_CONNECTION_TOKEN_HERE' }) }
$json = [ordered]@{ mcpServers = [ordered]@{ $Name = $entry } } | ConvertTo-Json -Depth 4
Write-Host ''
Write-Host 'Claude desktop: add this to claude_desktop_config.json'
Write-Host '(Settings > Developer > Edit Config; %APPDATA%\Claude\claude_desktop_config.json),'
Write-Host 'merging "mcpServers" with any servers already there, then restart Claude:'
Write-Host 'WARNING: once it holds your AI connection token, that file holds a secret. Keep it private.'
Write-Host ''
Write-Output $json
