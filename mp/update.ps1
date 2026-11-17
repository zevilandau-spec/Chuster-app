# Chuster Box-Print Pusher - one-time updater. Safe to run more than once.
# Run it with:   irm https://chuster.netlify.app/mp/update.ps1 | iex
# It raises its own admin prompt, stops the old pusher, installs the current version from the app's
# site, and starts it so it runs (and self-updates) from here on. Nothing is lost - the new pusher
# re-reads the full print log, so today's times come back on the next send.
$ErrorActionPreference = 'SilentlyContinue'

# ---- step 1: make sure we're running as administrator; if not, relaunch elevated (UAC prompt) ----
$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
if (-not $admin) {
  $self = Join-Path $env:TEMP 'chuster-update.ps1'
  try { (New-Object Net.WebClient).DownloadFile('https://chuster.netlify.app/mp/update.ps1?t=' + [DateTime]::UtcNow.Ticks, $self) }
  catch { Write-Host ('Could not download: ' + $_.Exception.Message); return }
  Start-Process powershell -Verb RunAs -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',$self
  Write-Host 'Opening an administrator window - click Yes on the popup.'
  return
}

# ---- step 2 (now elevated): replace the pusher and reinstall it ----
$d = 'C:\ProgramData\MarkoprintLog\push.ps1'
$t = Join-Path $env:TEMP 'push.ps1'
try { (New-Object Net.WebClient).DownloadFile('https://chuster.netlify.app/mp/push.ps1?t=' + [DateTime]::UtcNow.Ticks, $t) }
catch { Read-Host ('Could not download (' + $_.Exception.Message + ') - press Enter to close'); exit }
if ((Get-Content $t -Raw) -notmatch '2026-11-16\.2') { Read-Host 'Site not refreshed yet - close this, wait a minute, run again. Press Enter to close'; exit }
try { Copy-Item $t $d -Force -ErrorAction Stop }
catch { Read-Host ('No access (' + $_.Exception.Message + ') - press Enter to close'); exit }
Stop-ScheduledTask -TaskName 'Chuster Box-Print Pusher'
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -like '*push.ps1*-Watch*' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
Start-Sleep 2
powershell -NoProfile -ExecutionPolicy Bypass -File $d -Install
Read-Host 'DONE - times will come back within a minute. Press Enter to close'
