# Browser support tests: synthetic input, mocked transport, and isolated local ledger files.
$ErrorActionPreference='Stop'
$project=Split-Path $PSScriptRoot -Parent
. (Join-Path $project 'NotificationTransport.ps1')
. (Join-Path $project 'BrowserAlertSupport.ps1')
$script:BrowserChecks=0
$script:BrowserFailures=New-Object System.Collections.Generic.List[string]
$script:BrowserSends=0
$script:BrowserSaves=0
$script:BrowserSaveMode='Success'
$script:BrowserSendOutcome='Success'
$script:BrowserAccepted=$true
$script:BrowserDisk='[]'
$script:BrowserAlarmFlag=$false
$script:OriginalBrowserSave=${function:Save-BrowserLedger}
function Assert-Browser {
    param([bool]$Condition,[string]$Label)
    $script:BrowserChecks++
    if(-not $Condition){$script:BrowserFailures.Add($Label)}
}
function New-BrowserTestEvent {
    param([datetimeoffset]$CreatedAt=[datetimeoffset]::UtcNow,[int]$Sequence=1)
    return @{eventId=('11111111-2222-4333-8444-555555555555:'+$Sequence);keyword='告警';createdAt=$CreatedAt.ToString('o');sourceBody='PRIVATE_BODY_MUST_NOT_LEAVE';url='https://private.example.invalid/mail'}
}
function Reset-BrowserMocks {
    $script:BrowserSends=0;$script:BrowserSaves=0;$script:BrowserSaveMode='Success';$script:BrowserSendOutcome='Success';$script:BrowserAccepted=$true;$script:BrowserDisk='[]';$script:BrowserAlarmFlag=$false
}
function Save-BrowserLedger {
    param([hashtable]$Ledger,[string]$Path)
    $script:BrowserSaves++
    if($script:BrowserSaveMode -eq 'Before' -or ($script:BrowserSaveMode -eq 'After' -and $script:BrowserSaves -ge 2)){throw 'Synthetic ledger write failure.'}
    $script:BrowserDisk=ConvertTo-Json -InputObject @($Ledger.Values) -Depth 8 -Compress
}
function Send-MonitorNotification {
    param($Config,[string]$Title,[string]$Message,[ref]$Outcome,[switch]$IsAlarm)
    $script:BrowserSends++
    $script:BrowserAlarmFlag=[bool]$IsAlarm
    Assert-Browser ($script:BrowserDisk -match 'Sending') 'in-flight event is durably checkpointed before outgoing send'
    Assert-Browser (($Title+$Message) -notmatch 'PRIVATE_BODY|private\.example|sourceBody|http') 'mail body and URL never enter outgoing notification'
    if($script:BrowserSendOutcome -eq 'Throw'){throw 'Synthetic PRIVATE_BODY transport error.'}
    $Outcome.Value=$script:BrowserSendOutcome
    return $script:BrowserAccepted
}
$config=@{keywords=@('告警')}
$ledger=@{}
$event=New-BrowserTestEvent
$before=$ledger|ConvertTo-Json -Depth 6 -Compress
$dry=Invoke-BrowserAlertEvent -Event $event -Config $config -Ledger $ledger -LedgerPath 'unused' -NoSend
Assert-Browser (($ledger|ConvertTo-Json -Depth 6 -Compress) -ceq $before -and $script:BrowserSaves -eq 0 -and $script:BrowserSends -eq 0) 'NoSend leaves real dedupe and ledger untouched'
Assert-Browser ($dry.status -eq 'DryRun') 'NoSend does not falsely report delivered success'
$emptyFailure=$false
try{$empty=Invoke-BrowserAlertEvent -Event $event -Config @{keywords=@()} -Ledger @{} -LedgerPath 'unused'}catch{$emptyFailure=$true}
Assert-Browser (-not $emptyFailure) 'empty keyword configuration returns validation result instead of throwing'
if(-not $emptyFailure){Assert-Browser ($empty.Code -eq 400) 'empty keyword configuration rejects an unconfigured keyword'}

Reset-BrowserMocks
$script:BrowserSaveMode='Before'
$ledger=@{}
$failed=Invoke-BrowserAlertEvent -Event $event -Config $config -Ledger $ledger -LedgerPath 'unused'
Assert-Browser ($failed.status -eq 'RetryableFailure' -and $script:BrowserSends -eq 0) 'pre-send persistence failure prevents all outgoing sends'
Assert-Browser ($ledger[$event.eventId].Attempts -eq 0) 'disk failures do not consume actual transmission attempts'

