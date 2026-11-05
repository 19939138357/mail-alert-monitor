# Windows PowerShell 5.1 compatible. Dot-source after VerificationCode.ps1.
# This module never persists OCR text, verification codes, or notification secrets.

function Get-VerificationSetting {
    param($Config, [string]$Name, $DefaultValue)
    if ($null -eq $Config) { return $DefaultValue }
    if ($Config -is [System.Collections.IDictionary]) {
        if ($Config.Contains($Name) -and $null -ne $Config[$Name]) { return $Config[$Name] }
        return $DefaultValue
    }
    $property = $Config.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) { return $DefaultValue }
    return $property.Value
}

function Get-VerificationBoolean {
    param($Config, [string]$Name, [bool]$DefaultValue = $false)
    try { return [System.Convert]::ToBoolean((Get-VerificationSetting $Config $Name $DefaultValue)) }
    catch { return $DefaultValue }
}

function Write-VerificationPushLog {
    param($Config, [string]$Message)
    if (Get-Command Write-MonitorLog -CommandType Function -ErrorAction SilentlyContinue) {
        # A logging failure must not turn an acknowledged send into a retry.
        try { Write-MonitorLog $Config $Message | Out-Null } catch { }
    }
}

function New-VerificationPushState {
    return [pscustomobject]@{ Initialized = $false; LastScanAt = $null; DeliveryVersion = $null; Entries = [System.Collections.Hashtable]::new([StringComparer]::Ordinal) }
}

function Reset-VerificationScanContinuity {
    param([Parameter(Mandatory = $true)]$State)
    foreach ($entry in $State.Entries.Values) { $entry.Consecutive = 0 }
}

function Send-VerificationNotification {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Config,
        [Parameter(Mandatory = $true)][string]$Code,
        [switch]$IsTest,
        [datetime]$RecognizedAt = (Get-Date),
        [ref]$Outcome
    )
    if ($null -ne $Outcome) { $Outcome.Value = 'NotSent' }
    if (-not $IsTest -and -not (Get-VerificationBoolean $Config 'verificationCodeEnabled' $false)) { return $false }
    # Guard direct callers. No OCR evidence enters this function.
    if ($Code -cnotmatch '^[A-Za-z0-9]{4,8}$' -or $Code -cnotmatch '[0-9]') {
        if ($null -ne $Outcome) { $Outcome.Value = 'PermanentFailure' }
        Write-VerificationPushLog $Config 'Verification push rejected: invalid code format.'
        return $false
    }
    if (-not (Get-Command Send-MonitorNotification -CommandType Function -ErrorAction SilentlyContinue)) {
        if ($null -ne $Outcome) { $Outcome.Value = 'PermanentFailure' }
        Write-VerificationPushLog $Config 'Verification push unavailable: notification module not loaded.'
        return $false
    }
    $label = '验证码'
    if ($IsTest) { $label = '测试验证码' }
    $title = '{0}：{1}' -f $label, $Code
    $message = '{0}：{1}' -f $label, $Code
    $message += "`n识别时间：" + $RecognizedAt.ToString('yyyy-MM-dd HH:mm:ss')
    try {
        $deliveryOutcome = 'Uncertain'
        $accepted = Send-MonitorNotification -Config $Config -Title $title -Message $message -Outcome ([ref]$deliveryOutcome)
        if ($accepted -and $deliveryOutcome -eq 'Success') {
            if ($null -ne $Outcome) { $Outcome.Value = 'Success' }
            Write-VerificationPushLog $Config 'Verification push accepted by notification channel: count=1.'
            return $true
        }
        # Only the transport can establish that a failure happened before acceptance.
        if ($deliveryOutcome -notin @('RetryableFailure', 'PermanentFailure')) { $deliveryOutcome = 'Uncertain' }
        if ($null -ne $Outcome) { $Outcome.Value = $deliveryOutcome }
        if ($deliveryOutcome -eq 'RetryableFailure') {
            Write-VerificationPushLog $Config 'Verification push failed before acceptance; bounded retry allowed.'
        }
        else { Write-VerificationPushLog $Config 'Verification push unconfirmed or unavailable; automatic retry suppressed.' }
        return $false
    }
    catch {
        if ($null -ne $Outcome) { $Outcome.Value = 'Uncertain' }
        Write-VerificationPushLog $Config 'Verification push result uncertain; automatic retry suppressed.'
        return $false
    }
}

