# All transport is mocked. This test does not read live configuration or send notifications.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'VerificationPush.ps1')
$script:Checks = 0
$script:Requests = New-Object System.Collections.Generic.List[object]
$script:Logs = New-Object System.Collections.Generic.List[string]
$script:TransportMode = 'Success'

function Assert-True {
    param([bool]$Condition, [string]$Label)
    if (-not $Condition) { throw ('FAIL: ' + $Label) }
    $script:Checks++
}
function Write-MonitorLog { param($Config, [string]$Message) $script:Logs.Add($Message) }
function Get-VerificationCodes {
    param([string]$Text)
    if ($Text -eq 'parser-error') { throw 'Synthetic parser failure' }
    foreach ($match in [regex]::Matches($Text, 'OTP:([A-Za-z0-9]{4,10})')) {
        [pscustomobject]@{ Code = $match.Groups[1].Value; Evidence = $Text; Kind = 'mock' }
    }
}
function Send-MonitorNotification {
    [CmdletBinding()]
    param($Config, [string]$Title, [string]$Message, [ref]$Outcome)
    $script:Requests.Add([pscustomobject]@{
        Title = $Title; Message = $Message
    })
    switch ($script:TransportMode) {
        'Failure' { $Outcome.Value = 'RetryableFailure'; return $false }
        'Timeout' { $Outcome.Value = 'Uncertain'; return $false }
        'Exception' { throw 'Synthetic error containing fake-token 456789 private@example.invalid' }
        'NoOutcome' { return $true }
        'Inconsistent' { $Outcome.Value = 'Success'; return $false }
        'Permanent' { $Outcome.Value = 'PermanentFailure'; return $false }
        'Success' { $Outcome.Value = 'Success'; return $true }
    }
}
function New-TestConfig {
    return [pscustomobject]@{
        verificationCodeEnabled = $true; verificationCodePushExistingOnStart = $false
    }
}
function Invoke-At {
    param($State, [string]$Text, [int]$Seconds, $Config = $script:Config, [switch]$NoSend)
    return Invoke-VerificationCodeScan -Config $Config -State $State -Text $Text -Now $script:Epoch.AddSeconds($Seconds) -NoSend:$NoSend
}
$script:Epoch = [datetime]'2026-09-07T12:00:00'
$script:Config = New-TestConfig

$state = New-VerificationPushState
Assert-True (-not (Invoke-At $state 'OTP:123456' 0)) 'startup baseline is not sent'
[void](Invoke-At $state 'OTP:123456' 1)
Assert-True ($script:Requests.Count -eq 0) 'baseline stays suppressed'
[void](Invoke-At $state 'OTP:456789' 2)
Assert-True ($script:Requests.Count -eq 0) 'one frame is insufficient'
Assert-True (Invoke-At $state 'OTP:456789' 3) 'new code with unchanged count is sent after two frames'
[void](Invoke-At $state 'OTP:456789' 4)
[void](Invoke-At $state '' 5)
[void](Invoke-At $state 'OTP:456789' 6)
[void](Invoke-At $state 'OTP:456789' 7)
Assert-True ($script:Requests.Count -eq 1) 'same code stays suppressed across a brief disappearance'
Assert-True ($state.Entries['456789'].Status -eq 'Sent') 'empty screen does not erase successful delivery'
$request = $script:Requests[0]
Assert-True ($request.Title -ceq '验证码：456789') 'Chinese title prominently includes code'
Assert-True ($request.Message -eq "验证码：456789`n识别时间：2026-09-07 12:00:02") 'body contains only code and first recognition time'

$startExisting = New-TestConfig
$startExisting.verificationCodePushExistingOnStart = $true
$state = New-VerificationPushState
$before = $script:Requests.Count
[void](Invoke-At $state 'OTP:123456' 0 $startExisting)
Assert-True ($script:Requests.Count -eq $before) 'opt-in existing code still needs two frames'
Assert-True (Invoke-At $state 'OTP:123456' 1 $startExisting) 'opt-in existing code is sent'

$state = New-VerificationPushState
[void](Invoke-At $state '' 0)
Reset-VerificationScanContinuity -State $state
Assert-True (-not $state.Initialized) 'missing/empty first scan does not consume baseline'
[void](Invoke-At $state 'ordinary text' 1)
Assert-True ($state.Initialized) 'valid non-code screen establishes empty baseline'
[void](Invoke-At $state 'OTP:234567' 2)
Reset-VerificationScanContinuity -State $state
Assert-True (-not (Invoke-At $state 'OTP:234567' 3)) 'interruption breaks two-frame continuity'
Assert-True (Invoke-At $state 'OTP:234567' 4) 'two fresh consecutive frames recover'

