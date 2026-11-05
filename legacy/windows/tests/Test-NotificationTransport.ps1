Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'NotificationTransport.ps1')

$script:Checks = 0
function Assert-NotificationTest {
    param([bool]$Condition, [string]$Name)
    if (-not $Condition) { throw ('FAILED: ' + $Name) }
    $script:Checks++
}
function Assert-NotificationRejected {
    param([scriptblock]$Action, [string]$Name)
    $rejected = $false
    try { $null = & $Action } catch { $rejected = $true }
    Assert-NotificationTest $rejected $Name
}

# Synthetic credentials only; neither real credentials nor messages leave this process.
$script:SafePassword = ConvertTo-SecureString 'TEST_ONLY_SMTP_PASSWORD' -AsPlainText -Force
$script:SafeWebhook = ConvertTo-SecureString 'https://oapi.dingtalk.com/robot/send?access_token=TEST_ONLY_NOT_A_REAL_TOKEN' -AsPlainText -Force
$script:SafeSecret = ConvertTo-SecureString 'SECtestsecret' -AsPlainText -Force
$script:MailSettings = @{ provider = 'qqmail'; smtpHost = 'smtp.qq.com'; smtpPort = 587; smtpFrom = 'test-sender@qq.com'; smtpTo = 'test-recipient@qq.com' }
$script:DingSettings = @{ provider = 'dingtalk'; dingTalkKeyword = '验证码' }
$script:MailSecrets = @{ smtpPassword = $script:SafePassword }
$script:DingSecrets = @{ dingTalkWebhook = $script:SafeWebhook; dingTalkSecret = $script:SafeSecret }
$script:LoadedSettings = [pscustomobject]@{ Settings = $script:MailSettings; Secrets = $script:MailSecrets }
$script:ReadFailure = $false
$script:SendFailure = $null
$script:SendCalls = 0
$script:Response = [pscustomobject]@{ errcode = 0; errmsg = 'ok' }

# Replace only I/O boundaries. The production message builder, validation,
# signing, disposal and outcome-classification functions all still execute.
function Read-NotificationConfiguration {
    param($Config)
    if ($script:ReadFailure) { throw 'TEST_ONLY_CREDENTIAL_MUST_NOT_BE_LOGGED' }
    return $script:LoadedSettings
}
function Invoke-NotificationSmtpSend {
    param($Client, $Mail)
    $script:SendCalls++
    Assert-NotificationTest ($Client.EnableSsl -and $Client.Timeout -eq 10000 -and $Client.Port -eq 587) 'SMTP client is TLS with bounded timeout'
    Assert-NotificationTest ($Mail.To.Count -eq 1 -and $Mail.Subject -ceq '验证码通知' -and $Mail.Body -ceq "验证码：001234`n测试内容") 'SMTP message retains Unicode and leading zero'
    if ($null -ne $script:SendFailure) { throw $script:SendFailure }
}
function Invoke-NotificationDingTalkSend {
    param($Request)
    $script:SendCalls++
    Assert-NotificationTest ($Request.Body -is [byte[]]) 'DingTalk sends UTF8 bytes'
    if ($null -ne $script:SendFailure) { throw $script:SendFailure }
    return $script:Response
}

function Assert-NotificationSend {
    param([string]$ExpectedOutcome, [int]$ExpectedCalls = 1)
    $before = $script:SendCalls
    $outcome = ''
    $outputs = @(Send-MonitorNotification -Config @{} -Title '验证码通知' -Message "验证码：001234`n测试内容" -Outcome ([ref]$outcome) *>&1)
    Assert-NotificationTest ($outputs.Count -eq 1 -and $outputs[0] -is [bool]) 'Only boolean output; no credential-bearing error stream'
    Assert-NotificationTest ($outputs[0] -eq ($ExpectedOutcome -eq 'Success')) 'Boolean result matches outcome'
    Assert-NotificationTest ($outcome -ceq $ExpectedOutcome) ('Outcome ' + $ExpectedOutcome)
    Assert-NotificationTest (($script:SendCalls - $before) -eq $ExpectedCalls) 'Exactly one attempt; no automatic hidden retries'
}

$mail = New-NotificationMailMessage -Settings $script:MailSettings -Title '验证码 001234' -Message "<b>001234</b>`n保留原文"
try {
    Assert-NotificationTest (-not $mail.IsBodyHtml) 'Mail is plain text'
    Assert-NotificationTest ($mail.SubjectEncoding.WebName -eq 'utf-8' -and $mail.BodyEncoding.WebName -eq 'utf-8') 'Mail has UTF8 headers and body'
    Assert-NotificationTest ($mail.Body.Contains('<b>001234</b>')) 'Mail does not interpret message as HTML'
} finally { $mail.Dispose() }

