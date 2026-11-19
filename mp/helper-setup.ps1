# Chuster box printer helper - ONE-TIME setup on the printer PC. No admin needed.
#     irm https://chuster.netlify.app/mp/helper-setup.ps1 | iex
# Saves the helper in your own folder and has Windows run it quietly every 5 minutes while you're signed in.
# To remove it later:  Unregister-ScheduledTask -TaskName 'Chuster box printer helper' -Confirm:$false
& {
  $ErrorActionPreference = 'Stop'
  try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }
  try {
    $me = Join-Path $env:LOCALAPPDATA 'Chuster'
    New-Item -ItemType Directory -Force -Path $me | Out-Null
    $ps1 = Join-Path $me 'helper.ps1'; $vbs = Join-Path $me 'run-helper.vbs'
    $code = (New-Object Net.WebClient).DownloadString('https://chuster.netlify.app/mp/helper.ps1?t=' + [DateTime]::UtcNow.Ticks)
    if ($code -notmatch 'Chuster box printer helper') { throw 'Could not download the helper.' }
    Set-Content -Path $ps1 -Value $code -Encoding UTF8
    # a tiny starter so no window pops up every 5 minutes
    Set-Content -Path $vbs -Encoding ASCII -Value ('CreateObject("WScript.Shell").Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""' + $ps1 + '""", 0, False')
    $name = 'Chuster box printer helper'
    $act = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument ('"' + $vbs + '"')
    $trg = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 5)
    $trg2 = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
    $set = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 4)
    $who = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited
    Register-ScheduledTask -TaskName $name -Action $act -Trigger @($trg, $trg2) -Settings $set -Principal $who -Force | Out-Null
    # run it once now and show the result
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $ps1
    $last = ''; try { $last = (Get-Content (Join-Path $me 'helper-log.txt') -Tail 2) -join ' | ' } catch { }
    Write-Host ''
    if ($last -match 'problem') { Write-Host "Set up, but the first try had a problem: $last" -ForegroundColor Yellow }
    else { Write-Host "DONE - the box printer helper is set up and runs every 5 minutes. First run: $last" -ForegroundColor Green }
  } catch { Write-Host ('Could not set it up: ' + $_.Exception.Message) -ForegroundColor Red }
}
