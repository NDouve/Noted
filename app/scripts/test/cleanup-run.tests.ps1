# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

<#
.SYNOPSIS
  Tests for cleanup-run.ps1 with fake records. Touches no real process or
  folder. Plain asserts, no Pester. Exit 1 if any test fails.
#>
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\cleanup-run.ps1')

$script:pass = 0
$script:fail = 0
function Check([string]$Name, [bool]$Ok) {
  if ($Ok) { $script:pass++; Write-Host "  ok   $Name" }
  else { $script:fail++; Write-Host "  FAIL $Name" }
}

$root = 'C:\Users\dev\Noted'
$release = "$root\app\build\windows\x64\runner\Release"
$t0 = Get-Date '2026-01-01 10:00:00'
$script:seq = 0
function P($id, $parent, $name, $cmd, $exe = $null, $cwd = $null, $age = 0) {
  [pscustomobject]@{
    ProcessId = $id; ParentProcessId = $parent; Name = $name; CommandLine = $cmd
    ExecutablePath = $exe; Cwd = $cwd; CreationDate = $t0.AddSeconds($age + $id / 1000.0)
  }
}
function Run($procs, $self = @(9999)) {
  $r = Select-CleanupProcesses -Processes $procs -Roots @($root) -ReleaseDir $release -SelfPids $self
  $h = @{}
  foreach ($x in $r) { $h[$x.ProcessId] = $x }
  return $h
}
$pkg = "--packages=C:\Users\dev\Noted\.dart_tool\package_config.json"

# Tree: shell(10, parent 1 dead) -> flutter tool dart(11) -> vm(12) -> tester(13), tester(14, no cmdline)
function Tree($shellParent) {
  @(
    (P 10 $shellParent 'cmd.exe' 'cmd /c flutter test'),
    (P 11 10 'dart.exe' 'dart.exe flutter_tools.snapshot test'),
    (P 12 11 'dartvm.exe' 'dartvm.exe flutter_tools.snapshot test'),
    (P 13 12 'flutter_tester.exe' "flutter_tester.exe $pkg"),
    (P 14 12 'flutter_tester.exe' '')
  )
}

Write-Host 'processes'
$h = Run (Tree 1)
Check 'abandoned tree: all Dart members ended' (($h[11], $h[12], $h[13], $h[14] | Where-Object { $_.Action -ne 'End' }).Count -eq 0)
Check 'abandoned tree: shell not a candidate' (-not $h.ContainsKey(10))

$owned = (Tree 20) + @(
  (P 20 21 'bash.exe' 'bash -c flutter test' $null $null -10),
  (P 21 22 'claude.exe' 'claude' $null $null -50),
  (P 22 1 'explorer.exe' 'explorer' $null $null -100)
)
$h = Run $owned
Check 'owned by live chain: kept' (($h[11], $h[13] | Where-Object { $_.Action -ne 'Keep' }).Count -eq 0)
Check 'owned: the live shell is the owner' ($h[13].OwnerPid -eq 20 -and $h[13].OwnerName -eq 'bash.exe')

# Seen live: Git Bash's bash.exe runs with a dead parent while Claude Code
# uses it. A live bash owns its tree even when its own parent is gone.
$gitBash = (Tree 20) + @((P 20 1 'bash.exe' 'bash -c flutter test' $null $null -10))
$h = Run $gitBash
Check 'live Git Bash with a dead parent: its test run is kept' (($h[11], $h[12], $h[13], $h[14] | Where-Object { $_.Action -ne 'Keep' }).Count -eq 0)
Check 'live Git Bash with a dead parent: bash is the owner' ($h[11].OwnerPid -eq 20)
foreach ($shell in @(@('powershell.exe', 'powershell -c "flutter test"'), @('pwsh.exe', 'pwsh -c flutter test'), @('sh.exe', 'sh -c flutter test'))) {
  $h = Run ((Tree 20) + @((P 20 1 $shell[0] $shell[1] $null $null -10)))
  Check "live $($shell[0]) with a dead parent: owns its test run" ($h[11].Action -eq 'Keep' -and $h[11].OwnerPid -eq 20)
}
# A `cmd /k` window stays open for its user: it owns what runs in it.
$k = @(
  (P 10 1 'cmd.exe' 'cmd /k flutter run -d windows'),
  (P 11 10 'dart.exe' 'dart.exe flutter_tools.snapshot run'),
  (P 13 11 'flutter_tester.exe' "flutter_tester.exe $pkg")
)
$h = Run $k
Check 'cmd /k window with a dead parent: kept, cmd is the owner' ($h[11].Action -eq 'Keep' -and $h[11].OwnerPid -eq 10)

