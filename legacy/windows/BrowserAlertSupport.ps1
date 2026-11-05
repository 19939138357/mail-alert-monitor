Set-StrictMode -Version Latest

function Get-BrowserPairingToken {
    param([string]$TokenPath = (Join-Path $PSScriptRoot '04_资料/私密配置/browser_pairing.xml'))
    if (-not [IO.File]::Exists($TokenPath)) {
        [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($TokenPath))
        $bytes = New-Object byte[] 32
        $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
        try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
        $value = [BitConverter]::ToString($bytes).Replace('-', '').ToLowerInvariant()
        $secure = ConvertTo-SecureString $value -AsPlainText -Force
        $temporary = $TokenPath + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
        try { $secure | Export-Clixml -LiteralPath $temporary; [IO.File]::Move($temporary, $TokenPath) }
        catch { if (-not [IO.File]::Exists($TokenPath)) { throw } }
        finally { if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) } }
    }
    $secret = Import-Clixml -LiteralPath $TokenPath
    if ($secret -isnot [Security.SecureString]) { throw '本机配对信息格式错误。' }
    $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secret)
    try { $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer) }
    if ($plain -cnotmatch '^[a-f0-9]{64}$') { throw '本机配对信息无效。' }
    return $plain
}

function Read-BrowserHttpRequest {
    param([IO.Stream]$Stream)
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $header = New-Object System.Collections.Generic.List[byte]
    while ($true) {
        if ($clock.Elapsed.TotalSeconds -gt 3 -or $header.Count -ge 8192) { throw 'Request header limit' }
        $next = $Stream.ReadByte()
        if ($next -lt 0) { throw 'Incomplete request' }
        $header.Add([byte]$next)
        $n = $header.Count
        if ($n -ge 4 -and $header[$n-4] -eq 13 -and $header[$n-3] -eq 10 -and $header[$n-2] -eq 13 -and $header[$n-1] -eq 10) { break }
    }
    $lines = [Text.Encoding]::ASCII.GetString($header.ToArray()) -split "`r`n"
    if ($lines[0] -notmatch '^(GET|POST|OPTIONS) (/[^ ]*) HTTP/1\.[01]$') { throw 'Invalid request line' }
    $method = $Matches[1]; $path = $Matches[2]; $headers = @{}
    foreach ($line in $lines[1..($lines.Length-1)]) {
        if ($line -eq '') { continue }
        if ($line -notmatch '^([A-Za-z0-9-]+):\s*(.*)$') { throw 'Invalid header' }
        $key = $Matches[1].ToLowerInvariant()
        if ($headers.ContainsKey($key)) { throw 'Duplicate header' }
        $headers[$key] = $Matches[2].Trim()
    }
    if ($headers.ContainsKey('transfer-encoding')) { throw 'Unsupported transfer encoding' }
    $length = 0
    if ($headers.ContainsKey('content-length')) {
        if ($headers['content-length'] -cnotmatch '^[0-9]+$' -or -not [int]::TryParse($headers['content-length'], [ref]$length) -or $length -lt 0 -or $length -gt 2048) { throw 'Body too large' }
    }
    if ($method -eq 'POST' -and $length -eq 0) { throw 'Missing request body' }
    $body = New-Object byte[] $length; $offset = 0
    while ($offset -lt $length) {
        if ($clock.Elapsed.TotalSeconds -gt 5) { throw 'Body timeout' }
        $count = $Stream.Read($body,$offset,$length-$offset)
        if ($count -le 0) { throw 'Incomplete body' }
        $offset += $count
    }
    return [pscustomobject]@{ Method=$method; Path=$path; Headers=$headers; Body=[Text.UTF8Encoding]::new($false,$true).GetString($body) }
}

function Write-BrowserHttpResponse {
    param([IO.Stream]$Stream, [int]$Status, $Data, [string]$Origin = '')
    $body = [Text.Encoding]::UTF8.GetBytes(($Data | ConvertTo-Json -Compress -Depth 8))
    $cors = if ($Origin -cmatch '^chrome-extension://[a-p]{32}$') { "Access-Control-Allow-Origin: $Origin`r`nAccess-Control-Allow-Headers: X-Monitor-Token, Content-Type`r`nAccess-Control-Allow-Methods: GET, POST, OPTIONS`r`n" } else { '' }
    $header = [Text.Encoding]::ASCII.GetBytes("HTTP/1.1 $Status Result`r`n${cors}Content-Type: application/json; charset=utf-8`r`nCache-Control: no-store`r`nContent-Length: $($body.Length)`r`nConnection: close`r`n`r`n")
    $Stream.Write($header,0,$header.Length); $Stream.Write($body,0,$body.Length)
}

function Get-BrowserKeywords {
    param($Config)
    foreach ($keyword in @(Get-NotificationValue $Config 'keywords' @())) {
        if ($keyword -is [string] -and $keyword.Trim()) { [pscustomobject]@{name=$keyword;terms=@($keyword)} }
    }
}

