Set-StrictMode -Version Latest

function Get-NotificationValue {
    param($Object, [string]$Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
        return $Default
    }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $Default }
    return $property.Value
}

function Test-NotificationNightAlarmEnabled {
    param($Settings)
    try { return [Convert]::ToBoolean((Get-NotificationValue $Settings 'nightAlarmEnabled' $false)) }
    catch { return $false }
}

function Resolve-NotificationConfigPath {
    param($Config, [string]$Property, [string]$Default)
    $path = [string](Get-NotificationValue $Config $Property $Default)
    if ([string]::IsNullOrWhiteSpace($path)) { $path = $Default }
    if (-not [System.IO.Path]::IsPathRooted($path)) { $path = Join-Path $PSScriptRoot $path }
    return [System.IO.Path]::GetFullPath($path)
}

function Read-NotificationConfiguration {
    param($Config)
    $settingsPath = Resolve-NotificationConfigPath $Config 'notificationSettingsFile' '04_资料/私密配置/notification_settings.json'
    $secretsPath = Resolve-NotificationConfigPath $Config 'notificationSecretsFile' '04_资料/私密配置/notification_secrets.xml'
    if (-not (Test-Path -LiteralPath $secretsPath -PathType Leaf)) {
        throw [System.InvalidOperationException]::new('Notification settings are not configured.')
    }
    # Read the legacy public file FIRST. New saves commit the complete encrypted
    # snapshot first, so a concurrent reader can never pair old secrets with new settings.
    $settings = $null
    try { $settings = Get-Content -LiteralPath $settingsPath -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop } catch { }
    # Export-Clixml SecureString uses Windows DPAPI, bound to this computer/user.
    $secrets = Import-Clixml -LiteralPath $secretsPath -ErrorAction Stop
    if ($secrets -isnot [System.Collections.IDictionary]) { throw [System.InvalidOperationException]::new('Encrypted notification settings have an invalid format.') }
    $snapshot = Get-NotificationValue $secrets '_settings'
    if ($null -ne $snapshot) { $settings = $snapshot }
    if ($null -eq $settings) { throw [System.InvalidOperationException]::new('Notification settings are incomplete.') }
    return [pscustomobject]@{ Settings = $settings; Secrets = $secrets; Revision = [string](Get-NotificationValue $secrets '_revision' 'legacy') }
}

function Get-NotificationConfigurationVersion {
    param($Config)
    $parts = New-Object System.Collections.Generic.List[string]
    foreach ($definition in @(@('notificationSettingsFile', '04_资料/私密配置/notification_settings.json'), @('notificationSecretsFile', '04_资料/私密配置/notification_secrets.xml'))) {
        try {
            $path = Resolve-NotificationConfigPath $Config $definition[0] $definition[1]
            $parts.Add($path.ToLowerInvariant())
            if ([IO.File]::Exists($path)) {
                $info = [IO.FileInfo]::new($path)
                $parts.Add(('{0}:{1}' -f $info.Length, $info.LastWriteTimeUtc.Ticks))
            } else { $parts.Add('missing') }
        } catch { $parts.Add('unavailable') }
    }
    $hash = [Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes(($parts -join '|')))).Replace('-', '') }
    finally { $hash.Dispose() }
}

function Set-NotificationAtomicFile {
    param([string]$StagedPath, [string]$DestinationPath)
    # PS 5.1 marshals an ordinary $null argument to an empty string here.
    if ([IO.File]::Exists($DestinationPath)) { [IO.File]::Replace($StagedPath, $DestinationPath, [System.Management.Automation.Language.NullString]::Value) }
    else { [IO.File]::Move($StagedPath, $DestinationPath) }
}