$run = @(
  (P 30 31 'dart.exe' 'dart flutter_tools.snapshot run'),
  (P 31 32 'pwsh.exe' 'pwsh -NoLogo' $null $null -50),
  (P 32 1 'WindowsTerminal.exe' 'wt' $null $null -100),
  (P 33 30 'flutter_tester.exe' "flutter_tester.exe $pkg")
)
$h = Run $run
Check 'maintainer flutter run under pwsh: kept' ($h[30].Action -eq 'Keep' -and $h[33].Action -eq 'Keep' -and $h[30].OwnerPid -eq 31)

$h = Run @((P 40 1 'dart.exe' 'dart C:\other\thing.dart'), (P 41 40 'dartvm.exe' 'dartvm C:\other'))
Check 'outside repo with dead parent: kept' ($h[40].Action -eq 'Keep' -and $h[41].Action -eq 'Keep')

$h = Run @((P 50 1 'flutter_tester.exe' '--packages=C:\Users\dev\Noted2\.dart_tool\p.json'))
Check 'Noted2 does not match Noted' ($h[50].Action -eq 'Keep')
$h = Run @((P 51 1 'flutter_tester.exe' '--packages=C:\Users\dev\Noted\.dart_tool\p.json'))
Check 'Noted prefix path matches' ($h[51].Action -eq 'End')
$h = Run @((P 52 1 'dart.exe' 'dart C:\Users\dev\NOTED'))
Check 'path at end of text, case-insensitive' ($h[52].Action -eq 'End')
$h = Run @((P 53 1 'dart.exe' 'dart C:/Users/dev/Noted/app/x.dart'))
Check 'forward slashes match' ($h[53].Action -eq 'End')
$h = Run @((P 54 1 'dart.exe' 'dart /c/Users/dev/Noted/app/x.dart'))
Check 'Git Bash /c/ form matches' ($h[54].Action -eq 'End')
$h = Run @((P 55 1 'dart.exe' 'dart /c/Users/dev/Noted2/app/x.dart'))
Check 'Git Bash Noted2 does not match' ($h[55].Action -eq 'Keep')
$h = Run @((P 56 1 'dart.exe' 'dart.exe x' $null "$root\packages\a"))
Check 'cwd-only match' ($h[56].Action -eq 'End')
$h = Run @((P 57 1 'dart.exe' 'dart.exe x' "$root\.claude\worktrees\w1\dart.exe"))
Check 'worktree path covered by the prefix' ($h[57].Action -eq 'End')

# PID reuse: parent pid 60 exists but was created after the child.
$h = Run @((P 61 60 'flutter_tester.exe' "flutter_tester.exe $pkg"), (P 60 1 'explorer.exe' 'explorer' $null $null 100))
Check 'parent pid reused (newer) counts as dead' ($h[61].Action -eq 'End')

$h = Run @((P 70 1 'flutter_tester.exe' "flutter_tester.exe $pkg" "$release\flutter_tester.exe"))
Check 'release-folder exe never ended' ($h[70].Action -eq 'Keep')

