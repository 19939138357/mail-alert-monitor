param([string]$ConfigPath = (Join-Path $PSScriptRoot 'monitor_config.json'))
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
. (Join-Path $PSScriptRoot 'NotificationTransport.ps1')
$script:projectRoot = $PSScriptRoot
$script:monitorConfig = @{}
if (Test-Path -LiteralPath $ConfigPath) { $script:monitorConfig = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json }
$script:settingsPath = Resolve-NotificationConfigPath $script:monitorConfig 'notificationSettingsFile' '04_资料/私密配置/notification_settings.json'
$script:secretsPath = Resolve-NotificationConfigPath $script:monitorConfig 'notificationSecretsFile' '04_资料/私密配置/notification_secrets.xml'
$script:secretValues = @{}
$script:savedSettings = @{}
$script:settingsRevision = 'missing'
$script:loadFailed = $false
if (Test-Path -LiteralPath $script:secretsPath) {
    try {
        $loaded = Read-NotificationConfiguration -Config $script:monitorConfig
        $script:secretValues = $loaded.Secrets
        $script:savedSettings = $loaded.Settings
        $script:settingsRevision = $loaded.Revision
    }
    catch { $script:loadFailed = $true }
}
$form = New-Object System.Windows.Forms.Form
$form.Text = '手机推送设置 · 微信 / QQ 邮箱 / 钉钉'
$form.ClientSize = New-Object System.Drawing.Size(650, 785)
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox = $false
$form.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 10)
$form.BackColor = [System.Drawing.Color]::White
function Add-Label($Text, $X, $Y, $Width=570, $Height=28) {
    $control = New-Object System.Windows.Forms.Label
    $control.Text=$Text; $control.SetBounds($X,$Y,$Width,$Height)
    $form.Controls.Add($control)
    return $control
}
function Add-Input($Y, [bool]$Secret=$false) {
    $control = New-Object System.Windows.Forms.TextBox
    $control.SetBounds(175,$Y,435,30)
    $control.UseSystemPasswordChar=$Secret
    $form.Controls.Add($control)
    return $control
}
$heading=Add-Label '识别后推送手机；告警可持续响铃' 30 22 580 36
$heading.Font=New-Object System.Drawing.Font('Microsoft YaHei UI',16,[Drawing.FontStyle]::Bold)
[void](Add-Label '先设置接收通道，再发送测试，最后启动监控。' 30 66)
[void](Add-Label '通知方式' 30 110 140)
$provider=New-Object System.Windows.Forms.ComboBox
$provider.SetBounds(175,106,435,32); $provider.DropDownStyle='DropDownList'
[void]$provider.Items.Add('QQ 邮箱（手机安装 QQ 邮箱并开启新邮件通知）')
[void]$provider.Items.Add('钉钉群机器人（通知发到指定钉钉群）')
[void]$provider.Items.Add('微信（通过 PushPlus 接收通知）')
$provider.SelectedIndex=2; $form.Controls.Add($provider)
[void](Add-Label '发件 QQ 邮箱' 30 157 140); $from=Add-Input 153
[void](Add-Label '手机接收邮箱' 30 199 140); $to=Add-Input 195
[void](Add-Label '邮箱授权码' 30 241 140); $password=Add-Input 237 $true
$mailHint=Add-Label 'QQ 邮箱网页版 → 设置 → 账户 → 开启 SMTP，生成授权码。不是 QQ 登录密码。接收邮箱可填同一地址。' 30 280 580 50
[void](Add-Label '机器人 Webhook' 30 343 140); $webhook=Add-Input 339 $true
[void](Add-Label '机器人加签密钥' 30 385 140); $signing=Add-Input 381 $true
[void](Add-Label '机器人关键词' 30 427 140); $keyword=Add-Input 423; $keyword.Text='验证码'
$clearSigning=New-Object System.Windows.Forms.CheckBox
$clearSigning.Text='清除已保存的加签密钥（改用关键词验证）'
$clearSigning.SetBounds(175,460,435,30);$form.Controls.Add($clearSigning)
$dingHint=Add-Label '在钉钉群创建自定义机器人；安全设置用加签或关键词“验证码”。群成员都能看到通知，请使用自己的专用群。' 30 495 580 48
$legacyProviderControls=@($form.Controls | Where-Object {$_.Top -ge 153 -and $_.Top -le 543})
$wechatTokenLabel=Add-Label 'PushPlus Token' 30 157 140
$wechatToken=Add-Input 153 $true
$wechatModeLabel=Add-Label '微信接收方式' 30 205 140
$wechatMode=New-Object Windows.Forms.ComboBox
$wechatMode.SetBounds(175,201,435,32);$wechatMode.DropDownStyle='DropDownList'
[void]$wechatMode.Items.Add('微信公众号（扫码关注 PushPlus）')
[void]$wechatMode.Items.Add('微信 ClawBot 聊天（需另扫码绑定并激活）')
$wechatMode.SelectedIndex=0;$form.Controls.Add($wechatMode)
$wechatOpen=New-Object Windows.Forms.Button
$wechatOpen.Text='打开官网 · 扫码绑定 / 获取 Token';$wechatOpen.SetBounds(30,250,580,36);$form.Controls.Add($wechatOpen)
$wechatOpen.Add_Click({try {Start-Process 'https://www.pushplus.plus/'} catch {$status.Text='浏览器未能打开，请手动访问 www.pushplus.plus。'}})
$wechatHint=Add-Label '首次：官网扫码登录并按要求完成账户验证，关注公众号，将 Token 填到上方。消息经 PushPlus 转发到你的微信；Token 留空可沿用本机已保存值。' 30 305 580 65
$wechatNightHint=Add-Label '公众号默认可能隐藏正文，需点开详情看验证码。若要夜间响铃，通知须显示【夜间告警】；可在公众号发送「激活消息」后测试。ClawBot 也有主动对话与次数限制，请先按官网完成绑定。' 30 384 580 88
$wechatNightHint.ForeColor=[Drawing.Color]::DarkRed
$wechatHelp=New-Object Windows.Forms.Button
$wechatHelp.Text='查看微信接收与响铃说明';$wechatHelp.SetBounds(30,490,580,36);$form.Controls.Add($wechatHelp)
$wechatHelp.Add_Click({try {Start-Process -FilePath 'notepad.exe' -ArgumentList ('"{0}"' -f (Join-Path $script:projectRoot '03_交付物\微信通知使用说明.md'))} catch {$status.Text='请打开交付目录中的微信通知使用说明.md。'}})
$wechatControls=@($wechatTokenLabel,$wechatToken,$wechatModeLabel,$wechatMode,$wechatOpen,$wechatHint,$wechatNightHint,$wechatHelp)
$savedHint=Add-Label 'Token、授权码和机器人密钥在本机加密保存，已保存的密钥留空可沿用。' 30 547 580 38
$savedHint.ForeColor=[Drawing.Color]::DimGray
$nightAlarm=New-Object System.Windows.Forms.CheckBox
$nightAlarm.Text='告警通知触发手机持续响铃（需安卓响铃助手）'
$nightAlarm.SetBounds(30,590,585,30);$form.Controls.Add($nightAlarm)
$nightAlarm.Checked=Test-NotificationNightAlarmEnabled $script:savedSettings
$alarmHint=Add-Label '开启后，告警会触发手机持续响铃，请到手机按停止。验证码和普通测试不会触发；下方专用按钮会测试响铃。' 30 624 585 42
$alarmHint.ForeColor=[Drawing.Color]::DarkRed
$status=Add-Label '尚未测试手机通知。' 30 675 585 42
$save=New-Object System.Windows.Forms.Button
$save.Text='保存设置'; $save.SetBounds(30,733,160,36); $form.Controls.Add($save)
$test=New-Object System.Windows.Forms.Button
$test.Text='保存并发送普通测试'; $test.SetBounds(200,733,195,36); $form.Controls.Add($test)
$alarmTest=New-Object System.Windows.Forms.Button
$alarmTest.Text='测试持续响铃';$alarmTest.SetBounds(405,733,210,36);$form.Controls.Add($alarmTest)
$alarmTest.Enabled=$nightAlarm.Checked
$nightAlarm.Add_CheckedChanged({$alarmTest.Enabled=$nightAlarm.Checked})

