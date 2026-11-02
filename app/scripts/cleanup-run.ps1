# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

<#
.SYNOPSIS
  Ends leftover Flutter/Dart processes of this repository and removes
  leftover worktree folders.

.DESCRIPTION
  Processes: only dart.exe, dartvm.exe, dartaotruntime.exe and
  flutter_tester.exe are ever ended. A Dart process is grouped with its
  wrapper parents (other Dart processes, and `cmd.exe /c` running flutter
  or dart, as flutter.bat does) and all their descendants. The group is
  ended only if one member belongs to this repository (its command line,
  executable path or working directory is under the main checkout or a
  registered worktree) AND the group's top has no living parent. A group
  with a living parent is owned and kept: any live bash, sh, PowerShell,
  pwsh or `cmd /k` window, a terminal, an IDE, a running agent.

  Known gap: Git Bash runs the `flutter` shell script in its own bash.exe,
  and Git Bash processes show a dead Windows parent even while in use. So
  a test run whose Claude Code shell was killed, but whose `flutter` script
  bash lives on, looks the same as a live run and is kept (reported as
  owned by that bash.exe). End that bash.exe by hand; the next run of this
  script then ends the rest. Nothing under app\build\windows\x64\runner\Release is ever
  ended, nor this script or its ancestors. Because only Dart-family
  processes are candidates, noted.exe and noted_mcp.exe are never touched.

  Worktrees: runs `git worktree prune`, then removes leftover folders
  directly under <main>\.claude\worktrees\. A folder is a leftover only if
  git does not list it AND it has no .git entry, or a .git file pointing at
  a git directory that no longer exists. Any doubt keeps it: a .git folder
  (a full clone), a .git file whose target exists, an unreadable .git, a
  junction or symlink, a folder under 10 minutes old (newest write time of
  the folder and its .git entry), or if `git worktree list` fails (then the
  run stops). If .claude or .claude\worktrees is a junction or symlink the
  whole worktree step is skipped.

  Every action is also appended to %TEMP%\noted-cleanup-run.log.
  Safe to run at any time and more than once.

.PARAMETER Hook
  For Claude Code hooks. Prints one line only if something was ended or
  removed. Exit 0 on success; on any error one warning line on stderr and
  exit 1 (never 2, which would block stopping).

.PARAMETER WhatIf
  Lists what would be ended or removed and acts on nothing.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File app\scripts\cleanup-run.ps1 -WhatIf
#>
param(
  [switch]$Hook,
  [switch]$WhatIf
)

$ErrorActionPreference = 'Stop'

$script:DartNames = @('dart.exe', 'dartvm.exe', 'dartaotruntime.exe', 'flutter_tester.exe')
# Only cmd.exe can be a wrapper (flutter.bat runs in it). A live bash, sh,
# PowerShell or pwsh always owns what runs under it: Git Bash's bash.exe runs
# with a dead parent even while Claude Code is using it, so walking past it
# would end live test runs.
$script:ShellNames = @('cmd.exe')

# ---------- pure helpers (tested) ----------

