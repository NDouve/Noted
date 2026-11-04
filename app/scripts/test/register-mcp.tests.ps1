# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

<#
.SYNOPSIS
  Pester tests (written for Pester 3.4, which Windows PowerShell 5.1 ships)
  for the MCP copy in register-mcp.ps1 and package-windows.ps1.

.DESCRIPTION
  Everything runs under $TestDrive: the scripts are copied into a fake app
  folder, $env:LOCALAPPDATA points into $TestDrive, and flutter and dart are
  replaced by functions. The real `claude` CLI is never called
  (register-mcp.ps1 runs with -PrintOnly). A held file is one opened with a
  FileStream that shares Read and Delete, like a running exe: it can be read
  and renamed, so only the script's write probe stops a refresh.

  Run: Invoke-Pester app\scripts\test\register-mcp.tests.ps1
#>
$scripts = Split-Path -Parent $PSScriptRoot

# Returns Update-McpCopy's definition as a script block to dot-source,
# without running the script.
function Get-UpdateMcpCopy([string]$Path) {
  $ast = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$null)
  $fn = $ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Update-McpCopy' }, $true) | Select-Object -First 1
  if (-not $fn) { throw "Update-McpCopy not found in $Path" }
  [scriptblock]::Create($fn.Extent.Text)
}

function New-Exe([string]$Path, [string]$Content) {
  New-Item -ItemType Directory -Force (Split-Path -Parent $Path) | Out-Null
  [IO.File]::WriteAllText($Path, $Content)
}

function Hold([string]$Path) {
  New-Object IO.FileStream($Path, 'Open', 'Read', ([IO.FileShare]'Read, Delete'))
}

