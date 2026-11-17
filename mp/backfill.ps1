# Chuster box printer - re-send one day's boxes WITH packing order and start/finish times.
# Run from a normal PowerShell window on the printer PC (no admin needed):
#     irm https://chuster.netlify.app/mp/backfill.ps1 | iex
# Reads the Markoprint print log on this PC (read-only) and sends that day to the app. Default: today.
# For another day first run:  $env:CHUSTER_DAY='2026-11-16'
& {
  $ErrorActionPreference = 'Stop'
  try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }
  $dir = 'C:\ProgramData\MarkoprintLog'
  $day = if ($env:CHUSTER_DAY) { [string]$env:CHUSTER_DAY } else { Get-Date -Format 'yyyy-MM-dd' }
  try {
    $cfg = Get-Content (Join-Path $dir 'config.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $csvFolder = if ($cfg.csvFolder) { [string]$cfg.csvFolder } else { $dir }
    # the newest few log files, oldest first, so rows stay in the order they were printed
    $files = @(Get-ChildItem -Path $csvFolder -Filter 'prints-*.csv' | Sort-Object LastWriteTime -Descending | Select-Object -First 3 | Sort-Object LastWriteTime)
    if (-not $files.Count) { Write-Host "No print log found in $csvFolder" -ForegroundColor Red; return }

    $labels = [ordered]@{}; $starts = @{}; $ends = @{}
    foreach ($f in $files) {
      foreach ($r in @(Import-Csv -Path $f.FullName)) {
        if ([string]$r.Date -ne $day) { continue }
        $lab = ([string]$r.Label).Trim(); if (-not $lab) { continue }
        $n = 0; [void][int]::TryParse(([string]$r.PrintsAdded), [ref]$n)
        if ($n -le 0) { continue }
        if ($labels.Contains($lab)) { $labels[$lab] += $n } else { $labels[$lab] = $n }
        $p = (([string]$r.Time) -replace '[^0-9:]', '') -split ':'
        if ($p.Count -ge 2 -and $p[0] -ne '' -and $p[1] -ne '') {
          $hm = ('{0:00}:{1:00}' -f [int]$p[0], [int]$p[1])
          if (-not $starts.ContainsKey($lab)) { $starts[$lab] = $hm }; $ends[$lab] = $hm
        }
      }
    }
    if (-not $labels.Count) { Write-Host "Nothing printed on $day in the log." -ForegroundColor Yellow; return }

    $order = @($labels.Keys)
    $times = [ordered]@{}
    foreach ($k in $order) { $times[$k] = @{ s = [string]$starts[$k]; e = [string]$ends[$k] } }
    $body = (@{ day = $day; labels = $labels; order = $order; times = $times; now = $null } | ConvertTo-Json -Depth 6 -Compress)
    [void](Invoke-RestMethod -Uri ([string]$cfg.url) -Method Post -Body $body -ContentType 'application/json' -Headers @{ 'x-print-secret' = [string]$cfg.secret } -TimeoutSec 30)

    $sum = ($labels.Values | Measure-Object -Sum).Sum
    Write-Host ""
    Write-Host "DONE - sent $day : $($labels.Count) products, $sum boxes, with times:" -ForegroundColor Green
    $to12 = { param($t) if (-not $t) { return '' }; $h, $m = ([string]$t) -split ':'; $h = [int]$h; $ap = if ($h -ge 12) { 'PM' } else { 'AM' }; $h12 = $h % 12; if ($h12 -eq 0) { $h12 = 12 }; '{0}:{1} {2}' -f $h12, $m, $ap }
    foreach ($k in $order) { Write-Host ("   {0,-28} {1,5} boxes   {2,8} - {3}" -f $k, $labels[$k], (& $to12 $starts[$k]), (& $to12 $ends[$k])) }
  } catch {
    Write-Host ("Could not send: " + $_.Exception.Message) -ForegroundColor Red
  }
}