# A child older than its parent is a reused pid, not a descendant: the
# in-repo process 91 must not pull the outside cluster 90 into the repository.
$h = Run @((P 90 1 'dart.exe' 'dart C:\other\thing.dart'), (P 91 90 'dart.exe' "dart $root" $null $null -100))
Check 'older child (reused pid) is not a descendant' ($h[90].Action -eq 'Keep' -and $h[90].Reason -eq 'outside the repository')
Check 'older child with dead real parent: ended on its own' ($h[91].Action -eq 'End')
$h = Run @((P 92 1 'dart.exe' 'dart C:\other\thing.dart'), (P 93 92 'dart.exe' "dart $root" $null $null 100))
Check 'newer child is a descendant: cluster in repo' ($h[92].Action -eq 'End' -and $h[93].Action -eq 'End')

# Boundaries after the root: only a separator, a quote or the end.
$cases = @(
  @('C:\Users\dev\Noted - Copy\x', 'Keep'), @('C:\Users\dev\Noted (2)\x', 'Keep'),
  @('C:\Users\dev\Noted.bak\x', 'Keep'), @('C:\Users\dev\Noted-x\x', 'Keep'),
  @('C:\Users\dev\Noted_x\x', 'Keep'), @('C:\Users\dev\Noted2', 'Keep'),
  @('/c/Users/dev/Noted (2)/x', 'Keep'),
  @('C:\Users\dev\Noted', 'End'), @('C:\Users\dev\Noted\x', 'End'), @('C:/Users/dev/Noted/x', 'End'),
  @('"C:\Users\dev\Noted"', 'End'), @("'C:\Users\dev\Noted' --x", 'End')
)
foreach ($c in $cases) {
  $h = Run @((P 100 1 'dart.exe' "dart $($c[0])"))
  Check "boundary: $($c[0]) -> $($c[1])" ($h[100].Action -eq $c[1])
}

# Registered worktrees outside the main checkout count as part of the repository.
$wtRoot = 'D:\elsewhere\feature-wt'
$wtProc = @((P 110 1 'dart.exe' "dart $wtRoot\app\x.dart"), (P 111 1 'dart.exe' "dart D:\elsewhere\feature-wt2\x.dart"))
$r = Select-CleanupProcesses -Processes $wtProc -Roots @($root, $wtRoot) -ReleaseDir $release -SelfPids @(9999)
$wh = @{}; foreach ($x in $r) { $wh[$x.ProcessId] = $x }
Check 'registered worktree root: process in it ended' ($wh[110].Action -eq 'End')
Check 'registered worktree root: sibling-prefix path kept' ($wh[111].Action -eq 'Keep')
$r = Select-CleanupProcesses -Processes $wtProc -Roots @($root) -ReleaseDir $release -SelfPids @(9999)
Check 'without the worktree root: kept' (@($r | Where-Object { $_.Action -ne 'Keep' }).Count -eq 0)

# Depth and creation date in the decisions
$h = Run (Tree 1)
Check 'depth counts from the cluster top' ($h[11].Depth -eq 1 -and $h[12].Depth -eq 2 -and $h[13].Depth -eq 3 -and $h[14].Depth -eq 3)
Check 'decision carries CreationDate' ($h[12].CreationDate -eq $t0.AddSeconds(0.012))

# Select-ProcessesToEnd: depth first, then creation date; failed and kept pids left out.
function D($id, $depth, $age, $action = 'End') {
  [pscustomobject]@{ ProcessId = $id; Depth = $depth; CreationDate = $t0.AddSeconds($age); Action = $action }
}
$sel = Select-ProcessesToEnd @((D 1 2 0), (D 2 1 50), (D 3 1 10), (D 4 0 99), (D 5 1 5 'Keep'), (D 6 2 -5), (D 7 3 -50)) @{ 4 = $true }
Check 'ends shallow before deep, then oldest first' ((($sel | ForEach-Object { $_.ProcessId }) -join ',') -eq '3,2,6,1,7')
Check 'failed pid and kept records are left out' (-not ($sel | Where-Object { $_.ProcessId -in 4, 5 }))
Check 'nothing to end gives an empty list' (@(Select-ProcessesToEnd @((D 1 0 0 'Keep')) @{}).Count -eq 0)