function ConvertTo-PathKey([string]$Text) {
  # Lower case, one kind of slash, no trailing slash.
  if ($null -eq $Text) { return '' }
  return $Text.Replace('/', '\').ToLowerInvariant().TrimEnd('\')
}

function Test-TextInRoot([string]$Text, [string]$Root) {
  # True if Text contains Root at a path boundary. Also understands the Git
  # Bash form /c/Users/... for drive paths.
  if ([string]::IsNullOrEmpty($Text) -or [string]::IsNullOrEmpty($Root)) { return $false }
  $rootKey = ConvertTo-PathKey $Root
  $lower = $Text.ToLowerInvariant()
  $variants = @(
    $lower.Replace('/', '\'),
    ([regex]::Replace($lower, '(?<![a-z0-9])[\\/]([a-z])[\\/]', '$1:\')).Replace('/', '\')
  )
  foreach ($v in $variants) {
    $i = $v.IndexOf($rootKey, [StringComparison]::Ordinal)
    while ($i -ge 0) {
      $end = $i + $rootKey.Length
      # Only a separator, a quote or the end of the text ends the root.
      if ($end -ge $v.Length -or (@('\', '"', "'") -contains [string]$v[$end])) { return $true }
      $i = $v.IndexOf($rootKey, $i + 1, [StringComparison]::Ordinal)
    }
  }
  return $false
}

function Test-InsideDir([string]$Path, [string]$Dir) {
  if ([string]::IsNullOrEmpty($Path) -or [string]::IsNullOrEmpty($Dir)) { return $false }
  $p = ConvertTo-PathKey $Path
  $d = ConvertTo-PathKey $Dir
  return $p.StartsWith($d + '\', [StringComparison]::Ordinal)
}

function Select-CleanupProcesses {
  param(
    [object[]]$Processes,
    [string[]]$Roots,
    [string]$ReleaseDir,
    [int[]]$SelfPids = @()
  )
  $byId = @{}
  foreach ($p in $Processes) { $byId[[int]$p.ProcessId] = $p }
  $kids = @{}
  foreach ($p in $Processes) {
    $pp = [int]$p.ParentProcessId
    if (-not $kids.ContainsKey($pp)) { $kids[$pp] = New-Object System.Collections.ArrayList }
    [void]$kids[$pp].Add($p)
  }

  function Get-Name($p) { if ($p.Name) { $p.Name.ToLowerInvariant() } else { '' } }
  function Test-Dart($p) { $script:DartNames -contains (Get-Name $p) }
  function Test-Wrapper($p) {
    if (Test-Dart $p) { return $true }
    if ($script:ShellNames -contains (Get-Name $p)) {
      # Only `cmd /c` (runs one command, then exits). A `cmd /k` window stays
      # open for its user, so it owns what runs in it.
      $c = [string]$p.CommandLine
      if ($c -match '(?i)(^|\s)/k(\s|$)') { return $false }
      if ($c -notmatch '(?i)(^|\s)/c(\s|$)') { return $false }
      return $c -match '(?i)(?<![A-Za-z0-9_])(flutter|dart)(?![A-Za-z0-9_])'
    }
    return $false
  }
  # The parent record if it exists and was created no later than the child.
  function Get-LiveParent($p) {
    $pp = [int]$p.ParentProcessId
    if (-not $byId.ContainsKey($pp)) { return $null }
    $par = $byId[$pp]
    if ($par.CreationDate -gt $p.CreationDate) { return $null }
    return $par
  }
  function Test-InRepo($p) {
    foreach ($r in $Roots) {
      if (Test-TextInRoot ([string]$p.CommandLine) $r) { return $true }
      if (Test-TextInRoot ([string]$p.ExecutablePath) $r) { return $true }
      if (Test-TextInRoot ([string]$p.Cwd) $r) { return $true }
    }
    return $false
  }

  # Self and its ancestors.
  $protected = @{}
  foreach ($s in $SelfPids) {
    $cur = $s
    $guard = 0
    while ($cur -and -not $protected.ContainsKey([int]$cur) -and $guard -lt 100) {
      $protected[[int]$cur] = $true
      if (-not $byId.ContainsKey([int]$cur)) { break }
      $cur = [int]$byId[[int]$cur].ParentProcessId
      $guard++
    }
  }

  $clusterCache = @{}
  $results = @()
  foreach ($p in $Processes) {
    if (-not (Test-Dart $p)) { continue }
    $id = [int]$p.ProcessId
    $res = [pscustomobject]@{
      ProcessId = $id; Name = $p.Name; CommandLine = $p.CommandLine
      CreationDate = $p.CreationDate; Depth = 0
      Action = 'Keep'; Reason = ''; OwnerPid = $null; OwnerName = $null
    }
    $results += $res

    if ($protected.ContainsKey($id)) { $res.Reason = 'this script or its ancestor'; continue }
    if ($p.ExecutablePath -and $ReleaseDir -and (Test-InsideDir $p.ExecutablePath $ReleaseDir)) {
      $res.Reason = 'release build'; continue
    }

    # Walk up to the cluster top.
    $top = $p
    $guard = 0
    while ($guard -lt 100) {
      $par = Get-LiveParent $top
      if ($null -eq $par -or -not (Test-Wrapper $par)) { break }
      $top = $par
      $guard++
    }
    $topId = [int]$top.ProcessId
    if (-not $clusterCache.ContainsKey($topId)) {
      # The top plus all its descendants (a child older than its parent is
      # a reused pid, not a child). Depth counts from the top.
      $members = New-Object System.Collections.ArrayList
      [void]$members.Add($top)
      $queue = New-Object System.Collections.Queue
      $queue.Enqueue($top)
      $seen = @{ $topId = $true }
      $depth = @{ $topId = 0 }
      while ($queue.Count -gt 0) {
        $cur = $queue.Dequeue()
        $curId = [int]$cur.ProcessId
        if ($kids.ContainsKey($curId)) {
          foreach ($k in $kids[$curId]) {
            $kid = [int]$k.ProcessId
            if ($seen.ContainsKey($kid) -or $k.CreationDate -lt $cur.CreationDate) { continue }
            $seen[$kid] = $true
            $depth[$kid] = $depth[$curId] + 1
            [void]$members.Add($k)
            $queue.Enqueue($k)
          }
        }
      }
      $inRepo = $false
      foreach ($m in $members) { if (Test-InRepo $m) { $inRepo = $true; break } }
      $clusterCache[$topId] = [pscustomobject]@{
        InRepo = $inRepo; Owner = (Get-LiveParent $top); Depth = $depth
      }
    }
    $cl = $clusterCache[$topId]
    if ($cl.Depth.ContainsKey($id)) { $res.Depth = [int]$cl.Depth[$id] }
    if (-not $cl.InRepo) { $res.Reason = 'outside the repository'; continue }
    if ($null -ne $cl.Owner) {
      $res.Reason = 'owned by pid ' + $cl.Owner.ProcessId + ' ' + $cl.Owner.Name
      $res.OwnerPid = [int]$cl.Owner.ProcessId
      $res.OwnerName = $cl.Owner.Name
      continue
    }
    $res.Action = 'End'
    $res.Reason = 'abandoned'
  }
  return $results
}

function Select-CleanupWorktrees {
  # The one place that decides whether a folder is removed. Any doubt keeps.
  # Folder records: FullName, LastWriteTime (newest of the folder and its .git
  # entry), IsReparsePoint, GitKind ('none'|'dir'|'file'|'unreadable'),
  # GitDir (target of a .git file), GitDirExists, StatusOk, HasChanges.
  param(
    [object[]]$Folders,
    [string[]]$Registered,
    [string]$WorktreesDir,
    [datetime]$Now
  )
  $reg = @{}
  foreach ($r in $Registered) { $reg[(ConvertTo-PathKey $r)] = $true }
  $dirKey = ConvertTo-PathKey $WorktreesDir
  $results = @()
  foreach ($f in $Folders) {
    $key = ConvertTo-PathKey $f.FullName
    $res = [pscustomobject]@{ FullName = $f.FullName; Action = 'Keep'; Reason = '' }
    $results += $res
    # Only direct children of the worktrees folder.
    $inside = $key.StartsWith($dirKey + '\', [StringComparison]::Ordinal)
    if ($inside) { $inside = $key.Substring($dirKey.Length + 1).IndexOf('\') -lt 0 }
    if (-not $inside -or $key.Contains('\..\') -or $key.EndsWith('\..')) {
      $res.Action = 'Skip'; $res.Reason = 'not directly inside the worktrees folder'; continue
    }
    if ($f.IsReparsePoint) { $res.Action = 'Skip'; $res.Reason = 'junction or symlink'; continue }
    if ($reg.ContainsKey($key)) { $res.Reason = 'registered worktree'; continue }

    $kind = [string]$f.GitKind
    if ($kind -eq 'dir') { $res.Reason = 'not a worktree (.git is a folder)'; continue }
    if ($kind -eq 'file') {
      if ($f.GitDirExists) {
        if (-not $f.StatusOk) { $res.Reason = "linked to $($f.GitDir) (git status failed)"; continue }
        if ($f.HasChanges) { $res.Reason = "uncommitted changes (linked to $($f.GitDir))"; continue }
        $res.Reason = "linked to $($f.GitDir)"; continue
      }
      # The target is gone: a leftover, subject to the age rule below.
    } elseif ($kind -ne 'none') {
      $res.Reason = 'unreadable .git'; continue
    }
    if (($Now - $f.LastWriteTime).TotalMinutes -lt 10) { $res.Reason = 'too new (under 10 minutes)'; continue }
    $res.Action = 'Remove'
    $res.Reason = 'leftover (not registered, no live git link)'
  }
  return $results
}

function ConvertFrom-WorktreeList($Lines, [int]$ExitCode) {
  # Paths from `git worktree list --porcelain`. A failed git call throws, so
  # that no folder is acted on without knowing what git registers.
  if ($ExitCode -ne 0) { throw "git worktree list failed (exit code $ExitCode)" }
  $paths = @()
  foreach ($line in @($Lines)) {
    if ("$line" -like 'worktree *') { $paths += ("$line").Substring(9).Trim() }
  }
  return $paths
}

function Select-ProcessesToEnd($Decisions, [hashtable]$Failed) {
  # What to end in one pass: parents before their children (depth in the
  # cluster, then creation time), leaving out pids that failed earlier.
  $list = @($Decisions | Where-Object { $_.Action -eq 'End' -and -not $Failed.ContainsKey($_.ProcessId) })
  return @($list | Sort-Object @{ Expression = { [int]$_.Depth } }, @{ Expression = { $_.CreationDate } })
}

function Test-SameProcess([string]$SnapName, $SnapStart, [string]$CurName, $CurStart) {
  # PID-reuse guard: same executable name and start time within a second.
  if ($null -eq $SnapStart -or $null -eq $CurStart -or -not $SnapName -or -not $CurName) { return $false }
  $a = [IO.Path]::GetFileNameWithoutExtension($SnapName).ToLowerInvariant()
  $b = [IO.Path]::GetFileNameWithoutExtension($CurName).ToLowerInvariant()
  if ($a -ne $b) { return $false }
  return [math]::Abs(([datetime]$SnapStart - [datetime]$CurStart).TotalSeconds) -le 1
}

function Get-CleanupSummary([string[]]$Leftovers, [bool]$WhatIfMode) {
  if (@($Leftovers).Count -eq 0) {
    if ($WhatIfMode) { return @('Nothing would be left.') }
    return @('Nothing left.')
  }
  $lines = @($(if ($WhatIfMode) { 'Would leave:' } else { 'Left over:' }))
  foreach ($l in $Leftovers) { $lines += "  $l" }
  return $lines
}

# ---------- system access (not run by the tests) ----------

function Initialize-CwdHelper {
  if ('NotedCwdReader' -as [type]) { return }
  Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class NotedCwdReader {
  [DllImport("kernel32.dll")] static extern IntPtr OpenProcess(uint access, bool inherit, int pid);
  [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
  [DllImport("kernel32.dll")] static extern bool ReadProcessMemory(IntPtr h, IntPtr addr, byte[] buf, IntPtr size, out IntPtr read);
  [DllImport("ntdll.dll")] static extern int NtQueryInformationProcess(IntPtr h, int cls, byte[] info, int len, out int ret);
  public static string Get(int pid) {
    IntPtr h = IntPtr.Zero;
    try {
      if (IntPtr.Size != 8) return null;
      h = OpenProcess(0x0410, false, pid);
      if (h == IntPtr.Zero) return null;
      byte[] pbi = new byte[48];
      int ret;
      if (NtQueryInformationProcess(h, 0, pbi, 48, out ret) != 0) return null;
      long peb = BitConverter.ToInt64(pbi, 8);
      if (peb == 0) return null;
      IntPtr read;
      byte[] b8 = new byte[8];
      if (!ReadProcessMemory(h, new IntPtr(peb + 0x20), b8, new IntPtr(8), out read)) return null;
      long pp = BitConverter.ToInt64(b8, 0);
      if (pp == 0) return null;
      byte[] us = new byte[16];
      if (!ReadProcessMemory(h, new IntPtr(pp + 0x38), us, new IntPtr(16), out read)) return null;
      int len = BitConverter.ToUInt16(us, 0);
      long buf = BitConverter.ToInt64(us, 8);
      if (len == 0 || len > 32768 || buf == 0) return null;
      byte[] s = new byte[len];
      if (!ReadProcessMemory(h, new IntPtr(buf), s, new IntPtr(len), out read)) return null;
      return System.Text.Encoding.Unicode.GetString(s);
    } catch { return null; }
    finally { if (h != IntPtr.Zero) CloseHandle(h); }
  }
}
'@
}

function Get-ProcessCwd([int]$ProcessId) {
  try { return [NotedCwdReader]::Get($ProcessId) } catch { return $null }
}

function Write-CleanupLog([string]$Action, [string]$What) {
  try {
    $line = '{0:yyyy-MM-dd HH:mm:ss}  {1}  {2}' -f (Get-Date), $Action, $What
    Add-Content -Path (Join-Path $env:TEMP 'noted-cleanup-run.log') -Value $line -Encoding UTF8
  } catch { }
}

function Get-ShortCmd([string]$Cmd) {
  if (-not $Cmd) { return '' }
  $c = ($Cmd -replace '\s+', ' ').Trim()
  if ($c.Length -gt 100) { $c = $c.Substring(0, 97) + '...' }
  return $c
}

function Get-CleanupProcessDecisions($Roots, [string]$ReleaseDir) {
  $all = @(Get-CimInstance Win32_Process | ForEach-Object {
      [pscustomobject]@{
        ProcessId = [int]$_.ProcessId; ParentProcessId = [int]$_.ParentProcessId
        Name = $_.Name; CommandLine = $_.CommandLine; ExecutablePath = $_.ExecutablePath
        CreationDate = $_.CreationDate; Cwd = $null
      }
    })
  $wrappers = @($all | Where-Object {
      ($script:DartNames -contains "$($_.Name)".ToLowerInvariant()) -or
      (($script:ShellNames -contains "$($_.Name)".ToLowerInvariant()) -and
        "$($_.CommandLine)" -match '(?i)(?<![A-Za-z0-9_])(flutter|dart)(?![A-Za-z0-9_])')
    })
  if ($wrappers.Count -gt 0) {
    Initialize-CwdHelper
    foreach ($w in $wrappers) { $w.Cwd = Get-ProcessCwd $w.ProcessId }
  }
  return Select-CleanupProcesses -Processes $all -Roots $Roots -ReleaseDir $ReleaseDir -SelfPids @([int]$PID)
}

function Get-WorktreeListRaw([string]$Git, [string]$Main) {
  # UTF-8 output so that non-ASCII paths match the folders on disk.
  $old = $null
  try { $old = [Console]::OutputEncoding; [Console]::OutputEncoding = New-Object Text.UTF8Encoding($false) } catch { }
  try {
    $lines = @(& $Git -c core.quotepath=off -C $Main worktree list --porcelain)
    return [pscustomobject]@{ Lines = $lines; ExitCode = $LASTEXITCODE }
  } finally {
    if ($null -ne $old) { try { [Console]::OutputEncoding = $old } catch { } }
  }
}

function Get-WorktreeFolderInfo($Dir, [string]$Git) {
  # Gathers the facts Select-CleanupWorktrees decides on. Does not scan the tree.
  $reparse = [bool]($Dir.Attributes -band [IO.FileAttributes]::ReparsePoint)
  $info = [pscustomobject]@{
    FullName = $Dir.FullName; LastWriteTime = $Dir.LastWriteTime; IsReparsePoint = $reparse
    GitKind = 'none'; GitDir = ''; GitDirExists = $false; StatusOk = $true; HasChanges = $false
  }
  if ($reparse) { return $info }
  $gitPath = Join-Path $Dir.FullName '.git'
  $err = $null
  $item = Get-Item -LiteralPath $gitPath -Force -ErrorAction SilentlyContinue -ErrorVariable err
  if ($null -eq $item) {
    if ($err -and $err.Count -gt 0 -and $err[0].CategoryInfo.Category -ne 'ObjectNotFound') { $info.GitKind = 'unreadable' }
    return $info
  }
  if ($item.LastWriteTime -gt $info.LastWriteTime) { $info.LastWriteTime = $item.LastWriteTime }
  if ([bool]($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { $info.GitKind = 'unreadable'; return $info }
  if ($item.PSIsContainer) { $info.GitKind = 'dir'; return $info }
  try {
    $text = [IO.File]::ReadAllText($gitPath, (New-Object Text.UTF8Encoding($false)))
    $m = [regex]::Match($text, '^\s*gitdir:\s*(.+?)\s*$', [Text.RegularExpressions.RegexOptions]::Multiline)
    if (-not $m.Success) { $info.GitKind = 'unreadable'; return $info }
    $target = $m.Groups[1].Value.Replace('/', '\')
    if (-not [IO.Path]::IsPathRooted($target)) { $target = Join-Path $Dir.FullName $target }
    $info.GitDir = [IO.Path]::GetFullPath($target)
    $info.GitKind = 'file'
    $info.GitDirExists = [IO.Directory]::Exists($info.GitDir)
  } catch { $info.GitKind = 'unreadable'; return $info }
  if ($info.GitDirExists) {
    try {
      $st = @(& $Git -c core.quotepath=off -C $Dir.FullName status --porcelain)
      $info.StatusOk = ($LASTEXITCODE -eq 0)
      $info.HasChanges = (($st -join '').Trim().Length -gt 0)
    } catch { $info.StatusOk = $false }
  }
  return $info
}

function Invoke-Cleanup {
  $git = 'git'
  $common = @(& $git -C $PSScriptRoot rev-parse --path-format=absolute --git-common-dir)
  if ($LASTEXITCODE -ne 0 -or $common.Count -eq 0) { throw 'not inside a git repository' }
  $common = $common[0]
  $main = [IO.Path]::GetFullPath(([string]$common).Replace('/', '\')).TrimEnd('\')
  $main = Split-Path -Parent $main
  $releaseDir = Join-Path $main 'app\build\windows\x64\runner\Release'
  $worktreesDir = Join-Path $main '.claude\worktrees'

  # What git registers. A failure stops the run before anything is acted on.
  $raw = Get-WorktreeListRaw $git $main
  $registered = @(ConvertFrom-WorktreeList $raw.Lines $raw.ExitCode)
  $roots = @($main) + $registered

  $out = New-Object System.Collections.ArrayList
  $leftovers = New-Object System.Collections.ArrayList
  $acted = 0

  # Processes. An abandoned flutter tool can start new test processes
  # between the snapshot and the kill, so end parents first, then take a
  # fresh snapshot and repeat until nothing qualifies.
  $maxPasses = 5
  $failed = @{}
  for ($pass = 1; $pass -le $maxPasses + 1; $pass++) {
    $decisions = @(Get-CleanupProcessDecisions $roots $releaseDir)
    $toEnd = @(Select-ProcessesToEnd $decisions $failed)
    if ($WhatIf -or $toEnd.Count -eq 0 -or $pass -gt $maxPasses) {
      foreach ($d in $decisions) {
        $desc = "pid $($d.ProcessId) $($d.Name) $(Get-ShortCmd $d.CommandLine)"
        if ($d.Action -eq 'End') {
          if ($WhatIf) {
            [void]$out.Add("would end: $desc")
            Write-CleanupLog 'would-end' $desc
          } else {
            # Still there after every pass (or could not be ended).
            [void]$out.Add("could not end: $desc")
            [void]$leftovers.Add("process $desc")
          }
        } elseif ($d.Reason -like 'owned by*') {
          [void]$out.Add("kept: $desc ($($d.Reason))")
          [void]$leftovers.Add("process $desc ($($d.Reason))")
        } elseif ($d.Reason -eq 'release build') {
          [void]$out.Add("kept: $desc ($($d.Reason))")
        }
      }
      break
    }
    foreach ($d in $toEnd) {
      $desc = "pid $($d.ProcessId) $($d.Name) $(Get-ShortCmd $d.CommandLine)"
      # The pid may have been reused since the snapshot.
      $cur = Get-Process -Id $d.ProcessId -ErrorAction SilentlyContinue
      if ($null -eq $cur) { continue }
      $start = $null
      try { $start = $cur.StartTime } catch { }
      if (-not (Test-SameProcess $d.Name $d.CreationDate $cur.ProcessName $start)) {
        [void]$out.Add("skipped (pid reused or not verifiable): $desc")
        continue
      }
      try {
        Stop-Process -Id $d.ProcessId -Force
        [void]$out.Add("ended: $desc")
        Write-CleanupLog 'ended' $desc
        $acted++
      } catch {
        if (Get-Process -Id $d.ProcessId -ErrorAction SilentlyContinue) {
          [void]$out.Add("error ending: $desc ($($_.Exception.Message))")
          $failed[$d.ProcessId] = $true
        }
      }
    }
    Start-Sleep -Milliseconds 300
  }

  # Worktrees
  if (-not $WhatIf) { & $git -C $main worktree prune }
  $skipReason = $null
  foreach ($d in @((Join-Path $main '.claude'), $worktreesDir)) {
    $it = Get-Item -LiteralPath $d -Force -ErrorAction SilentlyContinue
    if ($it -and [bool]($it.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
      $skipReason = "$d is a junction or symlink"; break
    }
  }
  $wt = @()
  if ($skipReason) {
    [void]$out.Add("worktree step skipped: $skipReason")
    [void]$leftovers.Add("worktree folders not examined ($skipReason)")
  } elseif (Test-Path -LiteralPath $worktreesDir) {
    $folders = @()
    foreach ($dir in @(Get-ChildItem -LiteralPath $worktreesDir -Directory -Force)) {
      $folders += Get-WorktreeFolderInfo $dir $git
    }
    $wt = @(Select-CleanupWorktrees -Folders $folders -Registered $registered -WorktreesDir $worktreesDir -Now (Get-Date))
  }
  foreach ($w in $wt) {
    if ($w.Action -eq 'Remove') {
      if ($WhatIf) {
        [void]$out.Add("would remove: $($w.FullName)")
        Write-CleanupLog 'would-remove' $w.FullName
        continue
      }
      try {
        # Re-check just before deleting: must still be a direct child.
        $full = [IO.Path]::GetFullPath($w.FullName)
        if (-not (Test-InsideDir $full $worktreesDir)) { throw 'path is outside the worktrees folder' }
        Remove-Item -LiteralPath $full -Recurse -Force
        [void]$out.Add("removed: $($w.FullName)")
        Write-CleanupLog 'removed' $w.FullName
        $acted++
      } catch {
        if (Test-Path -LiteralPath $w.FullName) {
          [void]$out.Add("not removable: $($w.FullName) ($($_.Exception.Message))")
          [void]$leftovers.Add("folder $($w.FullName)")
        } else {
          [void]$out.Add("removed: $($w.FullName)")
          Write-CleanupLog 'removed' $w.FullName
          $acted++
        }
      }
    } else {
      [void]$out.Add("kept: $($w.FullName) ($($w.Reason))")
      if ($w.Action -eq 'Skip' -or $w.Reason -ne 'registered worktree') {
        [void]$leftovers.Add("folder $($w.FullName) ($($w.Reason))")
      }
    }
  }

  if ($Hook) {
    if ($acted -gt 0) { Write-Output "cleanup-run: ended or removed $acted item(s); see $env:TEMP\noted-cleanup-run.log" }
    return
  }
  foreach ($o in $out) { Write-Output $o }
  foreach ($l in @(Get-CleanupSummary @($leftovers) ([bool]$WhatIf))) { Write-Output $l }
}

if ($MyInvocation.InvocationName -ne '.') {
  if ($Hook) {
    # Exit 0 only on success; any error is one stderr line and exit 1
    # (Claude Code shows that as a non-blocking warning; never exit 2).
    try { Invoke-Cleanup } catch {
      [Console]::Error.WriteLine("cleanup-run: $($_.Exception.Message)")
      exit 1
    }
    exit 0
  }
  try {
    Invoke-Cleanup
    exit 0
  } catch {
    Write-Output "cleanup-run: $($_.Exception.Message)"
    exit 1
  }
}
