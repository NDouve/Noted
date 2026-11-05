# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

<#
.SYNOPSIS
  Creates "Noted" shortcuts on the Desktop and in the Start menu, and lets
  Noted open page files (.canvas) and binder files (noted-binder.json).

.DESCRIPTION
  The shortcuts point to noted.exe and use its icon. Run it from an unzipped
  Noted package (noted.exe next to this script) or from the repository
  (it then uses the release build in app\build\windows\x64\runner\Release).
  Running it again deletes and recreates the shortcuts and asks Explorer to
  refresh its icons.

  The file associations are per user (HKCU\Software\Classes, no admin):
    Noted.Page                  the page file type: icon and open command
    .canvas                     default is Noted.Page if none is set; always
                                listed in OpenWithProgids
    Applications\noted.exe      "Open with" entry (also for .json, so that
                                noted-binder.json can be opened; Noted
                                ignores any other .json file it is given)
  A default the user already chose for .canvas is not taken over, and Noted is
  not made the default for .json files. -Uninstall removes these keys and the
  shortcuts.

.PARAMETER ExePath
  The noted.exe to point to. Defaults as described above.

.PARAMETER Uninstall
  Removes the shortcuts and the file associations this script made.

.PARAMETER ResetIconCache
  Also restarts Explorer and deletes its icon cache files, for when an
  updated exe still shows its old icon. The taskbar disappears for a moment.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File install-shortcuts.ps1

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File install-shortcuts.ps1 -ResetIconCache
#>
param(
  [string]$ExePath,
  [switch]$Uninstall,
  [switch]$ResetIconCache
)

$ErrorActionPreference = 'Stop'

$notifySource = 'using System; using System.Runtime.InteropServices; public static class NotedShell { [DllImport("shell32.dll")] public static extern void SHChangeNotify(int e, uint f, IntPtr a, IntPtr b); }'
function Notify-AssociationsChanged {
  Add-Type -TypeDefinition $notifySource -ErrorAction SilentlyContinue
  [NotedShell]::SHChangeNotify(0x08000000, 0, [IntPtr]::Zero, [IntPtr]::Zero)
}

if ($Uninstall) {
  $classes = [Microsoft.Win32.Registry]::CurrentUser
  $classes.DeleteSubKeyTree('Software\Classes\Noted.Page', $false)
  $classes.DeleteSubKeyTree('Software\Classes\Applications\noted.exe', $false)
  # .canvas may be shared with other programs: only Noted's entries go.
  $ext = $classes.OpenSubKey('Software\Classes\.canvas', $true)
  if ($ext) {
    if ($ext.GetValue('') -eq 'Noted.Page') { $ext.DeleteValue('') }
    $ext.Close()
  }
  $progids = $classes.OpenSubKey('Software\Classes\.canvas\OpenWithProgids', $true)
  if ($progids) {
    if ($progids.GetValueNames() -contains 'Noted.Page') { $progids.DeleteValue('Noted.Page') }
    $progids.Close()
  }
  foreach ($lnk in @((Join-Path ([Environment]::GetFolderPath('Desktop')) 'Noted.lnk'),
                     (Join-Path ([Environment]::GetFolderPath('Programs')) 'Noted.lnk'))) {
    if (Test-Path $lnk) { Remove-Item $lnk -Force -Confirm:$false; Write-Host "Removed $lnk" }
  }
  Notify-AssociationsChanged
  Write-Host 'Removed the Noted shortcuts and file associations.'
  return
}

if (-not $ExePath) {
  $candidates = @(
    (Join-Path $PSScriptRoot 'noted.exe'),
    (Join-Path $PSScriptRoot '..\build\windows\x64\runner\Release\noted.exe')
  )
  $ExePath = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
  if (-not $ExePath) {
    throw "noted.exe not found next to this script or in the release build. Pass -ExePath."
  }
}
$ExePath = (Resolve-Path $ExePath).Path

$shell = New-Object -ComObject WScript.Shell
$links = @(
  (Join-Path ([Environment]::GetFolderPath('Desktop')) 'Noted.lnk'),
  (Join-Path ([Environment]::GetFolderPath('Programs')) 'Noted.lnk')
)
foreach ($lnk in $links) {
  # Deleting first makes Explorer treat it as a new shortcut, so it reads the
  # icon again instead of reusing what it cached for the old one.
  if (Test-Path $lnk) { Remove-Item $lnk -Force -Confirm:$false }
  $s = $shell.CreateShortcut($lnk)
  $s.TargetPath = $ExePath
  $s.WorkingDirectory = Split-Path $ExePath
  $s.IconLocation = "$ExePath,0"
  $s.Description = 'Noted'
  $s.Save()
  Write-Host "Created $lnk -> $ExePath"
}

# File associations. The .NET registry API is used so that the names are taken
# literally.
function Set-ClassKey([string]$subKey, [string]$name, [string]$value) {
  $k = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey("Software\Classes\$subKey")
  $k.SetValue($name, $value)
  $k.Close()
}
$open = '"' + $ExePath + '" "%1"'
Set-ClassKey 'Noted.Page' '' 'Noted page'
Set-ClassKey 'Noted.Page\DefaultIcon' '' "$ExePath,0"
Set-ClassKey 'Noted.Page\shell\open\command' '' $open
$ext = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey('Software\Classes\.canvas')
if (-not $ext.GetValue('')) { $ext.SetValue('', 'Noted.Page') }
$ext.Close()
Set-ClassKey '.canvas\OpenWithProgids' 'Noted.Page' ''
Set-ClassKey 'Applications\noted.exe' 'FriendlyAppName' 'Noted'
Set-ClassKey 'Applications\noted.exe\shell\open\command' '' $open
Set-ClassKey 'Applications\noted.exe\SupportedTypes' '.json' ''
Set-ClassKey 'Applications\noted.exe\SupportedTypes' '.canvas' ''
Notify-AssociationsChanged
Write-Host 'Noted can now open .canvas pages and noted-binder.json.'

# Ask Explorer to refresh the icons it shows.
& "$env:SystemRoot\System32\ie4uinit.exe" -show

if ($ResetIconCache) {
  # Explorer keeps icons in memory and in iconcache_*.db, so an updated exe
  # can keep its old icon on the Desktop, in the Start menu and on the
  # taskbar. Stop Explorer, delete the cache files and start it again; it
  # rebuilds them from the files.
  Write-Host 'Restarting Explorer to clear the icon cache...'
  Stop-Process -Name explorer -Force -Confirm:$false
  Start-Sleep -Seconds 2
  $cache = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Explorer'
  Get-ChildItem $cache -Filter 'iconcache*.db' -ErrorAction SilentlyContinue |
    Remove-Item -Force -Confirm:$false -ErrorAction SilentlyContinue
  Remove-Item (Join-Path $env:LOCALAPPDATA 'IconCache.db') -Force -Confirm:$false -ErrorAction SilentlyContinue
  if (-not (Get-Process explorer -ErrorAction SilentlyContinue)) { Start-Process explorer.exe }
  Write-Host 'Icon cache cleared.'
} else {
  Write-Host 'If Explorer still shows an old icon, run again with -ResetIconCache.'
}