# PID reuse check just before the kill
$s0 = $t0.AddSeconds(5)
Check 'same process: name and start match' (Test-SameProcess 'dart.exe' $s0 'dart' $s0.AddMilliseconds(400))
Check 'same process: start within a second earlier' (Test-SameProcess 'Dart.EXE' $s0 'dart' $s0.AddMilliseconds(-900))
Check 'reused pid: start differs' (-not (Test-SameProcess 'dart.exe' $s0 'dart' $s0.AddSeconds(3)))
Check 'reused pid: name differs' (-not (Test-SameProcess 'dart.exe' $s0 'chrome' $s0))
Check 'start time unreadable: not the same' (-not (Test-SameProcess 'dart.exe' $s0 'dart' $null))
Check 'snapshot without start time: not the same' (-not (Test-SameProcess 'dart.exe' $null 'dart' $s0))

$self = @((P 80 1 'dart.exe' "dart $root"), (P 81 80 'dart.exe' "dart $root"), (P 82 81 'pwsh.exe' 'pwsh cleanup'))
$h = Run $self @(82)
Check 'self ancestors never ended' ($h[80].Action -eq 'Keep' -and $h[81].Action -eq 'Keep')

Write-Host 'worktrees'
$wd = "$root\.claude\worktrees"
$now = Get-Date '2026-01-01 12:00:00'
function F($name, $kind = 'none', $age = 60, $o = @{}) {
  $full = if ($o.Full) { $o.Full } else { "$wd\$name" }
  [pscustomobject]@{
    FullName = $full; LastWriteTime = $now.AddMinutes(-$age); IsReparsePoint = [bool]$o.Reparse
    GitKind = $kind; GitDir = 'C:\repo\.git\worktrees\x'; GitDirExists = [bool]$o.Exists
    StatusOk = if ($o.ContainsKey('StatusOk')) { $o.StatusOk } else { $true }; HasChanges = [bool]$o.Changes
  }
}
$folders = @(
  (F 'reg'), (F 'REG2'), (F 'regfull' 'dir'),
  (F 'nogit-old'), (F 'nogit-new' 'none' 2),
  (F 'dead-old' 'file'), (F 'dead-new' 'file' 2),
  (F 'dead-dirty' 'file' 60 @{ Changes = $true }),
  (F 'linked' 'file' 60 @{ Exists = $true }),
  (F 'linked-new' 'file' 2 @{ Exists = $true }),
  (F 'linked-dirty' 'file' 60 @{ Exists = $true; Changes = $true }),
  (F 'linked-badstatus' 'file' 60 @{ Exists = $true; StatusOk = $false }),
  (F 'clone' 'dir'), (F 'unreadable' 'unreadable'), (F 'weird' 'something-else'),
  (F 'link' 'none' 60 @{ Reparse = $true }),
  (F 'x' 'none' 60 @{ Full = "$root\app" }), (F 'y' 'none' 60 @{ Full = "$wd\nogit-old\sub" }),
  (F 'z' 'none' 60 @{ Full = "$wd\..\app" })
)
$r = Select-CleanupWorktrees -Folders $folders -Registered @("$wd\reg", "$wd\reg2", "$wd\regfull") -WorktreesDir $wd -Now $now
$w = @{}
foreach ($x in $r) { $w[$x.FullName] = $x }
Check 'registered kept' ($w["$wd\reg"].Action -eq 'Keep' -and $w["$wd\reg"].Reason -eq 'registered worktree')
Check 'registered, case-insensitive' ($w["$wd\REG2"].Action -eq 'Keep')
Check 'registered wins over a .git folder' ($w["$wd\regfull"].Reason -eq 'registered worktree')
Check 'no .git, old: removed' ($w["$wd\nogit-old"].Action -eq 'Remove')
Check 'no .git, new: kept (10-minute rule)' ($w["$wd\nogit-new"].Action -eq 'Keep' -and $w["$wd\nogit-new"].Reason -like 'too new*')
Check '.git file with missing target, old: removed' ($w["$wd\dead-old"].Action -eq 'Remove')
Check '.git file with missing target, new: kept' ($w["$wd\dead-new"].Action -eq 'Keep' -and $w["$wd\dead-new"].Reason -like 'too new*')
Check 'missing target ignores HasChanges (no repo to ask)' ($w["$wd\dead-dirty"].Action -eq 'Remove')
Check 'target exists, not registered: kept as linked' ($w["$wd\linked"].Action -eq 'Keep' -and $w["$wd\linked"].Reason -like 'linked to C:\repo*')
Check 'target exists, new: kept as linked' ($w["$wd\linked-new"].Reason -like 'linked to*')
Check 'target exists with changes: kept, reason says so' ($w["$wd\linked-dirty"].Action -eq 'Keep' -and $w["$wd\linked-dirty"].Reason -like 'uncommitted changes*')
Check 'git status failed: kept, reason says so' ($w["$wd\linked-badstatus"].Action -eq 'Keep' -and $w["$wd\linked-badstatus"].Reason -like '*status failed*')
Check '.git folder (full clone): kept as not a worktree' ($w["$wd\clone"].Action -eq 'Keep' -and $w["$wd\clone"].Reason -like 'not a worktree*')
Check 'unreadable .git: kept' ($w["$wd\unreadable"].Action -eq 'Keep' -and $w["$wd\unreadable"].Reason -eq 'unreadable .git')
Check 'unknown git kind: kept' ($w["$wd\weird"].Action -eq 'Keep')
Check 'reparse point skipped' ($w["$wd\link"].Action -eq 'Skip')
Check 'main checkout subfolder never' ($w["$root\app"].Action -eq 'Skip')
Check 'nested folder never' ($w["$wd\nogit-old\sub"].Action -eq 'Skip')
Check 'dot-dot path never' ($w["$wd\..\app"].Action -eq 'Skip')
Check 'only the three leftovers are removed' ((@($r | Where-Object { $_.Action -eq 'Remove' }).Count) -eq 3)

