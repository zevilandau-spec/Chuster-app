# Chuster QB Sync
# Reads QuickBooks Desktop (read only) and sends new invoices, credits, payments, open balances,
# customers and stock to the Chuster app's shared database. Everything is scrambled with the app's
# key before it leaves this computer. Runs every minute from Windows Task Scheduler (full QuickBooks read every 15 minutes).
# Works next to other QuickBooks programs (LetSync etc.).
# It only ADDS what the office approved in the app's "To QuickBooks" list (invoices, payments, credit memos).
# It never changes or deletes anything that is already in QuickBooks.
param([switch]$Install, [switch]$Test, [switch]$Full, [switch]$Other, [switch]$History, [switch]$Watch)

$ErrorActionPreference = 'Stop'
$Ver = '3.8'
$AppName = 'Chuster App Sync'
$TaskName = 'Chuster QB Sync'
$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
$CfgPath = Join-Path $Here 'config.json'
$StatePath = Join-Path $Here 'state.json'
$LogPath = Join-Path $Here 'sync-log.txt'
$LockPath = Join-Path $Here 'running.lock'
$Batch = 200
$script:Batch = 200
$script:Gentle = 0
$script:Touched = @{}
$Inv = [Globalization.CultureInfo]::InvariantCulture
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }
# Windows PowerShell 5.1 can write lists as {"value":[...],"Count":n}; this keeps them plain lists.
try { Remove-TypeData System.Array -ErrorAction SilentlyContinue } catch { }

function Log([string]$m) {
  $line = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '  ' + $m
  Write-Host $line
  try {
    if ((Test-Path $LogPath) -and (Get-Item $LogPath).Length -gt 1MB) { Move-Item $LogPath ($LogPath + '.old') -Force }
    Add-Content -Path $LogPath -Value $line -Encoding UTF8
  } catch { }
}

# ---------------- settings ----------------
if (-not (Test-Path $CfgPath)) { Copy-Item (Join-Path $Here 'config.start.json') $CfgPath }
$cfg = Get-Content $CfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
foreach ($n in 'url', 'company', 'from') { if (-not ($cfg.PSObject.Properties.Name -contains $n)) { $cfg | Add-Member -NotePropertyName $n -NotePropertyValue '' } }
if (-not ($cfg.PSObject.Properties.Name -contains 'keepDays')) { $cfg | Add-Member -NotePropertyName keepDays -NotePropertyValue 60 }
function Save-Cfg { ($cfg | ConvertTo-Json -Depth 4) | Set-Content -Path $CfgPath -Encoding UTF8 }
function Url { ([string]$cfg.url).Trim().TrimEnd('/') }

# ---------------- scrambling (AES-256-CBC + HMAC-SHA256, keys made from the app's key) ----------------
$KeyBytes = [Convert]::FromBase64String($cfg.key)
$hm = New-Object System.Security.Cryptography.HMACSHA256 -ArgumentList (, $KeyBytes)
$EncKey = $hm.ComputeHash([Text.Encoding]::UTF8.GetBytes('chuster-qb-enc'))
$MacKey = $hm.ComputeHash([Text.Encoding]::UTF8.GetBytes('chuster-qb-mac'))
function Protect([string]$json) {
  $aes = [System.Security.Cryptography.Aes]::Create()
  $aes.Mode = [System.Security.Cryptography.CipherMode]::CBC
  $aes.Padding = [System.Security.Cryptography.PaddingMode]::PKCS7
  $aes.Key = $EncKey; $aes.GenerateIV()
  $pt = [Text.Encoding]::UTF8.GetBytes($json)
  $ct = $aes.CreateEncryptor().TransformFinalBlock($pt, 0, $pt.Length)
  [byte[]]$ivct = [byte[]]$aes.IV + [byte[]]$ct
  $mac = (New-Object System.Security.Cryptography.HMACSHA256 -ArgumentList (, $MacKey)).ComputeHash($ivct)
  'c1.' + [Convert]::ToBase64String([byte[]]($ivct + $mac))
}
function Sha([string]$s) {
  $b = (New-Object System.Security.Cryptography.SHA1Managed).ComputeHash([Text.Encoding]::UTF8.GetBytes($s))
  -join ($b | ForEach-Object { $_.ToString('x2') })
}
function SafeId([string]$s) { $s -replace '[^A-Za-z0-9_-]', '_' }
function ToJson($o) { ConvertTo-Json -InputObject $o -Depth 10 -Compress }