function Save-NotificationConfiguration {
    [CmdletBinding()]
    param($Settings, [System.Collections.IDictionary]$Secrets, [string]$SettingsPath, [string]$SecretsPath, [string]$ExpectedRevision = '')
    $settingsFull = [IO.Path]::GetFullPath($SettingsPath)
    $secretsFull = [IO.Path]::GetFullPath($SecretsPath)
    if ($settingsFull -ieq $secretsFull) { throw [InvalidOperationException]::new('通知配置与加密凭据必须使用不同文件。') }
    $hash = [Security.Cryptography.SHA256]::Create()
    try { $mutexName = 'Local\OCRNotificationSettings-' + [BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes($secretsFull.ToLowerInvariant()))).Replace('-', '') }
    finally { $hash.Dispose() }
    $mutex = [Threading.Mutex]::new($false, $mutexName)
    $locked = $false
    $stagedSecrets = ''
    $stagedSettings = ''
    try {
        try { $locked = $mutex.WaitOne(5000) } catch [Threading.AbandonedMutexException] { $locked = $true }
        if (-not $locked) { throw [InvalidOperationException]::new('另一个设置窗口正在保存，请稍后重试。') }
        if ($ExpectedRevision -ne '') {
            $currentRevision = 'missing'
            if ([IO.File]::Exists($secretsFull)) {
                $current = Import-Clixml -LiteralPath $secretsFull -ErrorAction Stop
                $currentRevision = [string](Get-NotificationValue $current '_revision' 'legacy')
            }
            if ($currentRevision -cne $ExpectedRevision) { throw [InvalidOperationException]::new('设置已被另一个窗口修改，请关闭并重新打开此窗口后再保存。') }
        }
        [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($settingsFull))
        [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($secretsFull))
        $revision = [guid]::NewGuid().ToString('N')
        $snapshot = @{}
        foreach ($key in $Secrets.Keys) { $snapshot[$key] = $Secrets[$key] }
        $snapshot['_settings'] = $Settings
        $snapshot['_revision'] = $revision
        $stagedSecrets = Join-Path ([IO.Path]::GetDirectoryName($secretsFull)) ('.notification-' + $revision + '.xml.tmp')
        $stagedSettings = Join-Path ([IO.Path]::GetDirectoryName($settingsFull)) ('.notification-' + $revision + '.json.tmp')
        $snapshot | Export-Clixml -LiteralPath $stagedSecrets -Depth 8 -ErrorAction Stop
        $Settings | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $stagedSettings -Encoding UTF8 -ErrorAction Stop
        # Single atomic commit: transport loads the matching settings and secrets
        # from this one file. The JSON file remains a readable compatibility mirror.
        Set-NotificationAtomicFile -StagedPath $stagedSecrets -DestinationPath $secretsFull
        $mirrorUpdated = $true
        try { Set-NotificationAtomicFile -StagedPath $stagedSettings -DestinationPath $settingsFull }
        catch { $mirrorUpdated = $false }
        return [pscustomobject]@{ Revision = $revision; MirrorUpdated = $mirrorUpdated }
    }
    finally {
        foreach ($staged in @($stagedSecrets, $stagedSettings)) {
            if ($staged -ne '' -and [IO.File]::Exists($staged)) { try { [IO.File]::Delete($staged) } catch { } }
        }
        if ($locked) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

function Get-NotificationSecureValue {
    param($Secrets, [string]$Name, [switch]$Optional)
    $value = Get-NotificationValue $Secrets $Name
    if ($null -eq $value -and $Optional) { return $null }
    if ($value -isnot [System.Security.SecureString]) { throw [System.InvalidOperationException]::new('A notification credential is missing or is not encrypted.') }
    if ($value.Length -eq 0 -and -not $Optional) { throw [System.InvalidOperationException]::new('A notification credential is empty.') }
    return $value
}

function ConvertFrom-NotificationSecureValue {
    param([System.Security.SecureString]$Value)
    if ($null -eq $Value -or $Value.Length -eq 0) { return '' }
    $pointer = [IntPtr]::Zero
    try {
        $pointer = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($Value)
        return [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
    }
    finally {
        if ($pointer -ne [IntPtr]::Zero) { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer) }
    }
}

function Get-NotificationMailAddress {
    param([string]$Value)
    $value = $Value.Trim()
    if ($value -notmatch '^[^\s@<>;,]+@[^\s@<>;,]+\.[^\s@<>;,]+$') {
        throw [System.ArgumentException]::new('Use one valid email address.')
    }
    $address = [System.Net.Mail.MailAddress]::new($value)
    if ($address.Address -cne $value -or -not [string]::IsNullOrEmpty($address.DisplayName)) {
        throw [System.ArgumentException]::new('Use one email address without a display name.')
    }
    return $address
}

function New-NotificationMailMessage {
    param($Settings, [string]$Title, [string]$Message)
    if ($Title -match '[\r\n]') { throw [System.ArgumentException]::new('The notification title must be one line.') }
    $from = Get-NotificationMailAddress ([string](Get-NotificationValue $Settings 'smtpFrom' ''))
    $to = Get-NotificationMailAddress ([string](Get-NotificationValue $Settings 'smtpTo' ''))
    $mail = [System.Net.Mail.MailMessage]::new()
    try {
        $mail.From = $from
        $mail.To.Add($to)
        $mail.Subject = $Title
        $mail.SubjectEncoding = [System.Text.Encoding]::UTF8
        $mail.Body = $Message
        $mail.BodyEncoding = [System.Text.Encoding]::UTF8
        $mail.HeadersEncoding = [System.Text.Encoding]::UTF8
        $mail.IsBodyHtml = $false
        return $mail
    }
    catch { $mail.Dispose(); throw }
}

function New-NotificationSmtpClient {
    param($Settings, [System.Security.SecureString]$Password)
    $smtpHost = [string](Get-NotificationValue $Settings 'smtpHost' 'smtp.qq.com')
    $smtpPort = [int](Get-NotificationValue $Settings 'smtpPort' 587)
    # This provider is deliberately limited to QQ's STARTTLS endpoint.
    if ($smtpHost -ine 'smtp.qq.com' -or $smtpPort -ne 587) {
        throw [System.ArgumentException]::new('QQ email requires smtp.qq.com with STARTTLS port 587.')
    }
    $sender = Get-NotificationMailAddress ([string](Get-NotificationValue $Settings 'smtpFrom' ''))
    $client = [System.Net.Mail.SmtpClient]::new($smtpHost, $smtpPort)
    $client.EnableSsl = $true
    $client.Timeout = 10000
    $client.DeliveryMethod = [System.Net.Mail.SmtpDeliveryMethod]::Network
    $client.UseDefaultCredentials = $false
    $client.Credentials = [System.Net.NetworkCredential]::new($sender.Address, $Password)
    return $client
}

function Invoke-NotificationSmtpSend {
    param([System.Net.Mail.SmtpClient]$Client, [System.Net.Mail.MailMessage]$Mail)
    $Client.Send($Mail)
}

function Get-NotificationTimestamp {
    return [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds().ToString([System.Globalization.CultureInfo]::InvariantCulture)
}

function New-NotificationDingTalkRequest {
    param($Settings, $Secrets, [string]$Title, [string]$Message, [string]$Timestamp = '')
    $webhookSecure = Get-NotificationSecureValue $Secrets 'dingTalkWebhook'
    $secretSecure = Get-NotificationSecureValue $Secrets 'dingTalkSecret' -Optional
    $webhook = ConvertFrom-NotificationSecureValue $webhookSecure
    $secret = ConvertFrom-NotificationSecureValue $secretSecure
    $uri = $null
    if (-not [Uri]::TryCreate($webhook, [UriKind]::Absolute, [ref]$uri) -or
        $uri.Scheme -cne 'https' -or $uri.DnsSafeHost -ine 'oapi.dingtalk.com' -or $uri.Port -ne 443 -or
        $uri.AbsolutePath -cne '/robot/send' -or $uri.UserInfo -ne '' -or $uri.Fragment -ne '' -or
        $uri.Query -cnotmatch '^\?access_token=[A-Za-z0-9_-]{10,256}$') {
        throw [System.ArgumentException]::new('Use the original HTTPS DingTalk robot webhook.')
    }
    $keyword = [string](Get-NotificationValue $Settings 'dingTalkKeyword' '验证码')
    $content = $Title + "`n" + $Message
    if (-not [string]::IsNullOrWhiteSpace($keyword) -and -not $content.Contains($keyword)) { $content = $keyword + "`n" + $content }
    if ([System.Text.Encoding]::UTF8.GetByteCount($content) -gt 18000) { throw [System.ArgumentException]::new('Notification content is too long.') }
    $requestUri = $uri.AbsoluteUri
    if (-not [string]::IsNullOrWhiteSpace($secret)) {
        if ($Timestamp -eq '') { $Timestamp = Get-NotificationTimestamp }
        if ($Timestamp -notmatch '^[0-9]{13}$') { throw [System.ArgumentException]::new('DingTalk timestamp must be milliseconds.') }
        $hmac = [System.Security.Cryptography.HMACSHA256]::new([System.Text.Encoding]::UTF8.GetBytes($secret))
        try {
            # Official rule: HMAC-SHA256(key=secret, UTF8(timestamp + LF + secret)).
            $signBytes = $hmac.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Timestamp + "`n" + $secret))
            $signature = [Uri]::EscapeDataString([Convert]::ToBase64String($signBytes))
            $requestUri += '&timestamp=' + $Timestamp + '&sign=' + $signature
        }
        finally { $hmac.Dispose(); $secret = $null }
    }
    $json = @{ msgtype = 'text'; text = @{ content = $content }; at = @{ isAtAll = $false } } | ConvertTo-Json -Depth 4 -Compress
    return [pscustomobject]@{ Uri = $requestUri; Body = [System.Text.Encoding]::UTF8.GetBytes($json) }
}

