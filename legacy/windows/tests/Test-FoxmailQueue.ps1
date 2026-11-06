param()
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'FoxmailQueue.ps1')
$nativeProtection = $env:OS -eq 'Windows_NT'
if ($nativeProtection) { Add-Type -AssemblyName System.Security }
else {
    # The portable queue protocol is also exercised on non-Windows; DPAPI runs on Windows only.
    function Protect-FoxmailQueue([byte[]]$Bytes) { return ,$Bytes }
    function Unprotect-FoxmailQueue([byte[]]$Bytes) { return ,$Bytes }
}
$dir = Join-Path $root ('../../.build/queue-tests/' + [guid]::NewGuid().ToString('N'))
$path = [IO.Path]::GetFullPath((Join-Path $dir 'synthetic.dpapi'))
$script:checks=0; $script:reads=0; $script:sends=0; $script:complete=$true; $script:outcome='Success'
$script:version='one'; $script:visible=@(); $script:intentSeen=$false; $script:captured=''
function Assert($condition,[string]$label) { if (-not $condition) { throw $label }; $script:checks++ }
function Ticket($key) { [pscustomobject]@{ Key=$key; Subject='合成标题'; Sender='author@example.org'; Time='08:01' } }
function Get-FoxmailScreenUnread($Config,$Engine) { return $script:visible }
function Get-FoxmailOpenContent($Config,$Engine,$Ticket,[switch]$ResumeOnly) {
    $script:reads++
    $persisted = Read-FoxmailQueue $path
    $record = @($persisted.Items | Where-Object {$_.Ticket -and $_.Ticket.Key -ceq $Ticket.Key})[0]
    Assert ($record.Status -eq 'reading') 'Read intent must be committed before opening'
    if ($script:reads -eq 1) { Assert ($persisted.Items.Count -eq 2) 'All visible tickets committed before opening any row' }
    $script:resumed=$ResumeOnly.IsPresent
    $identity = if ($Ticket.Key -eq 'alias') { 'first' } else { $Ticket.Key }
    [pscustomobject]@{Complete=$script:complete; Subject='合成完整标题'; Body="正文第一行`n第二行"; Sender=$Ticket.Sender; Time='2026-11-07 08:01'; Identity=$identity }
}
function Get-NotificationConfigurationVersion($Config) { return $script:version }
function Send-MonitorNotification($Config,$Title,$Message,[ref]$Outcome,[switch]$IsAlarm,[switch]$PreserveSubject) {
    $raw = [Text.Encoding]::UTF8.GetString((Unprotect-FoxmailQueue ([IO.File]::ReadAllBytes($path)))) | ConvertFrom-Json
    Assert (@($raw.Items | Where-Object Status -eq 'sending').Count -eq 1) 'Send intent durable before transport'
    Assert ($PreserveSubject -and $Title -ceq '合成完整标题' -and $Message.Contains("正文第一行`n第二行")) 'Original full subject and body reach transport'
    $script:sends++; $Outcome.Value=$script:outcome; return $script:outcome -eq 'Success'
}
function Tick($queue,[long]$time) { [void](Invoke-FoxmailQueueTick $queue @{} $null $path $time) }
try {
    $q=Read-FoxmailQueue $path
    $script:visible=@((Ticket 'first'),(Ticket 'second'))
    Tick $q 1
    Assert ($q.Items[0].Status -eq 'ready' -and $q.Items.Count -eq 2) 'Both tickets retained even after click'
    if ($nativeProtection) { Assert (-not [Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes($path)).Contains('正文第一行')) 'Windows queue encrypted at rest' }
    $q=Read-FoxmailQueue $path
    $script:visible=@()
    Tick $q 2
    Assert ($script:sends -eq 1 -and $q.Items[0].Status -eq 'accepted' -and $null -eq $q.Items[0].Mail) 'Restart delivers verified outbox without rereading'
    $script:complete=$false
    Tick $q 3
    Assert ($script:sends -eq 1 -and $q.Items[1].Status -eq 'review') 'Incomplete body never sent'
    $q=Read-FoxmailQueue $path
    $script:complete=$true
    Tick $q 12
    Assert ($script:resumed -and $q.Items[1].Status -eq 'ready') 'Resume must revalidate current or unread ticket'
    $script:outcome='Uncertain'
    Tick $q 13
    Assert ($q.Items[1].Status -eq 'uncertain') 'Unknown transport outcome quarantined'
    Tick $q 100
    Assert ($script:sends -eq 2) 'Unknown sends never automatically retried'
    $script:visible=@((Ticket 'alias'))
    Tick $q 110
    Assert ($q.Items[2].Status -eq 'duplicate' -and $script:sends -eq 2) 'Actual content identity deduplicates aliased screen ticket'
    $script:visible=@((Ticket 'other'))
    Tick $q 120
    $script:outcome='PermanentFailure'; Tick $q 121; Tick $q 500
    Assert ($q.Items[3].Status -eq 'rejected' -and $script:sends -eq 3) 'Channel rejection waits for configuration change'
    $script:version='two'; $script:outcome='RetryableFailure'
    Tick $q 501; Tick $q 507
    Assert ($q.Items[3].Status -eq 'ready' -and $script:sends -eq 4) 'Definite retryable rejection respects delay'
    $script:outcome='Success'; Tick $q 566
    Assert ($q.Items[3].Status -eq 'accepted' -and $script:sends -eq 5) 'Definite retry acknowledged once'
    $script:visible=@((Ticket 'same'),(Ticket 'same'))
    Tick $q 700
    Assert ($q.Items.Count -eq 4) 'Ambiguous rows never clicked'
    $q.Items[3].Status='sending'; Save-FoxmailQueue $q $path
    $q=Read-FoxmailQueue $path; Tick $q 1000
    Assert ($q.Items[3].Status -eq 'uncertain' -and $script:sends -eq 5) 'Crash after write-ahead intent cannot double send'
    [IO.File]::WriteAllText($path,'broken')
    $rejected=$false
    try { $null=Read-FoxmailQueue $path } catch { $rejected=$true }
    Assert $rejected 'Unreadable history cannot initialize empty'
    Write-Output ("PASS: {0} unread queue checks; simulated screen and transport; DPAPI={1}" -f $script:checks,$nativeProtection)
} finally {
    if ([IO.Directory]::Exists($dir)) { [IO.Directory]::Delete($dir,$true) }
}