# ---------------- QuickBooks ----------------
$script:QB = $null; $script:Ticket = $null
function QB-Open {
  if ($env:CHUSTER_QB_MOCK -or $script:Ticket) { return }
  $script:QB = New-Object -ComObject QBXMLRP2.RequestProcessor
  $script:QB.OpenConnection2('', $AppName, 1)
  $script:Ticket = $script:QB.BeginSession([string]$cfg.company, 2)
}
function QB-Close {
  if ($env:CHUSTER_QB_MOCK) { return }
  try { if ($script:Ticket) { $script:QB.EndSession($script:Ticket) } } catch { }
  try { if ($script:QB) { $script:QB.CloseConnection() } } catch { }
  try { if ($script:QB) { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($script:QB) } } catch { }
  $script:QB = $null; $script:Ticket = $null
}
function QB-Company {
  if ($env:CHUSTER_QB_MOCK) { return 'C:\mock\Chuster.QBW' }
  QB-Open; $script:QB.GetCurrentCompanyFileName($script:Ticket)
}
$script:MockN = @{}
function QB-Do([string]$name, [string]$body) {
  $xml = '<?xml version="1.0" encoding="utf-8"?><?qbxml version="13.0"?><QBXML><QBXMLMsgsRq onError="continueOnError">' + $body + '</QBXMLMsgsRq></QBXML>'
  if ($env:CHUSTER_QB_MOCK) {
    $script:MockN[$name] = 1 + [int]$script:MockN[$name]
    $f = Join-Path $env:CHUSTER_QB_MOCK ($name + '-' + $script:MockN[$name] + '.xml')
    if (-not (Test-Path $f)) { $f = Join-Path $env:CHUSTER_QB_MOCK ($name + '.xml') }
    Add-Content -Path (Join-Path $env:CHUSTER_QB_MOCK 'requests.log') -Value $body
    $txt = Get-Content $f -Raw -Encoding UTF8
    if ($txt.StartsWith('THROW:') -and $body.Contains('iterator=')) { throw $txt.Substring(6).Trim() }
    if ($txt.StartsWith('THROW:')) { $f2 = Join-Path $env:CHUSTER_QB_MOCK ($name + '.plain.xml'); $txt = Get-Content $f2 -Raw -Encoding UTF8 }
    return [xml]$txt
  }
  QB-Open
  [xml]$script:QB.ProcessRequest($script:Ticket, $xml)
}
function Rs($x, [string]$rsName) { $x.SelectSingleNode("//" + $rsName) }
function Check($rs, [string]$what) {
  if ($null -eq $rs) { throw "$what`: no answer from QuickBooks" }
  $code = $rs.GetAttribute('statusCode')
  if ($code -ne '0' -and $code -ne '1') { $pre = if ($what) { "$what`: " } else { '' }; throw ($pre + 'QuickBooks said: ' + $rs.GetAttribute('statusMessage') + " (code $code)") }
}
# Runs a query with an iterator so big lists come in pieces. Returns every <retName> node.
function QB-All([string]$rq, [string]$inner, [string]$ret) {
  $rsName = $rq -replace 'Rq$', 'Rs'
  $out = New-Object System.Collections.Generic.List[object]
  try { $x = QB-Do $rq "<$rq requestID=`"1`" iterator=`"Start`"><MaxReturned>$script:Batch</MaxReturned>$inner</$rq>" }
  catch {
    if ($_.Exception.Message -notmatch 'pars') { throw }
    try { $x = QB-Do $rq "<$rq requestID=`"1`">$inner</$rq>" } catch { throw "$rq`: " + $_.Exception.Message }
    $rs = Rs $x $rsName; Check $rs $rq
    foreach ($n in $rs.SelectNodes($ret)) { $out.Add($n) }
    return , $out
  }
  # what to include on every page (item lines, chosen fields, custom fields); the filters only go on the first page
  $keep = (([regex]::Matches($inner, '<(IncludeLineItems|IncludeLinkedTxns|IncludeRetElement|OwnerID)>[^<]*</\1>') | ForEach-Object { $_.Value }) -join '')
  $guard = 0
  while ($true) {
    $rs = Rs $x $rsName; Check $rs $rq
    foreach ($n in $rs.SelectNodes($ret)) { $out.Add($n) }
    $iter = $rs.GetAttribute('iteratorID'); $rem = $rs.GetAttribute('iteratorRemainingCount')
    try { (Get-Item $LockPath -ErrorAction Stop).LastWriteTime = Get-Date } catch { }
    if (-not $iter -or -not $rem -or [int]$rem -le 0) { break }
    $guard++; if ($guard -gt 2000) { break }
    if ($script:Gentle) { Start-Sleep -Milliseconds $script:Gentle }
    $x = QB-Do $rq "<$rq requestID=`"1`" iterator=`"Continue`" iteratorID=`"$iter`"><MaxReturned>$script:Batch</MaxReturned>$keep</$rq>"
    $rs2 = Rs $x $rsName
    if ($rs2 -and $rs2.GetAttribute('statusCode') -ne '0' -and $rs2.GetAttribute('statusCode') -ne '1') {
      $x = QB-Do $rq "<$rq requestID=`"1`" iterator=`"Continue`" iteratorID=`"$iter`"><MaxReturned>$script:Batch</MaxReturned>$inner</$rq>"
    }
  }
  , $out
}
function T($node, [string]$path) { $n = $node.SelectSingleNode($path); if ($n) { $n.InnerText } else { '' } }
function N($node, [string]$path) { $s = T $node $path; if ($s -eq '') { 0.0 } else { [double]::Parse($s, $Inv) } }
function Money([double]$v) { [Math]::Round($v, 2) }

function Lines($r, [string]$lineName, [string]$groupName, [int]$sign) {
  $L = New-Object System.Collections.Generic.List[object]
  $nodes = New-Object System.Collections.Generic.List[object]
  foreach ($n in $r.SelectNodes($lineName)) { $nodes.Add($n) }
  foreach ($g in $r.SelectNodes($groupName)) { foreach ($n in $g.SelectNodes($lineName)) { $nodes.Add($n) } }
  foreach ($n in $nodes) {
    $item = T $n 'ItemRef/FullName'
    if ($item -eq '') { continue }
    $q = N $n 'Quantity'; $a = N $n 'Amount'
    $L.Add([object[]]@($item, ($sign * $q), (Money ($sign * $a))))
  }
  , $L
}

# ---------------- shared database (Firebase REST) ----------------
function Db-Patch($updates) {
  $u = (Url) + '/' + $cfg.space + '.json'
  # tell the phones something changed (not for the minute-by-minute status or history pieces)
  $real = @($updates.Keys | Where-Object { $_ -ne 'qh/status' -and -not ([string]$_).StartsWith('hx/') }).Count
  if ($real -gt 0) { $updates['_t'] = @{ '.sv' = 'timestamp' } }
  $body = [Text.Encoding]::UTF8.GetBytes((ToJson $updates))
  Invoke-RestMethod -Method Patch -Uri $u -Body $body -ContentType 'application/json; charset=utf-8' -TimeoutSec 120 | Out-Null
}
function Db-Check {
  try { Invoke-RestMethod -Method Get -Uri ((Url) + '/' + $cfg.space + '/qh.json?shallow=true') -TimeoutSec 30 | Out-Null; $true }
  catch {
    $msg = $_.Exception.Message
    if ($msg -match '401|403|Permission|Unauthorized') { throw 'The shared database said no. Paste the rules from the app (Tools > Trucks & people > Shared database) into Firebase > Realtime Database > Rules and Publish.' }
    throw "Can't reach the shared database: $msg"
  }
}

# ---------------- app -> QuickBooks (only what the office approved) ----------------
function Unprotect([string]$v) {
  if (-not $v -or -not $v.StartsWith('c1.')) { return $null }
  try {
    $all = [Convert]::FromBase64String($v.Substring(3)); if ($all.Length -lt 64) { return $null }
    $body = New-Object byte[] ($all.Length - 32); [Array]::Copy($all, 0, $body, 0, $body.Length)
    $mac = New-Object byte[] 32; [Array]::Copy($all, $body.Length, $mac, 0, 32)
    $calc = (New-Object System.Security.Cryptography.HMACSHA256 -ArgumentList (, $MacKey)).ComputeHash($body)
    if ([Convert]::ToBase64String($calc) -ne [Convert]::ToBase64String($mac)) { return $null }
    $aes = [System.Security.Cryptography.Aes]::Create()
    $aes.Mode = [System.Security.Cryptography.CipherMode]::CBC; $aes.Padding = [System.Security.Cryptography.PaddingMode]::PKCS7; $aes.Key = $EncKey
    $iv = New-Object byte[] 16; [Array]::Copy($body, 0, $iv, 0, 16); $aes.IV = $iv
    $pt = $aes.CreateDecryptor().TransformFinalBlock($body, 16, $body.Length - 16)
    [Text.Encoding]::UTF8.GetString($pt) | ConvertFrom-Json
  } catch { $null }
}
function Db-Get([string]$path) { Invoke-RestMethod -Method Get -Uri ((Url) + '/' + $cfg.space + '/' + $path + '.json') -TimeoutSec 60 }
function NowS { (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss') }
function X([string]$s) { [Security.SecurityElement]::Escape($s) }
function Q($v) { ([Math]::Round([double]$v, 5)).ToString('0.#####', $Inv) }
function Put-Result([string]$id, $val) {
  Db-Patch ([ordered]@{ ('qr/r' + (Sha $id).Substring(0, 20)) = [ordered]@{ v = (Protect (ToJson ([ordered]@{ k = $id; val = $val; by = 'QuickBooks' }))); t = @{ '.sv' = 'timestamp' } } })
}
function Find-ByMemo([string]$kind, [string]$id) {
  $map = @{ inv = @('InvoiceQueryRq', 'InvoiceRet'); invmod = @('InvoiceQueryRq', 'InvoiceRet'); cm = @('CreditMemoQueryRq', 'CreditMemoRet'); pay = @('ReceivePaymentQueryRq', 'ReceivePaymentRet') }
  $p = $map[$kind]; if (-not $p) { return $null }
  $from = (Get-Date).AddDays(-3).ToString('yyyy-MM-ddTHH:mm:ss')
  foreach ($r in (QB-All $p[0] "<ModifiedDateRangeFilter><FromModifiedDate>$from</FromModifiedDate></ModifiedDateRangeFilter><IncludeRetElement>TxnID</IncludeRetElement><IncludeRetElement>RefNumber</IncludeRetElement><IncludeRetElement>Memo</IncludeRetElement>" $p[1])) {
    if ((T $r 'Memo').Contains("[app:$id]")) { return [ordered]@{ num = (T $r 'RefNumber'); txn = (T $r 'TxnID') } }
  }
  $null
}
# Two invoices with the same number (the app and the office at the same moment): give the app's invoice the next free number.
$script:DupAt = [datetime]::MinValue
function Inv-Count([string]$ref) {
  $r = Rs (QB-Do 'InvoiceQueryRq' ('<InvoiceQueryRq requestID="1"><RefNumber>' + (X $ref) + '</RefNumber><IncludeRetElement>TxnID</IncludeRetElement></InvoiceQueryRq>')) 'InvoiceQueryRs'
  if ($r -and $r.GetAttribute('statusCode') -eq '0') { $r.SelectNodes('InvoiceRet').Count } else { 0 }
}
function Fix-DupNumbers {
  if (((Get-Date) - $script:DupAt).TotalMinutes -lt 3) { return }
  $script:DupAt = Get-Date
  $from = (Get-Date).AddDays(-2).ToString('yyyy-MM-ddTHH:mm:ss')
  $recent = QB-All 'InvoiceQueryRq' "<ModifiedDateRangeFilter><FromModifiedDate>$from</FromModifiedDate></ModifiedDateRangeFilter><IncludeRetElement>TxnID</IncludeRetElement><IncludeRetElement>EditSequence</IncludeRetElement><IncludeRetElement>RefNumber</IncludeRetElement><IncludeRetElement>Memo</IncludeRetElement><IncludeRetElement>TimeCreated</IncludeRetElement><IncludeRetElement>Subtotal</IncludeRetElement><IncludeRetElement>SalesTaxTotal</IncludeRetElement>" 'InvoiceRet'
  $max = 0L; foreach ($r in $recent) { $n = T $r 'RefNumber'; if ($n -match '^\d{1,10}$' -and [long]$n -gt $max) { $max = [long]$n } }
  foreach ($r in $recent) {
    $memo = T $r 'Memo'; $ref = T $r 'RefNumber'
    $mm = [regex]::Match($memo, '\[app:([^\]]+)\]')
    if (-not $mm.Success -or -not ($ref -match '^\d+$')) { continue }
    $appId = $mm.Groups[1].Value
    # only invoices the app made (not an office invoice that was changed in the app): made after the app's request
    try {
      $b36 = $appId.Substring(0, $appId.Length - 5).ToLower(); $ms = 0L; foreach ($ch in $b36.ToCharArray()) { $ms = $ms * 36 + '0123456789abcdefghijklmnopqrstuvwxyz'.IndexOf($ch) }
      $asked = [DateTimeOffset]::FromUnixTimeMilliseconds($ms); $made = [DateTimeOffset]::Parse((T $r 'TimeCreated'), $Inv)
      if ($made -lt $asked.AddMinutes(-10)) { continue }
    } catch { continue }
    if ((Inv-Count $ref) -lt 2) { continue }
    $nx = [Math]::Max($max, [long]$ref)
    do { $nx++ } while ((Inv-Count ([string]$nx)) -gt 0)
    $x = QB-Do 'InvoiceModRq' ('<InvoiceModRq requestID="1"><InvoiceMod><TxnID>' + (T $r 'TxnID') + '</TxnID><EditSequence>' + (T $r 'EditSequence') + '</EditSequence><RefNumber>' + $nx + '</RefNumber></InvoiceMod></InvoiceModRq>')
    $rs = Rs $x 'InvoiceModRs'; Check $rs ''
    $max = $nx
    Log "Invoice #$ref was used twice (the app and the office). The app's invoice is now #$nx."
    try { Put-Result $appId ([ordered]@{ num = [string]$nx; txn = (T $r 'TxnID'); amt = (Money ((N $r 'Subtotal') + (N $r 'SalesTaxTotal'))); was = $ref }) } catch { }
  }
}
function Add-ToQB($o) {
  $memo = X ((([string]$o.memo).Trim() + ' [app:' + $o.id + ']').Trim())
  $cust = '<CustomerRef><FullName>' + (X ([string]$o.c)) + '</FullName></CustomerRef>'
  $date = if ($o.d) { '<TxnDate>' + (X ([string]$o.d)) + '</TxnDate>' } else { '' }
  if ($o.kind -eq 'inv' -or $o.kind -eq 'cm') {
    $tag = if ($o.kind -eq 'inv') { 'Invoice' } else { 'CreditMemo' }
    $lines = ''
    foreach ($l in @($o.lines)) {
      $rate = if ($null -ne $l[2] -and [double]$l[2] -gt 0) { '<Rate>' + (Q $l[2]) + '</Rate>' } else { '' }
      $lines += "<${tag}LineAdd><ItemRef><FullName>" + (X ([string]$l[0])) + '</FullName></ItemRef><Quantity>' + (Q $l[1]) + '</Quantity>' + $rate + "</${tag}LineAdd>"
    }
    if (-not $lines) { throw 'There are no items on it.' }
    $po = if ($o.po) { '<PONumber>' + (X ([string]$o.po)) + '</PONumber>' } else { '' }
    $refn = ''
    if ($o.kind -eq 'inv' -and $o.ref) {
      # the number the app picked: make sure QuickBooks doesn't have it already
      $chk = QB-Do 'InvoiceQueryRq' ('<InvoiceQueryRq requestID="1"><RefNumber>' + (X ([string]$o.ref)) + '</RefNumber><IncludeRetElement>TxnID</IncludeRetElement></InvoiceQueryRq>')
      $crs = Rs $chk 'InvoiceQueryRs'
      $useRef = [string]$o.ref
      if ($crs -and $crs.GetAttribute('statusCode') -eq '0' -and $crs.SelectNodes('InvoiceRet').Count) {
        if (-not $o.refAuto -or -not ($useRef -match '^\d+$')) { throw "Invoice number $($o.ref) is already used in QuickBooks. Change the number and try again." }
        # the app filled in the number and someone used it meanwhile (the old app, QuickBooks): take the next free one
        $nx = [long]$useRef; $free = $false
        for ($k = 0; $k -lt 50 -and -not $free; $k++) {
          $nx++
          $c2 = Rs (QB-Do 'InvoiceQueryRq' ('<InvoiceQueryRq requestID="1"><RefNumber>' + $nx + '</RefNumber><IncludeRetElement>TxnID</IncludeRetElement></InvoiceQueryRq>')) 'InvoiceQueryRs'
          if (-not ($c2 -and $c2.GetAttribute('statusCode') -eq '0' -and $c2.SelectNodes('InvoiceRet').Count)) { $free = $true }
        }
        if (-not $free) { throw "Invoice number $($o.ref) is already used in QuickBooks. Change the number and try again." }
        Log "Invoice number $useRef was taken meanwhile, used $nx instead."; $useRef = [string]$nx
      }
      $refn = '<RefNumber>' + (X $useRef) + '</RefNumber>'
    }
    $x = QB-Do "${tag}AddRq" "<${tag}AddRq requestID=`"1`"><${tag}Add>$cust$date$refn$po<Memo>$memo</Memo>$lines</${tag}Add></${tag}AddRq>"
    $rs = Rs $x "${tag}AddRs"; Check $rs ''
    $ret = $rs.SelectSingleNode("${tag}Ret")
    $amt = if ($tag -eq 'Invoice') { Money ((N $ret 'Subtotal') + (N $ret 'SalesTaxTotal')) } else { Money (N $ret 'TotalAmount') }
    return [ordered]@{ num = (T $ret 'RefNumber'); txn = (T $ret 'TxnID'); amt = $amt }
  }
  if ($o.kind -eq 'invmod') {
    # change an invoice that's already in QuickBooks: new amounts, items taken off, items added
    $x = QB-Do 'InvoiceQueryRq' ('<InvoiceQueryRq requestID="1"><RefNumber>' + (X ([string]$o.n)) + '</RefNumber><IncludeLineItems>true</IncludeLineItems></InvoiceQueryRq>')
    $rs = Rs $x 'InvoiceQueryRs'
    if ($rs -and $rs.GetAttribute('statusCode') -eq '1') { throw "Invoice #$($o.n) was not found in QuickBooks." }
    Check $rs 'InvoiceQueryRq'
    $invx = $null; foreach ($r in $rs.SelectNodes('InvoiceRet')) { if (-not $invx -or (T $r 'CustomerRef/FullName') -eq [string]$o.c) { $invx = $r } }
    if (-not $invx) { throw "Invoice #$($o.n) was not found in QuickBooks." }
    if ($invx.SelectNodes('InvoiceLineGroupRet').Count) { throw "Invoice #$($o.n) has group items. Change it in QuickBooks." }
    $want = [ordered]@{}; $rate = @{}
    foreach ($l in @($o.lines)) { if ($l -and $l[0]) { $want[[string]$l[0]] = [double]$l[1]; if ($null -ne $l[2] -and [double]$l[2] -gt 0) { $rate[[string]$l[0]] = [double]$l[2] } } }
    $mods = New-Object System.Collections.Generic.List[string]; $added = $false
    $newLines = ''
    foreach ($it in @($want.Keys)) {
      $found = $false
      foreach ($ln in $invx.SelectNodes('InvoiceLineRet')) { if ((T $ln 'ItemRef/FullName') -eq $it) { $found = $true; break } }
      if (-not $found -and $want[$it] -gt 0) { $r2 = if ($rate.ContainsKey($it)) { '<Rate>' + (Q $rate[$it]) + '</Rate>' } else { '' }; $newLines += '<InvoiceLineMod><TxnLineID>-1</TxnLineID><ItemRef><FullName>' + (X $it) + '</FullName></ItemRef><Quantity>' + (Q $want[$it]) + '</Quantity>' + $r2 + '</InvoiceLineMod>' }
    }
    foreach ($ln in $invx.SelectNodes('InvoiceLineRet')) {
      $id = T $ln 'TxnLineID'; $it = T $ln 'ItemRef/FullName'
      $isTotal = ($it -match '(?i)total') -or ($it -eq '')
      if ($isTotal -and -not $added) { $mods.Add($newLines); $added = $true }
      if (-not $isTotal -and $want.Contains($it)) {
        if ($want[$it] -le 0) { continue }   # taken off the invoice
        $mods.Add('<InvoiceLineMod><TxnLineID>' + $id + '</TxnLineID><Quantity>' + (Q $want[$it]) + '</Quantity></InvoiceLineMod>')
      } else { $mods.Add('<InvoiceLineMod><TxnLineID>' + $id + '</TxnLineID></InvoiceLineMod>') }
    }
    if (-not $added) { $mods.Add($newLines) }
    $memo2 = X (((T $invx 'Memo') + ' [app:' + $o.id + ']').Trim())
    $x = QB-Do 'InvoiceModRq' ('<InvoiceModRq requestID="1"><InvoiceMod><TxnID>' + (T $invx 'TxnID') + '</TxnID><EditSequence>' + (T $invx 'EditSequence') + '</EditSequence><Memo>' + $memo2 + '</Memo>' + ($mods -join '') + '</InvoiceMod></InvoiceModRq>')
    $rs = Rs $x 'InvoiceModRs'; Check $rs ''
    $ret = $rs.SelectSingleNode('InvoiceRet')
    return [ordered]@{ num = (T $ret 'RefNumber'); txn = (T $ret 'TxnID'); amt = (Money ((N $ret 'Subtotal') + (N $ret 'SalesTaxTotal'))) }
  }
  if ($o.kind -eq 'invvoid') {
    # cancel an invoice: void it (keeps the number, becomes $0)
    $x = QB-Do 'InvoiceQueryRq' ('<InvoiceQueryRq requestID="1"><RefNumber>' + (X ([string]$o.n)) + '</RefNumber><IncludeRetElement>TxnID</IncludeRetElement><IncludeRetElement>CustomerRef</IncludeRetElement><IncludeRetElement>RefNumber</IncludeRetElement></InvoiceQueryRq>')
    $rs = Rs $x 'InvoiceQueryRs'
    if ($rs -and $rs.GetAttribute('statusCode') -eq '1') { throw "Invoice #$($o.n) was not found in QuickBooks." }
    Check $rs 'InvoiceQueryRq'
    $invx = $null; foreach ($r in $rs.SelectNodes('InvoiceRet')) { if (-not $invx -or (T $r 'CustomerRef/FullName') -eq [string]$o.c) { $invx = $r } }
    if (-not $invx) { throw "Invoice #$($o.n) was not found in QuickBooks." }
    $x = QB-Do 'TxnVoidRq' ('<TxnVoidRq requestID="1"><TxnVoidType>Invoice</TxnVoidType><TxnID>' + (T $invx 'TxnID') + '</TxnID></TxnVoidRq>')
    $rs = Rs $x 'TxnVoidRs'; Check $rs ''
    return [ordered]@{ num = [string]$o.n; txn = (T $invx 'TxnID'); amt = 0 }
  }
  if ($o.kind -eq 'pay') {
    $total = '<TotalAmount>' + ([double]$o.amt).ToString('0.00', $Inv) + '</TotalAmount>'
    $ref = if ($o.ref) { '<RefNumber>' + (X ([string]$o.ref)) + '</RefNumber>' } else { '' }
    $apply = ''
    foreach ($a in @($o.apply)) { if ($a -and $a[0]) { $apply += '<AppliedToTxnAdd><TxnID>' + (X ([string]$a[0])) + '</TxnID><PaymentAmount>' + ([double]$a[1]).ToString('0.00', $Inv) + '</PaymentAmount></AppliedToTxnAdd>' } }
    if (-not $apply) { $apply = '<IsAutoApply>true</IsAutoApply>' }
    foreach ($withMethod in @($true, $false)) {
      $pm = if ($withMethod -and $o.method) { '<PaymentMethodRef><FullName>' + (X ([string]$o.method)) + '</FullName></PaymentMethodRef>' } else { '' }
      $m2 = if (-not $withMethod -and $o.method) { X ((([string]$o.memo).Trim() + ' ' + [string]$o.method + ' [app:' + $o.id + ']').Trim()) } else { $memo }
      $x = QB-Do 'ReceivePaymentAddRq' "<ReceivePaymentAddRq requestID=`"1`"><ReceivePaymentAdd>$cust$date$ref$total$pm<Memo>$m2</Memo>$apply</ReceivePaymentAdd></ReceivePaymentAddRq>"
      $rs = Rs $x 'ReceivePaymentAddRs'
      if ($withMethod -and $o.method -and $rs -and $rs.GetAttribute('statusCode') -eq '3140' -and $rs.GetAttribute('statusMessage') -match 'PaymentMethod') { Log "Payment method '$($o.method)' is not in QuickBooks, sending without it"; continue }
      Check $rs ''; $ret = $rs.SelectSingleNode('ReceivePaymentRet')
      return [ordered]@{ num = (T $ret 'RefNumber'); txn = (T $ret 'TxnID'); amt = (Money (N $ret 'TotalAmount')); unused = (Money (N $ret 'UnusedPayment')) }
    }
  }
  throw "Unknown kind: $($o.kind)"
}
# Makes every approved item that isn't in QuickBooks yet. Only downloads what changed since last time.
function Process-Queue($st, [bool]$upload) {
  $made = 0
  if (-not ((Url) -match '^https?://')) { return 0 }
  $since = [double]$st.qwT
  $w = Invoke-RestMethod -Method Get -Uri ((Url) + '/' + $cfg.space + '/qw.json?orderBy=%22t%22&startAt=' + $since.ToString('0', $Inv)) -TimeoutSec 60
  if ($w) {
    foreach ($p in $w.PSObject.Properties) {
      $t = [double]$p.Value.t; if ($t -gt [double]$st.qwT) { $st.qwT = $t }
      $rec = Unprotect ([string]$p.Value.v); if (-not $rec -or -not $rec.val -or -not $rec.val.id) { continue }
      $o = $rec.val; $id = [string]$o.id
      if ($st.done.ContainsKey($id)) { continue }
      if ($o.st -eq 'ok') { $st.pending[$id] = $o } else { $st.pending.Remove($id) }
    }
  }
  foreach ($id in @($st.pending.Keys)) {
    $o = $st.pending[$id]; $try = [int]$o.try; $tk = "$id#$try"
    if ($st.failed.ContainsKey($tk)) { $st.pending.Remove($id); continue }
    if ($st.sending.ContainsKey($tk)) {
      $f = Find-ByMemo ([string]$o.kind) $id
      if ($f) { if ($upload) { $f['st'] = 'done'; $f['try'] = $try; $f['at'] = (NowS); Put-Result $id $f }; $st.done[$id] = (NowS); $st.pending.Remove($id); $st.sending.Remove($tk); continue }
    }
    if (-not $upload) { Log "Would make $($o.kind) for $($o.c) (test only)"; continue }
    $st.sending[$tk] = 1; Save-State $st
    Put-Result $id ([ordered]@{ st = 'sending'; try = $try; at = (NowS) })
    try {
      $out = Add-ToQB $o; $out['st'] = 'done'; $out['try'] = $try; $out['at'] = (NowS)
      $st.done[$id] = (NowS); $st.pending.Remove($id); $st.sending.Remove($tk); Save-State $st
      Put-Result $id $out; $made++; Log "Made $($o.kind) #$($out.num) for $($o.c)"
    } catch {
      $msg = $_.Exception.Message
      $st.failed[$tk] = 1; $st.pending.Remove($id); $st.sending.Remove($tk); Save-State $st
      Put-Result $id ([ordered]@{ st = 'error'; try = $try; err = $msg; at = (NowS) }); Log "Could not make $($o.kind) for $($o.c): $msg"
    }
  }
  # once a day: clear finished items older than 30 days from the shared database
  $today = (Get-Date).ToString('yyyy-MM-dd')
  if ($upload -and $st.pruned -ne $today) {
    try {
      $cut = ([DateTimeOffset](Get-Date).AddDays(-30)).ToUnixTimeMilliseconds()
      $old = Invoke-RestMethod -Method Get -Uri ((Url) + '/' + $cfg.space + '/qw.json?orderBy=%22t%22&endAt=' + $cut) -TimeoutSec 60
      $del = [ordered]@{}
      if ($old) { foreach ($p in $old.PSObject.Properties) { $rec = Unprotect ([string]$p.Value.v); $del['qw/' + $p.Name] = $null; if ($rec -and $rec.val -and $rec.val.id) { $del['qr/r' + (Sha ([string]$rec.val.id)).Substring(0, 20)] = $null; $st.done.Remove([string]$rec.val.id) } } }
      if ($del.Count) { Db-Patch $del }
      foreach ($k in @($st.failed.Keys)) { if ($st.failed.Count -gt 500) { $st.failed.Remove($k) } }
      $st.pruned = $today
    } catch { }
  }
  $made
}

# ---------------- state ----------------
function Load-State {
  $s = @{ last = ''; full = ''; qwT = 0; pruned = ''; sent = @{}; dates = @{}; parts = @{}; pending = @{}; done = @{}; sending = @{}; failed = @{} }
  if ((Test-Path $StatePath) -and -not $Full) {
    try {
      $j = Get-Content $StatePath -Raw -Encoding UTF8 | ConvertFrom-Json
      $s.last = [string]$j.last; $s.full = [string]$j.full; $s.qwT = [double]$j.qwT; $s.pruned = [string]$j.pruned
      foreach ($k in 'sent', 'dates', 'parts', 'pending', 'done', 'sending', 'failed') { if ($j.$k) { foreach ($p in $j.$k.PSObject.Properties) { $s[$k][$p.Name] = $p.Value } } }
    } catch { Log "Starting fresh (could not read state.json)" }
  }
  $s
}
function Save-State($s) { (ToJson $s) | Set-Content -Path $StatePath -Encoding UTF8 }

# ---------------- one sync ----------------
function Sync-Once([bool]$upload) {
  $st = Load-State
  $started = Get-Date
  $first = -not $st.last
  $from = if ($cfg.from) { [string]$cfg.from } else { $started.AddDays(-7).ToString('yyyy-MM-dd') }
  $since = if ($first) { '' } else { ([datetime]::Parse($st.last, $Inv)).AddMinutes(-15).ToString('yyyy-MM-ddTHH:mm:ss') }
  $recs = @{}   # id -> @(coll, key, val)
  $count = [ordered]@{ made = 0; invoices = 0; credits = 0; deleted = 0; payments = 0; customers = 0; open = 0; items = 0 }

  try {
    if (-not $cfg.company -and -not $env:CHUSTER_QB_MOCK) { try { $cfg.company = QB-Company; Save-Cfg } catch { } }
    # first: what the office approved in the app
    $made = 0
    try { $made = Process-Queue $st $upload; if ($upload) { Save-State $st } } catch { Log ('To QuickBooks list: ' + $_.Exception.Message) }
    if ($upload) { try { Fix-DupNumbers } catch { Log ('Same-number check: ' + $_.Exception.Message) } }
    $count['made'] = $made
    $mins = if ($st.full) { ($started - [datetime]::Parse($st.full, $Inv)).TotalMinutes } else { 999 }
    if (-not $first -and -not $Full -and -not $script:ForceRead -and $made -eq 0 -and $mins -lt 14) {
      if ($upload) { $status = [ordered]@{ at = $started.ToString('yyyy-MM-ddTHH:mm:ss'); full = $st.full; ok = $true; ver = $Ver; from = $from; pc = $env:COMPUTERNAME; counts = $count; mail = (Mail-Probe) }
        Db-Patch ([ordered]@{ 'qh/status' = [ordered]@{ v = (Protect (ToJson ([ordered]@{ k = 'status'; val = $status; by = 'QuickBooks' }))); t = @{ '.sv' = 'timestamp' } } }) }
      Log ('Checked the To QuickBooks list: nothing new. Next full QuickBooks read in ' + [Math]::Ceiling(14 - $mins) + ' min.')
      return
    }
    $txnFilter = if ($first) { "<TxnDateRangeFilter><FromTxnDate>$from</FromTxnDate></TxnDateRangeFilter>" } else { "<ModifiedDateRangeFilter><FromModifiedDate>$since</FromModifiedDate></ModifiedDateRangeFilter>" }

    # invoices with their lines
    foreach ($r in (QB-All 'InvoiceQueryRq' ($txnFilter + '<IncludeLineItems>true</IncludeLineItems>') 'InvoiceRet')) {
      $d = T $r 'TxnDate'; if ($d -lt $from) { continue }
      $id = 'i' + (SafeId (T $r 'TxnID'))
      $val = [ordered]@{ d = $d; n = (T $r 'RefNumber'); c = (T $r 'CustomerRef/FullName'); t = 'inv'; a = (Money ((N $r 'Subtotal') + (N $r 'SalesTaxTotal'))); due = (T $r 'DueDate'); l = (Lines $r 'InvoiceLineRet' 'InvoiceLineGroupRet' 1) }
      $recs[$id] = @('qi', $id, $val); $st.dates[$id] = $d; $count.invoices++
    }
    # credit memos
    foreach ($r in (QB-All 'CreditMemoQueryRq' ($txnFilter + '<IncludeLineItems>true</IncludeLineItems>') 'CreditMemoRet')) {
      $d = T $r 'TxnDate'; if ($d -lt $from) { continue }
      $id = 'm' + (SafeId (T $r 'TxnID'))
      $val = [ordered]@{ d = $d; n = (T $r 'RefNumber'); c = (T $r 'CustomerRef/FullName'); t = 'cm'; a = (Money (-(N $r 'TotalAmount'))); l = (Lines $r 'CreditMemoLineRet' 'CreditMemoLineGroupRet' -1) }
      $recs[$id] = @('qi', $id, $val); $st.dates[$id] = $d; $count.credits++
    }
    # payments
    foreach ($r in (QB-All 'ReceivePaymentQueryRq' ($txnFilter + '<IncludeRetElement>TxnID</IncludeRetElement><IncludeRetElement>TxnDate</IncludeRetElement><IncludeRetElement>CustomerRef</IncludeRetElement><IncludeRetElement>RefNumber</IncludeRetElement><IncludeRetElement>TotalAmount</IncludeRetElement><IncludeRetElement>PaymentMethodRef</IncludeRetElement>') 'ReceivePaymentRet')) {
      $d = T $r 'TxnDate'; if ($d -lt $from) { continue }
      $id = 'p' + (SafeId (T $r 'TxnID'))
      $val = [ordered]@{ d = $d; c = (T $r 'CustomerRef/FullName'); a = (Money (N $r 'TotalAmount')); n = (T $r 'RefNumber'); m = (T $r 'PaymentMethodRef/FullName') }
      $recs[$id] = @('qp', $id, $val); $st.dates[$id] = $d; $count.payments++
    }
    # deleted invoices, credits and payments
    if (-not $first) {
      $x = QB-Do 'TxnDeletedQueryRq' "<TxnDeletedQueryRq requestID=`"1`"><TxnDelType>Invoice</TxnDelType><TxnDelType>CreditMemo</TxnDelType><TxnDelType>ReceivePayment</TxnDelType><DeletedDateRangeFilter><FromDeletedDate>$since</FromDeletedDate></DeletedDateRangeFilter></TxnDeletedQueryRq>"
      $rs = Rs $x 'TxnDeletedQueryRs'; Check $rs 'TxnDeletedQueryRq'
      foreach ($r in $rs.SelectNodes('TxnDeletedRet')) {
        $type = T $r 'TxnDelType'; $pre = if ($type -eq 'Invoice') { 'i' } elseif ($type -eq 'CreditMemo') { 'm' } else { 'p' }
        $id = $pre + (SafeId (T $r 'TxnID')); $coll = if ($pre -eq 'p') { 'qp' } else { 'qi' }
        $recs[$id] = @($coll, $id, $null); $count.deleted++
      }
    }
    # customers: balance, active, phone (every run, only changes are sent)
    foreach ($r in (QB-All 'CustomerQueryRq' '<ActiveStatus>All</ActiveStatus><IncludeRetElement>ListID</IncludeRetElement><IncludeRetElement>FullName</IncludeRetElement><IncludeRetElement>Sublevel</IncludeRetElement><IncludeRetElement>IsActive</IncludeRetElement><IncludeRetElement>TotalBalance</IncludeRetElement><IncludeRetElement>Phone</IncludeRetElement>' 'CustomerRet')) {
      if ((T $r 'Sublevel') -ne '' -and (T $r 'Sublevel') -ne '0') { continue }
      $name = T $r 'FullName'; $id = 'c' + (SafeId (T $r 'ListID'))
      $val = [ordered]@{ c = $name; b = (Money (N $r 'TotalBalance')); on = ((T $r 'IsActive') -ne 'false'); ph = (T $r 'Phone') }
      $recs[$id] = @('qc', $name, $val); $count.customers++
    }
    # open invoices, grouped by customer (for who owes and how late)
    $open = @{}
    foreach ($r in (QB-All 'InvoiceQueryRq' '<PaidStatus>NotPaidOnly</PaidStatus><IncludeRetElement>TxnID</IncludeRetElement><IncludeRetElement>RefNumber</IncludeRetElement><IncludeRetElement>CustomerRef</IncludeRetElement><IncludeRetElement>TxnDate</IncludeRetElement><IncludeRetElement>DueDate</IncludeRetElement><IncludeRetElement>BalanceRemaining</IncludeRetElement>' 'InvoiceRet')) {
      $c = T $r 'CustomerRef/FullName'; if ($c -match ':') { $c = $c.Split(':')[0] }
      if (-not $open.ContainsKey($c)) { $open[$c] = New-Object System.Collections.Generic.List[object] }
      $open[$c].Add([object[]]@((T $r 'TxnDate'), (T $r 'RefNumber'), (Money (N $r 'BalanceRemaining')), (T $r 'DueDate'), (T $r 'TxnID'))); $count.open++
    }
    $names = @($open.Keys) + @($st.parts.Keys | Where-Object { -not $open.ContainsKey($_) })
    foreach ($c in ($names | Select-Object -Unique)) {
      $all = @(if ($open.ContainsKey($c)) { $open[$c].ToArray() } else { @() })
      $per = 110; $parts = [Math]::Max(1, [Math]::Ceiling($all.Count / $per))
      $old = [int]$st.parts[$c]
      for ($p = 0; $p -lt [Math]::Max($parts, $old); $p++) {
        $id = 'o' + (Sha $c).Substring(0, 16) + '_' + $p
        if ($p -lt $parts) {
          $chunk = New-Object System.Collections.Generic.List[object]
          for ($i = $p * $per; $i -lt [Math]::Min($all.Count, ($p + 1) * $per); $i++) { $chunk.Add($all[$i]) }
          $recs[$id] = @('qo', ($c + '#' + $p), [ordered]@{ c = $c; p = $p; of = $parts; o = $chunk })
        } else { $recs[$id] = @('qo', ($c + '#' + $p), $null) }
      }
      if ($all.Count) { $st.parts[$c] = $parts } else { $st.parts.Remove($c) }
    }
    # stock on hand
    $itemInner = '<ActiveStatus>All</ActiveStatus><IncludeRetElement>ListID</IncludeRetElement><IncludeRetElement>FullName</IncludeRetElement><IncludeRetElement>IsActive</IncludeRetElement><IncludeRetElement>QuantityOnHand</IncludeRetElement><IncludeRetElement>QuantityOnOrder</IncludeRetElement><IncludeRetElement>QuantityOnSalesOrder</IncludeRetElement><IncludeRetElement>SalesDesc</IncludeRetElement><IncludeRetElement>PurchaseDesc</IncludeRetElement><IncludeRetElement>UnitOfMeasureSetRef</IncludeRetElement><IncludeRetElement>DataExtRet</IncludeRetElement><OwnerID>0</OwnerID>'
    foreach ($pair in @(@('ItemInventoryQueryRq', 'ItemInventoryRet'), @('ItemInventoryAssemblyQueryRq', 'ItemInventoryAssemblyRet'))) {
      foreach ($r in (QB-All $pair[0] $itemInner $pair[1])) {
        $name = T $r 'FullName'; $id = 's' + (SafeId (T $r 'ListID'))
        $val = [ordered]@{ f = $name; q = (N $r 'QuantityOnHand'); oo = (N $r 'QuantityOnOrder'); so = (N $r 'QuantityOnSalesOrder'); on = ((T $r 'IsActive') -ne 'false') }
        # case size and other details the office keeps on the item (custom fields, unit of measure, descriptions)
        $ext = @(); foreach ($d in $r.SelectNodes('DataExtRet')) { $ext += ((T $d 'DataExtName') + '=' + (T $d 'DataExtValue')) }
        if ($ext.Count) { $val['x'] = ($ext -join '; ') }
        $u = T $r 'UnitOfMeasureSetRef/FullName'; if ($u) { $val['u'] = $u }
        $pd = T $r 'PurchaseDesc'; if ($pd) { $val['pd'] = $pd }
        $sd = T $r 'SalesDesc'; if ($sd) { $val['sd'] = $sd }
        $recs[$id] = @('qs', $name, $val); $count.items++
      }
    }
  } finally { QB-Close }

  # drop old invoices and payments from the shared database
  $cut = $started.AddDays(-[int]$cfg.keepDays).ToString('yyyy-MM-dd')
  $prune = @($st.dates.Keys | Where-Object { $st.dates[$_] -lt $cut })

  # send only what changed
  $updates = [ordered]@{}; $sentNow = @{}
  foreach ($id in $recs.Keys) {
    $r = $recs[$id]; $plain = ToJson ([ordered]@{ k = $r[1]; val = $r[2]; by = 'QuickBooks' })
    $h = Sha $plain
    if ($st.sent[$id] -eq $h) { continue }
    if ($null -eq $r[2] -and -not $st.sent.ContainsKey($id)) { continue }
    $updates[$r[0] + '/' + $id] = [ordered]@{ v = (Protect $plain); t = @{ '.sv' = 'timestamp' } }
    $sentNow[$id] = $h
  }
  foreach ($id in $prune) { $coll = if ($id.StartsWith('p')) { 'qp' } else { 'qi' }; $updates[$coll + '/' + $id] = $null }
  $summary = ($count.GetEnumerator() | ForEach-Object { "$($_.Value) $($_.Key)" }) -join ', '
  Log ("Read from QuickBooks: $summary. Changed: " + $sentNow.Count + ", old removed: " + $prune.Count)
  if (-not $upload) { Log 'Test only, nothing was sent.'; return }

  $keys = @($updates.Keys); $i = 0
  while ($i -lt $keys.Count) {
    $part = [ordered]@{}; foreach ($k in $keys[$i..([Math]::Min($keys.Count, $i + $Batch) - 1)]) { $part[$k] = $updates[$k] }
    Db-Patch $part; $i += $Batch
  }
  foreach ($id in $sentNow.Keys) { if ($null -eq $recs[$id][2]) { $st.sent.Remove($id) } else { $st.sent[$id] = $sentNow[$id] } }
  foreach ($id in $prune) { $st.sent.Remove($id); $st.dates.Remove($id) }
  foreach ($id in @($st.dates.Keys)) { if ($recs.ContainsKey($id) -and $null -eq $recs[$id][2]) { $st.dates.Remove($id) } }
  $st.last = $started.ToString('yyyy-MM-ddTHH:mm:ss'); $st.full = $st.last
  Save-State $st
  $status = [ordered]@{ at = $started.ToString('yyyy-MM-ddTHH:mm:ss'); full = $started.ToString('yyyy-MM-ddTHH:mm:ss'); ok = $true; ver = $Ver; from = $from; pc = $env:COMPUTERNAME; counts = $count; mail = (Mail-Probe) }
  Db-Patch ([ordered]@{ 'qh/status' = [ordered]@{ v = (Protect (ToJson ([ordered]@{ k = 'status'; val = $status; by = 'QuickBooks' }))); t = @{ '.sv' = 'timestamp' } } })
  Log ('Sent ' + $sentNow.Count + ' changes to the app.')
}

function Report-Error([string]$msg) {
  try {
    if ((Url) -match '^https?://') {
      $status = [ordered]@{ at = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss'); ok = $false; err = $msg; ver = $Ver; pc = $env:COMPUTERNAME }
      Db-Patch ([ordered]@{ 'qh/status' = [ordered]@{ v = (Protect (ToJson ([ordered]@{ k = 'status'; val = $status; by = 'QuickBooks' }))); t = @{ '.sv' = 'timestamp' } } })
    }
  } catch { }
}

# Some PCs only have the 32-bit (or only the 64-bit) QuickBooks connector. Try the other PowerShell once.
function Try-OtherBitness {
  if ($Other -or $env:CHUSTER_QB_MOCK) { return $false }
  $root = $env:SystemRoot
  $ps = if ([Environment]::Is64BitProcess) { "$root\SysWOW64\WindowsPowerShell\v1.0\powershell.exe" } else { "$root\Sysnative\WindowsPowerShell\v1.0\powershell.exe" }
  if (-not (Test-Path $ps)) { return $false }
  $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath, '-Other')
  if ($Install) { $a += '-Install' }; if ($Test) { $a += '-Test' }; if ($Full) { $a += '-Full' }; if ($History) { $a += '-History' }; if ($Watch) { $a += '-Watch' }
  Log 'Trying the other QuickBooks connector...'
  & $ps @a; $true
}

# ---------------- full history for the app (every night, from 2020) ----------------
# Reads everything the app is built from, sends it scrambled to the shared database; GitHub rebuilds the app from it.
$HistDir = Join-Path $Here 'history'
function ProtectBytes([byte[]]$pt) {
  $aes = [System.Security.Cryptography.Aes]::Create()
  $aes.Mode = [System.Security.Cryptography.CipherMode]::CBC; $aes.Padding = [System.Security.Cryptography.PaddingMode]::PKCS7
  $aes.Key = $EncKey; $aes.GenerateIV()
  $ct = $aes.CreateEncryptor().TransformFinalBlock($pt, 0, $pt.Length)
  [byte[]]$ivct = [byte[]]$aes.IV + [byte[]]$ct
  $mac = (New-Object System.Security.Cryptography.HMACSHA256 -ArgumentList (, $MacKey)).ComputeHash($ivct)
  'c1.' + [Convert]::ToBase64String([byte[]]($ivct + $mac))
}
function GzipText([string]$s) {
  $ms = New-Object System.IO.MemoryStream
  $gz = New-Object System.IO.Compression.GZipStream($ms, [System.IO.Compression.CompressionMode]::Compress)
  $b = [Text.Encoding]::UTF8.GetBytes($s); $gz.Write($b, 0, $b.Length); $gz.Close(); $ms.ToArray()
}
function Addr($node, [string]$path) {
  $a = $node.SelectSingleNode($path)
  if (-not $a) { return [ordered]@{ a = @() } }
  $L = New-Object System.Collections.Generic.List[object]
  foreach ($k in 'Addr1', 'Addr2', 'Addr3', 'Addr4', 'Addr5') { $v = T $a $k; if ($v) { $L.Add($v) } }
  [ordered]@{ a = $L; city = (T $a 'City'); state = (T $a 'State'); zip = (T $a 'PostalCode') }
}
function CountOf($x) { if ($null -eq $x) { 0 } elseif ($x -is [System.Collections.ICollection]) { $x.Count } else { 1 } }
function NN($node, [string]$path) { $s = T $node $path; if ($s -eq '') { $null } else { [double]::Parse($s, $Inv) } }
function TLines($r, [string]$ln, [string]$gn, [bool]$withCost, [int]$sign) {
  $L = New-Object System.Collections.Generic.List[object]
  $nodes = New-Object System.Collections.Generic.List[object]
  foreach ($n in $r.SelectNodes($ln)) { $nodes.Add($n) }
  foreach ($g in $r.SelectNodes($gn)) { foreach ($n in $g.SelectNodes($ln)) { $nodes.Add($n) } }
  foreach ($n in $nodes) {
    $item = T $n 'ItemRef/FullName'; if (-not $item) { continue }
    if ($withCost) { $L.Add([object[]]@($item, (T $n 'Desc'), ($sign * (N $n 'Quantity')), (N $n 'Cost'), (Money ($sign * (N $n 'Amount'))))) }
    else { $L.Add([object[]]@($item, (T $n 'Desc'), (N $n 'Quantity'), (Money (N $n 'Amount')))) }
  }
  , $L
}
# Every kind of QuickBooks transaction the app keeps, read gently: one month at a time, 50 at a time,
# saved on this PC month by month (history\cache), then only what changed on later nights.
$Kinds = @(
  @{ k = 'inv'; rq = 'InvoiceQueryRq'; ret = 'InvoiceRet'; del = 'Invoice'; lines = $true },
  @{ k = 'cm'; rq = 'CreditMemoQueryRq'; ret = 'CreditMemoRet'; del = 'CreditMemo'; lines = $true },
  @{ k = 'sr'; rq = 'SalesReceiptQueryRq'; ret = 'SalesReceiptRet'; del = 'SalesReceipt'; lines = $true },
  @{ k = 'pay'; rq = 'ReceivePaymentQueryRq'; ret = 'ReceivePaymentRet'; del = 'ReceivePayment'; lines = $false },
  @{ k = 'bill'; rq = 'BillQueryRq'; ret = 'BillRet'; del = 'Bill'; lines = $true; t = 'Bill'; who = 'VendorRef'; sign = 1 },
  @{ k = 'ir'; rq = 'ItemReceiptQueryRq'; ret = 'ItemReceiptRet'; del = 'ItemReceipt'; lines = $true; t = 'Item Receipt'; who = 'VendorRef'; sign = 1 },
  @{ k = 'chk'; rq = 'CheckQueryRq'; ret = 'CheckRet'; del = 'Check'; lines = $true; t = 'Check'; who = 'PayeeEntityRef'; sign = 1 },
  @{ k = 'ccc'; rq = 'CreditCardChargeQueryRq'; ret = 'CreditCardChargeRet'; del = 'CreditCardCharge'; lines = $true; t = 'Credit Card Charge'; who = 'PayeeEntityRef'; sign = 1 },
  @{ k = 'vc'; rq = 'VendorCreditQueryRq'; ret = 'VendorCreditRet'; del = 'VendorCredit'; lines = $true; t = 'Credit'; who = 'VendorRef'; sign = -1 },
  @{ k = 'dep'; rq = 'DepositQueryRq'; ret = 'DepositRet'; del = 'Deposit'; lines = $true },
  @{ k = 'je'; rq = 'JournalEntryQueryRq'; ret = 'JournalEntryRet'; del = 'JournalEntry'; lines = $true },
  @{ k = 'bpc'; rq = 'BillPaymentCheckQueryRq'; ret = 'BillPaymentCheckRet'; del = 'BillPaymentCheck'; lines = $false; t = 'Check'; acct = 'BankAccountRef' },
  @{ k = 'bpcc'; rq = 'BillPaymentCreditCardQueryRq'; ret = 'BillPaymentCreditCardRet'; del = 'BillPaymentCreditCard'; lines = $false; t = 'Credit card'; acct = 'CreditCardAccountRef' },
  @{ k = 'so'; rq = 'SalesOrderQueryRq'; ret = 'SalesOrderRet'; del = 'SalesOrder'; lines = $true; ln = 'SalesOrderLineRet'; gn = 'SalesOrderLineGroupRet' },
  @{ k = 'est'; rq = 'EstimateQueryRq'; ret = 'EstimateRet'; del = 'Estimate'; lines = $true; ln = 'EstimateLineRet'; gn = 'EstimateLineGroupRet' },
  @{ k = 'adj'; rq = 'InventoryAdjustmentQueryRq'; ret = 'InventoryAdjustmentRet'; del = 'InventoryAdjustment'; lines = $true },
  @{ k = 'build'; rq = 'BuildAssemblyQueryRq'; ret = 'BuildAssemblyRet'; del = 'BuildAssembly'; lines = $false },
  @{ k = 'poall'; rq = 'PurchaseOrderQueryRq'; ret = 'PurchaseOrderRet'; del = 'PurchaseOrder'; lines = $true }
)
# what goes into the app for each kind (the same shapes the app was built with)
function Make-Recs($K, $r) {
  $id = T $r 'TxnID'; $d = T $r 'TxnDate'; $out = New-Object System.Collections.Generic.List[object]
  switch ($K.k) {
    'inv' { $out.Add(@('inv', [ordered]@{ d = $d; n = (T $r 'RefNumber'); c = (T $r 'CustomerRef/FullName'); sub = (N $r 'Subtotal'); tax = (N $r 'SalesTaxTotal'); bal = (N $r 'BalanceRemaining'); due = (T $r 'DueDate'); memo = (T $r 'Memo'); terms = (T $r 'TermsRef/FullName'); l = (TLines $r 'InvoiceLineRet' 'InvoiceLineGroupRet' $false 1) })) }
    'cm' { $out.Add(@('cm', [ordered]@{ d = $d; n = (T $r 'RefNumber'); c = (T $r 'CustomerRef/FullName'); tot = (N $r 'TotalAmount'); rem = (N $r 'CreditRemaining'); memo = (T $r 'Memo'); l = (TLines $r 'CreditMemoLineRet' 'CreditMemoLineGroupRet' $false 1) })) }
    'sr' { $out.Add(@('sr', [ordered]@{ d = $d; n = (T $r 'RefNumber'); c = (T $r 'CustomerRef/FullName'); tot = (N $r 'TotalAmount'); memo = (T $r 'Memo'); l = (TLines $r 'SalesReceiptLineRet' 'SalesReceiptLineGroupRet' $false 1) })) }
    'pay' { $out.Add(@('pay', [ordered]@{ d = $d; n = (T $r 'RefNumber'); c = (T $r 'CustomerRef/FullName'); amt = (N $r 'TotalAmount'); unused = (N $r 'UnusedPayment'); memo = (T $r 'Memo') })) }
    { $_ -in 'bill', 'ir', 'chk', 'ccc', 'vc' } {
      $lines = TLines $r 'ItemLineRet' 'ItemGroupLineRet' $true $K.sign
      $who = T $r ($K.who + '/FullName')
      if ($lines.Count) { $out.Add(@('pur', [ordered]@{ t = $K.t; d = $d; n = (T $r 'RefNumber'); v = $who; memo = (T $r 'Memo'); l = $lines })) }
      $ex = New-Object System.Collections.Generic.List[object]
      foreach ($n in $r.SelectNodes('ExpenseLineRet')) { $ex.Add([object[]]@((T $n 'AccountRef/FullName'), (T $n 'Memo'), (Money ($K.sign * (N $n 'Amount'))), (T $n 'CustomerRef/FullName'), (T $n 'ClassRef/FullName'))) }
      if ($ex.Count) { $out.Add(@('exp', [ordered]@{ t = $K.t; d = $d; n = (T $r 'RefNumber'); v = $who; acct = (T $r 'AccountRef/FullName'); memo = (T $r 'Memo'); l = $ex })) }
    }
    'dep' {
      $ln = New-Object System.Collections.Generic.List[object]
      foreach ($n in $r.SelectNodes('DepositLineRet')) { $ln.Add([object[]]@((T $n 'EntityRef/FullName'), (T $n 'AccountRef/FullName'), (T $n 'Memo'), (Money (N $n 'Amount')), (T $n 'PaymentMethodRef/FullName'), (T $n 'CheckNumber'))) }
      $out.Add(@('dep', [ordered]@{ d = $d; to = (T $r 'DepositToAccountRef/FullName'); memo = (T $r 'Memo'); tot = (N $r 'DepositTotal'); l = $ln }))
    }
    'je' {
      $ln = New-Object System.Collections.Generic.List[object]
      foreach ($n in $r.SelectNodes('JournalDebitLine')) { $ln.Add([object[]]@('D', (T $n 'AccountRef/FullName'), (Money (N $n 'Amount')), (T $n 'EntityRef/FullName'), (T $n 'Memo'))) }
      foreach ($n in $r.SelectNodes('JournalCreditLine')) { $ln.Add([object[]]@('C', (T $n 'AccountRef/FullName'), (Money (N $n 'Amount')), (T $n 'EntityRef/FullName'), (T $n 'Memo'))) }
      $out.Add(@('je', [ordered]@{ d = $d; n = (T $r 'RefNumber'); adj = ((T $r 'IsAdjustment') -eq 'true'); l = $ln }))
    }
    { $_ -in 'bpc', 'bpcc' } { $out.Add(@('bp', [ordered]@{ t = $K.t; d = $d; n = (T $r 'RefNumber'); v = (T $r 'PayeeEntityRef/FullName'); acct = (T $r ($K.acct + '/FullName')); amt = (N $r 'Amount'); memo = (T $r 'Memo') })) }
    { $_ -in 'so', 'est' } {
      $ln = New-Object System.Collections.Generic.List[object]; $nodes = New-Object System.Collections.Generic.List[object]
      foreach ($n in $r.SelectNodes($K.ln)) { $nodes.Add($n) }; foreach ($g in $r.SelectNodes($K.gn)) { foreach ($n in $g.SelectNodes($K.ln)) { $nodes.Add($n) } }
      foreach ($n in $nodes) { $it = T $n 'ItemRef/FullName'; if ($it) { $ln.Add([object[]]@($it, (T $n 'Desc'), (N $n 'Quantity'), (Money (N $n 'Amount')), (N $n 'Invoiced'))) } }
      $out.Add(@($K.k, [ordered]@{ d = $d; n = (T $r 'RefNumber'); c = (T $r 'CustomerRef/FullName'); tot = (N $r 'TotalAmount'); ship = (T $r 'ShipDate'); closed = ((T $r 'IsManuallyClosed') -eq 'true'); done = ((T $r 'IsFullyInvoiced') -eq 'true'); memo = (T $r 'Memo'); l = $ln }))
    }
    'adj' {
      $ln = New-Object System.Collections.Generic.List[object]
      foreach ($n in $r.SelectNodes('InventoryAdjustmentLineRet')) { $ln.Add([object[]]@((T $n 'ItemRef/FullName'), (N $n 'QuantityDifference'), (N $n 'ValueDifference'))) }
      $out.Add(@('adj', [ordered]@{ d = $d; n = (T $r 'RefNumber'); acct = (T $r 'AccountRef/FullName'); memo = (T $r 'Memo'); l = $ln }))
    }
    'build' { $out.Add(@('build', [ordered]@{ d = $d; n = (T $r 'RefNumber'); item = (T $r 'ItemInventoryAssemblyRef/FullName'); q = (N $r 'QuantityToBuild'); pending = ((T $r 'IsPending') -eq 'true'); memo = (T $r 'Memo') })) }
    'poall' {
      $ln = New-Object System.Collections.Generic.List[object]
      foreach ($n in $r.SelectNodes('PurchaseOrderLineRet')) { $it = T $n 'ItemRef/FullName'; if ($it) { $ln.Add([object[]]@($it, (T $n 'Desc'), (N $n 'Quantity'), (N $n 'ReceivedQuantity'), (N $n 'Rate'))) } }
      $out.Add(@('poall', [ordered]@{ d = $d; n = (T $r 'RefNumber'); v = (T $r 'VendorRef/FullName'); deliv = (T $r 'ExpectedDate'); tot = (N $r 'TotalAmount'); closed = ((T $r 'IsManuallyClosed') -eq 'true'); rcv = ((T $r 'IsFullyReceived') -eq 'true'); l = $ln }))
    }
  }
  , @($id, $d, $out)
}
# ---- the month cache: one file per set and month, each line "TxnID<TAB>json" (no big JSON to read back)
$CacheDir = Join-Path $HistDir 'cache'
$script:Cache = @{}      # "set|yyyy-MM" -> Dictionary[id -> json]
$script:Where = @{}      # "set|id" -> "yyyy-MM"
$script:Dirty = @{}      # "set|yyyy" -> 1
function Cache-Load([string]$set, [string]$ym) {
  $key = "$set|$ym"
  if (-not $script:Cache.ContainsKey($key)) {
    $dct = New-Object 'System.Collections.Generic.Dictionary[string,string]'
    $f = Join-Path $CacheDir "$set\$ym.tsv"
    if (Test-Path $f) { foreach ($line in [IO.File]::ReadAllLines($f, [Text.Encoding]::UTF8)) { $i = $line.IndexOf("`t"); if ($i -gt 0) { $dct[$line.Substring(0, $i)] = $line.Substring($i + 1) } } }
    $script:Cache[$key] = $dct
  }
  $script:Cache[$key]
}
function Cache-Save([string]$set, [string]$ym) {
  $dct = $script:Cache["$set|$ym"]; if ($null -eq $dct) { return }
  $dir = Join-Path $CacheDir $set; if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  $lines = New-Object System.Collections.Generic.List[string]
  foreach ($kv in $dct.GetEnumerator()) { $lines.Add($kv.Key + "`t" + $kv.Value) }
  [IO.File]::WriteAllLines((Join-Path $dir "$ym.tsv"), $lines, (New-Object System.Text.UTF8Encoding($false)))
}
function Cache-Index {
  $script:Where = @{}
  if (-not (Test-Path $CacheDir)) { return }
  foreach ($sd in Get-ChildItem $CacheDir -Directory) {
    foreach ($f in Get-ChildItem $sd.FullName -Filter '*.tsv') {
      $ym = $f.BaseName
      foreach ($line in [IO.File]::ReadAllLines($f.FullName, [Text.Encoding]::UTF8)) { $i = $line.IndexOf("`t"); if ($i -gt 0) { $script:Where[$sd.Name + '|' + $line.Substring(0, $i)] = $ym } }
    }
  }
}
function Cache-Remove([string]$set, [string]$id) {
  $old = $script:Where["$set|$id"]
  if ($old) { $dct = Cache-Load $set $old; [void]$dct.Remove($id); $script:Dirty["$set|$($old.Substring(0, 4))"] = 1; $script:Touched["$set|$old"] = 1; $script:Where.Remove("$set|$id") }
}
function Cache-Put([string]$set, [string]$id, [string]$d, $rec) {
  if (-not $d -or $d.Length -lt 7) { return }
  $ym = $d.Substring(0, 7)
  $old = $script:Where["$set|$id"]; if ($old -and $old -ne $ym) { Cache-Remove $set $id }
  $dct = Cache-Load $set $ym; $dct[$id] = (ToJson $rec)
  $script:Where["$set|$id"] = $ym; $script:Dirty["$set|$($ym.Substring(0, 4))"] = 1; $script:Touched["$set|$ym"] = 1
}
# all the sets one kind can write (bill/check/... write both "pur" and "exp")
function Sets-Of($K) { if ($K.k -in 'bill', 'ir', 'chk', 'ccc', 'vc') { @('pur', 'exp') } elseif ($K.k -in 'bpc', 'bpcc') { @('bp') } else { @($K.k) } }
function Put-Node($K, $r) {
  $res = Make-Recs $K $r; $id = $res[0]; $d = $res[1]
  $wrote = @{}
  foreach ($x in $res[2]) { Cache-Put $x[0] ($K.k + ':' + $id) $d $x[1]; $wrote[$x[0]] = 1 }
  foreach ($set in (Sets-Of $K)) { if (-not $wrote[$set]) { Cache-Remove $set ($K.k + ':' + $id) } }
}
function Save-Touched { foreach ($t in @($script:Touched.Keys)) { $p = $t.Split('|'); Cache-Save $p[0] $p[1] }; $script:Touched = @{} }
function Year-Json([string]$set, [int]$y) {
  $parts = New-Object System.Collections.Generic.List[string]
  for ($m = 1; $m -le 12; $m++) { $ym = '{0}-{1:00}' -f $y, $m; foreach ($v in (Cache-Load $set $ym).Values) { $parts.Add($v) } }
  '[' + ($parts -join ',') + ']'
}
function Try-Part([string]$what, [scriptblock]$sb) {
  try { & $sb } catch { Log ("History: skipped $what (" + $_.Exception.Message + ')'); $script:HistSkipped += $what }
}
function Hist-Lists {
  $out = [ordered]@{}
  $L = New-Object System.Collections.Generic.List[object]
  Try-Part 'customers' { foreach ($r in (QB-All 'CustomerQueryRq' '<ActiveStatus>All</ActiveStatus>' 'CustomerRet')) {
    $L.Add([ordered]@{ n = (T $r 'FullName'); sub = ((T $r 'Sublevel') -ne '' -and (T $r 'Sublevel') -ne '0'); active = ((T $r 'IsActive') -ne 'false'); bal = (N $r 'Balance'); tbal = (N $r 'TotalBalance')
      company = (T $r 'CompanyName'); contact = (T $r 'Contact'); phone = (T $r 'Phone'); alt = (T $r 'AltPhone'); email = (T $r 'Email')
      bill = (Addr $r 'BillAddress'); ship = (Addr $r 'ShipAddress'); type = (T $r 'CustomerTypeRef/FullName'); terms = (T $r 'TermsRef/FullName'); rep = (T $r 'SalesRepRef/FullName'); limit = (NN $r 'CreditLimit') })
  } }
  if ($L.Count) { $out['customers'] = $L }
  $L = New-Object System.Collections.Generic.List[object]
  foreach ($q in @(@('ItemInventoryQueryRq', 'ItemInventoryRet', 'inv'), @('ItemInventoryAssemblyQueryRq', 'ItemInventoryAssemblyRet', 'asm'), @('ItemNonInventoryQueryRq', 'ItemNonInventoryRet', 'non'), @('ItemServiceQueryRq', 'ItemServiceRet', 'svc'), @('ItemOtherChargeQueryRq', 'ItemOtherChargeRet', 'oth'), @('ItemDiscountQueryRq', 'ItemDiscountRet', 'disc'), @('ItemSubtotalQueryRq', 'ItemSubtotalRet', 'sub'), @('ItemGroupQueryRq', 'ItemGroupRet', 'grp'), @('ItemPaymentQueryRq', 'ItemPaymentRet', 'pay'))) {
    Try-Part $q[2] { foreach ($r in (QB-All $q[0] '<ActiveStatus>All</ActiveStatus>' $q[1])) {
      $desc = T $r 'SalesDesc'; if (-not $desc) { $desc = T $r 'SalesOrPurchase/Desc' }; if (-not $desc) { $desc = T $r 'SalesAndPurchase/SalesDesc' }; if (-not $desc) { $desc = T $r 'ItemDesc' }
      $price = NN $r 'SalesPrice'; if ($null -eq $price) { $price = NN $r 'SalesOrPurchase/Price' }; if ($null -eq $price) { $price = NN $r 'SalesAndPurchase/SalesPrice' }
      $cost = NN $r 'PurchaseCost'; if ($null -eq $cost) { $cost = NN $r 'SalesAndPurchase/PurchaseCost' }
      $L.Add([ordered]@{ n = (T $r 'FullName'); t = $q[2]; active = ((T $r 'IsActive') -ne 'false'); desc = $desc; price = $price; cost = $cost; avg = (NN $r 'AverageCost')
        qoh = (NN $r 'QuantityOnHand'); qso = (NN $r 'QuantityOnSalesOrder'); qpo = (NN $r 'QuantityOnOrder'); rp = (NN $r 'ReorderPoint'); vendor = (T $r 'PrefVendorRef/FullName') })
    } }
  }
  if ($L.Count) { $out['items'] = $L }
  $L = New-Object System.Collections.Generic.List[object]
  Try-Part 'reps' { foreach ($r in (QB-All 'SalesRepQueryRq' '<ActiveStatus>All</ActiveStatus>' 'SalesRepRet')) { $L.Add([ordered]@{ i = (T $r 'Initial'); n = (T $r 'SalesRepEntityRef/FullName') }) } }
  if ($L.Count) { $out['reps'] = $L }
  $L = New-Object System.Collections.Generic.List[object]
  Try-Part 'open POs' { foreach ($r in (QB-All 'PurchaseOrderQueryRq' '<IncludeLineItems>true</IncludeLineItems>' 'PurchaseOrderRet')) {
    if ((T $r 'IsFullyReceived') -eq 'true' -or (T $r 'IsManuallyClosed') -eq 'true') { continue }
    $lines = New-Object System.Collections.Generic.List[object]
    foreach ($n in $r.SelectNodes('PurchaseOrderLineRet')) {
      if ((T $n 'IsManuallyClosed') -eq 'true') { continue }
      $item = T $n 'ItemRef/FullName'; if (-not $item) { continue }
      $lines.Add([object[]]@($item, (T $n 'Desc'), (N $n 'Quantity'), (N $n 'ReceivedQuantity'), (N $n 'Rate')))
    }
    if ($lines.Count) { $L.Add([ordered]@{ d = (T $r 'TxnDate'); n = (T $r 'RefNumber'); v = (T $r 'VendorRef/FullName'); deliv = (T $r 'ExpectedDate'); shipto = (T $r 'ShipAddress/Addr1'); l = $lines }) }
  } }
  $out['po'] = $L
  $L = New-Object System.Collections.Generic.List[object]
  Try-Part 'vendors' { foreach ($r in (QB-All 'VendorQueryRq' '<ActiveStatus>All</ActiveStatus>' 'VendorRet')) {
    $L.Add([ordered]@{ n = (T $r 'Name'); active = ((T $r 'IsActive') -ne 'false'); company = (T $r 'CompanyName'); phone = (T $r 'Phone'); email = (T $r 'Email'); addr = (Addr $r 'VendorAddress'); terms = (T $r 'TermsRef/FullName'); bal = (N $r 'Balance'); type = (T $r 'VendorTypeRef/FullName') })
  } }
  if ($L.Count) { $out['vendors'] = $L }
  $L = New-Object System.Collections.Generic.List[object]
  Try-Part 'accounts' { foreach ($r in (QB-All 'AccountQueryRq' '<ActiveStatus>All</ActiveStatus>' 'AccountRet')) {
    $L.Add([ordered]@{ n = (T $r 'FullName'); type = (T $r 'AccountType'); num = (T $r 'AccountNumber'); bal = (N $r 'TotalBalance'); active = ((T $r 'IsActive') -ne 'false') })
  } }
  if ($L.Count) { $out['accounts'] = $L }
  $out
}
function Hist-Report([string]$type, [string]$from, [string]$to, [string]$by) {
  $x = QB-Do 'GeneralSummaryReportQueryRq' "<GeneralSummaryReportQueryRq requestID=`"1`"><GeneralSummaryReportType>$type</GeneralSummaryReportType><ReportPeriod><FromReportDate>$from</FromReportDate><ToReportDate>$to</ToReportDate></ReportPeriod><SummarizeColumnsBy>$by</SummarizeColumnsBy></GeneralSummaryReportQueryRq>"
  $rs = Rs $x 'GeneralSummaryReportQueryRs'; Check $rs $type
  $ret = $rs.SelectSingleNode('ReportRet')
  $cols = New-Object System.Collections.Generic.List[int]
  foreach ($cd in $ret.SelectNodes('ColDesc')) {
    $id = [int]$cd.GetAttribute('colID'); $ty = T $cd 'ColType'
    $titles = (@($cd.SelectNodes('ColTitle')) | ForEach-Object { $_.GetAttribute('value') }) -join ' '
    if ($id -gt 1 -and $ty -ne 'Label' -and $titles -notmatch 'TOTAL') { $cols.Add($id) }
  }
  $rows = New-Object System.Collections.Generic.List[object]
  $data = $ret.SelectSingleNode('ReportData')
  if ($data) {
    foreach ($row in $data.ChildNodes) {
      if ($row.NodeType -ne 'Element') { continue }
      $name = ''
      if ($row.Name -eq 'TextRow') { $name = $row.GetAttribute('value') }
      else {
        $rd = $row.SelectSingleNode('RowData'); if ($rd) { $name = $rd.GetAttribute('value') }
        $c1 = $row.SelectSingleNode("ColData[@colID='1']"); if ($c1 -and $c1.GetAttribute('value')) { $name = $c1.GetAttribute('value') }
      }
      if (-not $name) { continue }
      $vals = New-Object System.Collections.Generic.List[object]
      foreach ($id in $cols) {
        $c = $row.SelectSingleNode("ColData[@colID='$id']"); $v = if ($c) { $c.GetAttribute('value') } else { '' }
        if ($v -eq '' -or $row.Name -eq 'TextRow') { $vals.Add($null) } else { $vals.Add([double]::Parse($v, $Inv)) }
      }
      $rows.Add([ordered]@{ n = $name; k = $row.Name; v = $vals })
    }
  }
  [ordered]@{ from = $from; rows = $rows }
}
function Hist-Upload($sets, $man) {
  $total = 0
  foreach ($name in @($sets.Keys)) {
    $v = $sets[$name]; $json = if ($v -is [psobject] -and $v.PSObject.Properties.Name -contains 'json') { [string]$v.json } else { ToJson $v }; $sha = Sha $json
    $old = $man.sets[$name]
    if ($old -and $old.sha -eq $sha) { $man.sets[$name].at = (NowS); continue }
    $c = ProtectBytes (GzipText $json)
    $size = 15000; $parts = [int][Math]::Ceiling($c.Length / $size)
    $oldParts = if ($old) { [int]$old.parts } else { 0 }
    $batch = [ordered]@{}
    for ($i = 0; $i -lt [Math]::Max($parts, $oldParts); $i++) {
      $key = 'hx/' + $name + '-' + $i.ToString('0000')
      if ($i -lt $parts) { $batch[$key] = [ordered]@{ v = $c.Substring($i * $size, [Math]::Min($size, $c.Length - $i * $size)); t = @{ '.sv' = 'timestamp' } } } else { $batch[$key] = $null }
      if ($batch.Count -ge 40) { Db-Patch $batch; $batch = [ordered]@{} }
    }
    if ($batch.Count) { Db-Patch $batch }
    $man.sets[$name] = [ordered]@{ parts = $parts; sha = $sha; at = (NowS) }
    $total += $parts
  }
  $total
}
# the night a time belongs to: 11 PM to 6 AM counts as one night (named by the evening's date)
function Night-Of([datetime]$t) { if ($t.Hour -lt 12) { $t.AddDays(-1).ToString('yyyy-MM-dd') } else { $t.ToString('yyyy-MM-dd') } }
function Hist-Due {
  $mp = Join-Path $HistDir 'manifest.json'
  $last = ''; if (Test-Path $mp) { try { $last = [string](Get-Content $mp -Raw -Encoding UTF8 | ConvertFrom-Json).day } catch { } }
  $h = (Get-Date).Hour
  ($last -ne (Night-Of (Get-Date))) -and (($h -ge 23) -or ($h -lt 6))
}
function Collect-History([bool]$upload) {
  if (-not (Test-Path $HistDir)) { New-Item -ItemType Directory -Path $HistDir | Out-Null }
  $from = if ($cfg.PSObject.Properties.Name -contains 'historyFrom' -and $cfg.historyFrom) { [string]$cfg.historyFrom } else { '2020-01-01' }
  $mp = Join-Path $HistDir 'manifest.json'; $hp = Join-Path $HistDir 'progress.json'
  $man = [ordered]@{ day = ''; sets = @{} }
  if (Test-Path $mp) { try { $j = Get-Content $mp -Raw -Encoding UTF8 | ConvertFrom-Json; foreach ($p in $j.sets.PSObject.Properties) { $man.sets[$p.Name] = [ordered]@{ parts = $p.Value.parts; sha = $p.Value.sha; rows = $p.Value.rows; at = $p.Value.at } } } catch { } }
  $prog = @{ done = @{}; lastMod = ''; began = '' }
  if (Test-Path $hp) { try { $j = Get-Content $hp -Raw -Encoding UTF8 | ConvertFrom-Json; $prog.lastMod = [string]$j.lastMod; $prog.began = [string]$j.began; foreach ($p in $j.done.PSObject.Properties) { $prog.done[$p.Name] = $p.Value } } catch { } }
  # history version 2: earlier reads lost the item lines after the first 50 of each month, so read everything once more
  if (Test-Path $hp) { try { $j2 = Get-Content $hp -Raw -Encoding UTF8 | ConvertFrom-Json; if ([string]$j2.cv -ne '2') { $prog.done = @{}; $prog.lastMod = ''; $prog.began = ''; Log 'History: reading all months again once (to get every item line)' } } catch { } }
  $saveProg = { (ToJson ([ordered]@{ cv = '2'; lastMod = $prog.lastMod; began = $prog.began; done = $prog.done })) | Set-Content -Path $hp -Encoding UTF8 }
  $started = Get-Date; $today = $started.ToString('yyyy-MM-dd'); $curYm = $started.ToString('yyyy-MM')
  $auto = -not $History -and -not $script:HistNow
  $timeUp = { if ($auto) { $hh = (Get-Date).Hour; ($hh -ge 6) -and ($hh -lt 23) } else { $false } }
  $script:Gentle = 150; $script:Touched = @{}; $script:Dirty = @{}; $script:HistSkipped = @()
  $savedBatch = $Batch; $script:Batch = 50
  Log "History: reading QuickBooks gently from $from (one month at a time; what's done is kept)"
  Cache-Index
  $sets = [ordered]@{}
  $stopped = $false
  try {
    foreach ($kv in (Hist-Lists).GetEnumerator()) { $sets[$kv.Key] = $kv.Value }
    Try-Part 'profit & loss' { $sets['pl'] = Hist-Report 'ProfitAndLossStandard' ($from.Substring(0, 7) + '-01') $today 'Month' }
    Try-Part 'balance sheet' { $sets['bs'] = Hist-Report 'BalanceSheetStandard' $today $today 'TotalOnly' }
    # 1. what changed since last time (fast, small)
    $modStart = $started.ToString('yyyy-MM-ddTHH:mm:ss')
    if (-not $prog.began) { $prog.began = $modStart; & $saveProg }
    if ($prog.lastMod) {
      $since = ([datetime]::Parse($prog.lastMod, $Inv)).AddHours(-2).ToString('yyyy-MM-ddTHH:mm:ss')
      foreach ($K in $Kinds) {
        Try-Part ($K.k + ' changes') {
          $inner = "<ModifiedDateRangeFilter><FromModifiedDate>$since</FromModifiedDate></ModifiedDateRangeFilter>" + $(if ($K.lines) { '<IncludeLineItems>true</IncludeLineItems>' } else { '' })
          foreach ($r in (QB-All $K.rq $inner $K.ret)) { Put-Node $K $r }
          Save-Touched
        }
      }
      Try-Part 'deleted' {
        $types = ($Kinds | ForEach-Object { '<TxnDelType>' + $_.del + '</TxnDelType>' }) -join ''
        $x = QB-Do 'TxnDeletedQueryRq' "<TxnDeletedQueryRq requestID=`"1`">$types<DeletedDateRangeFilter><FromDeletedDate>$since</FromDeletedDate></DeletedDateRangeFilter></TxnDeletedQueryRq>"
        $rs = Rs $x 'TxnDeletedQueryRs'; Check $rs 'TxnDeletedQueryRq'
        foreach ($r in $rs.SelectNodes('TxnDeletedRet')) { $tp = T $r 'TxnDelType'; $K = $Kinds | Where-Object { $_.del -eq $tp } | Select-Object -First 1; if ($K) { foreach ($set in (Sets-Of $K)) { Cache-Remove $set ($K.k + ':' + (T $r 'TxnID')) } } }
        Save-Touched
      }
    }
    # 2. months not read yet, oldest first, a month at a time (continues where it stopped)
    $y = [int]$from.Substring(0, 4); $m = [int]$from.Substring(5, 2)
    $months = New-Object System.Collections.Generic.List[string]
    while (('{0}-{1:00}' -f $y, $m) -le $curYm) { $months.Add(('{0}-{1:00}' -f $y, $m)); $m++; if ($m -gt 12) { $m = 1; $y++ } }
    :outer foreach ($ym in $months) {
      foreach ($K in $Kinds) {
        $dk = $K.k + '|' + $ym
        if ($prog.done[$dk] -and $ym -lt $curYm) { continue }
        if ($prog.done[$dk] -and $prog.lastMod) { continue }
        if (& $timeUp) { $stopped = $true; break outer }
        $last = [datetime]::ParseExact($ym + '-01', 'yyyy-MM-dd', $Inv).AddMonths(1).AddDays(-1).ToString('yyyy-MM-dd')
        $ok = $true
        try {
          $inner = "<TxnDateRangeFilter><FromTxnDate>$ym-01</FromTxnDate><ToTxnDate>$last</ToTxnDate></TxnDateRangeFilter>" + $(if ($K.lines) { '<IncludeLineItems>true</IncludeLineItems>' } else { '' })
          foreach ($r in (QB-All $K.rq $inner $K.ret)) { Put-Node $K $r }
          Save-Touched
        } catch { $ok = $false; Log ("History: skipped " + $K.k + " $ym (" + $_.Exception.Message + ')'); $script:HistSkipped += ($K.k + " $ym") }
        if ($ok) { $prog.done[$dk] = 1; & $saveProg }
      }
      Log "History: $ym done"
      if ($script:InWatch) { try { $qs = Load-State; if (Queue-HasNew $qs) { [void](Process-Queue $qs $true); Save-State $qs } } catch { } }
    }
    if (-not $prog.lastMod) { $prog.lastMod = $prog.began } elseif (-not $stopped) { $prog.lastMod = $modStart }
    & $saveProg
  } finally { QB-Close; $script:Batch = $savedBatch; $script:Gentle = 0 }
  # 3. send the years that changed
  # every year of every set (unchanged ones are skipped by their fingerprint, so a stop half-way never loses anything)
  foreach ($set in 'inv', 'cm', 'sr', 'pay', 'pur', 'exp', 'dep', 'je', 'bp', 'so', 'est', 'adj', 'build', 'poall') {
    for ($yy = [int]$from.Substring(0, 4); $yy -le $started.Year; $yy++) {
      $has = (Test-Path (Join-Path $CacheDir "$set\$yy-*.tsv")) -or $man.sets.ContainsKey("${set}_$yy")
      if ($has) { $sets["${set}_$yy"] = [pscustomobject]@{ json = (Year-Json $set $yy) } }
    }
  }
  $sets['meta'] = [ordered]@{ asOf = $today; from = $from; at = $started.ToString('yyyy-MM-ddTHH:mm:ss'); pc = $env:COMPUTERNAME; ver = $Ver; complete = (-not $stopped) }
  if (-not $upload) { Log ('History test: ' + (@($sets.Keys) -join ', ')); return }
  $parts = Hist-Upload $sets $man
  if (-not $stopped) { $man.day = (Night-Of $started) }
  Db-Patch ([ordered]@{ 'hx/manifest' = [ordered]@{ v = (Protect (ToJson ([ordered]@{ asOf = $today; from = $from; at = (NowS); complete = (-not $stopped); sets = $man.sets }))); t = @{ '.sv' = 'timestamp' } } })
  (ToJson $man) | Set-Content -Path $mp -Encoding UTF8
  if ($script:HistSkipped.Count) { Log ('History: skipped (tried again next time): ' + ($script:HistSkipped -join ', ')) }
  Log ("History: sent $parts new pieces in " + [Math]::Round(((Get-Date) - $started).TotalMinutes, 1) + ' min.' + $(if ($stopped) { ' Stopped at 6 AM, it continues tonight at 11 PM.' } else { '' }))
}

# ---------------- always on: checks the app every 2 seconds ----------------
# Runs for up to 170 minutes, then the 1-minute schedule starts a fresh one (so updates and restarts happen by themselves).
$StopFlag = Join-Path $Here 'stop.flag'; $ReadFlag = Join-Path $Here 'read-now.flag'; $HistFlag = Join-Path $Here 'history-now.flag'
function Queue-HasNew($st) {
  if ($st.pending.Count) { return $true }
  $since = [double]$st.qwT + 1
  $w = Invoke-RestMethod -Method Get -Uri ((Url) + '/' + $cfg.space + '/qw.json?orderBy=%22t%22&startAt=' + $since.ToString('0', $Inv) + '&limitToFirst=1') -TimeoutSec 20
  ($null -ne $w) -and (@($w.PSObject.Properties).Count -gt 0)
}
# Is Outlook set up on this PC (for sending statements)? Checked once per start.
$script:MailInfo = $null
function Mail-Probe {
  # only looks in the registry: never opens Outlook (an Outlook window waiting for an answer would stop the sync)
  if ($null -ne $script:MailInfo) { return $script:MailInfo }
  $script:MailInfo = 'none'
  try {
    $found = @()
    foreach ($v in '16.0', '15.0') {
      $pk = "HKCU:\Software\Microsoft\Office\$v\Outlook\Profiles"
      if (-not (Test-Path $pk)) { continue }
      foreach ($prof in @(Get-ChildItem $pk -ErrorAction SilentlyContinue)) {
        $ak = Join-Path $prof.PSPath '9375CFF0413111d3B88A00104B2A6676'
        foreach ($acc in @(Get-ChildItem $ak -ErrorAction SilentlyContinue)) {
          $p = Get-ItemProperty $acc.PSPath -ErrorAction SilentlyContinue
          foreach ($n in 'Account Name', 'Email') { if ($p -and $p.$n -is [byte[]]) { $t = ([Text.Encoding]::Unicode.GetString($p.$n)).Trim([char]0); if ($t -match '@') { $found += $t; break } } }
        }
      }
      if ($found.Count) { break }
    }
    $found = @($found | Select-Object -Unique)
    $script:MailInfo = if ($found.Count) { 'outlook:' + $found.Count + ':' + ($found -join ',') } else { 'none:no Outlook account on this PC' }
  } catch { $script:MailInfo = 'none:check failed' }
  $script:MailInfo
}
# ---------------- statements by email (Outlook on this PC) ----------------
# The app's Statements screen sets: on/off, day and hour, stores left out, "send now" and "send a test".
function Coll-Read([string]$coll) {
  $m = @{}
  $r = Invoke-RestMethod -Method Get -Uri ((Url) + '/' + $cfg.space + '/' + $coll + '.json') -TimeoutSec 60
  if ($r) { foreach ($p in $r.PSObject.Properties) { $rec = Unprotect ([string]$p.Value.v); if ($rec -and $rec.k) { $m[[string]$rec.k] = $rec.val } } }
  $m
}
function Sl-Put([string]$k, $val) {
  Db-Patch ([ordered]@{ ('sl/s' + (Sha $k).Substring(0, 20)) = [ordered]@{ v = (Protect (ToJson ([ordered]@{ k = $k; val = $val; by = 'QuickBooks' }))); t = @{ '.sv' = 'timestamp' } } })
}
function Stmt-Data {
  $today = (Get-Date).Date; $by = @{}
  foreach ($r in (QB-All 'InvoiceQueryRq' '<PaidStatus>NotPaidOnly</PaidStatus><IncludeRetElement>RefNumber</IncludeRetElement><IncludeRetElement>CustomerRef</IncludeRetElement><IncludeRetElement>TxnDate</IncludeRetElement><IncludeRetElement>DueDate</IncludeRetElement><IncludeRetElement>BalanceRemaining</IncludeRetElement>' 'InvoiceRet')) {
    $b = N $r 'BalanceRemaining'; if ($b -le 0.005) { continue }
    $c = T $r 'CustomerRef/FullName'; $d = T $r 'TxnDate'; $due = T $r 'DueDate'; if (-not $due) { $due = $d }
    $days = 0; try { $days = ($today - [datetime]::ParseExact($due, 'yyyy-MM-dd', $Inv)).Days } catch { }
    if (-not $by.ContainsKey($c)) { $by[$c] = New-Object System.Collections.Generic.List[object] }
    $by[$c].Add([ordered]@{ n = (T $r 'RefNumber'); d = $d; due = $due; b = $b; days = $days })
  }
  $cust = @{}
  foreach ($r in (QB-All 'CustomerQueryRq' '<ActiveStatus>All</ActiveStatus><IncludeRetElement>FullName</IncludeRetElement><IncludeRetElement>Email</IncludeRetElement><IncludeRetElement>Cc</IncludeRetElement><IncludeRetElement>TotalBalance</IncludeRetElement>' 'CustomerRet')) {
    $cust[(T $r 'FullName')] = [ordered]@{ em = (T $r 'Email'); cc = (T $r 'Cc'); bal = (N $r 'TotalBalance') }
  }
  $out = @{}
  foreach ($c in $by.Keys) {
    $inv = @($by[$c] | Sort-Object { $_.d }); $mx = ($inv | Measure-Object -Property days -Maximum).Maximum
    $info = $cust[$c]; if (-not $info) { $info = [ordered]@{ em = ''; cc = ''; bal = 0 } }
    if (-not $info.em -and $c.Contains(':')) { $p = $cust[$c.Split(':')[0]]; if ($p) { $info.em = $p.em; $info.cc = $p.cc } }
    $grp = if ($mx -gt 90) { '90' } elseif ($mx -gt 60) { '60' } else { '' }
    $out[$c] = [ordered]@{ name = $c; inv = $inv; max = $mx; grp = $grp; em = $info.em; cc = $info.cc; bal = $info.bal }
  }
  $out
}
function Mail-List([string]$s) { (($s -split '[;,\s]+') | Where-Object { $_ -match '@' }) -join '; ' }
function HtmlE([string]$s) { [Net.WebUtility]::HtmlEncode($s) }
function Stmt-Html($x) {
  $us = { param($iso) try { [datetime]::ParseExact($iso, 'yyyy-MM-dd', $Inv).ToString('MM/dd/yyyy', $Inv) } catch { $iso } }
  $m = { param($v) $(if ([double]$v -lt 0) { '-$' } else { '$' }) + ([Math]::Abs([double]$v)).ToString('#,##0.00', $Inv) }
  $sum = 0.0; $late = 0.0; $rows = ''
  foreach ($i in $x.inv) {
    $sum += $i.b; if ($i.days -gt 0) { $late += $i.b }
    $red = if ($i.days -gt 60) { 'color:#8A1C12;font-weight:bold' } else { '' }
    $rows += '<tr style="border-bottom:1px solid #e3dccb"><td>' + (& $us $i.d) + '</td><td>#' + (HtmlE $i.n) + '</td><td>' + (& $us $i.due) + '</td><td align="right" style="' + $red + '">' + $(if ($i.days -gt 0) { [string]$i.days } else { '' }) + '</td><td align="right">' + (& $m $i.b) + '</td></tr>'
  }
  $bal = if ([Math]::Abs($x.bal) -gt 0.005) { $x.bal } else { $sum }
  $tot = '<tr><td colspan="4" align="right">Open invoices</td><td align="right">' + (& $m $sum) + '</td></tr>'
  if ([Math]::Abs($bal - $sum) -ge 1) { $tot += '<tr><td colspan="4" align="right">Credits and payments not yet applied</td><td align="right">' + (& $m ($bal - $sum)) + '</td></tr>' }
  if ($late -gt 1) { $tot += '<tr><td colspan="4" align="right" style="color:#8A1C12"><b>Past due</b></td><td align="right" style="color:#8A1C12"><b>' + (& $m $late) + '</b></td></tr>' }
  $tot += '<tr style="font-size:16px"><td colspan="4" align="right"><b>Total due</b></td><td align="right"><b>' + (& $m $bal) + '</b></td></tr>'
  '<div style="font-family:Arial,Helvetica,sans-serif;color:#1a2340;max-width:680px">' +
  '<table width="100%" style="border-bottom:3px solid #E8B730;margin-bottom:12px"><tr><td><img src="https://chuster.netlify.app/icon-192.png" width="70" height="70" alt="Chuster Noodle"></td><td align="right"><div style="font-size:22px;font-weight:bold;color:#22409A">Statement</div><div>' + (Get-Date).ToString('MMMM d, yyyy', $Inv) + '</div></td></tr></table>' +
  '<p style="margin:0 0 10px">To: <b>' + (HtmlE $x.name) + '</b></p>' +
  '<table cellpadding="6" style="border-collapse:collapse;width:100%;font-size:14px"><tr style="background:#22409A;color:#ffffff"><th align="left">Date</th><th align="left">Invoice</th><th align="left">Due</th><th align="right">Days late</th><th align="right">Open amount</th></tr>' + $rows + $tot + '</table>' +
  '<p style="margin-top:16px">' + $(if ($late -gt 1) { 'Please send payment for the past-due invoices. If you already sent it, thank you, please reply with the check number so we can match it.' } else { 'Thank you for your business.' }) + '</p>' +
  '<p>Questions? Just reply to this email.<br><b>Chuster Noodle</b></p></div>'
}
function Mail-Send([string]$to, [string]$cc, [string]$subj, [string]$html) {
  # in a separate helper with a time limit, so Outlook can never freeze the sync
  if (-not (Mail-Probe).StartsWith('outlook:')) { throw 'Outlook is not set up on the office PC.' }
  $j = Start-Job -ScriptBlock { param($to, $cc, $subj, $html)
    $ol = New-Object -ComObject Outlook.Application
    $mi = $ol.CreateItem(0); $mi.To = $to; if ($cc) { $mi.CC = $cc }; $mi.Subject = $subj; $mi.HTMLBody = $html; $mi.Send(); 'ok'
  } -ArgumentList $to, $cc, $subj, $html
  if (-not (Wait-Job $j -Timeout 90)) { Stop-Job $j -ErrorAction SilentlyContinue; Remove-Job $j -Force -ErrorAction SilentlyContinue; throw 'Outlook did not answer (is a window open in Outlook waiting for an answer?).' }
  $r = Receive-Job $j -ErrorAction SilentlyContinue -ErrorVariable je; Remove-Job $j -Force -ErrorAction SilentlyContinue
  if ($r -notcontains 'ok') { throw ('Outlook: ' + $(if ($je) { [string]$je[0] } else { 'could not send' })) }
}
function Stmt-Send($x, [string]$why, [string]$testTo) {
  $to = if ($testTo) { Mail-List $testTo } else { Mail-List $x.em }
  $cc = if ($testTo) { '' } else { Mail-List $x.cc }
  $subj = $(if ($testTo) { '[TEST] ' } else { '' }) + 'Statement from Chuster Noodle - ' + $x.name
  if (-not $to) { if (-not $testTo) { Sl-Put $x.name ([ordered]@{ at = (NowS); grp = $x.grp; ok = $false; err = 'No email for this store in QuickBooks'; why = $why }) }; return $false }
  try {
    Mail-Send $to $cc $subj (Stmt-Html $x)
    if (-not $testTo) { Sl-Put $x.name ([ordered]@{ at = (NowS); grp = $x.grp; ok = $true; to = $to; why = $why }) }
    Log "Statement: $($x.name) -> $to ($why)"; Start-Sleep -Seconds 2; return $true
  } catch {
    $e = ([string]$_.Exception.Message); if ($e.Length -gt 160) { $e = $e.Substring(0, 160) }
    if (-not $testTo) { Sl-Put $x.name ([ordered]@{ at = (NowS); grp = $x.grp; ok = $false; err = $e; why = $why }) }
    Log "Statement: $($x.name) failed: $e"; throw
  }
}
$script:StmtTried = [datetime]::MinValue
function Stmt-Tick {
  if (((Get-Date) - $script:StmtTried).TotalMinutes -lt 3) { return }
  $script:StmtTried = Get-Date
  $sx = Coll-Read 'sx'; $sl = Coll-Read 'sl'
  $done = @(); if ($sl['_req'] -and $sl['_req'].ids) { $done = @($sl['_req'].ids) }
  $cfgS = $sx['cfg']; $now = Get-Date
  $test = $sx['test']; $req = $sx['now']
  $needTest = $test -and $test.id -and -not ($done -contains $test.id)
  $needNow = $req -and $req.id -and -not ($done -contains $req.id)
  $due = $false
  if ($cfgS -and $cfgS.on -and [int]$now.DayOfWeek -eq [int]$cfgS.day -and $now.Hour -ge [int]$cfgS.hour) { $due = $true }
  if ($due -and $sl['_auto'] -and [string]$sl['_auto'].day -eq $now.ToString('yyyy-MM-dd')) { $due = $false }
  if (-not ($needTest -or $needNow -or $due)) { return }
  $data = Stmt-Data
  if ($needTest) {
    $ids = $done + @($test.id); Sl-Put '_req' ([ordered]@{ ids = @($ids | Select-Object -Last 40) }); $done = $ids
    $pick = @($data.Values | Where-Object { $_.grp } | Sort-Object { - $_.max } | Select-Object -First 2)
    if (-not $pick.Count) { $pick = @($data.Values | Select-Object -First 1) }
    try { foreach ($x in $pick) { [void](Stmt-Send $x 'test' ([string]$test.to)) }; Sl-Put '_test' ([ordered]@{ id = $test.id; at = (NowS); ok = $true; to = [string]$test.to; n = $pick.Count }) }
    catch { Sl-Put '_test' ([ordered]@{ id = $test.id; at = (NowS); ok = $false; err = ([string]$_.Exception.Message); to = [string]$test.to }) }
  }
  if ($needNow) {
    $ids = $done + @($req.id); Sl-Put '_req' ([ordered]@{ ids = @($ids | Select-Object -Last 40) }); $done = $ids
    $n = 0; foreach ($name in @($req.names)) { $x = $data[[string]$name]; if ($x -and $n -lt 300) { try { if (Stmt-Send $x 'now' '') { $n++ } } catch { } } }
    Sl-Put '_now' ([ordered]@{ id = $req.id; at = (NowS); n = $n })
  }
  if ($due) {
    $n = 0
    foreach ($x in $data.Values) {
      if (-not $x.grp -or $n -ge 300) { continue }
      $off = $sx['x:' + $x.name]; if ($off -and $off.off) { continue }
      $last = $sl[$x.name]; $every = if ($x.grp -eq '90') { 6.5 } else { 13.5 }
      if ($last -and $last.at -and $last.ok -ne $false) { try { if (($now - [datetime]::ParseExact([string]$last.at, 'yyyy-MM-ddTHH:mm:ss', $Inv)).TotalDays -lt $every) { continue } } catch { } }
      if ($last -and $last.ok -eq $false -and $last.at -and ([string]$last.at).StartsWith($now.ToString('yyyy-MM-dd'))) { continue }
      try { if (Stmt-Send $x 'auto' '') { $n++ } } catch { }
    }
    Sl-Put '_auto' ([ordered]@{ day = $now.ToString('yyyy-MM-dd'); n = $n; at = (NowS) })
    if ($n) { Log "Statements: sent $n." }
  }
}
# Self-update: picks up new versions of this program from the app's site, only when signed with this office's key.
$CodeKey = $hm.ComputeHash([Text.Encoding]::UTF8.GetBytes('chuster-qb-code'))
function Code-Mac([byte[]]$b) { [Convert]::ToBase64String((New-Object System.Security.Cryptography.HMACSHA256 -ArgumentList (, $CodeKey)).ComputeHash($b)) }
function Check-Update {
  if ($env:CHUSTER_QB_MOCK) { return }
  $base = 'https://chuster.netlify.app/qb/'; $wc = New-Object Net.WebClient; $wc.Headers.Add('Cache-Control', 'no-cache')
  $sig = ($wc.DownloadString($base + 'sync.sig?t=' + [DateTime]::UtcNow.Ticks)).Trim()
  if (-not $sig -or $sig.Length -gt 100) { return }
  $mine = [IO.File]::ReadAllBytes($PSCommandPath)
  if ((Code-Mac $mine) -eq $sig) { return }
  $wc = New-Object Net.WebClient; $new = $wc.DownloadData($base + 'sync.ps1?t=' + [DateTime]::UtcNow.Ticks)
  if ((Code-Mac $new) -ne $sig) { Log 'Update: the download did not match its signature, skipped.'; return }
  [IO.File]::WriteAllBytes($PSCommandPath + '.prev', $mine)
  [IO.File]::WriteAllBytes($PSCommandPath, $new)
  Log 'Update: new version downloaded, restarting.'
}
function Watch-Loop {
  $begin = Get-Date; $codeAt = (Get-Item $PSCommandPath).LastWriteTime
  $lastSync = [datetime]::MinValue; $fails = 0; $lastUpd = (Get-Date).AddMinutes(-9)
  $script:InWatch = $true; $script:HistTried = [datetime]::MinValue
  Log 'Always-on: watching the app for new orders (every 2 seconds).'
  while ($true) {
    if (Test-Path $StopFlag) { Log 'Always-on: turned off.'; return }
    if (((Get-Date) - $begin).TotalMinutes -ge 170) { return }
    if ((Get-Item $PSCommandPath).LastWriteTime -ne $codeAt) { Log 'Always-on: new version found, restarting.'; return }
    try { (Get-Item $LockPath -ErrorAction Stop).LastWriteTime = Get-Date } catch { }
    if (((Get-Date) - $lastUpd).TotalMinutes -ge 10) { $lastUpd = Get-Date; try { Check-Update } catch { } }
    try { Stmt-Tick } catch { Log ('Statements: ' + $_.Exception.Message) }
    try {
      $script:ForceRead = Test-Path $ReadFlag; if ($script:ForceRead) { Remove-Item $ReadFlag -ErrorAction SilentlyContinue }
      $st = Load-State
      $new = Queue-HasNew $st
      if ($new -or $script:ForceRead -or ((Get-Date) - $lastSync).TotalSeconds -ge 60) {
        # makes the new orders in QuickBooks, then reads them back so the app shows them right away
        Sync-Once $true
        $lastSync = Get-Date; $script:ForceRead = $false
      }
      if ((Test-Path $HistFlag) -or ((Hist-Due) -and ((Get-Date) - $script:HistTried).TotalMinutes -ge 30)) {
        $script:HistTried = Get-Date
        $script:HistNow = Test-Path $HistFlag; Remove-Item $HistFlag -ErrorAction SilentlyContinue
        try { Collect-History $true } catch { Log ('History: ' + $_.Exception.Message) }
        $script:HistNow = $false
      }
      $fails = 0
    } catch {
      $fails++; $msg = $_.Exception.Message
      if ($fails -le 3 -or $fails % 30 -eq 0) { Log ('Always-on: ' + $msg) }
      try { QB-Close } catch { }
      if ($fails -eq 3) { try { Report-Error $msg } catch { } }
      Start-Sleep -Seconds ([Math]::Min(30, 2 * $fails)); continue
    }
    Start-Sleep -Seconds 2
  }
}

# ---------------- main ----------------
if (-not $Install -and -not $Test -and (Test-Path $LockPath)) {
  # a sync that stopped answering (no sign of life for 15 minutes): stop it and take over
  if ((Get-Item $LockPath).LastWriteTime -lt (Get-Date).AddMinutes(-15)) {
    try { $old = [int](Get-Content $LockPath -Raw).Trim(); if ($old -and $old -ne $PID) { $pr = Get-Process -Id $old -ErrorAction SilentlyContinue; if ($pr -and $pr.ProcessName -match 'powershell') { Stop-Process -Id $old -Force -ErrorAction SilentlyContinue; Log "Stopped a sync that was frozen (process $old)." } } } catch { }
    Remove-Item $LockPath -Force -ErrorAction SilentlyContinue
  }
}
if (-not $Install -and -not $Test -and (Test-Path $LockPath)) {
  if ((Get-Item $LockPath).LastWriteTime -gt (Get-Date).AddMinutes(-90)) {
    if ($History) { Set-Content -Path $HistFlag -Value 1; Write-Host 'The sync is running. It starts reading the history in a few seconds (one month at a time). See sync-log.txt.' -ForegroundColor Green }
    elseif (-not $Watch) { Set-Content -Path $ReadFlag -Value 1; Write-Host 'The sync is running. It reads QuickBooks again in a few seconds. See sync-log.txt.' -ForegroundColor Green }
    exit 0
  }
}
if (-not $Install) { Set-Content -Path $LockPath -Value $PID }
try {
  if ($Install) {
    Write-Host ''; Write-Host '=== Chuster QB Sync setup ===' -ForegroundColor Cyan
    Get-ChildItem $Here | Unblock-File -ErrorAction SilentlyContinue
    while ((Url) -notmatch '^https://.+') {
      $u = Read-Host 'Paste the Firebase database link (it starts with https:// and ends with firebaseio.com or firebasedatabase.app)'
      $cfg.url = ([string]$u).Trim().TrimEnd('/')
    }
    Save-Cfg
    Remove-Item $StopFlag -ErrorAction SilentlyContinue
    Write-Host 'Checking the shared database...'; Db-Check | Out-Null; Write-Host 'Shared database OK.' -ForegroundColor Green
    Write-Host ''
    Write-Host 'Now QuickBooks will ask if "Chuster App Sync" may read your company file.' -ForegroundColor Yellow
    Write-Host 'Open QuickBooks with your company file, log in as Admin, then pick:' -ForegroundColor Yellow
    Write-Host '  "Yes, always; allow access even if QuickBooks is not running", then Continue and Done.' -ForegroundColor Yellow
    Read-Host 'Press Enter when QuickBooks is open'
    Sync-Once $true
    $vbs = Join-Path $Here 'run-hidden.vbs'
    try {
      $act = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument ('"' + $vbs + '"') -WorkingDirectory $Here
      $trg = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(2) -RepetitionInterval (New-TimeSpan -Minutes 1)
      $set = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Hours 3) -MultipleInstances IgnoreNew
      Register-ScheduledTask -TaskName $TaskName -Action $act -Trigger $trg -Settings $set -Description 'Chuster app <-> QuickBooks: always on, orders within seconds, full read every 15 min' -Force | Out-Null
    } catch {
      $short = (New-Object -ComObject Scripting.FileSystemObject).GetFile($vbs).ShortPath
      schtasks.exe /Create /F /SC MINUTE /MO 1 /TN $TaskName /TR "wscript.exe $short" | Out-Null
    }
    Write-Host ''; Write-Host 'Done. It is always on now: orders from the app go into QuickBooks within seconds, and it reads QuickBooks every 15 minutes, while this computer is on.' -ForegroundColor Green
    Write-Host 'Open the Chuster app: the dashboard shows "QuickBooks live".'
  } else {
    if (-not ((Url) -match '^https?://') -and -not $Test) { throw 'No database link yet. Run Install.cmd first.' }
    if ($History) { Collect-History (-not $Test) }
    elseif ($Watch -and -not $Test) {
      if (Test-Path $StopFlag) { exit 0 }
      Sync-Once $true
      Watch-Loop
    }
    else {
      Sync-Once (-not $Test)
      if (-not $Test -and (Hist-Due)) { try { Collect-History $true } catch { Log ('History: ' + $_.Exception.Message) } }
    }
  }
} catch {
  $msg = $_.Exception.Message; $where = ($_.ScriptStackTrace -split "`n" | Select-Object -First 2) -join ' < '
  if ($msg -match 'QBXMLRP2|80040154|Class not registered') {
    Remove-Item $LockPath -ErrorAction SilentlyContinue
    if (Try-OtherBitness) { exit 0 }
    $msg = 'The QuickBooks connector is not on this computer. Run this on the computer where QuickBooks Desktop is installed.'
  } elseif ($msg -match '80040408|could not start QuickBooks|not running') { $msg = 'QuickBooks is closed and has no permission to open in the background. Open QuickBooks, then run Install.cmd again and pick "Yes, always; allow access even if QuickBooks is not running".' }
  elseif ($msg -match '80040410|80040418|application certificate|not permitted|access') { $msg = 'QuickBooks did not give permission. In QuickBooks as Admin: Edit > Preferences > Integrated Applications > Company Preferences, allow "Chuster App Sync", or run Install.cmd again.' }
  elseif ($msg -match '80040417|80040422|another company|different company') { $msg = 'A different company file is open in QuickBooks. Open the Chuster company file.' }
  Log ('Problem: ' + $msg + '   [' + $where + ']')
  Report-Error $msg
  if ($Install) { Write-Host ''; Write-Host $msg -ForegroundColor Red }
  exit 1
} finally {
  if (-not $Install) { Remove-Item $LockPath -ErrorAction SilentlyContinue }
}
