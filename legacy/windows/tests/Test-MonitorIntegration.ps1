# Run in a fresh Windows PowerShell 5.1 process. All screen, process, OCR,
# filesystem and notification effects below are fakes; no real configuration is read.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent
$script:passed = 0

function Assert-True {
    param([bool]$Condition, [string]$Name)
    if (-not $Condition) { throw "FAILED: $Name" }
    $script:passed++
}

function Read-TestAst {
    param([string]$Name)
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $projectRoot $Name), [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) { throw "Parse failed: $Name ($($errors[0].Message))" }
    return $ast
}

$mainAst = Read-TestAst 'Monitor-WindowKeywords.ps1'
$workerAst = Read-TestAst 'VerificationMonitor.ps1'
$allFunctions = @{}
foreach ($ast in @($mainAst, $workerAst)) {
    foreach ($node in $ast.FindAll({ param($item) $item -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
        $allFunctions[$node.Name] = $node.Extent.Text
    }
}
foreach ($name in @('Get-ConfigInt', 'Get-ConfigString', 'Get-ConfigBool', 'Get-ObjectNumberProperty', 'Test-TextPatternMatch', 'Get-TargetRectangle', 'Get-CaptureRectangle', 'Normalize-Text', 'Find-Keyword', 'Test-RequiredContext', 'Get-KeywordTerms', 'Count-TermOccurrences', 'Get-KeywordCounts', 'Get-KeywordLineCounts', 'Get-StableKeywordLineText', 'Get-KeywordFromLineKey', 'Get-TotalKeywordCount', 'Format-KeywordCounts', 'Start-VerificationMonitor')) {
    . ([scriptblock]::Create($allFunctions[$name]))
}

if ('Win32WindowTools' -as [type]) { throw 'Use a fresh PowerShell process: the fake window type must not replace a loaded native type.' }
Add-Type 'public static class Win32WindowTools { public static System.IntPtr Foreground = new System.IntPtr(101); public static System.IntPtr GetForegroundWindow() { return Foreground; } }'

function New-TestConfig {
    [pscustomobject]@{
        verificationCodeEnabled = $true
        verificationScanIntervalMs = 1000
        ocrLanguage = 'zh-Hans-CN'
        windowTitleContains = @('Synthetic remote')
        processNameContains = @('msedge')
        scanFullDesktopWhenNoWindow = $true
        captureCrop = [pscustomobject]@{ leftRatio = 0.2; topRatio = 0.3; rightRatio = 0.8; bottomRatio = 0.7 }
        verificationCaptureCrop = $null
        titleEventMode = $false
        bringTargetToFront = $false
        ocrScale = 1
        lastScreenshotFile = 'should-not-write.png'
        ocrTextFile = 'should-not-write.txt'
        triggerMode = 'cooldown'
        ocrLineMode = $false
        keywords = @('告警')
        keywordAliases = $null
        requiredContextAny = @()
        requiredContextAll = @()
        requireContext = $false
        ringExistingOnStart = $false
        repeatGapSeconds = 0
        cooldownSeconds = 1
    }
}

function Reset-TestFakes {
    $script:events = [System.Collections.Generic.List[string]]::new()
    $script:frames = [System.Collections.Generic.List[object]]::new()
    $script:scanConfigs = [System.Collections.Generic.List[object]]::new()
    $script:parentCalls = 0
    $script:parentMode = 'alive'
    $script:ocrFails = $false
    $script:foregroundChangesDuringOcr = $false
    $script:targetMissing = $false
    $script:ocrText = '验证码：001234'
    $script:ocrSequence = @()
    $script:alertOcrSequence = @()
    $script:alertReadCount = 0
    $script:alertWaitCount = 0
    $script:alertTransportOutcome = 'Success'
    $script:foreground = [IntPtr]101
    [Win32WindowTools]::Foreground = $script:foreground
    $script:windowList = @([pscustomobject]@{ Left = 100; Top = 200; Width = 1000; Height = 600; Title = 'Synthetic remote'; ProcessName = 'msedge'; Handle = [IntPtr]101 })
}

function Write-MonitorLog { param($Config, [string]$Message) [void]$script:events.Add('log'); [void]$script:events.Add('message:' + $Message) }
function New-OcrEngine { param($LanguageTag) [void]$script:events.Add('engine'); return [pscustomobject]@{ Fake = $true } }
function New-VerificationPushState { return [pscustomobject]@{ Fake = $true } }
function Reset-VerificationScanContinuity { param($State) [void]$script:events.Add('reset') }
function Get-TopLevelWindows {
    if ($script:targetMissing) { return @() }
    return $script:windowList
}
function Limit-RectangleToScreen { param($Rectangle) return $Rectangle }
function Read-VerificationRectangleText {
    param($Engine, $Rectangle)
    [void]$script:events.Add('ocr')
    [void]$script:frames.Add($Rectangle)
    if ($script:ocrFails) { throw [InvalidOperationException]::new('synthetic OCR failure') }
    if ($script:foregroundChangesDuringOcr) { [Win32WindowTools]::Foreground = [IntPtr]202 }
    if ($script:ocrSequence.Count -gt 0) { return $script:ocrSequence[$script:frames.Count - 1] }
    return $script:ocrText
}
function Invoke-VerificationCodeScan {
    param($Config, $State, $Text, [switch]$NoSend)
    [void]$script:events.Add('scan:' + [bool]$NoSend)
    if ($Text -cne $script:ocrText) { throw 'OCR text not passed through' }
}
function Get-Process {
    param([int]$Id)
    $script:parentCalls++
    if ($script:parentMode -eq 'missing' -or ($script:parentMode -eq 'exits' -and $script:events.Contains('sleep'))) { return $null }
    if ($script:parentMode -eq 'three-scans' -and @($script:events | Where-Object { $_ -eq 'sleep' }).Count -ge 3) { return $null }
    if ($script:parentMode -eq 'exits-during-ocr' -and $script:frames.Count -gt 0) { return $null }
    $started = [datetime]'2026-01-01T00:00:00'
    if ($script:parentMode -eq 'reused' -and $script:parentCalls -gt 1) { $started = $started.AddSeconds(1) }
    return [pscustomobject]@{ StartTime = $started }
}
function Start-Sleep { param($Milliseconds, $Seconds) [void]$script:events.Add('sleep'); if (@($script:events | Where-Object { $_ -eq 'sleep' }).Count -gt 3) { throw 'Unexpected unbounded test loop' } }

Reset-TestFakes
$config = New-TestConfig
$before = $config | ConvertTo-Json -Depth 10 -Compress
Start-VerificationMonitor -Config $config -Once -NoSend
Assert-True ($script:events.Contains('scan:True')) 'NoSend reaches the code scan'
Assert-True (@($script:events | Where-Object { $_ -eq 'ocr' }).Count -eq 1) 'Once captures exactly one frame'
Assert-True (-not $script:events.Contains('sleep')) 'Once does not wait for another frame'
Assert-True (($config | ConvertTo-Json -Depth 10 -Compress) -ceq $before) 'Verification does not mutate the alert config'
Assert-True ($script:frames[0].Left -eq 100 -and $script:frames[0].Width -eq 1000) 'Verification does not reuse the narrow alert crop'

Reset-TestFakes
$config = New-TestConfig
$config.verificationCaptureCrop = [pscustomobject]@{ leftRatio = 0.1; topRatio = 0.2; rightRatio = 0.9; bottomRatio = 0.8 }
Start-VerificationMonitor -Config $config -Once
Assert-True ($script:frames[0].Left -eq 200 -and $script:frames[0].Top -eq 320 -and $script:frames[0].Width -eq 800 -and $script:frames[0].Height -eq 360) 'Verification uses its configured crop'
Assert-True ($script:events.Contains('scan:False')) 'Normal worker allows notification delivery'

Reset-TestFakes
$config = New-TestConfig
$config.PSObject.Properties.Remove('captureCrop')
$config.PSObject.Properties.Remove('processNameContains')
$config.PSObject.Properties.Remove('scanFullDesktopWhenNoWindow')
Start-VerificationMonitor -Config $config -Once
Assert-True ($script:events.Contains('scan:False') -and $script:frames.Count -eq 1) 'Optional legacy capture settings may be absent'

Reset-TestFakes
$script:targetMissing = $true
Start-VerificationMonitor -Config (New-TestConfig) -Once
Assert-True ($script:frames.Count -eq 0 -and $script:events.Contains('reset')) 'Missing target cannot fall back to the full desktop'

Reset-TestFakes
$script:windowList[0].Title = 'Unrelated browser page'
Start-VerificationMonitor -Config (New-TestConfig) -Once
Assert-True ($script:frames.Count -eq 0 -and $script:events.Contains('reset')) 'Browser process match alone cannot authorize verification scanning'

Reset-TestFakes
[Win32WindowTools]::Foreground = [IntPtr]202
Start-VerificationMonitor -Config (New-TestConfig) -Once
Assert-True ($script:frames.Count -eq 0 -and $script:events.Contains('reset')) 'Background target breaks consecutive-frame confirmation'

Reset-TestFakes
$script:windowList += [pscustomobject]@{ Left = 50; Top = 50; Width = 1800; Height = 1000; Title = 'Synthetic remote background'; ProcessName = 'msedge'; Handle = [IntPtr]202 }
Start-VerificationMonitor -Config (New-TestConfig) -Once
Assert-True ($script:frames.Count -eq 1 -and $script:frames[0].Handle -eq [IntPtr]101) 'A larger background window cannot mask the matching foreground target'

Reset-TestFakes
$script:ocrFails = $true
Start-VerificationMonitor -Config (New-TestConfig) -Once
Assert-True ($script:events.Contains('reset') -and -not $script:events.Contains('scan:False')) 'OCR failure resets continuity without sending'

Reset-TestFakes
$script:foregroundChangesDuringOcr = $true
Start-VerificationMonitor -Config (New-TestConfig) -Once
Assert-True (-not $script:events.Contains('scan:False') -and $script:events.Contains('reset')) 'Foreground change during OCR discards the result'

Reset-TestFakes
$script:parentMode = 'exits-during-ocr'
Start-VerificationMonitor -Config (New-TestConfig) -ParentMonitorId 4242 -Once
Assert-True (-not $script:events.Contains('scan:False')) 'Parent exit during OCR prevents a late notification'

Reset-TestFakes
$config = New-TestConfig
$config.verificationCodeEnabled = $false
Start-VerificationMonitor -Config $config -Once
Assert-True ($script:events.Count -eq 0) 'Disabled verification returns without initializing OCR'

foreach ($mode in @('missing', 'reused')) {
    Reset-TestFakes
    $script:parentMode = $mode
    Start-VerificationMonitor -Config (New-TestConfig) -ParentMonitorId 4242
    Assert-True ($script:frames.Count -eq 0 -and -not $script:events.Contains('sleep')) "Worker exits when parent is $mode"
    if ($mode -eq 'missing') { Assert-True (-not $script:events.Contains('engine')) 'Worker does not initialize OCR for an already-dead parent' }
}
Reset-TestFakes
$script:parentMode = 'exits'
Start-VerificationMonitor -Config (New-TestConfig) -ParentMonitorId 4242
Assert-True ($script:frames.Count -eq 1 -and $script:events.Contains('scan:False')) 'Parent exit ends worker after the current scan'

# Check the real alert loop using its AST, with all effects replaced by fakes.
$mainTry = @($mainAst.EndBlock.Statements | Where-Object { $_ -is [System.Management.Automation.Language.TryStatementAst] -and $_.Extent.Text.Contains('while ($true)') })
Assert-True ($mainTry.Count -eq 1) 'Main alert loop remains a single guarded loop'
$script:alertLoop = [scriptblock]::Create('$PSScriptRoot = $projectRoot' + "`n" + $mainTry[0].Extent.Text)
function Save-Screenshot { param($Rectangle, $Path, $Scale) [void]$script:events.Add('screenshot') }
function Read-ConfiguredOcrText {
    param($Config, $Engine, $Path)
    if ($script:ocrFails) { throw 'synthetic OCR failure' }
    if ($script:alertOcrSequence.Count -gt 0) {
        $value = $script:alertOcrSequence[[Math]::Min($script:alertReadCount, $script:alertOcrSequence.Count - 1)]
        $script:alertReadCount++
        return $value
    }
    return $script:ocrText
}
function Protect-VerificationText { param($Text) return '[redacted synthetic OCR]' }
function Remove-Item { param($LiteralPath, [switch]$Force) [void]$script:events.Add('remove') }
function Copy-Item { param($LiteralPath, $Destination, [switch]$Force) [void]$script:events.Add('copy') }
function Set-Content { param($LiteralPath, $Value, $Encoding) [void]$script:events.Add('text:' + $Value) }
function Stop-PaddleOcrWorker { [void]$script:events.Add('stop-paddle') }
function Invoke-PhoneCall {
    param($Config, $Keyword)
    [void]$script:events.Add('alert:' + $Keyword)
    $script:LastNotificationOutcome = $script:alertTransportOutcome
    return $script:alertTransportOutcome -eq 'Success'
}
function Wait-MonitorInterval {
    param($Config)
    $script:alertWaitCount++
    if ($script:alertWaitCount -ge 2) { Set-Variable -Name Once -Value $true -Scope 1 }
    if ($script:alertWaitCount -gt 4) { throw 'Unexpected unbounded alert test loop' }
}
function Invoke-TestAlertLoop {
    param($Config, [switch]$Continuous)
    $Once = -not $Continuous
    $NoCall = $true
    $engine = $null
    $lastCallAt = [datetime]::MinValue
    $previousKeywordCounts = $null
    $previousKeywordLineCounts = $null
    $previousKeywordLineTotals = $null
    $zeroKeywordLineTotalCycles = 0
    $seenKeywordLineKeys = @{}
    $lastKeywordLineAttemptAt = @{}
    $lastNoNewLogAt = [datetime]::MinValue
    $lastNoTargetLogAt = [datetime]::MinValue
    $lastTitleEventId = 0
    $tempImage = 'synthetic-file-never-written.png'
    $verificationWorker = $null
    $monitorLocked = $false
    $monitorMutex = [System.IO.MemoryStream]::new()
    . $script:alertLoop
}

Reset-TestFakes
$script:ocrText = '告警：业务异常'
Invoke-TestAlertLoop (New-TestConfig)
Assert-True ($script:events.Contains('alert:告警')) 'Existing cooldown alert still triggers'
Assert-True (-not $script:events.Contains('copy')) 'Verification-enabled alert loop does not persist a screenshot copy'
Assert-True ($script:events.Contains('text:[redacted synthetic OCR]')) 'Alert OCR text is redacted before writing'
Assert-True ($script:events.Contains('remove') -and $script:events.Contains('stop-paddle')) 'Alert loop releases its temporary image and OCR worker'

Reset-TestFakes
$script:ocrText = "告警：业务一`n告警：业务二"
$config = New-TestConfig
$config.triggerMode = 'new-occurrence'
$config.ocrLineMode = $true
Invoke-TestAlertLoop $config
Assert-True (@($script:events | Where-Object { $_ -like 'message:Error:*' }).Count -eq 0) 'New-occurrence baseline executes without errors'
Assert-True (-not $script:events.Contains('alert:告警')) 'Existing new-occurrence baseline does not ring on startup'

Reset-TestFakes
$script:ocrFails = $true
Invoke-TestAlertLoop (New-TestConfig)
Assert-True (-not $script:events.Contains('alert:告警') -and $script:events.Contains('remove')) 'Failed alert OCR cleans the screenshot and does not trigger'

Reset-TestFakes
$config = New-TestConfig
$config.triggerMode = 'new-occurrence'
$config.ocrLineMode = $true
$config | Add-Member -NotePropertyName 'retryFailedTriggerSeconds' -NotePropertyValue 0
$script:alertOcrSequence = @('ordinary text', '告警：业务异常', '告警：业务异常')
$script:alertTransportOutcome = 'Uncertain'
Invoke-TestAlertLoop -Config $config -Continuous
Assert-True ($script:alertReadCount -eq 3) 'Uncertain-delivery regression exercises baseline, new event and unchanged event'
Assert-True (@($script:events | Where-Object { $_ -like 'message:Error:*' }).Count -eq 0) 'Uncertain-delivery regression executes the actual alert loop without errors'
Assert-True (@($script:events | Where-Object { $_ -eq 'alert:告警' }).Count -eq 1) 'Uncertain ordinary alert is not resent for an unchanged occurrence'

Reset-TestFakes
$config = New-TestConfig
$config.triggerMode = 'new-occurrence'
$config.ocrLineMode = $true
$config | Add-Member -NotePropertyName 'retryFailedTriggerSeconds' -NotePropertyValue 0
$script:alertOcrSequence = @('ordinary text', '告警：业务异常', '告警：业务异常')
$script:alertTransportOutcome = 'RetryableFailure'
Invoke-TestAlertLoop -Config $config -Continuous
Assert-True (@($script:events | Where-Object { $_ -eq 'alert:告警' }).Count -eq 2) 'Definite ordinary alert failure still permits a retry'

Reset-TestFakes
$config = New-TestConfig
$config.triggerMode = 'new-occurrence'
$config.ocrLineMode = $true
$config | Add-Member -NotePropertyName 'retryFailedTriggerSeconds' -NotePropertyValue 0
$script:alertOcrSequence = @('ordinary text', '告警：业务一', "告警：业务一`n告警：业务二")
$script:alertTransportOutcome = 'Uncertain'
Invoke-TestAlertLoop -Config $config -Continuous
Assert-True (@($script:events | Where-Object { $_ -eq 'alert:告警' }).Count -eq 2) 'A genuinely new ordinary alert can send after an earlier uncertain outcome'

Reset-TestFakes
. ([scriptblock]::Create($allFunctions['Invoke-PhoneCall']))
$NoCall = $true
$result = Invoke-PhoneCall -Config (New-TestConfig) -Keyword '告警'
Assert-True ($result -and $script:events.Contains('log')) 'Actual NoCall returns simulated success before calling a transport'

$mainText = $mainAst.Extent.Text
$workerText = $workerAst.Extent.Text
Assert-True ($mainText.IndexOf('if ($LibraryOnly) { return }') -lt $mainText.IndexOf('$config = Read-Config')) 'LibraryOnly returns before config is read'
Assert-True ($mainText.Contains('-ParentMonitorId $PID -NoSend:$NoCall')) 'Main forwards process identity and NoCall to the verification worker'
Assert-True ($mainText.Contains("'verificationCodeEnabled' `$false) -and -not `$Once")) 'Main Once mode does not spawn a long-lived child'
Assert-True ($workerText.Contains('$psi.CreateNoWindow = $true')) 'Verification worker is started without a visible PowerShell window'
Assert-True ($allFunctions['Read-VerificationRectangleText'].Contains('InMemoryRandomAccessStream') -and -not $allFunctions['Read-VerificationRectangleText'].Contains('WriteAllBytes')) 'Verification OCR uses an in-memory image stream'

# Exercise the actual worker -> extraction -> confirmation -> generic notification
# connection. Only the final transport is faked; the input contains synthetic data.
foreach ($name in @('VerificationCode.ps1', 'VerificationPush.ps1', 'NotificationTransport.ps1')) {
    [void](Read-TestAst $name)
    Assert-True ($mainText.Contains(". (Join-Path `$PSScriptRoot '$name')")) "Main loads the $name dependency"
}
. (Join-Path $projectRoot 'VerificationCode.ps1')
. (Join-Path $projectRoot 'VerificationPush.ps1')
function Send-MonitorNotification {
    param($Config, [string]$Title, [string]$Message, [ref]$Outcome)
    [void]$script:deliveries.Add([pscustomobject]@{ Title = $Title; Message = $Message })
    $Outcome.Value = 'Success'
    return $true
}
Reset-TestFakes
$script:deliveries = [System.Collections.Generic.List[object]]::new()
$script:parentMode = 'three-scans'
$script:ocrSequence = @('Synthetic login page', '验证码：001234，请勿泄露。', '验证码：001234，请勿泄露。')
Start-VerificationMonitor -Config (New-TestConfig) -ParentMonitorId 4242
Assert-True ($script:frames.Count -eq 3 -and $script:deliveries.Count -eq 1) 'Actual modules confirm two frames and deliver exactly once after baseline'
Assert-True ($script:deliveries[0].Title.Contains('001234') -and $script:deliveries[0].Message.Contains('001234')) 'Phone title and body both contain the recognized code'
Assert-True (-not $script:deliveries[0].Message.Contains('请勿泄露')) 'Notification excludes surrounding OCR evidence'
Assert-True (@($script:events | Where-Object { $_ -like '*001234*' }).Count -eq 0) 'Worker and push logs do not expose the code'

Write-Output "PASS: $script:passed monitor integration assertions (synthetic inputs only; no capture, config read or external delivery)."