function Invoke-NotificationDingTalkSend {
    param($Request)
    # Never follow redirects while holding the webhook token or message content.
    return Invoke-RestMethod -Uri $Request.Uri -Method Post -ContentType 'application/json; charset=utf-8' -Body $Request.Body -TimeoutSec 10 -MaximumRedirection 0 -ErrorAction Stop
}

function Test-NotificationWeChatToken {
    param([string]$Token)
    # Supports user/message tokens; reject pasted URLs, whitespace and control bytes.
    return $Token -cmatch '^[A-Za-z0-9_-]{16,128}$'
}

function New-NotificationWeChatRequest {
    param($Settings, $Secrets, [string]$Title, [string]$Message)
    $token = ConvertFrom-NotificationSecureValue (Get-NotificationSecureValue $Secrets 'wechatToken')
    if (-not (Test-NotificationWeChatToken $token)) { throw [ArgumentException]::new('请填写 PushPlus 个人中心的完整 Token，不是网页地址。') }
    $channel = [string](Get-NotificationValue $Settings 'wechatChannel' 'wechat')
    if ($channel -cnotin @('wechat','clawbot')) { throw [ArgumentException]::new('微信接收方式无效。') }
    if ([string]::IsNullOrWhiteSpace($Title) -or $Title -match '[\r\n]' -or $Title.Length -gt 200) { throw [ArgumentException]::new('通知标题无效。') }
    $content = $Title + "`n" + $Message
    if ([Text.Encoding]::UTF8.GetByteCount($content) -gt 18000) { throw [ArgumentException]::new('通知内容过长。') }
    $body = @{token=$token;title=$Title;content=$content;template='txt';channel=$channel;timestamp=[DateTimeOffset]::UtcNow.AddSeconds(120).ToUnixTimeMilliseconds()} | ConvertTo-Json -Compress -Depth 4
    # No to/topic: use only the account paired by the user. Never put tokens in URLs.
    return [pscustomobject]@{Uri='https://www.pushplus.plus/send';Body=[Text.Encoding]::UTF8.GetBytes($body)}
}