function Assert-BrowserRejected {
    param([scriptblock]$Action,[string]$Label)
    $rejected=$false
    try{[void](& $Action)}catch{$rejected=$true}
    Assert-Browser $rejected $Label
}
if($null -eq ('BrowserChunkedMemoryStream' -as [type])) {
    Add-Type @'
using System;
using System.IO;
public sealed class BrowserChunkedMemoryStream : MemoryStream {
    private readonly int chunk;
    public BrowserChunkedMemoryStream(byte[] data, int maximumChunk) : base(data) { chunk=maximumChunk; }
    public override int Read(byte[] buffer, int offset, int count) { return base.Read(buffer, offset, Math.Min(chunk,count)); }
}
'@
}
function Invoke-BrowserParser {
    param([byte[]]$Bytes,[int]$Chunk=1)
    $stream=[BrowserChunkedMemoryStream]::new($Bytes,$Chunk)
    try{return Read-BrowserHttpRequest -Stream $stream}finally{$stream.Dispose()}
}
function New-BrowserRequestBytes {
    param([string]$Headers,[byte[]]$Body=@())
    return [byte[]]([Text.Encoding]::ASCII.GetBytes($Headers)+$Body)
}
$bodyText='{"keyword":"告警正文","note":"保留中文"}'
$bodyBytes=[Text.Encoding]::UTF8.GetBytes($bodyText)
$requestBytes=New-BrowserRequestBytes -Headers ("POST /event HTTP/1.1`r`nHost: 127.0.0.1`r`nContent-Length: "+$bodyBytes.Length+"`r`nContent-Type: application/json`r`n`r`n") -Body $bodyBytes
$parsed=Invoke-BrowserParser $requestBytes
Assert-Browser ($parsed.Method -eq 'POST' -and $parsed.Path -eq '/event' -and $parsed.Body -ceq $bodyText) 'single-byte segmented body preserves multibyte UTF8 characters'
Assert-Browser (-not $parsed.Headers.ContainsKey('x-monitor-token')) 'parser leaves missing-token authorization to the server wrapper'
Assert-Browser ($parsed.Headers['content-length'] -eq [string]$bodyBytes.Length) 'content length counts bytes rather than Unicode characters'
$get=Invoke-BrowserParser (New-BrowserRequestBytes "GET /health HTTP/1.1`r`nHost: localhost`r`n`r`n")
Assert-Browser ($get.Method -eq 'GET' -and $get.Body -eq '') 'GET without body parses'
$options=Invoke-BrowserParser (New-BrowserRequestBytes "OPTIONS /event HTTP/1.1`r`nHost: localhost`r`n`r`n")
Assert-Browser ($options.Method -eq 'OPTIONS') 'preflight OPTIONS parses'
foreach($badRequest in @(
    "POST /event HTTP/1.1`r`nContent-Length: 2`r`ncontent-length: 2`r`n`r`n{}",
    "GET /health HTTP/1.1`r`nHost: one`r`nHOST: two`r`n`r`n",
    "POST /event HTTP/1.1`r`nContent-Length: 2`r`nTransfer-Encoding: chunked`r`n`r`n{}",
    "POST /event HTTP/1.1`r`nContent-Length: 2049`r`n`r`n",
    "POST /event HTTP/1.1`r`nContent-Length: 999999999999999999`r`n`r`n",
    "POST /event HTTP/1.1`r`nContent-Length: -1`r`n`r`n",
    "POST /event HTTP/1.1`r`nContent-Length: +2`r`n`r`n{}",
    "POST /event HTTP/1.1`r`nContent-Length: 3`r`n`r`n{}",
    "POST /event HTTP/1.1`r`nHost: localhost`r`n`r`n",
    "GET /health HTTP/1.1`r`nHost: localhost",
    "PUT /event HTTP/1.1`r`nContent-Length: 2`r`n`r`n{}",
    ("GET /health HTTP/1.1`r`nX-Large: "+('a'*8200)+"`r`n`r`n"))) {
    Assert-BrowserRejected {Invoke-BrowserParser (New-BrowserRequestBytes $badRequest)} 'invalid framing, duplicate header, incomplete body, or size violation rejected'
}
Assert-BrowserRejected {Invoke-BrowserParser (New-BrowserRequestBytes "POST /event HTTP/1.1`r`nContent-Length: 2`r`n`r`n" ([byte[]]@(0xc3,0x28)))} 'invalid UTF8 fails instead of silently replacing bytes'
$maximum=Invoke-BrowserParser (New-BrowserRequestBytes "POST /event HTTP/1.1`r`nContent-Length: 2048`r`n`r`n" ([Text.Encoding]::UTF8.GetBytes('a'*2048)))
Assert-Browser ($maximum.Body.Length -eq 2048) 'maximum permitted body accepted even when segmented'
$responseStream=[IO.MemoryStream]::new()
try {
    Write-BrowserHttpResponse -Stream $responseStream -Status 200 -Data @{message='告警已处理'} -Origin ('chrome-extension://'+('a'*32))
    $responseText=[Text.Encoding]::UTF8.GetString($responseStream.ToArray())
    $parts=$responseText -split "`r`n`r`n",2
    Assert-Browser ($parts[0] -match 'Cache-Control: no-store' -and $parts[0] -match 'Access-Control-Allow-Origin: chrome-extension://a{32}') 'HTTP response disallows caching and allows exact extension origin'
    [void]($parts[0] -match 'Content-Length: ([0-9]+)')
    Assert-Browser ([int]$Matches[1] -eq [Text.Encoding]::UTF8.GetByteCount($parts[1])) 'response content length is UTF8 byte length'
}finally{$responseStream.Dispose()}
$responseStream=[IO.MemoryStream]::new()
try {
    Write-BrowserHttpResponse -Stream $responseStream -Status 403 -Data @{status='denied'} -Origin "https://evil.example.invalid`r`nInjected: true"
    Assert-Browser ([Text.Encoding]::UTF8.GetString($responseStream.ToArray()) -notmatch 'Access-Control-Allow-Origin|Injected') 'untrusted origin cannot inject response headers'
}finally{$responseStream.Dispose()}

