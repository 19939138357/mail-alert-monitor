# Real notification builders and real OCR entry function, mocked outgoing I/O only.
$ErrorActionPreference='Stop'
$project=Split-Path $PSScriptRoot -Parent
. (Join-Path $project 'NotificationTransport.ps1')
. (Join-Path $project 'VerificationPush.ps1')
$script:NightChecks=0
$script:LastTitle=''
$script:LastBody=''
$script:NightSettings=@{provider='qqmail';smtpHost='smtp.qq.com';smtpPort=587;smtpFrom='sender@example.invalid';smtpTo='receiver@example.invalid'}
$script:NightSecrets=@{smtpPassword=(ConvertTo-SecureString 'SYNTHETIC_ONLY_NO_SEND' -AsPlainText -Force);dingTalkWebhook=(ConvertTo-SecureString 'https://oapi.dingtalk.com/robot/send?access_token=SYNTHETIC_ONLY_NO_SEND' -AsPlainText -Force)}
function Assert-Night {param([bool]$Condition,[string]$Label)if(-not $Condition){throw ('FAIL: '+$Label)};$script:NightChecks++}
function Read-NotificationConfiguration {param($Config)return [pscustomobject]@{Settings=$script:NightSettings;Secrets=$script:NightSecrets}}
function Invoke-NotificationSmtpSend {param($Client,$Mail)$script:LastTitle=$Mail.Subject;$script:LastBody=$Mail.Body}
function Invoke-NotificationDingTalkSend {
    param($Request)
    $payload=[Text.Encoding]::UTF8.GetString($Request.Body)|ConvertFrom-Json
    $script:LastTitle='';$script:LastBody=$payload.text.content
    return [pscustomobject]@{errcode=0;errmsg='ok'}
}
function Write-MonitorLog {param($Config,$Message)}
function Test-AlarmSend {
    param([switch]$IsAlarm)
    $outcome=''
    $result=Send-MonitorNotification -Config @{} -Title '监控提醒：待处理告警' -Message '测试内容' -Outcome ([ref]$outcome) -IsAlarm:$IsAlarm
    Assert-Night ($result -and $outcome -eq 'Success') 'synthetic send acknowledged'
}
$pattern='^【夜间告警】\[事件:([0-9a-f]{32})\] '
Test-AlarmSend -IsAlarm
Assert-Night ($script:LastTitle -notmatch '夜间告警|\[事件:') 'legacy missing opt-in remains an ordinary notification'
$script:NightSettings.nightAlarmEnabled=$false
Test-AlarmSend -IsAlarm
Assert-Night ($script:LastTitle -notmatch '夜间告警|\[事件:') 'explicitly disabled alarm has no helper marker'
$script:NightSettings.nightAlarmEnabled=$true
Test-AlarmSend
Assert-Night ($script:LastTitle -notmatch '夜间告警|\[事件:' -and $script:LastBody -notmatch '夜间告警|\[事件:') 'ordinary caller cannot become an alarm through settings alone'
Test-AlarmSend -IsAlarm
Assert-Night ($script:LastTitle -cmatch $pattern) 'opted-in alarm subject has exact marker and unique event identifier'
$firstEvent=$Matches[1]
Assert-Night ($script:LastBody.StartsWith($script:LastTitle+"`n")) 'QQ mail preview body also carries the same marked subject'
Test-AlarmSend -IsAlarm
Assert-Night ($script:LastTitle -cmatch $pattern -and $Matches[1] -cne $firstEvent) 'each new actual alarm send gets its own identifier'
$outcome=''
$codeResult=Send-VerificationNotification -Config @{verificationCodeEnabled=$true} -Code '001234' -Outcome ([ref]$outcome)
Assert-Night ($codeResult -and $script:LastTitle -eq '验证码：001234' -and $script:LastBody -notmatch '夜间告警|\[事件:') 'verification code stays ordinary while alarm opt-in is on'
[void](Send-VerificationNotification -Config @{verificationCodeEnabled=$true} -Code '001234' -IsTest -Outcome ([ref]$outcome))
Assert-Night ($script:LastTitle -eq '测试验证码：001234' -and $script:LastBody -notmatch '夜间告警|\[事件:') 'ordinary verification test stays ordinary'

$script:NightSettings.provider='dingtalk'
$script:NightSettings.dingTalkKeyword='监控'
Test-AlarmSend -IsAlarm
Assert-Night ($script:LastBody -cmatch ('(?m)'+$pattern)) 'DingTalk content exposes the exact marked title to notification listener'
Test-AlarmSend
Assert-Night ($script:LastBody -notmatch '夜间告警|\[事件:') 'ordinary DingTalk content has no night alarm marker'
$script:NightSettings.nightAlarmEnabled='false'
Test-AlarmSend -IsAlarm
Assert-Night ($script:LastBody -notmatch '夜间告警|\[事件:') 'string false is not accidentally enabled by PowerShell boolean casting'
$script:NightSettings.nightAlarmEnabled='invalid'
Test-AlarmSend -IsAlarm
Assert-Night ($script:LastBody -notmatch '夜间告警|\[事件:') 'invalid opt-in value fails closed'

# Exercise the production OCR keyword entry without starting OCR or reading settings.
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $project 'Monitor-WindowKeywords.ps1'),[ref]$tokens,[ref]$errors)
$entry=$ast.Find({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-PhoneCall'},$true)
. ([scriptblock]::Create($entry.Extent.Text))
$NoCall=$false
$script:NightSettings.provider='qqmail';$script:NightSettings.nightAlarmEnabled=$true
$entryResult=Invoke-PhoneCall -Config ([pscustomobject]@{callCommand='';callMode='notification';phoneNumber=''}) -Keyword '待处理告警'
Assert-Night ($entryResult -and $script:LastTitle -cmatch $pattern) 'actual OCR keyword alert requests alarm routing'
$previousTitle=$script:LastTitle
$NoCall=$true
[void](Invoke-PhoneCall -Config ([pscustomobject]@{callCommand='';callMode='notification';phoneNumber=''}) -Keyword '不要发送')
Assert-Night ($script:LastTitle -ceq $previousTitle) 'OCR NoCall still suppresses all actual sends'
Write-Host ('PASS: {0} night alarm checks; all mail and robot sends mocked.' -f $script:NightChecks)