function Read-BrowserLedger {
    param([string]$Path, [datetimeoffset]$Now = [datetimeoffset]::UtcNow)
    $ledger = @{}
    if ([IO.File]::Exists($Path)) {
        # PS 5.1 emits a JSON array as one pipeline object. Wrapping that pipeline
        # in @() nests the array and stores arrays instead of mutable ledger entries.
        $items = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
        foreach ($entry in $items) {
            if ($null -ne $entry -and [datetime]::Parse($entry.Time).ToUniversalTime() -gt $Now.UtcDateTime.AddDays(-1)) { $ledger[[string]$entry.Id] = $entry }
        }
    }
    return ,$ledger
}

function Save-BrowserLedger {
    param([hashtable]$Ledger, [string]$Path)
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path))
    $temp = $Path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    try {
        [IO.File]::WriteAllText($temp, (ConvertTo-Json -InputObject @($Ledger.Values) -Depth 5), [Text.UTF8Encoding]::new($false))
        Set-NotificationAtomicFile -StagedPath $temp -DestinationPath $Path
    } finally { if ([IO.File]::Exists($temp)) { [IO.File]::Delete($temp) } }
}

function Invoke-BrowserAlertEvent {
    param($Event, $Config, [hashtable]$Ledger, [string]$LedgerPath, [switch]$NoSend, [datetimeoffset]$Now = [datetimeoffset]::UtcNow)
    $id = [string](Get-NotificationValue $Event 'eventId' '')
    $keyword = [string](Get-NotificationValue $Event 'keyword' '')
    $date = [datetimeoffset]::MinValue
    $allowedKeywords = @(Get-BrowserKeywords $Config | ForEach-Object { $_.name })
    if ($id -cnotmatch '^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}:[0-9]{1,8}$' -or $allowedKeywords -cnotcontains $keyword -or -not [datetimeoffset]::TryParse([string](Get-NotificationValue $Event 'createdAt' ''),[ref]$date)) {
        return @{Code=400;status='PermanentFailure';message='无效告警事件'}
    }
    if ($date -lt $Now.AddSeconds(-120) -or $date -gt $Now.AddSeconds(30)) { return @{Code=422;status='PermanentFailure';message='告警已过期，请检查电脑时间'} }
    if ($NoSend) { return @{Code=200;status='DryRun';message='仅检查事件，未发送且未写入告警记录'} }
    foreach ($old in @($Ledger.Keys)) { if ([datetime]::Parse($Ledger[$old].Time).ToUniversalTime() -lt $Now.UtcDateTime.AddDays(-1)) { $Ledger.Remove($old) } }
    if ($Ledger.ContainsKey($id)) {
        $entry = $Ledger[$id]
        if ($entry.Outcome -ne 'RetryableFailure') {
            $outcome = if ($entry.Outcome -eq 'Sending') {'Uncertain'} else {$entry.Outcome}
            return @{Code=200;status=$outcome;duplicate=$true;message='已处理此事件'}
        }
        if ($entry.Attempts -ge 3) { return @{Code=422;status='PermanentFailure';message='告警已达到重试上限'} }
        if ([datetime]::Parse($entry.Time).ToUniversalTime() -gt $Now.UtcDateTime.AddSeconds(-10)) { return @{Code=503;status='RetryableFailure';message='等待重试间隔'} }
    } else {
        if ($Ledger.Count -ge 5000) { return @{Code=503;status='RetryableFailure';message='告警记录已满，请检查频繁触发原因'} }
        $entry = [pscustomobject]@{Id=$id;Time=$Now.UtcDateTime.ToString('o');Attempts=0;Outcome='Sending'}
        $Ledger[$id] = $entry
    }
    $entry.Attempts++; $entry.Time=$Now.UtcDateTime.ToString('o'); $entry.Outcome='Sending'
    # Persist the in-flight marker before transmission: restart cannot send twice.
    try { Save-BrowserLedger $Ledger $LedgerPath }
    catch { $entry.Attempts--; $entry.Outcome='RetryableFailure'; return @{Code=503;status='RetryableFailure';message='本机记录写入失败，尚未发送'} }
    $outcome = 'Uncertain'
    try {
        $accepted = Send-MonitorNotification -Config $Config -Title '网页告警提醒' -Message '监控页面检测到新的业务告警，请打开电脑查看。' -IsAlarm -Outcome ([ref]$outcome)
        if ($accepted -isnot [bool] -or ($accepted -ne ($outcome -eq 'Success'))) { $outcome='Uncertain' }
    } catch { $outcome='Uncertain' }
    if ($outcome -notin @('Success','RetryableFailure','Uncertain','PermanentFailure')) { $outcome='Uncertain' }
    $entry.Outcome=$outcome
    try { Save-BrowserLedger $Ledger $LedgerPath } catch { $entry.Outcome='Uncertain'; $outcome='Uncertain' }
    $code = switch ($outcome) { 'RetryableFailure' {503} 'PermanentFailure' {422} default {200} }
    return @{Code=$code;status=$outcome;message=$(if ($outcome -eq 'Success') {'推送服务已接受'} else {'请检查推送设置与手机收件状态'})}
}