$state = New-VerificationPushState
$snapshot = $state | ConvertTo-Json -Depth 5 -Compress
$before = $script:Requests.Count
[void](Invoke-At $state 'OTP:234567' 0 $script:Config -NoSend)
[void](Invoke-At $state 'OTP:234567' 1 $script:Config -NoSend)
Assert-True (($state | ConvertTo-Json -Depth 5 -Compress) -ceq $snapshot) 'NoSend has no state side effects'
Assert-True ($script:Requests.Count -eq $before) 'NoSend never invokes transport'
$disabled = [pscustomobject]@{}
[void](Invoke-At $state 'OTP:234567' 2 $disabled)
Assert-True (($state | ConvertTo-Json -Depth 5 -Compress) -ceq $snapshot) 'missing enabled setting is backward-compatible off'
[void](Invoke-At $state 'ordinary text' 3)
[void](Invoke-At $state 'OTP:234567' 4)
$snapshot = $state | ConvertTo-Json -Depth 5 -Compress
[void](Invoke-At $state 'OTP:234567' 5 $script:Config -NoSend)
Assert-True (($state | ConvertTo-Json -Depth 5 -Compress) -ceq $snapshot) 'NoSend never consumes pending notification'
Assert-True (Invoke-At $state 'OTP:234567' 6) 'real scan can deliver pending notification after dry run'

$state = New-VerificationPushState
$script:TransportMode = 'Failure'
$before = $script:Requests.Count
[void](Invoke-At $state 'ordinary text' 0)
[void](Invoke-At $state 'OTP:345678' 1)
Assert-True (-not (Invoke-At $state 'OTP:345678' 2)) 'definite failure is not success'
Assert-True ($state.Entries['345678'].Status -eq 'Pending') 'definite failure preserves pending state'
[void](Invoke-At $state 'OTP:345678' 11)
Assert-True ($script:Requests.Count -eq ($before + 1)) 'retry waits at least ten seconds'
$script:TransportMode = 'Success'
Assert-True (Invoke-At $state 'OTP:345678' 12) 'definite failure retries and succeeds'
Assert-True ($state.Entries['345678'].Attempts -eq 2) 'retry attempt recorded exactly once'

$state = New-VerificationPushState
$script:TransportMode = 'Failure'
$before = $script:Requests.Count
[void](Invoke-At $state 'ordinary text' 0)
[void](Invoke-At $state 'OTP:456789' 1)
foreach ($second in @(2, 11, 12, 21, 22, 31, 32, 120)) { [void](Invoke-At $state 'OTP:456789' $second) }
Assert-True ($script:Requests.Count -eq ($before + 3)) 'total send attempts capped at three'
Assert-True ($state.Entries['456789'].Status -eq 'Expired') 'attempt exhaustion is terminal'
$state = New-VerificationPushState
[void](Invoke-At $state 'ordinary text' 0)
[void](Invoke-At $state 'OTP:567890' 1)
[void](Invoke-At $state 'OTP:567890' 2)
$before = $script:Requests.Count
[void](Invoke-At $state 'OTP:567890' 121)
Assert-True ($script:Requests.Count -eq $before -and $state.Entries['567890'].Status -eq 'Expired') '120-second lifetime prevents stale retry'

foreach ($mode in @('Timeout', 'Exception', 'NoOutcome', 'Inconsistent')) {
    $script:TransportMode = $mode
    $state = New-VerificationPushState
    $before = $script:Requests.Count
    [void](Invoke-At $state 'ordinary text' 0)
    [void](Invoke-At $state 'OTP:678901' 1)
    Assert-True (-not (Invoke-At $state 'OTP:678901' 2)) ($mode + ' is not a confirmed success')
    [void](Invoke-At $state 'OTP:678901' 12)
    Assert-True ($script:Requests.Count -eq ($before + 1) -and $state.Entries['678901'].Status -eq 'Uncertain') ($mode + ' does not cause automatic duplicates')
}
$script:TransportMode = 'Success'
$state = New-VerificationPushState
[void](Invoke-At $state 'ordinary text' 0)
[void](Invoke-At $state 'OTP:789012 OTP:890123' 1)
$before = $script:Requests.Count
[void](Invoke-At $state 'OTP:789012 OTP:890123' 2)
Assert-True ($script:Requests.Count -eq ($before + 2)) 'multiple codes have independent state'
[void](Invoke-At $state 'ordinary text' 601)
Assert-True ($state.Entries.Count -eq 2) 'dedupe retained during absence less than ten minutes'
[void](Invoke-At $state 'ordinary text' 602)
Assert-True ($state.Entries.Count -eq 0) 'absent codes are purged at ten minutes'