$epoch=[datetimeoffset]'2026-09-07T12:00:00Z'
$event=New-BrowserTestEvent $epoch
Reset-BrowserMocks
$ledger=@{}
$result=Invoke-BrowserAlertEvent -Event $event -Config $config -Ledger $ledger -LedgerPath 'unused' -Now $epoch
Assert-Browser ($result.status -eq 'Success' -and $script:BrowserAlarmFlag -and $script:BrowserSaves -eq 2 -and $script:BrowserSends -eq 1) 'new event writes before and after exactly one explicit alarm send'
Assert-Browser ($ledger[$event.eventId].Attempts -eq 1 -and $ledger[$event.eventId].Outcome -eq 'Success') 'successful event records one completed attempt'
$result=Invoke-BrowserAlertEvent -Event $event -Config $config -Ledger $ledger -LedgerPath 'unused' -Now $epoch.AddSeconds(1)
Assert-Browser ($result.duplicate -and $result.status -eq 'Success' -and $script:BrowserSends -eq 1) 'same event ID is never sent twice after success'
$nextEvent=New-BrowserTestEvent $epoch 2
[void](Invoke-BrowserAlertEvent -Event $nextEvent -Config $config -Ledger $ledger -LedgerPath 'unused' -Now $epoch.AddSeconds(2))
Assert-Browser ($script:BrowserSends -eq 2) 'new event with unchanged keyword has independent delivery state'
Assert-Browser (($script:BrowserDisk+($result|ConvertTo-Json -Compress)) -notmatch 'PRIVATE_BODY|private\.example|sourceBody|https://') 'ledger and response never persist or reveal source page body or URL'

