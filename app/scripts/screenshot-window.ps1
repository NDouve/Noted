# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

<#
.SYNOPSIS
  Starts Noted against a scratch data folder, optionally clicks and types
  in it, and saves a PNG of its window.

.DESCRIPTION
  For reviewing visible changes (.claude/agents/reviewer-ui.md). The child
  process gets APPDATA and LOCALAPPDATA pointing into -DataRoot
  (<DataRoot>\Roaming and <DataRoot>\Local), so the real notebook is never
  touched; this script's own environment is unchanged. Noted keeps its
  pages in %APPDATA%\Noted\pages and its settings in
  %APPDATA%\Noted\settings.json, so -Theme and -Toolbar write
  <DataRoot>\Roaming\Noted\settings.json (other keys in it are kept).

  The script finds the window of the process it started, resizes it, and
  sends input only to its FLUTTERVIEW child window (mouse messages with
  client coordinates of that view, then WM_CHAR for -Keys). The picture is
  taken with PrintWindow (PW_RENDERFULLCONTENT), so only Noted's window is
  captured, whatever is on top of it. It never stops a process it didn't
  start.

.PARAMETER Exe
  Path of noted.exe (default: the release build in this repository).

.PARAMETER DataRoot
  A scratch folder (created if missing) that holds the app's data.

.PARAMETER Theme
  light, dark or system: written to settings.json before launch.

.PARAMETER Toolbar
  tabs or contextual: written to settings.json before launch.

.PARAMETER Width
  Window width in pixels (default 1500).

.PARAMETER Height
  Window height in pixels (default 900).

.PARAMETER Out
  Where to save the PNG (default: noted-screenshot.png in -DataRoot).

.PARAMETER Clicks
  Points to click, as "x,y" in client coordinates of the Flutter view,
  sent in order with a short wait between.

.PARAMETER Keys
  Text to type after the clicks (WM_CHAR to the Flutter view).

.PARAMETER WaitMs
  How long to wait after launch before the first input (default 4000).

