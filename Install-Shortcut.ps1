<#
    Creates a Start menu shortcut for WT SSH Manager with the app icon and a
    Ctrl+Alt+S hotkey. Run once from the repo folder; rerun if you move it.
#>
$script = Join-Path $PSScriptRoot 'WT-SSH-Manager.ps1'
$icon   = Join-Path $PSScriptRoot 'WT-SSH-Manager.ico'
$path   = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\WT SSH Manager.lnk'

$lnk = (New-Object -ComObject WScript.Shell).CreateShortcut($path)
$lnk.TargetPath       = 'powershell.exe'
$lnk.Arguments        = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$script`""
$lnk.WorkingDirectory = $PSScriptRoot
$lnk.IconLocation     = $icon
$lnk.Hotkey           = 'Ctrl+Alt+S'
$lnk.Save()

Write-Host "Shortcut created: $path" -ForegroundColor Green
Write-Host 'Launch it from the Start menu or with Ctrl+Alt+S. Right-click it to pin to the taskbar.'
