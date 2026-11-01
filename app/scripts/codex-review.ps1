# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

<#
.SYNOPSIS
  Runs an independent Codex review of Noted with a fixed prompt and writes
  the report to docs/reviews/.

.DESCRIPTION
  Reads docs/reviews/prompts/<Prompt>.md, fills in only {{BASE}} and
  {{HEAD}}, and runs it with `codex exec` (read-only sandbox, nothing saved
  to Codex's session history). Codex's final message is the report; this
  script writes it, with a header, to
  docs/reviews/YYYY-MM-DD-codex-<Prompt>.md (-2, -3, ... if that exists).

  The prompt files are not edited by the build team, so the review's scope
  is never set by the team whose work is reviewed. See docs/reviews/README.md.

  The working tree must be clean. If Codex changes any tracked file anyway,
  the change is undone and the script fails. Untracked files it creates
  are listed, not deleted.

  Prints the report's path on the last line of output. Exit codes:
  0 report written; 2 Codex isn't installed (nothing ran); 1 anything else.

.PARAMETER Prompt
  The prompt's name in docs/reviews/prompts/, without .md (default:
  run-diff).

.PARAMETER Base
  The commit the review starts from. For run-diff: the commit main was at
  when the run started. If omitted, the commit reviewed by the newest
  run-diff report is used.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File app\scripts\codex-review.ps1 -Base 7e11096

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File app\scripts\codex-review.ps1 -Prompt area-data-integrity
#>
param(
  [ValidatePattern('^[a-z0-9-]+$')][string]$Prompt = 'run-diff',
  [ValidatePattern('^[0-9a-fA-F]{7,40}$')][string]$Base
)

$ErrorActionPreference = 'Stop'
$utf8 = New-Object System.Text.UTF8Encoding($false)
# Windows PowerShell pipes text to native programs as ASCII unless told otherwise.
$OutputEncoding = $utf8

$repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
Set-Location $repo
$reviews = Join-Path $repo 'docs\reviews'
$promptFile = Join-Path $reviews "prompts\$Prompt.md"
if (-not (Test-Path $promptFile)) { throw "No prompt docs\reviews\prompts\$Prompt.md." }

$codex = Get-Command codex -ErrorAction SilentlyContinue
if (-not $codex) {
  Write-Host 'Codex review skipped: the "codex" command was not found. Install the Codex CLI and run "codex login".'
  exit 2
}

if (git status --porcelain --untracked-files=no) { throw 'The working tree has uncommitted changes. Commit or stash them first.' }

$head = (git rev-parse --short HEAD).Trim()

if ($Prompt -eq 'run-diff' -and -not $Base) {
  # The run-diff report committed most recently.
  $last = git log -1 --diff-filter=A --format= --name-only -- 'docs/reviews/*-codex-run-diff*.md' | Where-Object { $_ } | Select-Object -First 1
  if ($last -and (Test-Path $last)) {
    $line = Select-String -Path $last -Pattern '^- Commit reviewed: ([0-9a-fA-F]{7,40})' | Select-Object -First 1
    if ($line) { $Base = $line.Matches[0].Groups[1].Value }
  }
  if (-not $Base) { throw 'No -Base given and no earlier run-diff report to start from.' }
}
if ($Base) {
  # Windows PowerShell turns redirected native stderr into errors, so don't stop on it here.
  $previous = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  git cat-file -e "$Base^{commit}" 2>$null
  $found = ($LASTEXITCODE -eq 0)
  $ErrorActionPreference = $previous
  if (-not $found) { throw "Base $Base isn't a commit in this clone. Pull, or deepen the clone." }
  $Base = (git rev-parse --short $Base).Trim()
}
if ($Prompt -eq 'run-diff' -and $Base -eq $head) {
  Write-Host "Codex review skipped: nothing to review ($Base is HEAD)."
  exit 0
}

$text = [IO.File]::ReadAllText($promptFile, $utf8)
$text = $text.Replace('{{BASE}}', $(if ($Base) { $Base } else { '(none)' })).Replace('{{HEAD}}', $head)

$date = Get-Date -Format 'yyyy-MM-dd'
$name = "$date-codex-$Prompt"
$out = Join-Path $reviews "$name.md"
$n = 2
while (Test-Path $out) { $out = Join-Path $reviews "$name-$n.md"; $n++ }

$tmp = Join-Path ([IO.Path]::GetTempPath()) ("noted-codex-review-" + [guid]::NewGuid().ToString('N') + '.md')
$untrackedBefore = @(git ls-files --others --exclude-standard)

Write-Host "Codex review: $Prompt, $(if ($Base) { "$Base.." })$head. This can take several minutes."
$previous = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$text | & $codex.Source exec --ephemeral -o $tmp - | Out-Host
$codexExit = $LASTEXITCODE
$ErrorActionPreference = $previous

$changed = @(git diff --name-only)
if ($changed.Count -gt 0) {
  git restore -- $changed
  throw "Codex changed tracked files, which a review must not do. Undone: $($changed -join ', ')"
}
$created = @(git ls-files --others --exclude-standard | Where-Object { $untrackedBefore -notcontains $_ })

if ($codexExit -ne 0 -or -not (Test-Path $tmp)) { throw "codex exec failed (exit $codexExit); no report written." }
$body = [IO.File]::ReadAllText($tmp, $utf8).Trim()
Remove-Item $tmp
if (-not $body) { throw 'Codex returned an empty report.' }

$header = @(
  "# Codex review: $Prompt, $date",
  '',
  '- Reviewer: Codex (codex exec, read-only sandbox), run by app/scripts/codex-review.ps1',
  "- Prompt: docs/reviews/prompts/$Prompt.md",
  "- Commit reviewed: $head",
  "- Base: $(if ($Base) { $Base } else { '(none)' })",
  ''
)
if ($created.Count -gt 0) {
  $header += "- Untracked files Codex created (not deleted): $($created -join ', ')"
  $header += ''
}
[IO.File]::WriteAllText($out, (($header -join "`n") + "`n" + $body + "`n"), $utf8)

Write-Host 'Report written. Commit it unchanged.'
Write-Output (Resolve-Path -Relative $out)
