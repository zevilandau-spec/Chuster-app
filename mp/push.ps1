# Chuster Box-Print Pusher
# Reads the Markoprint logger's CSV on this PC and sends today's box counts to the Chuster app, so the
# app's "Box printer" screen shows live counts from anywhere. Read-only on the CSV; it never changes the
# printer or the logger. Sends only counts (label name + how many boxes) over HTTPS to the app's own
# address. Runs every minute from Windows Task Scheduler.
#
# Setup (Nexivity):
#   1) Put push.ps1 + config.json in  C:\ProgramData\MarkoprintLog\  (next to the existing logger).
#   2) Edit config.json: set "secret" to the value Zevi gives you. Leave "url" as is.
#   3) Run once elevated:   powershell -NoProfile -ExecutionPolicy Bypass -File "C:\ProgramData\MarkoprintLog\push.ps1" -Install
#   4) Test:                powershell -NoProfile -ExecutionPolicy Bypass -File "C:\ProgramData\MarkoprintLog\push.ps1" -Once
#      A healthy test prints  OK  and the number of labels sent.
#   CrowdStrike: same folder as the logger, so the existing MarkoprintLog exclusion covers it. Start it by
#   full path (as above), not with .\push.ps1 from an open window, or CrowdStrike will block it.

param([switch]$Install, [switch]$Once)
$ErrorActionPreference = 'Stop'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }

$Here     = Split-Path -Parent $MyInvocation.MyCommand.Path
$CfgPath  = Join-Path $Here 'config.json'
$LogPath  = Join-Path $Here 'push-log.txt'
$TaskName = 'Chuster Box-Print Pusher'

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

# ---------- install the scheduled task ----------
if ($Install) {
  $ps  = (Get-Command powershell.exe).Source
  $arg = '-NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $Here 'push.ps1') + '" -Once'
  $act = New-ScheduledTaskAction -Execute $ps -Argument $arg
  # every 1 minute, forever, starting at the next whole minute
  $trg = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 1)
  $pr  = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
  $set = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 4)
  Register-ScheduledTask -TaskName $TaskName -Action $act -Trigger $trg -Principal $pr -Settings $set -Force | Out-Null
  Log "Installed scheduled task '$TaskName' (every minute, as SYSTEM)."
  return
}

# ---------- find the newest monthly CSV the logger writes ----------
$csv = Get-ChildItem -Path $csvFolder -Filter 'prints-*.csv' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
if (-not $csv) { Log "No prints-*.csv found in $csvFolder - nothing to send yet."; return }

$rows = @(Import-Csv -Path $csv.FullName)
if (-not $rows -or $rows.Count -eq 0) { Log "CSV is empty - nothing to send."; return }

$today = Get-Date -Format 'yyyy-MM-dd'

# today's boxes per label
$labels = @{}
foreach ($r in $rows) {
  if ([string]$r.Date -ne $today) { continue }
  $lab = ([string]$r.Label).Trim()
  if (-not $lab) { continue }
  $n = 0; [void][int]::TryParse(([string]$r.PrintsAdded), [ref]$n)
  if ($n -gt 0) { if ($labels.ContainsKey($lab)) { $labels[$lab] += $n } else { $labels[$lab] = $n } }
}

# "running now" = the last line in the file
$last = $rows[$rows.Count - 1]
$now = $null
if ($last -and ([string]$last.Label).Trim()) {
  $cnt = 0; [void][int]::TryParse(([string]$last.PrinterCounter), [ref]$cnt)
  $t = (([string]$last.Time) -replace '[^0-9:]', '')
  $at = ([string]$last.Date) + 'T' + $t
  $now = @{ label = ([string]$last.Label).Trim(); state = 0; counter = $cnt; at = $at }
}

$payload = @{ day = $today; labels = $labels; now = $now }
$bodyJson = $payload | ConvertTo-Json -Depth 5 -Compress

try {
  $resp = Invoke-RestMethod -Uri ([string]$cfg.url) -Method Post -Body $bodyJson -ContentType 'application/json' -Headers @{ 'x-print-secret' = [string]$cfg.secret } -TimeoutSec 20
  Log ("OK  sent " + $labels.Count + " label(s), " + (($labels.Values | Measure-Object -Sum).Sum) + " boxes today" + $(if ($now) { " - running '" + $now.label + "' (" + $now.counter + ")" } else { "" }))
} catch {
  Log ("SEND FAILED: " + $_.Exception.Message)
}