if((Get-NotificationValue $script:savedSettings 'provider' '') -eq 'dingtalk'){$provider.SelectedIndex=1}
if((Get-NotificationValue $script:savedSettings 'provider' '') -eq 'qqmail'){$provider.SelectedIndex=0}
if((Get-NotificationValue $script:savedSettings 'wechatChannel' '') -eq 'clawbot'){$wechatMode.SelectedIndex=1}
$from.Text=[string](Get-NotificationValue $script:savedSettings 'smtpFrom' '')
$to.Text=[string](Get-NotificationValue $script:savedSettings 'smtpTo' '')
$keyword.Text=[string](Get-NotificationValue $script:savedSettings 'dingTalkKeyword' '验证码')
if($script:loadFailed){$status.Text='凭据无法解密或配置损坏。请在原电脑、原 Windows 用户下打开。';$status.ForeColor=[Drawing.Color]::Firebrick}
function Update-ProviderFields {
    $isMail=$provider.SelectedIndex -eq 0
    $isDing=$provider.SelectedIndex -eq 1
    $isWechat=$provider.SelectedIndex -eq 2
    foreach($control in $legacyProviderControls){$control.Visible=-not $isWechat}
    foreach($control in $wechatControls){$control.Visible=$isWechat;$control.Enabled=$isWechat}
    $from.Enabled=$isMail; $to.Enabled=$isMail; $password.Enabled=$isMail
    $webhook.Enabled=$isDing; $signing.Enabled=($isDing -and -not $clearSigning.Checked); $keyword.Enabled=$isDing
    $clearSigning.Enabled=$isDing
}
$provider.Add_SelectedIndexChanged({Update-ProviderFields}); Update-ProviderFields
$clearSigning.Add_CheckedChanged({Update-ProviderFields})