foreach ($badAddress in @('', 'invalid', 'a@example.com,b@example.com', 'a@example.com;b@example.com', 'Someone <a@example.com>', "a@example.com`r`nBcc: b@example.com")) {
    Assert-NotificationRejected { Get-NotificationMailAddress $badAddress } 'Reject invalid or multiple recipient address'
}
Assert-NotificationRejected { New-NotificationMailMessage -Settings $script:MailSettings -Title "bad`nheader" -Message 'test' } 'Reject title header injection'
Assert-NotificationRejected { Get-NotificationSecureValue @{ smtpPassword = 'plaintext' } 'smtpPassword' } 'Reject plaintext credential'
Assert-NotificationRejected { Get-NotificationSecureValue @{} 'smtpPassword' } 'Reject missing credential'
Assert-NotificationRejected { Get-NotificationSecureValue @{ smtpPassword = [System.Security.SecureString]::new() } 'smtpPassword' } 'Reject empty credential'
Assert-NotificationTest ($null -eq (Get-NotificationSecureValue @{} 'dingTalkSecret' -Optional)) 'Optional signing secret can be absent'

$customPath = Resolve-NotificationConfigPath @{ notificationSettingsFile = '04_资料/私密配置/custom.json' } 'notificationSettingsFile' 'unused'
Assert-NotificationTest ($customPath.StartsWith((Split-Path $PSScriptRoot -Parent)) -and $customPath.EndsWith('custom.json')) 'Relative configuration path uses project root'
$defaultPath = Resolve-NotificationConfigPath @{} 'notificationSettingsFile' '04_资料/私密配置/notification_settings.json'
Assert-NotificationTest ($defaultPath.EndsWith('notification_settings.json')) 'Default settings path'

Assert-NotificationSend 'Success'
$script:ReadFailure = $true
Assert-NotificationSend 'PermanentFailure' 0
$script:ReadFailure = $false
$script:LoadedSettings = [pscustomobject]@{ Settings = @{ provider = 'unsupported' }; Secrets = @{} }
Assert-NotificationSend 'PermanentFailure' 0
$script:LoadedSettings = [pscustomobject]@{ Settings = $script:MailSettings; Secrets = @{ smtpPassword = 'plaintext' } }
Assert-NotificationSend 'PermanentFailure' 0
$script:LoadedSettings = [pscustomobject]@{ Settings = $script:MailSettings; Secrets = $script:MailSecrets }
$script:MailSettings.smtpPort = 465
Assert-NotificationSend 'PermanentFailure' 0
$script:MailSettings.smtpPort = 587
$script:MailSettings.smtpHost = 'untrusted.example.com'
Assert-NotificationSend 'PermanentFailure' 0
$script:MailSettings.smtpHost = 'smtp.qq.com'

$script:SendFailure = [System.Net.Mail.SmtpException]::new([System.Net.Mail.SmtpStatusCode]535, 'TEST_ONLY_AUTH_CREDENTIAL')
Assert-NotificationSend 'PermanentFailure'
$script:SendFailure = [System.Net.Mail.SmtpException]::new([System.Net.Mail.SmtpStatusCode]450, 'TEST_ONLY_TEMPORARY')
Assert-NotificationSend 'RetryableFailure'
$script:SendFailure = [System.Net.Mail.SmtpException]::new('TEST_ONLY_TIMEOUT', [System.Net.WebException]::new('timeout', [System.Net.WebExceptionStatus]::Timeout))
Assert-NotificationSend 'Uncertain'
$script:SendFailure = [System.Net.Mail.SmtpException]::new('TEST_ONLY_DNS', [System.Net.Sockets.SocketException]::new(11001))
Assert-NotificationSend 'RetryableFailure'
$script:SendFailure = [System.Net.Mail.SmtpException]::new('TEST_ONLY_DISCONNECT', [System.Net.Sockets.SocketException]::new(10054))
Assert-NotificationSend 'Uncertain'
$script:SendFailure = $null

