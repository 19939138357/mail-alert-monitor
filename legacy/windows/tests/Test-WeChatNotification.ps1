$ErrorActionPreference='Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'NotificationTransport.ps1')
$script:checks=0;$script:sendCount=0;$script:captured=$null
$script:settings=@{provider='wechat';wechatChannel='wechat';nightAlarmEnabled=$false}
$script:secrets=@{wechatToken=(ConvertTo-SecureString ('A'*32) -AsPlainText -Force)}
$script:response=@{code=200;data='synthetic-receipt'}
$script:version=1
function Get-NotificationConfigurationVersion {param($Config);return [string]$script:version}
function Check([bool]$value,[string]$name){$script:checks++;if(-not $value){throw ('FAIL: '+$name)}}
function Read-NotificationConfiguration {param($Config);return @{Settings=$script:settings;Secrets=$script:secrets}}
function Invoke-RestMethod {
    param($Uri,$Method,$ContentType,$Body,$TimeoutSec,$MaximumRedirection,$ErrorAction)
    Check ($Uri -ceq 'https://www.pushplus.plus/send') 'fixed HTTPS endpoint without token in URL'
    Check ($Method -eq 'Post' -and $TimeoutSec -eq 10 -and $MaximumRedirection -eq 0) 'bounded POST without redirects'
    Check ($ContentType -eq 'application/json; charset=utf-8' -and $Body -is [byte[]]) 'UTF8 JSON byte request'
    $script:sendCount++;$script:captured=[Text.Encoding]::UTF8.GetString($Body)|ConvertFrom-Json
    return $script:response
}
$outcome='';$sent=Send-MonitorNotification @{} '验证码：001234' '仅供本人使用' ([ref]$outcome)
Check ($sent -and $outcome -eq 'Success') 'valid receipt is accepted'
Check ($script:captured.channel -eq 'wechat' -and $script:captured.template -eq 'txt') 'explicit WeChat text mode'
Check ($script:captured.content.Contains('001234') -and $script:captured.content.Contains('仅供本人')) 'leading zeros and Unicode preserved'
Check ($null -eq $script:captured.PSObject.Properties['to'] -and $null -eq $script:captured.PSObject.Properties['topic']) 'self only no group or friend recipients'
Check ($script:captured.timestamp -gt [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() -and $script:captured.timestamp -le [DateTimeOffset]::UtcNow.AddSeconds(121).ToUnixTimeMilliseconds()) 'queued messages expire soon'
Check ($script:LastNotificationDetail -match '尚不代表') 'acceptance not presented as delivery'
$script:settings.nightAlarmEnabled=$true
$null=Send-MonitorNotification @{} '业务告警' '请处理' ([ref]$outcome) -IsAlarm
Check ($script:captured.title -match '^【夜间告警】\[事件:[a-f0-9]{32}\]') 'alarm marker and unique event included'
Check ($script:captured.content.StartsWith($script:captured.title)) 'marker also in body for WeChat preview'
$firstTitle=$script:captured.title
$null=Send-MonitorNotification @{} '业务告警' '请处理' ([ref]$outcome) -IsAlarm
Check ($firstTitle -ne $script:captured.title) 'new alert has distinct ID'
$null=Send-MonitorNotification @{} '测试验证码：008812' '普通测试' ([ref]$outcome)
Check ($script:captured.content -notmatch '夜间告警|\[事件:') 'ordinary verification never rings'
$script:settings.wechatChannel='clawbot'
$null=Send-MonitorNotification @{} '验证码：008812' '普通测试' ([ref]$outcome)
Check ($script:captured.channel -eq 'clawbot') 'explicitly selected chat channel supported'
foreach($code in @(302,401,403,600,805,888,900,903,905,999)){
    $script:version++
    $script:response=@{code=$code;data=$null;msg=('never print '+('A'*32))}
    $sent=Send-MonitorNotification @{} '测试' '正文' ([ref]$outcome)
    Check (-not $sent -and $outcome -eq 'PermanentFailure') ('documented rejection not retried: '+$code)
    Check (-not $script:LastNotificationDetail.Contains(('A'*32))) 'provider error text never leaks token'
    $beforeBlocked=$script:sendCount
    $sent=Send-MonitorNotification @{} '另一条告警' '正文' ([ref]$outcome)
    Check (-not $sent -and $outcome -eq 'PermanentFailure' -and $script:sendCount -eq $beforeBlocked) 'account rejection suppresses subsequent automatic requests'
}
$script:version++
$script:response=@{code=200;data='synthetic-recovered'}
$sent=Send-MonitorNotification @{} '已修正配置' '正文' ([ref]$outcome)
Check ($sent -and $outcome -eq 'Success') 'saved settings revision permits a fresh request after configuration repair'
foreach($response in @(@{code=200},@{code=200;data=@{unexpected=1}},@{code=500},@{code='invalid'},@{},@{code=777})){
    $script:response=$response;$sent=Send-MonitorNotification @{} '测试' '正文' ([ref]$outcome)
    Check (-not $sent -and $outcome -eq 'Uncertain') 'malformed or unknown responses remain uncertain'
}
$before=$script:sendCount
foreach($token in @('', 'short','https://www.pushplus.plus/send',('a'*16+"`n"),('a'*129))){
    $script:secrets.wechatToken=ConvertTo-SecureString ($token+'x') -AsPlainText -Force
    if($token -eq ''){$script:secrets=@{}}
    $sent=Send-MonitorNotification @{} '测试' '正文' ([ref]$outcome)
    Check (-not $sent -and $outcome -eq 'PermanentFailure') 'bad credentials rejected before I/O'
}
Check ($script:sendCount -eq $before) 'invalid credentials never submitted'
$script:secrets=@{wechatToken=(ConvertTo-SecureString ('A'*32) -AsPlainText -Force)}
$script:settings.wechatChannel='voice'
$sent=Send-MonitorNotification @{} '测试' '正文' ([ref]$outcome)
Check (-not $sent -and $script:sendCount -eq $before) 'unsupported or billable channels cannot be selected'
$script:settings.wechatChannel='wechat';$script:response=@{code=200;data='synthetic'}
$sent=Send-MonitorNotification @{} "标题`n换行" '正文' ([ref]$outcome)
Check (-not $sent -and $script:sendCount -eq $before) 'multiline title rejected before I/O'
Write-Output "PASS: $script:checks WeChat notification checks; all HTTPS calls mocked, zero external sends"