$state = New-VerificationPushState
[void](Invoke-At $state 'ordinary text' 0)
[void](Invoke-At $state 'OTP:901234' 1)
[void](Invoke-At $state 'parser-error' 2)
Assert-True (-not (Invoke-At $state 'OTP:901234' 3)) 'parser failure breaks continuity'
Assert-True (Invoke-At $state 'OTP:901234' 4) 'parser recovery requires fresh stable frames'

$config = New-TestConfig
Assert-True (Send-VerificationNotification -Config $config -Code 'AB1234') 'alphanumeric code can be sent'
Assert-True (-not (Send-VerificationNotification -Config $config -Code "1234`nTitle:bad")) 'code header injection rejected'
$config.verificationCodeEnabled = $false
Assert-True (-not (Send-VerificationNotification -Config $config -Code '123456')) 'direct production send observes enabled setting'
Assert-True (Send-VerificationNotification -Config $config -Code '123456' -IsTest) 'explicit test can verify transport when feature is disabled'
Assert-True ($script:Requests[$script:Requests.Count - 1].Title -eq '测试验证码：123456') 'explicit test is visibly marked'
$script:Config = New-TestConfig
$state = New-VerificationPushState
$script:TransportMode = 'Permanent'
[void](Invoke-At $state 'ordinary text' 0)
[void](Invoke-At $state 'OTP:678901' 1)
$before = $script:Requests.Count
[void](Invoke-At $state 'OTP:678901' 2)
[void](Invoke-At $state 'OTP:678901' 12)
Assert-True ($script:Requests.Count -eq ($before + 1) -and $state.Entries['678901'].Status -eq 'PermanentFailure') 'permanent failure is not retried'
Assert-True (($script:Logs -join "`n") -notmatch 'fake-token|456789|example\.invalid|OTP:') 'logs contain no addresses, token, code or OCR evidence'

# Regression: letters are part of the credential and their case is significant.
$script:TransportMode = 'Success'
$state = New-VerificationPushState
[void](Invoke-At $state 'ordinary text' 0)
[void](Invoke-At $state 'OTP:A1b2' 1)
[void](Invoke-At $state 'OTP:A1b2' 2)
$before = $script:Requests.Count
[void](Invoke-At $state 'OTP:A1B2' 3)
Assert-True (Invoke-At $state 'OTP:A1B2' 4) 'case-distinct code is independently delivered'
Assert-True ($script:Requests.Count -eq $before + 1 -and $state.Entries.Count -eq 2) 'dedupe preserves case-distinct keys'
$state = New-VerificationPushState
[void](Invoke-At $state 'ordinary text' 0)
[void](Invoke-At $state 'OTP:A1b2 OTP:A1B2' 1)
$before = $script:Requests.Count
[void](Invoke-At $state 'OTP:A1b2 OTP:A1B2' 2)
Assert-True ($script:Requests.Count -eq $before + 2) 'same-frame case-distinct candidates are not collapsed'

# A long pause is not consecutive evidence, even when no blank scan was received.
$state = New-VerificationPushState
[void](Invoke-At $state 'ordinary text' 0)
[void](Invoke-At $state 'OTP:123456' 1)
Assert-True (-not (Invoke-At $state 'OTP:123456' 31)) 'long observation gap breaks confirmation'
Assert-True (Invoke-At $state 'OTP:123456' 32) 'fresh pair after long gap can deliver'

$state = New-VerificationPushState
[void](Invoke-At $state 'ordinary text' 0)
[void](Invoke-At $state 'OTP:123456' 10)
Assert-True (-not (Invoke-At $state 'OTP:123456' 9)) 'backward wall-clock adjustment breaks confirmation'
Assert-True (Invoke-At $state 'OTP:123456' 10) 'confirmation recovers after clock adjustment'