function Invoke-NotificationWeChatSend {
    param($Request)
    return Invoke-RestMethod -Uri $Request.Uri -Method Post -ContentType 'application/json; charset=utf-8' -Body $Request.Body -TimeoutSec 10 -MaximumRedirection 0 -ErrorAction Stop
}

function Get-NotificationWeChatResponse {
    param($Response)
    $code = 0L
    $rawCode = Get-NotificationValue $Response 'code'
    if ($null -eq $rawCode -or -not [long]::TryParse([string]$rawCode,[ref]$code)) { return @{Outcome='Uncertain';Detail='微信接口回执不完整，请检查微信后再处理。'} }
    if ($code -eq 200) {
        $receipt = Get-NotificationValue $Response 'data'
        if ($receipt -isnot [string] -or [string]::IsNullOrWhiteSpace($receipt)) { return @{Outcome='Uncertain';Detail='微信接口缺少受理流水号，请检查微信。'} }
        return @{Outcome='Success';Detail='微信推送服务已受理，尚不代表投递成功；请在微信确认。'}
    }
    $detail = switch ($code) {
        903 {'Token无效，请在PushPlus个人中心重新复制。'}
        905 {'PushPlus要求先在其官网完成实名认证。'}
        900 {'PushPlus账户或额度受限，请在其官网检查，勿连续重试。'}
        888 {'PushPlus提示积分不足，请检查所选通道和账户设置。'}
        403 {'PushPlus拒绝此请求，请检查官网的IP/账户设置。'}
        401 {'PushPlus未授权，请检查Token与账户设置。'}
        default {'微信服务未确认投递，请到PushPlus个人中心查看记录。'}
    }
    $outcome = if ($code -in @(302,401,403,600,805,888,900,903,905,999)) {'PermanentFailure'} else {'Uncertain'}
    return @{Outcome=$outcome;Detail=$detail}
}

