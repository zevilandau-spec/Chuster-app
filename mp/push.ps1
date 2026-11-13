# Chuster Box-Print Pusher
# Reads the Markoprint logger's CSV on this PC and sends today's box counts to the Chuster app, so the
# app's "Box printer" screen shows live counts from anywhere. Read-only on the CSV; it never changes the
# printer or the logger. Sends only counts (label name + how many boxes) over HTTPS to the app's own
# address.
#
#   -Once    send one update now (for testing)
#   -Watch   stay running and send every ~10 seconds (this is what -Install sets up)
#   -Install register it to run in -Watch mode at startup, as SYSTEM, and restart itself if it stops
#
# Setup (Nexivity or Zevi):
#   1) Put push.ps1 + config.json in  C:\ProgramData\MarkoprintLog\  (next to the existing logger).
#   2) Edit config.json: set "secret" to the value Zevi gives you. Leave "url" as is.
#   3) Test:     powershell -NoProfile -ExecutionPolicy Bypass -File "C:\ProgramData\MarkoprintLog\push.ps1" -Once
#   4) Install:  powershell -NoProfile -ExecutionPolicy Bypass -File "C:\ProgramData\MarkoprintLog\push.ps1" -Install
#   CrowdStrike: same folder as the logger, so the existing MarkoprintLog exclusion covers it. Start it by
#   full path (as above), not with .\push.ps1 from an open window, or CrowdStrike will block it.

param([switch]$Install, [switch]$Once, [switch]$Watch)
$ErrorActionPreference = 'Stop'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }

$Here     = Split-Path -Parent $MyInvocation.MyCommand.Path
$CfgPath  = Join-Path $Here 'config.json'
$LogPath  = Join-Path $Here 'push-log.txt'
$TaskName = 'Chuster Box-Print Pusher'
$Interval = 10   # seconds between sends in -Watch mode

function Log([string]$m) {
  $line = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '  ' + $m
  Write-Host $line
  try {
    if ((Test-Path $LogPath) -and (Get-Item $LogPath).Length -gt 1MB) { Move-Item $LogPath ($LogPath + '.old') -Force }
    Add-Content -Path $LogPath -Value $line -Encoding UTF8
  } catch { }
}

# ---------- config ----------
if (-not (Test-Path $CfgPath)) {
  @{ url = 'https://chuster.netlify.app/printlog/in'; secret = 'PASTE-SECRET-FROM-ZEVI'; csvFolder = $Here } | ConvertTo-Json | Set-Content -Path $CfgPath -Encoding UTF8
  Log "Wrote a starter config.json - set the secret, then run again."
  if (-not $Install) { return }
}
$cfg = Get-Content $CfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
if (-not $cfg.url)       { throw 'config.json: url is missing' }
if (-not $cfg.secret -or $cfg.secret -eq 'PASTE-SECRET-FROM-ZEVI') { throw 'config.json: set "secret" to the value Zevi gave you' }
$csvFolder = if ($cfg.csvFolder) { [string]$cfg.csvFolder } else { $Here }

# ---------- install the scheduled task (runs -Watch at startup, restarts if it stops) ----------
if ($Install) {
  $ps  = (Get-Command powershell.exe).Source
  $arg = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + (Join-Path $Here 'push.ps1') + '" -Watch'
  $act = New-ScheduledTaskAction -Execute $ps -Argument $arg
  $trg = New-ScheduledTaskTrigger -AtStartup
  $pr  = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
  $set = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew -RestartInterval (New-TimeSpan -Minutes 1) -RestartCount 999 -ExecutionTimeLimit ([TimeSpan]::Zero)
  Register-ScheduledTask -TaskName $TaskName -Action $act -Trigger $trg -Principal $pr -Settings $set -Force | Out-Null
  try { Start-ScheduledTask -TaskName $TaskName } catch { }
  Log "Installed scheduled task '$TaskName' (stay-running, every $Interval sec, as SYSTEM) and started it."
  return
}

# ---------- one send ----------
function Send-Once {
  $csv = Get-ChildItem -Path $csvFolder -Filter 'prints-*.csv' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
  if (-not $csv) { return @{ ok = $false; sig = 'nocsv'; msg = "No prints-*.csv in $csvFolder" } }
  $rows = @(Import-Csv -Path $csv.FullName)
  if (-not $rows -or $rows.Count -eq 0) { return @{ ok = $false; sig = 'empty'; msg = 'CSV empty' } }

  $today = Get-Date -Format 'yyyy-MM-dd'
  $labels = @{}
  foreach ($r in $rows) {
    if ([string]$r.Date -ne $today) { continue }
    $lab = ([string]$r.Label).Trim(); if (-not $lab) { continue }
    $n = 0; [void][int]::TryParse(([string]$r.PrintsAdded), [ref]$n)
    if ($n -gt 0) { if ($labels.ContainsKey($lab)) { $labels[$lab] += $n } else { $labels[$lab] = $n } }
  }
  $last = $rows[$rows.Count - 1]; $now = $null
  if ($last -and ([string]$last.Label).Trim()) {
    $cnt = 0; [void][int]::TryParse(([string]$last.PrinterCounter), [ref]$cnt)
    $t = (([string]$last.Time) -replace '[^0-9:]', '')
    $now = @{ label = ([string]$last.Label).Trim(); state = 0; counter = $cnt; at = (([string]$last.Date) + 'T' + $t) }
  }
  $bodyJson = (@{ day = $today; labels = $labels; now = $now } | ConvertTo-Json -Depth 5 -Compress)
  $sum = ($labels.Values | Measure-Object -Sum).Sum
  $sig = "$today|$sum|" + $(if ($now) { $now.label + '|' + $now.counter } else { '' })
  try {
    [void](Invoke-RestMethod -Uri ([string]$cfg.url) -Method Post -Body $bodyJson -ContentType 'application/json' -Headers @{ 'x-print-secret' = [string]$cfg.secret } -TimeoutSec 20)
    return @{ ok = $true; sig = $sig; msg = ("OK  " + $labels.Count + " label(s), " + $sum + " boxes today" + $(if ($now) { " - running '" + $now.label + "' (" + $now.counter + ")" } else { "" })) }
  } catch {
    return @{ ok = $false; sig = 'err'; msg = ("SEND FAILED: " + $_.Exception.Message) }
  }
}

# ---------- stay-running mode: send every ~$Interval seconds, log only on change or error ----------
if ($Watch) {
  Log "Watch started - sending every $Interval sec."
  $lastSig = ''
  while ($true) {
    $r = Send-Once
    if (-not $r.ok) { Log $r.msg }
    elseif ($r.sig -ne $lastSig) { Log $r.msg; $lastSig = $r.sig }
    Start-Sleep -Seconds $Interval
  }
}

# ---------- default / -Once ----------
$r = Send-Once
Log $r.msg