$script:ConfigurationVersion = 'version-1'
function Get-NotificationConfigurationVersion { param($Config) return $script:ConfigurationVersion }
$state = New-VerificationPushState
$script:TransportMode = 'Permanent'
[void](Invoke-At $state 'ordinary text' 0)
[void](Invoke-At $state 'OTP:234567' 1)
[void](Invoke-At $state 'OTP:234567' 2)
$before = $script:Requests.Count
$script:TransportMode = 'Success'
[void](Invoke-At $state 'OTP:234567' 12)
Assert-True ($script:Requests.Count -eq $before) 'permanent failure stays terminal until configuration changes'
$script:ConfigurationVersion = 'version-2'
Assert-True (-not (Invoke-At $state 'OTP:234567' 13)) 'changed settings require a fresh confirmation pair'
Assert-True (Invoke-At $state 'OTP:234567' 14) 'corrected settings recover a definite configuration failure'
$before = $script:Requests.Count
$script:ConfigurationVersion = 'version-3'
[void](Invoke-At $state 'OTP:234567' 15)
[void](Invoke-At $state 'OTP:234567' 16)
Assert-True ($script:Requests.Count -eq $before) 'settings changes never resend successful codes'

$state = New-VerificationPushState
$script:TransportMode = 'Timeout'
[void](Invoke-At $state 'ordinary text' 0)
[void](Invoke-At $state 'OTP:345678' 1)
[void](Invoke-At $state 'OTP:345678' 2)
$before = $script:Requests.Count
$script:ConfigurationVersion = 'version-4'
$script:TransportMode = 'Success'
[void](Invoke-At $state 'OTP:345678' 13)
[void](Invoke-At $state 'OTP:345678' 14)
Assert-True ($script:Requests.Count -eq $before) 'settings changes do not retry an uncertain prior send'

$state = New-VerificationPushState
$script:TransportMode = 'Permanent'
[void](Invoke-At $state 'ordinary text' 0)
[void](Invoke-At $state 'OTP:456789' 1)
[void](Invoke-At $state 'OTP:456789' 2)
$before = $script:Requests.Count
$script:ConfigurationVersion = 'version-5'
$script:TransportMode = 'Success'
[void](Invoke-At $state 'OTP:456789' 121)
[void](Invoke-At $state 'OTP:456789' 122)
Assert-True ($script:Requests.Count -eq $before) 'configuration correction does not revive an expired code'

foreach ($invalidCode in @('123456789', '1234567890', 'ABCD', 'ABCDEFGHIJ')) {
    $before = $script:Requests.Count
    Assert-True (-not (Send-VerificationNotification -Config (New-TestConfig) -Code $invalidCode)) 'direct API rejects candidates outside the extraction contract'
    Assert-True ($script:Requests.Count -eq $before) 'invalid direct candidate never reaches transport'
}
$state = New-VerificationPushState
[void](Invoke-At $state 'ordinary text' 0)
[void](Invoke-At $state 'OTP:123456789 OTP:ABCD' 1)
[void](Invoke-At $state 'OTP:123456789 OTP:ABCD' 2)
Assert-True ($state.Entries.Count -eq 0) 'invalid parser output does not create pending delivery entries'

$state = New-VerificationPushState
$script:TransportMode = 'Failure'
[void](Invoke-At $state 'ordinary text' 0)
[void](Invoke-At $state 'OTP:567890' 100)
[void](Invoke-At $state 'OTP:567890' 101)
$before = $script:Requests.Count
$script:TransportMode = 'Success'
[void](Invoke-At $state 'OTP:567890' 50)
[void](Invoke-At $state 'OTP:567890' 59)
Assert-True ($script:Requests.Count -eq $before) 'clock rollback preserves the ten-second retry cooldown'
Assert-True (Invoke-At $state 'OTP:567890' 60) 'clock rollback does not freeze retries until the old timestamp'

$state = New-VerificationPushState
$script:TransportMode = 'Permanent'
[void](Invoke-At $state 'ordinary text' 0)
[void](Invoke-At $state 'OTP:678901' 1)
$before = $script:Requests.Count
[void](Invoke-At $state 'OTP:678901' 2)
foreach ($attempt in 1..3) {
    $script:ConfigurationVersion = 'configuration-correction-' + $attempt
    [void](Invoke-At $state 'OTP:678901' (10 * $attempt + 2))
    [void](Invoke-At $state 'OTP:678901' (10 * $attempt + 3))
}
Assert-True ($script:Requests.Count -eq $before + 3 -and $state.Entries['678901'].Attempts -eq 3) 'repeated configuration changes cannot bypass the total retry budget'

Write-Host ('PASS: {0} verification push checks; all {1} requests mocked; no real notifications sent.' -f $script:Checks, $script:Requests.Count)