foreach($scenario in @('Uncertain','Throw','PermanentFailure','Unknown','FalseSuccess','TrueFailure')) {
    Reset-BrowserMocks
    $ledger=@{}
    $script:BrowserAccepted=$false
    $script:BrowserSendOutcome=$scenario
    if($scenario -eq 'FalseSuccess'){$script:BrowserSendOutcome='Success'}
    if($scenario -eq 'TrueFailure'){$script:BrowserSendOutcome='RetryableFailure';$script:BrowserAccepted=$true}
    $first=Invoke-BrowserAlertEvent -Event $event -Config $config -Ledger $ledger -LedgerPath 'unused' -Now $epoch
    $second=Invoke-BrowserAlertEvent -Event $event -Config $config -Ledger $ledger -LedgerPath 'unused' -Now $epoch.AddSeconds(10)
    $expected=if($scenario -eq 'PermanentFailure'){'PermanentFailure'}else{'Uncertain'}
    Assert-Browser ($first.status -eq $expected -and $second.status -eq $expected -and $script:BrowserSends -eq 1) ($scenario+' remains terminal and cannot cause duplicate delivery')
}
Reset-BrowserMocks
$ledger=@{};$script:BrowserAccepted=$false;$script:BrowserSendOutcome='RetryableFailure'
[void](Invoke-BrowserAlertEvent -Event $event -Config $config -Ledger $ledger -LedgerPath 'unused' -Now $epoch)
$tooSoon=Invoke-BrowserAlertEvent -Event $event -Config $config -Ledger $ledger -LedgerPath 'unused' -Now $epoch.AddSeconds(9)
Assert-Browser ($tooSoon.Code -eq 503 -and $script:BrowserSends -eq 1) 'explicit failure waits ten full seconds before retry'
[void](Invoke-BrowserAlertEvent -Event $event -Config $config -Ledger $ledger -LedgerPath 'unused' -Now $epoch.AddSeconds(10))
[void](Invoke-BrowserAlertEvent -Event $event -Config $config -Ledger $ledger -LedgerPath 'unused' -Now $epoch.AddSeconds(20))
$exhausted=Invoke-BrowserAlertEvent -Event $event -Config $config -Ledger $ledger -LedgerPath 'unused' -Now $epoch.AddSeconds(30)
Assert-Browser ($exhausted.Code -eq 422 -and $script:BrowserSends -eq 3 -and $ledger[$event.eventId].Attempts -eq 3) 'three actual transmission attempts exhaust event retries'
Reset-BrowserMocks
$ledger=@{};$script:BrowserSaveMode='Before'
[void](Invoke-BrowserAlertEvent -Event $event -Config $config -Ledger $ledger -LedgerPath 'unused' -Now $epoch)
$script:BrowserSaveMode='Success'
$recovered=Invoke-BrowserAlertEvent -Event $event -Config $config -Ledger $ledger -LedgerPath 'unused' -Now $epoch.AddSeconds(10)
Assert-Browser ($recovered.status -eq 'Success' -and $ledger[$event.eventId].Attempts -eq 1) 'fixed disk failure allows the first actual send without lost retry quota'
Reset-BrowserMocks
$ledger=@{};$script:BrowserSaveMode='After'
$uncertain=Invoke-BrowserAlertEvent -Event $event -Config $config -Ledger $ledger -LedgerPath 'unused' -Now $epoch
Assert-Browser ($uncertain.status -eq 'Uncertain' -and $script:BrowserDisk -match 'Sending') 'post-send persistence failure preserves durable uncertain crash marker'
[void](Invoke-BrowserAlertEvent -Event $event -Config $config -Ledger $ledger -LedgerPath 'unused' -Now $epoch.AddSeconds(10))
Assert-Browser ($script:BrowserSends -eq 1) 'post-send persistence failure is never automatically resent'

Reset-BrowserMocks
foreach($offset in @(-121,31)) {
    $invalidDate=New-BrowserTestEvent $epoch.AddSeconds($offset)
    $rejected=Invoke-BrowserAlertEvent -Event $invalidDate -Config $config -Ledger @{} -LedgerPath 'unused' -Now $epoch
    Assert-Browser ($rejected.Code -eq 422 -and $script:BrowserSends -eq 0 -and $script:BrowserSaves -eq 0) 'expired or future-dated event rejected before persistence and sending'
}
$malformed=New-BrowserTestEvent $epoch;$malformed.eventId=('a'*36)+':1'
$invalidId=Invoke-BrowserAlertEvent -Event $malformed -Config $config -Ledger @{} -LedgerPath 'unused' -Now $epoch
Assert-Browser ($invalidId.Code -eq 400) 'event ID must have canonical UUID separators'
$malformed=New-BrowserTestEvent $epoch;$malformed.keyword='未配置关键字'
Assert-Browser ((Invoke-BrowserAlertEvent -Event $malformed -Config $config -Ledger @{} -LedgerPath 'unused' -Now $epoch).Code -eq 400) 'unconfigured keyword rejected'
$malformed=New-BrowserTestEvent $epoch;$malformed.createdAt='invalid'
Assert-Browser ((Invoke-BrowserAlertEvent -Event $malformed -Config $config -Ledger @{} -LedgerPath 'unused' -Now $epoch).Code -eq 400) 'invalid creation time rejected'
$fullLedger=@{}
for($index=0;$index -lt 5000;$index++){$fullLedger['existing-'+$index]=[pscustomobject]@{Id=('existing-'+$index);Time=$epoch.UtcDateTime.ToString('o');Attempts=1;Outcome='Success'}}
$fullResult=Invoke-BrowserAlertEvent -Event $event -Config $config -Ledger $fullLedger -LedgerPath 'unused' -Now $epoch
Assert-Browser ($fullResult.Code -eq 503 -and $script:BrowserSends -eq 0 -and $fullLedger.Count -eq 5000) 'full retained ledger rejects new events without evicting successful dedupe history'
$fullLedger['existing-0'].Time=$epoch.AddDays(-2).UtcDateTime.ToString('o')
$slotResult=Invoke-BrowserAlertEvent -Event $event -Config $config -Ledger $fullLedger -LedgerPath 'unused' -Now $epoch
Assert-Browser ($slotResult.status -eq 'Success' -and $fullLedger.Count -eq 5000) 'expired ledger entry frees capacity for a valid new event'