$request = New-NotificationDingTalkRequest -Settings $script:DingSettings -Secrets $script:DingSecrets -Title '测试通知' -Message '001234' -Timestamp '1700000000123'
# Expected signature independently calculated with Python's hmac/hashlib implementation.
$knownSignature = 'MhvU0gAL8Hb%2B7ixEIvwuAThiacacreSMo9LF952YiD8%3D'
Assert-NotificationTest ($request.Uri.EndsWith('&timestamp=1700000000123&sign=' + $knownSignature)) 'DingTalk signature matches independent fixed vector'
$body = [System.Text.Encoding]::UTF8.GetString($request.Body) | ConvertFrom-Json
Assert-NotificationTest ($body.msgtype -eq 'text' -and $body.text.content -ceq "验证码`n测试通知`n001234") 'DingTalk keyword, title and code'
Assert-NotificationTest (-not $body.at.isAtAll) 'No whole-group mention'
$request = New-NotificationDingTalkRequest -Settings $script:DingSettings -Secrets @{ dingTalkWebhook = $script:SafeWebhook } -Title '验证码通知' -Message '001234'
Assert-NotificationTest (-not $request.Uri.Contains('&sign=') -and -not $request.Uri.Contains('&timestamp=')) 'Keyword-only robot supported'
$body = [System.Text.Encoding]::UTF8.GetString($request.Body) | ConvertFrom-Json
Assert-NotificationTest ($body.text.content -ceq "验证码通知`n001234") 'Existing keyword is not duplicated'
foreach ($badWebhook in @('http://oapi.dingtalk.com/robot/send?access_token=TEST_ONLY_TOKEN', 'https://evil.example.com/robot/send?access_token=TEST_ONLY_TOKEN', 'https://oapi.dingtalk.com.evil.example.com/robot/send?access_token=TEST_ONLY_TOKEN', 'https://oapi.dingtalk.com/other?access_token=TEST_ONLY_TOKEN', 'https://oapi.dingtalk.com:8443/robot/send?access_token=TEST_ONLY_TOKEN', 'https://name@oapi.dingtalk.com/robot/send?access_token=TEST_ONLY_TOKEN', 'https://oapi.dingtalk.com/robot/send?access_token=TEST_ONLY_TOKEN&sign=stale', 'https://oapi.dingtalk.com/robot/send?access_token=TEST_ONLY_TOKEN#fragment')) {
    $badSecrets = @{ dingTalkWebhook = (ConvertTo-SecureString $badWebhook -AsPlainText -Force) }
    Assert-NotificationRejected { New-NotificationDingTalkRequest -Settings $script:DingSettings -Secrets $badSecrets -Title 'test' -Message 'test' } 'Reject noncanonical webhook or credential destination'
}

$script:LoadedSettings = [pscustomobject]@{ Settings = $script:DingSettings; Secrets = $script:DingSecrets }
Assert-NotificationSend 'Success'
foreach ($code in @(310000, 40014, 40035, 40036)) {
    $script:Response = [pscustomobject]@{ errcode = $code; errmsg = 'TEST_ONLY_SECRET_MUST_NOT_BE_LOGGED' }
    Assert-NotificationSend 'PermanentFailure'
}
foreach ($code in @(88, 130101)) {
    $script:Response = [pscustomobject]@{ errcode = $code }
    Assert-NotificationSend 'RetryableFailure'
}
foreach ($response in @([pscustomobject]@{ errmsg = 'unknown' }, [pscustomobject]@{ errcode = 'garbage' }, $null)) {
    $script:Response = $response
    Assert-NotificationSend 'Uncertain'
}
$script:Response = [pscustomobject]@{ errcode = 0 }
$script:SendFailure = [System.Net.WebException]::new('TEST_ONLY_URI_CREDENTIAL', [System.Net.WebExceptionStatus]::NameResolutionFailure)
Assert-NotificationSend 'RetryableFailure'
$script:SendFailure = [System.Net.WebException]::new('TEST_ONLY_URI_CREDENTIAL', [System.Net.WebExceptionStatus]::ConnectFailure)
Assert-NotificationSend 'RetryableFailure'
$script:SendFailure = [System.Net.WebException]::new('TEST_ONLY_URI_CREDENTIAL', [System.Net.WebExceptionStatus]::Timeout)
Assert-NotificationSend 'Uncertain'
$script:SendFailure = [System.Net.WebException]::new('TEST_ONLY_URI_CREDENTIAL', [System.Net.WebExceptionStatus]::TrustFailure)
Assert-NotificationSend 'PermanentFailure'
$script:SendFailure = $null

if ($null -eq ('NotificationTestHttpException' -as [type])) {
    Add-Type @'
using System;
public sealed class NotificationTestHttpResponse { public int StatusCode { get; set; } }
public sealed class NotificationTestHttpException : Exception {
    public NotificationTestHttpResponse Response { get; private set; }
    public NotificationTestHttpException(int status) : base("TEST_ONLY_URI_CREDENTIAL") { Response = new NotificationTestHttpResponse { StatusCode = status }; }
}
'@
}
foreach ($status in @(400, 401, 403, 404, 413)) {
    $script:SendFailure = [NotificationTestHttpException]::new($status)
    Assert-NotificationSend 'PermanentFailure'
}
$script:SendFailure = [NotificationTestHttpException]::new(429)
Assert-NotificationSend 'RetryableFailure'
foreach ($status in @(500, 502, 503, 504, 408)) {
    $script:SendFailure = [NotificationTestHttpException]::new($status)
    Assert-NotificationSend 'Uncertain'
}
$script:SendFailure = $null
Write-Output "PASS: $script:Checks notification transport assertions (PowerShell $($PSVersionTable.PSVersion)); all network sends mocked, no real messages sent."