# The "command" the script printed for Claude desktop.
function Get-PrintedCommand([string]$Out) {
  if ($Out -notmatch '"command":\s+"([^"]+)"') { throw "no command in: $Out" }
  $Matches[1].Replace('\\', '\')
}

function Read-Text([string]$Path) { [IO.File]::ReadAllText($Path) }

foreach ($name in 'register-mcp.ps1', 'package-windows.ps1') {
  Describe "Update-McpCopy in $name" {
    . (Get-UpdateMcpCopy (Join-Path $scripts $name))

    BeforeEach {
      $ErrorActionPreference = 'Stop'  # as the scripts run
      $script:root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
      $script:src = Join-Path $script:root 'src\noted_mcp.exe'
      $script:dest = Join-Path $script:root 'local\Noted\mcp\noted_mcp.exe'
      New-Exe $script:src 'new'
    }

    It 'returns null without a LOCALAPPDATA root' {
      Update-McpCopy $script:src '' 6>$null | Should BeNullOrEmpty
    }

    It 'is the same function in both scripts' {
      $a = (Get-UpdateMcpCopy (Join-Path $scripts 'register-mcp.ps1')).ToString() -replace "`r`n", "`n"
      $b = (Get-UpdateMcpCopy (Join-Path $scripts 'package-windows.ps1')).ToString() -replace "`r`n", "`n"
      $a | Should BeExactly $b
    }

    It 'leaves an up-to-date copy alone, even when a process holds it' {
      New-Exe $script:dest 'new'
      $h = Hold $script:dest
      try {
        $out = Update-McpCopy $script:src (Join-Path $script:root 'local') 2>$null 6>&1
      } finally { $h.Dispose() }
      ($out | Where-Object { $_ -is [string] }) | Should Be $script:dest
      ($out | Out-String) | Should Match 'up to date'
      ($out | Out-String) | Should Not Match 'NOT refreshed'
      Test-Path "$($script:dest).tmp" | Should Be $false
    }

    It 'makes the first copy' {
      $r = Update-McpCopy $script:src (Join-Path $script:root 'local') 6>$null
      $r | Should Be $script:dest
      Read-Text $script:dest | Should Be 'new'
      Test-Path "$($script:dest).tmp" | Should Be $false
    }

    It 'refreshes an older copy' {
      New-Exe $script:dest 'old'
      Update-McpCopy $script:src (Join-Path $script:root 'local') 6>$null | Out-Null
      Read-Text $script:dest | Should Be 'new'
    }

    It 'keeps a held copy and returns its path' {
      New-Exe $script:dest 'old'
      $h = Hold $script:dest
      try {
        $out = Update-McpCopy $script:src (Join-Path $script:root 'local') 2>$null 6>&1
      } finally { $h.Dispose() }
      ($out | Where-Object { $_ -is [string] }) | Should Be $script:dest
      ($out | Out-String) | Should Match 'NOT refreshed because a process holds it'
      Read-Text $script:dest | Should Be 'old'
      Test-Path "$($script:dest).tmp" | Should Be $false
    }

    It 'keeps the existing copy when the copy fails' {
      New-Exe $script:dest 'old'
      $missing = Join-Path $script:root 'src\gone.exe'
      $out = Update-McpCopy $missing (Join-Path $script:root 'local') 2>$null 6>&1
      ($out | Where-Object { $_ -is [string] }) | Should Be $script:dest
      ($out | Out-String) | Should Match 'existing copy is untouched'
      Read-Text $script:dest | Should Be 'old'
    }

    It 'keeps the existing copy when the hash check fails' {
      New-Exe $script:dest 'old'
      Mock Copy-Item { [IO.File]::WriteAllText($Destination, 'corrupt') }
      $out = Update-McpCopy $script:src (Join-Path $script:root 'local') 2>$null 6>&1
      ($out | Where-Object { $_ -is [string] }) | Should Be $script:dest
      ($out | Out-String) | Should Match 'does not match the source'
      Read-Text $script:dest | Should Be 'old'
      Test-Path "$($script:dest).tmp" | Should Be $false
    }

    It 'returns null when the copy fails and there is no copy' {
      $r = Update-McpCopy (Join-Path $script:root 'src\gone.exe') (Join-Path $script:root 'local') 2>$null 6>$null
      $r | Should BeNullOrEmpty
      Test-Path $script:dest | Should Be $false
    }
  }
}

Describe 'register-mcp.ps1' {
  BeforeEach {
    $script:oldLocal = $env:LOCALAPPDATA
    $script:app = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force (Join-Path $script:app 'scripts') | Out-Null
    $script:reg = Join-Path $script:app 'scripts\register-mcp.ps1'
    Copy-Item (Join-Path $scripts 'register-mcp.ps1') $script:reg
    $script:release = Join-Path $script:app 'build\windows\x64\runner\Release\noted_mcp.exe'
    $script:held = Join-Path $script:app 'build\noted_mcp.new.exe'
    $env:LOCALAPPDATA = Join-Path $script:app 'local'
  }
  AfterEach { $env:LOCALAPPDATA = $script:oldLocal }

  function Run-Register([hashtable]$More = @{}) {
    # -PrintOnly: never reaches the claude CLI.
    (& $script:reg -PrintOnly @More *>&1 | Out-String -Width 4000)
  }

  It 'warns with -NoCopy that the build-output exe is registered in place' {
    New-Exe $script:release 'exe'
    $out = Run-Register @{ NoCopy = $true }
    $out | Should Match '-NoCopy: .* is registered in place'
    $out | Should Match 'blocks rebuilding'
    $out | Should Match 'replace'
    Test-Path (Join-Path $env:LOCALAPPDATA 'Noted\mcp\noted_mcp.exe') | Should Be $false
  }

  It 'does not print the -NoCopy warning when it copies' {
    New-Exe $script:release 'exe'
    $out = Run-Register
    $out | Should Not Match '-NoCopy'
    $out | Should Match 'Copied noted_mcp.exe'
    $dest = Join-Path $env:LOCALAPPDATA 'Noted\mcp\noted_mcp.exe'
    Read-Text $dest | Should Be 'exe'
    Get-PrintedCommand $out | Should Be $dest
  }

  It 'registers the exe beside the script, not a newer fallback' {
    $beside = Join-Path $script:app 'scripts\noted_mcp.exe'
    New-Exe $beside 'beside'
    New-Exe $script:held 'fallback'
    (Get-Item $beside).LastWriteTime = (Get-Date).AddHours(-2)
    (Get-Item $script:held).LastWriteTime = (Get-Date).AddHours(-1)
    $out = Run-Register @{ NoCopy = $true }
    Get-PrintedCommand $out | Should Be $beside
  }

  It 'takes the newer held-fallback exe over the release exe' {
    New-Exe $script:release 'release'
    New-Exe $script:held 'fallback'
    (Get-Item $script:release).LastWriteTime = (Get-Date).AddHours(-2)
    (Get-Item $script:held).LastWriteTime = (Get-Date).AddHours(-1)
    Run-Register @{ NoCopy = $true } | Should Match 'noted_mcp\.new\.exe'
  }

  It 'keeps the release exe when it is newer than the fallback' {
    New-Exe $script:release 'release'
    New-Exe $script:held 'fallback'
    (Get-Item $script:held).LastWriteTime = (Get-Date).AddHours(-2)
    (Get-Item $script:release).LastWriteTime = (Get-Date).AddHours(-1)
    Run-Register @{ NoCopy = $true } | Should Not Match 'noted_mcp\.new\.exe'
  }

  It 'uses the fallback when there is no release exe' {
    New-Exe $script:held 'fallback'
    Run-Register @{ NoCopy = $true } | Should Match 'noted_mcp\.new\.exe'
  }

  It 'registers the held copy path and keeps it when a process holds the copy' {
    New-Exe $script:release 'new'
    $dest = Join-Path $env:LOCALAPPDATA 'Noted\mcp\noted_mcp.exe'
    New-Exe $dest 'old'
    $h = Hold $dest
    try { $out = Run-Register } finally { $h.Dispose() }
    $out | Should Match 'NOT refreshed because a process holds it'
    Read-Text $dest | Should Be 'old'
    Get-PrintedCommand $out | Should Be $dest
  }
}

Describe 'package-windows.ps1' {
  BeforeEach {
    $script:oldLocal = $env:LOCALAPPDATA
    $script:app = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
    $s =Join-Path $script:app 'scripts'
    New-Item -ItemType Directory -Force $s | Out-Null
    Copy-Item (Join-Path $scripts 'package-windows.ps1') $s
    Set-Content (Join-Path $s 'install-shortcuts.ps1') '# fake'
    Set-Content (Join-Path $s 'register-mcp.ps1') '# fake'
    Set-Content (Join-Path $script:app 'pubspec.yaml') 'version: 1.2.3'
    $script:pkg = Join-Path $s 'package-windows.ps1'
    $script:release = Join-Path $script:app 'build\windows\x64\runner\Release'
    New-Exe (Join-Path $script:release 'noted.exe') 'app'
    $script:local = Join-Path $script:app 'local'
    $env:LOCALAPPDATA = $script:local
    $global:FakeDartArgs = $null
    $global:FakeDartContent = 'compiled'
    function global:git { 'abc1234' }
    # Visible to the script run below (PowerShell scopes are dynamic).
    function global:flutter { throw 'flutter must not run in tests' }
    function global:dart {
      $global:FakeDartArgs = $args
      $out = $args[$args.IndexOf('-o') + 1]
      New-Item -ItemType Directory -Force (Split-Path -Parent $out) | Out-Null
      [IO.File]::WriteAllText($out, $global:FakeDartContent)
      $global:LASTEXITCODE = 0
    }
  }
  AfterEach {
    $env:LOCALAPPDATA = $script:oldLocal
    # The fakes this Describe defines.
    Remove-Item function:\dart, function:\flutter, function:\git -Force -ErrorAction SilentlyContinue
    Remove-Variable FakeDartArgs, FakeDartContent -Scope Global -ErrorAction SilentlyContinue
  }

  It 'builds the zip and refreshes the copy' {
    & $script:pkg -SkipBuild *>&1 | Out-Null
    Test-Path (Join-Path $script:app 'build\Noted-windows-x64.zip') | Should Be $true
    Read-Text (Join-Path $script:local 'Noted\mcp\noted_mcp.exe') | Should Be 'compiled'
  }

  It 'keeps a held copy and still builds the zip' {
    $dest = Join-Path $script:local 'Noted\mcp\noted_mcp.exe'
    New-Exe $dest 'old'
    $h = Hold $dest
    try { $out = (& $script:pkg -SkipBuild *>&1 | Out-String -Width 4000) } finally { $h.Dispose() }
    $out | Should Match 'NOT refreshed because a process holds it'
    Read-Text $dest | Should Be 'old'
    Test-Path (Join-Path $script:app 'build\Noted-windows-x64.zip') | Should Be $true
  }

  It 'still builds the zip when the copy cannot be made' {
    # LOCALAPPDATA is a file, so the folder cannot be created.
    Set-Content $script:local 'not a folder'
    & $script:pkg -SkipBuild *>&1 | Out-Null
    Test-Path (Join-Path $script:app 'build\Noted-windows-x64.zip') | Should Be $true
  }

  It 'compiles to noted_mcp.new.exe when a process holds the release exe' {
    $rel = Join-Path $script:release 'noted_mcp.exe'
    New-Exe $rel 'running'
    $global:FakeDartContent = 'fresh'
    $h = Hold $rel
    try { & $script:pkg -SkipBuild *>&1 | Out-Null } finally { $h.Dispose() }
    $global:FakeDartArgs[$global:FakeDartArgs.IndexOf('-o') + 1] | Should Be (Join-Path $script:app 'build\noted_mcp.new.exe')
    Read-Text $rel | Should Be 'running'
    Read-Text (Join-Path $script:app 'build\package\Noted\noted_mcp.exe') | Should Be 'fresh'
    Read-Text (Join-Path $script:local 'Noted\mcp\noted_mcp.exe') | Should Be 'fresh'
    Test-Path (Join-Path $script:app 'build\Noted-windows-x64.zip') | Should Be $true
  }
}
