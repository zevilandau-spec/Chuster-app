# Chuster box printer helper. Runs by itself every 5 minutes on the printer PC (set up once by helper-setup.ps1).
# Reads the Markoprint print log on this PC (read-only) and sends today's boxes WITH their real times to the app,
# so the app stays right even when the regular sender stops. Also sends yesterday once, in case it ended badly,
# and a short health note (the sender's last log lines) so problems can be seen from the app side.
$HelperVer = '2026-11-18.1'
$ErrorActionPreference = 'Stop'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }
$dir = if ($env:CHUSTER_MPDIR) { $env:CHUSTER_MPDIR } else { 'C:\ProgramData\MarkoprintLog' }
$me = Join-Path $env:LOCALAPPDATA 'Chuster'
$logf = Join-Path $me 'helper-log.txt'
$statef = Join-Path $me 'helper-state.txt'
try { New-Item -ItemType Directory -Force -Path $me | Out-Null } catch { }
function Log([string]$m) { try { if ((Test-Path $logf) -and (Get-Item $logf).Length -gt 512KB) { Move-Item $logf ($logf + '.old') -Force }; Add-Content -Path $logf -Value ((Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '  ' + $m) -Encoding UTF8 } catch { } }
function Tail([string]$p, [int]$n) { try { if (Test-Path $p) { return ((Get-Content -Path $p -Tail $n) -join "`n") } } catch { }; return '(none)' }
try {
  $cfg = Get-Content (Join-Path $dir 'config.json') -Raw -Encoding UTF8 | ConvertFrom-Json
  $csvFolder = if ($cfg.csvFolder) { [string]$cfg.csvFolder } else { $dir }
  $files = @(Get-ChildItem -Path $csvFolder -Filter 'prints-*.csv' | Sort-Object LastWriteTime -Descending | Select-Object -First 2 | Sort-Object LastWriteTime)
  $rows = @(); foreach ($f in $files) { $rows += @(Import-Csv -Path $f.FullName) }

  $task = ''
  try { $t = Get-ScheduledTask -TaskName 'Chuster Box-Print Pusher' -ErrorAction Stop; $i = $t | Get-ScheduledTaskInfo; $task = "sender task: $($t.State), last start $($i.LastRunTime), result $($i.LastTaskResult)" } catch { $task = 'sender task: cannot see it from this account' }
  $diag = ("helper $HelperVer on $env:COMPUTERNAME as $env:USERNAME | $task`n--- sender log ---`n" + (Tail (Join-Path $dir 'push-log.txt') 12) + "`n--- logger errors ---`n" + (Tail (Join-Path $dir 'errors.log') 6))
  if ($diag.Length -gt 3500) { $diag = $diag.Substring($diag.Length - 3500) }

  function DayBody([string]$day) {
    $labels = [ordered]@{}; $starts = @{}; $ends = @{}
    foreach ($r in $rows) {
      if ([string]$r.Date -ne $day) { continue }
      $lab = ([string]$r.Label).Trim(); if (-not $lab) { continue }
      $n = 0; [void][int]::TryParse(([string]$r.PrintsAdded), [ref]$n); if ($n -le 0) { continue }
      if ($labels.Contains($lab)) { $labels[$lab] += $n } else { $labels[$lab] = $n }
      $p = (([string]$r.Time) -replace '[^0-9:]', '') -split ':'
      if ($p.Count -ge 2 -and $p[0] -ne '' -and $p[1] -ne '') { $hm = ('{0:00}:{1:00}' -f [int]$p[0], [int]$p[1]); if (-not $starts.ContainsKey($lab)) { $starts[$lab] = $hm }; $ends[$lab] = $hm }
    }
    if (-not $labels.Count) { return $null }
    $order = @($labels.Keys); $times = [ordered]@{}
    foreach ($k in $order) { $times[$k] = @{ s = [string]$starts[$k]; e = [string]$ends[$k] } }
    return @{ day = $day; labels = $labels; order = $order; times = $times; now = $null }
  }
  function Send($b) { $b.diag = $diag; [void](Invoke-RestMethod -Uri ([string]$cfg.url) -Method Post -Body ($b | ConvertTo-Json -Depth 6 -Compress) -ContentType 'application/json' -Headers @{ 'x-print-secret' = [string]$cfg.secret } -TimeoutSec 30) }

  $today = Get-Date -Format 'yyyy-MM-dd'; $yday = (Get-Date).AddDays(-1).ToString('yyyy-MM-dd')
  $b = DayBody $today
  if ($b) { Send $b; Log ("sent today: " + $b.labels.Count + " products") } else { Send @{ }; Log 'nothing printed yet today; sent health note' }
  $done = ''; try { if (Test-Path $statef) { $done = (Get-Content $statef -Raw).Trim() } } catch { }
  if ($done -ne $yday) { $y = DayBody $yday; if ($y) { Send $y; Log 'sent yesterday' }; Set-Content -Path $statef -Value $yday -Encoding UTF8 }
} catch { Log ('problem: ' + $_.Exception.Message) }
