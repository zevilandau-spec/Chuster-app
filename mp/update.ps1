# Chuster Box-Print Pusher - one-time updater. Run elevated. Safe to run more than once.
# Stops the old pusher, drops in the current version from the app's site, and reinstalls it so it
# runs (and self-updates) from here on. Nothing is lost - the new pusher re-reads the full print log.
$ErrorActionPreference = 'SilentlyContinue'
$d = 'C:\ProgramData\MarkoprintLog\push.ps1'
$t = Join-Path $env:TEMP 'push.ps1'
try {
  (New-Object Net.WebClient).DownloadFile('https://chuster.netlify.app/mp/push.ps1?t=' + [DateTime]::UtcNow.Ticks, $t)
} catch { Read-Host ('Could not download (' + $_.Exception.Message + ') - press Enter to close'); exit }
if ((Get-Content $t -Raw) -notmatch '2026-11-16\.2') { Read-Host 'Site not refreshed yet - close this, wait a minute, run again. Press Enter to close'; exit }
try {
  Copy-Item $t $d -Force -ErrorAction Stop
} catch { Read-Host ('No access - this did not run as administrator (' + $_.Exception.Message + ') - press Enter to close'); exit }
Stop-ScheduledTask -TaskName 'Chuster Box-Print Pusher'
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -like '*push.ps1*-Watch*' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
Start-Sleep 2
powershell -NoProfile -ExecutionPolicy Bypass -File $d -Install
Read-Host 'DONE - times will come back within a minute. Press Enter to close'