function Get-NotificationExceptionOutcome {
    param([System.Exception]$Exception)
    $current = $Exception
    while ($null -ne $current) {
        if ($current -is [System.Net.Mail.SmtpException]) {
            $status = [int]$current.StatusCode
            if ($status -ge 500 -and $status -lt 600) { return 'PermanentFailure' }
            if ($status -ge 400 -and $status -lt 500) { return 'RetryableFailure' }
        }
        if ($current -is [System.Net.WebException]) {
            if ($current.Status -in @([System.Net.WebExceptionStatus]::NameResolutionFailure, [System.Net.WebExceptionStatus]::ProxyNameResolutionFailure, [System.Net.WebExceptionStatus]::ConnectFailure)) { return 'RetryableFailure' }
            if ($current.Status -in @([System.Net.WebExceptionStatus]::TrustFailure, [System.Net.WebExceptionStatus]::SecureChannelFailure)) { return 'PermanentFailure' }
        }
        $response = Get-NotificationValue $current 'Response'
        if ($null -ne $response) {
            $status = [int](Get-NotificationValue $response 'StatusCode' 0)
            if ($status -eq 429) { return 'RetryableFailure' }
            if ($status -in @(400, 401, 403, 404, 405, 410, 413, 414, 415, 422)) { return 'PermanentFailure' }
            # HTTP 5xx/timeout can follow acceptance; they are not safe to retry.
        }
        if ($current -is [System.Net.Sockets.SocketException]) {
            if ($current.SocketErrorCode -in @([System.Net.Sockets.SocketError]::HostNotFound, [System.Net.Sockets.SocketError]::NoData, [System.Net.Sockets.SocketError]::ConnectionRefused, [System.Net.Sockets.SocketError]::NetworkUnreachable, [System.Net.Sockets.SocketError]::HostUnreachable)) { return 'RetryableFailure' }
        }
        if ($current -is [System.Security.Authentication.AuthenticationException]) { return 'PermanentFailure' }
        $current = $current.InnerException
    }
    return 'Uncertain'
}