.PARAMETER KeepOpen
  Leave the instance this script started running.

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File screenshot-window.ps1 `
    -DataRoot $env:TEMP\noted-shot -Theme light -Out shot.png -Clicks "200,120","400,300" -Keys "Hello"
#>
param(
  [string]$Exe,
  [Parameter(Mandatory = $true)][string]$DataRoot,
  [ValidateSet('light', 'dark', 'system')][string]$Theme,
  [ValidateSet('tabs', 'contextual')][string]$Toolbar,
  [int]$Width = 1500,
  [int]$Height = 900,
  [string]$Out,
  [string[]]$Clicks,
  [string]$Keys,
  [int]$WaitMs = 4000,
  [switch]$KeepOpen
)

$ErrorActionPreference = 'Stop'

if (-not $Exe) {
  $Exe = Join-Path $PSScriptRoot '..\build\windows\x64\runner\Release\noted.exe'
}
if (-not (Test-Path $Exe)) { throw "noted.exe not found at $Exe. Pass -Exe <path>, or build the release first." }
$Exe = (Resolve-Path $Exe).Path

New-Item -ItemType Directory -Force $DataRoot | Out-Null
$DataRoot = (Resolve-Path $DataRoot).Path
$roaming = Join-Path $DataRoot 'Roaming'
$local = Join-Path $DataRoot 'Local'
$notedDir = Join-Path $roaming 'Noted'

# Never let the child's data folders be, or contain, the real ones (or the
# real Noted folder inside them). A scratch folder under %TEMP% is fine.
function Test-SameOrNested([string]$a, [string]$b) {
  $x = [System.IO.Path]::GetFullPath($a).TrimEnd('\') + '\'
  $y = [System.IO.Path]::GetFullPath($b).TrimEnd('\') + '\'
  return $x.StartsWith($y, [System.StringComparison]::OrdinalIgnoreCase) -or
    $y.StartsWith($x, [System.StringComparison]::OrdinalIgnoreCase)
}
$realRoaming = [Environment]::GetFolderPath('ApplicationData')
$realLocal = [Environment]::GetFolderPath('LocalApplicationData')
$realAppData = Join-Path ([Environment]::GetFolderPath('UserProfile')) 'AppData'
$realNoted = @((Join-Path $realRoaming 'Noted'), (Join-Path $realLocal 'Noted'))
foreach ($mine in @($roaming, $local)) {
  foreach ($real in @($realRoaming, $realLocal, $realAppData)) {
    # Equal to, or an ancestor of, a real folder.
    $m = [System.IO.Path]::GetFullPath($mine).TrimEnd('\') + '\'
    $r = [System.IO.Path]::GetFullPath($real).TrimEnd('\') + '\'
    if ($r.StartsWith($m, [System.StringComparison]::OrdinalIgnoreCase)) {
      throw "Refusing to run: -DataRoot '$DataRoot' would use '$mine', which is or contains the real data folder '$real'. Use a scratch folder."
    }
  }
  foreach ($real in $realNoted) {
    if (Test-SameOrNested $mine $real) {
      throw "Refusing to run: '$mine' overlaps the real Noted folder '$real'. Use a scratch folder."
    }
  }
}

New-Item -ItemType Directory -Force $notedDir, $local | Out-Null

if (-not $Out) { $Out = Join-Path $DataRoot 'noted-screenshot.png' }
if (-not [System.IO.Path]::IsPathRooted($Out)) { $Out = Join-Path (Get-Location).Path $Out }
$Out = [System.IO.Path]::GetFullPath($Out)
New-Item -ItemType Directory -Force (Split-Path $Out) | Out-Null

# settings.json: keep the other keys, set the ones asked for.
if ($Theme -or $Toolbar) {
  $settingsPath = Join-Path $notedDir 'settings.json'
  $settings = [ordered]@{ format = 1 }
  if (Test-Path $settingsPath) {
    try {
      $existing = Get-Content -Raw $settingsPath | ConvertFrom-Json
      $settings = [ordered]@{}
      foreach ($p in $existing.PSObject.Properties) { $settings[$p.Name] = $p.Value }
    } catch {
      $settings = [ordered]@{ format = 1 }
    }
  }
  if ($Theme) { $settings['theme'] = $Theme }
  if ($Toolbar) { $settings['toolbar'] = $Toolbar }
  $text = $settings | ConvertTo-Json -Depth 32
  [System.IO.File]::WriteAllText($settingsPath, $text, (New-Object System.Text.UTF8Encoding($false)))
}

Add-Type -ReferencedAssemblies System.Drawing -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using System.Text;

public static class NotedShot {
  delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc p, IntPtr l);
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr FindWindowEx(IntPtr parent, IntPtr after, string cls, string title);
  [DllImport("user32.dll")] static extern bool MoveWindow(IntPtr h, int x, int y, int w, int hgt, bool repaint);
  [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint flags);
  [DllImport("user32.dll")] static extern bool PostMessage(IntPtr h, uint msg, IntPtr w, IntPtr l);
  [DllImport("user32.dll")] static extern bool SetProcessDPIAware();
  [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr h, int cmd);
  [StructLayout(LayoutKind.Sequential)] struct RECT { public int L, T, R, B; }

  public static void InitDpi() { SetProcessDPIAware(); }

  // The visible top-level window of the process that has a FLUTTERVIEW child.
  public static IntPtr TopWindow(uint pid) {
    IntPtr found = IntPtr.Zero;
    EnumWindows((h, l) => {
      uint p; GetWindowThreadProcessId(h, out p);
      if (p == pid && IsWindowVisible(h) &&
          FindWindowEx(h, IntPtr.Zero, "FLUTTERVIEW", null) != IntPtr.Zero) {
        found = h; return false;
      }
      return true;
    }, IntPtr.Zero);
    return found;
  }

  public static IntPtr FlutterView(IntPtr top) {
    return FindWindowEx(top, IntPtr.Zero, "FLUTTERVIEW", null);
  }

  public static void Resize(IntPtr top, int w, int h) {
    ShowWindow(top, 9);
    MoveWindow(top, 40, 40, w, h, true);
  }

  static IntPtr Pack(int lo, int hi) { return (IntPtr)((hi << 16) | (lo & 0xFFFF)); }

  public static void Click(IntPtr view, int x, int y) {
    IntPtr pos = Pack(x, y);
    PostMessage(view, 0x0200, IntPtr.Zero, pos);          // WM_MOUSEMOVE
    System.Threading.Thread.Sleep(80);
    PostMessage(view, 0x0201, (IntPtr)1, pos);            // WM_LBUTTONDOWN
    System.Threading.Thread.Sleep(60);
    PostMessage(view, 0x0202, IntPtr.Zero, pos);          // WM_LBUTTONUP
  }

  public static void TypeText(IntPtr view, string s) {
    foreach (char c in s) {
      PostMessage(view, 0x0102, (IntPtr)c, (IntPtr)1);    // WM_CHAR
      System.Threading.Thread.Sleep(15);
    }
  }

  public static void Save(IntPtr top, string path) {
    RECT r; GetWindowRect(top, out r);
    int w = r.R - r.L, h = r.B - r.T;
    using (Bitmap bmp = new Bitmap(w, h, PixelFormat.Format32bppArgb))
    using (Graphics g = Graphics.FromImage(bmp)) {
      IntPtr hdc = g.GetHdc();
      bool ok;
      try { ok = PrintWindow(top, hdc, 2); } finally { g.ReleaseHdc(hdc); }
      if (!ok) throw new Exception("PrintWindow failed");
      bmp.Save(path, ImageFormat.Png);
    }
  }
}
'@

[NotedShot]::InitDpi()

$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = $Exe
$psi.WorkingDirectory = Split-Path $Exe
$psi.UseShellExecute = $false
$psi.EnvironmentVariables['APPDATA'] = $roaming
$psi.EnvironmentVariables['LOCALAPPDATA'] = $local
$proc = [System.Diagnostics.Process]::Start($psi)

function Stop-Started {
  if ($KeepOpen -or $proc.HasExited) { return }
  [void]$proc.CloseMainWindow()
  if (-not $proc.WaitForExit(5000)) { Stop-Process -Id $proc.Id -Force }
}

try {
  # Wait for the top-level window and its Flutter view.
  $top = [IntPtr]::Zero
  $view = [IntPtr]::Zero
  $deadline = (Get-Date).AddSeconds(30)
  while ((Get-Date) -lt $deadline) {
    if ($proc.HasExited) { throw "Noted exited before showing a window (exit code $($proc.ExitCode))." }
    $top = [NotedShot]::TopWindow([uint32]$proc.Id)
    if ($top -ne [IntPtr]::Zero) {
      $view = [NotedShot]::FlutterView($top)
      if ($view -ne [IntPtr]::Zero) { break }
    }
    Start-Sleep -Milliseconds 200
  }
  if ($top -eq [IntPtr]::Zero -or $view -eq [IntPtr]::Zero) {
    throw 'Noted''s window (with a FLUTTERVIEW child) did not appear within 30 seconds.'
  }

  [NotedShot]::Resize($top, $Width, $Height)
  Start-Sleep -Milliseconds $WaitMs

  foreach ($c in $Clicks) {
    $parts = $c -split ','
    if ($parts.Count -ne 2) { throw "Bad click '$c': use x,y." }
    [NotedShot]::Click($view, [int]$parts[0], [int]$parts[1])
    Start-Sleep -Milliseconds 400
  }
  if ($Keys) {
    [NotedShot]::TypeText($view, $Keys)
    Start-Sleep -Milliseconds 400
  }
  Start-Sleep -Milliseconds 600

  [NotedShot]::Save($top, $Out)
  Write-Output $Out
} finally {
  Stop-Started
}