# Real local crash recovery: only event ID/time/attempt/outcome reach the isolated file.
$fixtureRoot=Join-Path $project '04_资料\夜间告警升级_20260907'
$fixture=[IO.Path]::GetFullPath((Join-Path $fixtureRoot ('browser-tests-'+[guid]::NewGuid().ToString('N'))))
[void][IO.Directory]::CreateDirectory($fixture)
$ledgerFile=Join-Path $fixture 'ledger.json'
try {
    $crashLedger=@{}
    $crashLedger[$event.eventId]=[pscustomobject]@{Id=$event.eventId;Time=$epoch.UtcDateTime.ToString('o');Attempts=1;Outcome='Sending'}
    & $script:OriginalBrowserSave -Ledger $crashLedger -Path $ledgerFile
    $restored=Read-BrowserLedger -Path $ledgerFile -Now $epoch.AddSeconds(1)
    Reset-BrowserMocks
    $crashResult=Invoke-BrowserAlertEvent -Event $event -Config $config -Ledger $restored -LedgerPath $ledgerFile -Now $epoch.AddSeconds(1)
    Assert-Browser ($crashResult.status -eq 'Uncertain' -and $crashResult.duplicate -and $script:BrowserSends -eq 0) 'restart treats durable Sending as uncertain and never sends again'
    $restored[$event.eventId].Outcome='Success'
    & $script:OriginalBrowserSave -Ledger $restored -Path $ledgerFile
    $loaded=Read-BrowserLedger -Path $ledgerFile -Now $epoch.AddSeconds(2)
    Assert-Browser ($loaded[$event.eventId].Outcome -eq 'Success') 'second atomic save and reload retain completed outcome'
    Assert-Browser ($loaded[$event.eventId] -is [pscustomobject] -and $loaded[$event.eventId] -isnot [array]) 'PowerShell 5.1 restores an individual mutable entry rather than nested JSON array'
    $loaded[$event.eventId].Outcome='RetryableFailure'
    $otherEvent=New-BrowserTestEvent $epoch 2
    $loaded[$otherEvent.eventId]=[pscustomobject]@{Id=$otherEvent.eventId;Time=$epoch.UtcDateTime.ToString('o');Attempts=1;Outcome='Success'}
    & $script:OriginalBrowserSave -Ledger $loaded -Path $ledgerFile
    $retryRestored=Read-BrowserLedger -Path $ledgerFile -Now $epoch.AddSeconds(10)
    Assert-Browser ($retryRestored.Count -eq 2 -and $retryRestored.ContainsKey($otherEvent.eventId)) 'multiple persisted entries are restored under separate event IDs'
    Reset-BrowserMocks
    $retryResult=Invoke-BrowserAlertEvent -Event $event -Config $config -Ledger $retryRestored -LedgerPath $ledgerFile -Now $epoch.AddSeconds(10)
    Assert-Browser ($retryResult.status -eq 'Success' -and $retryRestored[$event.eventId].Attempts -eq 2 -and $script:BrowserSends -eq 1) 'explicit failed event can mutate and retry correctly after restart'
    Assert-Browser ([IO.File]::ReadAllText($ledgerFile) -notmatch 'PRIVATE_BODY|private\.example|keyword|sourceBody') 'real ledger file stores no page contents or keyword'
    $expiredLedger=Read-BrowserLedger -Path $ledgerFile -Now $epoch.AddDays(2)
    Assert-Browser ($expiredLedger.Count -eq 0) 'restart drops ledger entries older than one day'
    Assert-Browser (@([IO.Directory]::GetFiles($fixture,'*.tmp')).Count -eq 0) 'atomic ledger save cleans staging files'
}finally{
    $allowedRoot=[IO.Path]::GetFullPath($fixtureRoot).TrimEnd('\')+'\'
    if(-not $fixture.StartsWith($allowedRoot,[StringComparison]::OrdinalIgnoreCase)){throw 'Unexpected fixture cleanup target.'}
    Remove-Item -LiteralPath $fixture -Recurse -Force
}

if($script:BrowserFailures.Count -gt 0){foreach($failure in $script:BrowserFailures){Write-Host ('FAIL: '+$failure)};throw ('Browser support failures: '+$script:BrowserFailures.Count)}
Write-Host ('PASS: {0} browser support checks; synthetic inputs and mocked sends only.' -f $script:BrowserChecks)