function Send-MonitorNotification {
    [CmdletBinding()]
    param($Config, [string]$Title, [string]$Message, [Parameter(Mandatory = $true)][ref]$Outcome, [switch]$IsAlarm)

    $Outcome.Value = 'PermanentFailure'
    $script:LastNotificationDetail = ''
    $mail = $null
    $client = $null
    $sendStarted = $false
    try {
        $loaded = Read-NotificationConfiguration -Config $Config
        $provider = [string](Get-NotificationValue $loaded.Settings 'provider' 'qqmail')
        $nightAlarm = $IsAlarm -and (Test-NotificationNightAlarmEnabled $loaded.Settings)
        if ($nightAlarm) {
            # Only explicit alarm callers can opt into the Android ring-helper protocol.
            # The event ID distinguishes new messages when a source app reuses its notification ID.
            $Title = '【夜间告警】[事件:' + [guid]::NewGuid().ToString('N') + '] ' + $Title
        }
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12
        if ($provider -ieq 'qqmail') {
            $password = Get-NotificationSecureValue $loaded.Secrets 'smtpPassword'
            $mailMessage = $Message
            if ($nightAlarm) { $mailMessage = $Title + "`n" + $Message }
            $mail = New-NotificationMailMessage -Settings $loaded.Settings -Title $Title -Message $mailMessage
            $client = New-NotificationSmtpClient -Settings $loaded.Settings -Password $password
            $sendStarted = $true
            $null = Invoke-NotificationSmtpSend -Client $client -Mail $mail
        }
        elseif ($provider -ieq 'dingtalk') {
            $request = New-NotificationDingTalkRequest -Settings $loaded.Settings -Secrets $loaded.Secrets -Title $Title -Message $Message
            $sendStarted = $true
            $response = Invoke-NotificationDingTalkSend -Request $request
            $errorCode = Get-NotificationValue $response 'errcode'
            $parsedCode = 0L
            if ($null -eq $errorCode -or -not [long]::TryParse([string]$errorCode, [ref]$parsedCode)) { $Outcome.Value = 'Uncertain'; return $false }
            if ($parsedCode -ne 0) {
                # DingTalk explicitly rejected the request. Auth/keyword/sign/IP failures need configuration changes.
                $Outcome.Value = 'PermanentFailure'
                if ($parsedCode -in @(88, 130101, 45009, 90018)) { $Outcome.Value = 'RetryableFailure' }
                return $false
            }
        }
        elseif ($provider -ieq 'wechat') {
            $version = Get-NotificationConfigurationVersion -Config $Config
            $blocked = Get-Variable NotificationWeChatBlock -Scope Script -ErrorAction SilentlyContinue
            if ($null -ne $blocked -and $blocked.Value.Version -ceq $version -and $blocked.Value.Until -gt [DateTimeOffset]::UtcNow) {
                $Outcome.Value='PermanentFailure'; $script:LastNotificationDetail=$blocked.Value.Detail
                return $false
            }
            $request = New-NotificationWeChatRequest -Settings $loaded.Settings -Secrets $loaded.Secrets -Title $Title -Message $Message
            $sendStarted = $true
            $response = Invoke-NotificationWeChatSend -Request $request
            $result = Get-NotificationWeChatResponse $response
            $Outcome.Value = $result.Outcome
            $script:LastNotificationDetail = $result.Detail
            if ($Outcome.Value -eq 'PermanentFailure') {
                # The OCR loop may revisit visible alerts; don't keep hitting a restricted account.
                $script:LastNotificationDetail += ' 自动发送暂停；修正后请重新保存设置。'
                $script:NotificationWeChatBlock = @{Version=$version;Until=[DateTimeOffset]::UtcNow.AddHours(24);Detail=$script:LastNotificationDetail}
            }
            return ($Outcome.Value -eq 'Success')
        }
        else { return $false }
        $Outcome.Value = 'Success'
        return $true
    }
    catch {
        # Never print exception text: it may contain a webhook, mailbox or SMTP response.
        if ($sendStarted) { $Outcome.Value = Get-NotificationExceptionOutcome -Exception $_.Exception }
        return $false
    }
    finally {
        if ($null -ne $mail) { $mail.Dispose() }
        if ($null -ne $client) { $client.Dispose() }
    }
}