# git worktree list
$uml = 'worktree C:/Users/dev/Noted/.claude/worktrees/w-' + [char]0x00FC
$paths = @(ConvertFrom-WorktreeList @('worktree C:/Users/dev/Noted', 'HEAD abc', 'branch refs/heads/main', '', $uml) 0)
Check 'worktree list parsed, non-ASCII path kept' ($paths.Count -eq 2 -and $paths[1].EndsWith([string][char]0x00FC))
$threw = $false
try { [void](ConvertFrom-WorktreeList @('worktree C:/x') 128) } catch { $threw = $true }
Check 'git worktree list failure throws' $threw
$threw = $false
try { [void](ConvertFrom-WorktreeList @() 1) } catch { $threw = $true }
Check 'git worktree list failure with no output throws' $threw

# Final line
Check 'summary: nothing left' (((Get-CleanupSummary @() $false) -join '|') -eq 'Nothing left.')
Check 'summary: nothing would be left' (((Get-CleanupSummary @() $true) -join '|') -eq 'Nothing would be left.')
Check 'summary: left over' (((Get-CleanupSummary @('a', 'b') $false) -join '|') -eq 'Left over:|  a|  b')
Check 'summary: would leave' (((Get-CleanupSummary @('a') $true) -join '|') -eq 'Would leave:|  a')

Write-Host ''
Write-Host "$($script:pass) passed, $($script:fail) failed"
if ($script:fail -gt 0) { exit 1 }
exit 0