function Save-NotificationSettings {
    if($script:loadFailed){throw '无法安全读取原设置，请先在原电脑、原 Windows 用户下恢复配置。'}
    $password.Text=$password.Text.Trim()
    $webhook.Text=$webhook.Text.Trim()
    $signing.Text=$signing.Text.Trim()
    $wechatToken.Text=$wechatToken.Text.Trim()
    $channel=switch($provider.SelectedIndex){0{'qqmail'}1{'dingtalk'}2{'wechat'}default{throw '请选择通知方式。'}}
    if($channel -eq 'qqmail') {
        if([string]::IsNullOrWhiteSpace($to.Text)){$to.Text=$from.Text.Trim()}
        foreach($address in @($from.Text.Trim(),$to.Text.Trim())) {
            if([string]::IsNullOrWhiteSpace($address)){throw '请填写发件邮箱和接收邮箱。'}
            try{$parsed=Get-NotificationMailAddress $address}catch{throw '邮箱地址格式不正确，请只填写完整邮箱地址。'}
            if($parsed.Address -ne $address){throw '每个位置只填写一个邮箱地址。'}
        }
        if(-not $password.Text -and -not $script:secretValues.ContainsKey('smtpPassword')){throw '请填写 QQ 邮箱的 SMTP 授权码。'}
        if(-not $password.Text -and $from.Text.Trim() -ine [string](Get-NotificationValue $script:savedSettings 'smtpFrom' '')){throw '发件邮箱已更换，请填写新邮箱对应的 SMTP 授权码。'}
    }
    elseif($channel -eq 'dingtalk') {
        if(-not $webhook.Text -and -not $script:secretValues.ContainsKey('dingTalkWebhook')){throw '请填写钉钉机器人的 Webhook 地址。'}
        if($webhook.Text) {
            $uri=$null
            if(-not [uri]::TryCreate($webhook.Text.Trim(),[UriKind]::Absolute,[ref]$uri) -or $uri.Scheme -ne 'https' -or $uri.Host -ne 'oapi.dingtalk.com' -or $uri.Port -ne 443 -or $uri.UserInfo -ne '' -or $uri.Fragment -ne '' -or $uri.AbsolutePath -ne '/robot/send' -or $uri.Query -cnotmatch '^\?access_token=[A-Za-z0-9_-]{10,256}$') {throw '请完整复制钉钉官方机器人的 HTTPS Webhook，必须含 access_token。'}
            if($script:secretValues.ContainsKey('dingTalkSecret') -and -not $signing.Text -and -not $clearSigning.Checked) {
                $oldWebhook=ConvertFrom-NotificationSecureValue (Get-NotificationSecureValue $script:secretValues 'dingTalkWebhook')
                if($webhook.Text -cne $oldWebhook){throw '机器人已更换，请填写新加签密钥，或勾选清除旧密钥并使用关键词验证。'}
            }
        }
        if($clearSigning.Checked -and -not $keyword.Text.Trim()){throw '清除加签密钥时，请填写机器人安全设置中的关键词。'}
    }
    elseif($channel -eq 'wechat') {
        if($wechatMode.SelectedIndex -notin @(0,1)){throw '请选择微信接收方式。'}
        if(-not $wechatToken.Text -and -not $script:secretValues.ContainsKey('wechatToken')){throw '请扫码绑定PushPlus，并填写个人中心的Token。'}
        $checkToken=if($wechatToken.Text){$wechatToken.Text}else{ConvertFrom-NotificationSecureValue (Get-NotificationSecureValue $script:secretValues 'wechatToken')}
        if(-not (Test-NotificationWeChatToken $checkToken)){throw 'Token格式不正确，请复制完整Token，不要填写微信号或网址。'}
    }
    $nextSecrets=@{}
    foreach($key in $script:secretValues.Keys){$nextSecrets[$key]=$script:secretValues[$key]}
    if($channel -eq 'qqmail' -and $password.Text){$nextSecrets['smtpPassword']=ConvertTo-SecureString $password.Text -AsPlainText -Force}
    if($channel -eq 'wechat' -and $wechatToken.Text){$nextSecrets['wechatToken']=ConvertTo-SecureString $wechatToken.Text -AsPlainText -Force}
    if($channel -eq 'dingtalk') {
        if($webhook.Text){$nextSecrets['dingTalkWebhook']=ConvertTo-SecureString $webhook.Text -AsPlainText -Force}
        if($clearSigning.Checked){$nextSecrets.Remove('dingTalkSecret')}
        elseif($signing.Text){$nextSecrets['dingTalkSecret']=ConvertTo-SecureString $signing.Text -AsPlainText -Force}
    }
    $settings=[ordered]@{provider=$channel;wechatChannel=$(if($wechatMode.SelectedIndex -eq 1){'clawbot'}else{'wechat'});smtpHost='smtp.qq.com';smtpPort=587;smtpFrom=$from.Text.Trim();smtpTo=$to.Text.Trim();dingTalkKeyword=$keyword.Text.Trim();nightAlarmEnabled=[bool]$nightAlarm.Checked}
    $saved=Save-NotificationConfiguration -Settings $settings -Secrets $nextSecrets -SettingsPath $script:settingsPath -SecretsPath $script:secretsPath -ExpectedRevision $script:settingsRevision
    $script:secretValues=$nextSecrets
    $script:savedSettings=$settings
    $script:settingsRevision=$saved.Revision
    $password.Clear();$webhook.Clear();$signing.Clear();$wechatToken.Clear()
    $clearSigning.Checked=$false
    $status.Text='已保存。监控下一次发送时会读取新设置。'
    $status.ForeColor=[Drawing.Color]::DarkGreen
    if(-not $saved.MirrorUpdated){$status.Text='通知设置已保存；可读配置备份未更新，请检查目录写入权限。';$status.ForeColor=[Drawing.Color]::DarkGoldenrod}
}
$save.Add_Click({
    try {Save-NotificationSettings}
    catch {$status.Text=$_.Exception.Message; $status.ForeColor=[Drawing.Color]::Firebrick}
})
$test.Add_Click({
    $save.Enabled=$false;$test.Enabled=$false;$alarmTest.Enabled=$false
    $testStage='save'
    try {
        Save-NotificationSettings
        $testStage='send'
        $status.Text='正在发送测试，请稍候…';$form.Refresh()
        $outcome=''
        $sent=Send-MonitorNotification -Config $script:monitorConfig -Title '测试验证码：083729' -Message "这是手机通知测试，验证码：083729。`n无需进行任何登录操作。" -Outcome ([ref]$outcome)
        if($sent){$status.Text='服务端已受理测试，尚不代表送达。请到微信／QQ邮箱／钉钉确认。';$status.ForeColor=[Drawing.Color]::DarkGreen}
        else{$status.Text='未确认发送成功（'+$outcome+'）。请检查授权码/机器人安全设置和网络。';$status.ForeColor=[Drawing.Color]::Firebrick}
        if($provider.SelectedIndex -eq 2 -and (Get-Variable LastNotificationDetail -Scope Script -ErrorAction SilentlyContinue)){$status.Text=$script:LastNotificationDetail}
    }
    catch {
        if($testStage -eq 'save'){$status.Text=$_.Exception.Message}
        else{$status.Text='发送未确认，请检查授权码/机器人安全设置和网络。'}
        $status.ForeColor=[Drawing.Color]::Firebrick
    }
    finally {$save.Enabled=$true;$test.Enabled=$true;$alarmTest.Enabled=$nightAlarm.Checked}
})
$alarmTest.Add_Click({
    if(-not $nightAlarm.Checked){$status.Text='请先勾选持续响铃，并在安卓手机设置响铃助手。';return}
    $save.Enabled=$false;$test.Enabled=$false;$alarmTest.Enabled=$false
    $testStage='save'
    try {
        Save-NotificationSettings
        $testStage='send'
        $status.Text='正在发送持续响铃测试；收到后请在手机按停止。';$form.Refresh()
        $outcome=''
        $sent=Send-MonitorNotification -Config $script:monitorConfig -Title '持续响铃测试' -Message '这是手动触发的夜间告警测试。手机可能持续响铃，请在响铃助手中按停止。' -Outcome ([ref]$outcome) -IsAlarm
        if($sent){$status.Text='服务端已接受响铃测试。请确认手机响铃，然后在手机按停止。';$status.ForeColor=[Drawing.Color]::DarkGreen}
        else{$status.Text='响铃测试未确认发送，请检查通知配置和网络。';$status.ForeColor=[Drawing.Color]::Firebrick}
        if($provider.SelectedIndex -eq 2 -and -not $sent -and (Get-Variable LastNotificationDetail -Scope Script -ErrorAction SilentlyContinue)){$status.Text=$script:LastNotificationDetail}
    }
    catch {
        if($testStage -eq 'save'){$status.Text=$_.Exception.Message}
        else{$status.Text='响铃测试发送未确认，请检查通知配置和网络。'}
        $status.ForeColor=[Drawing.Color]::Firebrick
    }
    finally {$save.Enabled=$true;$test.Enabled=$true;$alarmTest.Enabled=$nightAlarm.Checked}
})
[void]$form.ShowDialog()
$form.Dispose()