function Invoke-VerificationCodeScan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Config,
        [Parameter(Mandatory = $true)]$State,
        [AllowEmptyString()][AllowNull()][string]$Text,
        [switch]$NoSend,
        [datetime]$Now = (Get-Date)
    )
    # Dry runs and disabled scans must never consume real baseline/delivery state.
    if ($NoSend -or -not (Get-VerificationBoolean $Config 'verificationCodeEnabled' $false)) { return $false }
    if ($null -ne $State.LastScanAt -and $Now -lt $State.LastScanAt) {
        # Preserve elapsed lifetimes when Windows corrects its wall clock backwards.
        $clockShift = $Now - $State.LastScanAt
        foreach ($entry in $State.Entries.Values) {
            $entry.FirstSeen = $entry.FirstSeen.Add($clockShift)
            $entry.LastSeen = $entry.LastSeen.Add($clockShift)
            if ($null -ne $entry.LastAttempt) { $entry.LastAttempt = $entry.LastAttempt.Add($clockShift) }
        }
        Reset-VerificationScanContinuity -State $State
    }
    $State.LastScanAt = $Now
    $intervalMs = 1000
    try { $intervalMs = [Math]::Max(500, [int](Get-VerificationSetting $Config 'verificationScanIntervalMs' 1000)) } catch { }
    $confirmationGapSeconds = [Math]::Max(5.0, $intervalMs * 3.0 / 1000.0)
    if (Get-Command Get-NotificationConfigurationVersion -CommandType Function -ErrorAction SilentlyContinue) {
        try {
            $deliveryVersion = [string](Get-NotificationConfigurationVersion -Config $Config)
            if (-not [string]::IsNullOrEmpty($deliveryVersion)) {
                if ($null -ne $State.DeliveryVersion -and $State.DeliveryVersion -cne $deliveryVersion) {
                    foreach ($entry in $State.Entries.Values) {
                        # Only a definite rejection may be retried after settings are fixed.
                        # Preserve the original age and attempt budget; sent/uncertain stay terminal.
                        if ($entry.Status -eq 'PermanentFailure' -and $entry.Attempts -lt 3 -and ($Now - $entry.FirstSeen).TotalSeconds -lt 120) {
                            $entry.Status = 'Pending'
                            $entry.Consecutive = 0
                        }
                    }
                }
                $State.DeliveryVersion = $deliveryVersion
            }
        }
        catch { } # A transient version read must not turn terminal deliveries into retries.
    }
    foreach ($key in @($State.Entries.Keys)) {
        if (($Now - $State.Entries[$key].LastSeen).TotalSeconds -ge 600) { $State.Entries.Remove($key) }
    }
    if ([string]::IsNullOrWhiteSpace($Text)) {
        Reset-VerificationScanContinuity -State $State
        return $false
    }
    if (-not (Get-Command Get-VerificationCodes -CommandType Function -ErrorAction SilentlyContinue)) {
        Reset-VerificationScanContinuity -State $State
        Write-VerificationPushLog $Config 'Verification extraction unavailable; scan skipped.'
        return $false
    }
    $codes = [System.Collections.Hashtable]::new([StringComparer]::Ordinal)
    try {
        foreach ($candidate in @(Get-VerificationCodes -Text $Text)) {
            if ($null -eq $candidate) { continue }
            $code = [string]$candidate.Code
            if ($code -cmatch '^[A-Za-z0-9]{4,8}$' -and $code -cmatch '[0-9]') { $codes[$code] = $true }
        }
    }
    catch {
        Reset-VerificationScanContinuity -State $State
        Write-VerificationPushLog $Config 'Verification extraction failed; scan skipped.'
        return $false
    }
    $baseline = -not $State.Initialized -and -not (Get-VerificationBoolean $Config 'verificationCodePushExistingOnStart' $false)
    $State.Initialized = $true
    foreach ($key in @($State.Entries.Keys)) {
        if (-not $codes.ContainsKey($key)) { $State.Entries[$key].Consecutive = 0 }
    }
    $sentAny = $false
    foreach ($code in $codes.Keys) {
        if (-not $State.Entries.ContainsKey($code)) {
            $status = 'Pending'
            if ($baseline) { $status = 'Baseline' }
            $State.Entries[$code] = [pscustomobject]@{
                Status = $status
                FirstSeen = $Now
                LastSeen = $Now
                Consecutive = 0
                Attempts = 0
                LastAttempt = $null
            }
        }
        $entry = $State.Entries[$code]
        if (($Now - $entry.LastSeen).TotalSeconds -gt $confirmationGapSeconds) { $entry.Consecutive = 0 }
        $entry.LastSeen = $Now
        $entry.Consecutive = [Math]::Min(2, $entry.Consecutive + 1)
        if ($entry.Status -ne 'Pending') { continue }
        if (($Now - $entry.FirstSeen).TotalSeconds -ge 120 -or $entry.Attempts -ge 3) {
            $entry.Status = 'Expired'
            Write-VerificationPushLog $Config 'Verification push retry window exhausted: count=1.'
            continue
        }
        if ($entry.Consecutive -lt 2) { continue }
        if ($null -ne $entry.LastAttempt -and ($Now - $entry.LastAttempt).TotalSeconds -lt 10) { continue }
        $entry.Attempts++
        $entry.LastAttempt = $Now
        $outcome = 'NotSent'
        $success = Send-VerificationNotification -Config $Config -Code $code -RecognizedAt $entry.FirstSeen -Outcome ([ref]$outcome)
        if ($success) {
            $entry.Status = 'Sent'
            $sentAny = $true
        }
        elseif ($outcome -ne 'RetryableFailure') {
            $entry.Status = $outcome
        }
    }
    if ($baseline) { Write-VerificationPushLog $Config ('Verification baseline established: count={0}.' -f $codes.Count) }
    return $sentAny
}
