# Hidden WinForms/AST tests. No dialog is displayed, files saved, or notifications sent.
$ErrorActionPreference = 'Stop'
$script:SettingsChecks = 0
$script:SettingsFailures = New-Object System.Collections.Generic.List[string]
$script:CapturedSecrets = $null
$script:CapturedSettings = ''
$script:SettingsSends = 0
$script:MockAccepted = $true
$script:MockThrow = $false
$script:MockSaveFailure = $false
$script:MockConfigAvailable = $false
$script:MockConfigJson = '{}'
$script:LastSendWasAlarm = $false
$script:projectRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $script:projectRoot 'NotificationTransport.ps1')
$ConfigPath = Join-Path $PSScriptRoot 'not-read-monitor.json'
$script:settingsPath = Join-Path $PSScriptRoot 'not-written-settings.json'
$script:secretsPath = Join-Path $PSScriptRoot 'not-written-secrets.xml'
$sourcePath = Join-Path $script:projectRoot 'Configure-PhoneNotification.ps1'
$tokens = $null
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($sourcePath, [ref]$tokens, [ref]$parseErrors)

function Assert-Setting {
    param([bool]$Condition, [string]$Label)
    $script:SettingsChecks++
    if (-not $Condition) { $script:SettingsFailures.Add($Label) }
}
Assert-Setting ($parseErrors.Count -eq 0) 'PowerShell parser accepts settings GUI'
function Test-Path { param($LiteralPath, $Path) return ($script:MockConfigAvailable -and $LiteralPath -eq $ConfigPath) }
function Import-Clixml { throw 'Tests must not import real secrets.' }
function Export-Clixml {
    [CmdletBinding()]
    param([Parameter(ValueFromPipeline=$true)]$InputObject, $LiteralPath, $Depth)
    process { $script:CapturedSecrets = $InputObject.Clone() }
}
function Set-Content {
    [CmdletBinding()]
    param([Parameter(ValueFromPipeline=$true)]$Value, $LiteralPath, $Encoding)
    process {
        if ($script:MockSaveFailure) { throw 'Synthetic disk write failure.' }
        $script:CapturedSettings = [string]$Value
    }
}
function Get-Content {
    [CmdletBinding()]
    param($LiteralPath, [switch]$Raw, $Encoding)
    return $script:MockConfigJson
}
function Send-MonitorNotification {
    [CmdletBinding()]
    param($Config, [string]$Title, [string]$Message, [ref]$Outcome, [switch]$IsAlarm)
    $script:SettingsSends++
    $script:LastSendWasAlarm = [bool]$IsAlarm
    if ($script:MockThrow) { throw 'Synthetic notification exception.' }
    if ($script:MockAccepted) { $Outcome.Value = 'Success'; return $true }
    $Outcome.Value = 'PermanentFailure'
    return $false
}
function Save-NotificationConfiguration {
    param($Settings, $Secrets, $SettingsPath, $SecretsPath, $ExpectedRevision)
    if ($script:MockSaveFailure) { throw 'Synthetic disk write failure.' }
    $script:CapturedSecrets = $Secrets.Clone()
    $script:CapturedSettings = $Settings | ConvertTo-Json -Depth 5
    return [pscustomobject]@{ Revision = [guid]::NewGuid().ToString('N'); MirrorUpdated = $true }
}

# Evaluate the actual GUI and event handlers without dot-sourcing transport, replacing
# filesystem paths, displaying its modal window, or disposing controls before assertions.
$safeStatements = foreach ($statement in $ast.EndBlock.Statements) {
    $source = $statement.Extent.Text
    if ($source -match '^\.\s*\(' -and $source -match 'NotificationTransport\.ps1') { continue }
    if ($statement -is [Management.Automation.Language.AssignmentStatementAst] -and
        $statement.Left.Extent.Text -in @('$script:projectRoot', '$script:settingsPath', '$script:secretsPath')) { continue }
    if ($source -match '\$form\.(ShowDialog|Dispose)\(') { continue }
    $source
}
. ([scriptblock]::Create(($safeStatements -join "`r`n")))

function Click-SettingsButton {
    param([System.Windows.Forms.Button]$Button)
    $method = [System.Windows.Forms.Control].GetMethod('OnClick', [Reflection.BindingFlags]'Instance,NonPublic')
    [void]$method.Invoke($Button, @([EventArgs]::Empty))
}
function Assert-SaveRejected {
    param([string]$Label)
    $rejected = $false
    try { Save-NotificationSettings } catch { $rejected = $true }
    Assert-Setting $rejected $Label
}

try {
    Assert-Setting (-not $form.Visible) 'tests keep WinForms dialog hidden'
    Assert-Setting (-not $nightAlarm.Checked -and -not $alarmTest.Enabled) 'night alarm defaults off and dedicated test is disabled'
    Assert-Setting ($password.UseSystemPasswordChar -and $webhook.UseSystemPasswordChar -and $signing.UseSystemPasswordChar) 'all secret fields mask their text'
    foreach ($control in $form.Controls) {
        Assert-Setting ($control.Left -ge 0 -and $control.Top -ge 0 -and $control.Right -le $form.ClientSize.Width -and $control.Bottom -le $form.ClientSize.Height) ('control fits client area: ' + $control.GetType().Name)
        if ($control -is [System.Windows.Forms.Label]) {
            $measured = [System.Windows.Forms.TextRenderer]::MeasureText($control.Text, $control.Font, [System.Drawing.Size]::new($control.Width, 10000), [System.Windows.Forms.TextFormatFlags]::WordBreak)
            Assert-Setting ($measured.Height -le $control.Height) ('label has sufficient text height: ' + $control.Text)
        }
    }
    Assert-Setting ($provider.SelectedIndex -eq 2 -and $wechatToken.Enabled -and -not $from.Enabled -and -not $webhook.Enabled) 'WeChat is the default new-user channel'
    Assert-Setting $wechatToken.UseSystemPasswordChar 'WeChat token field is masked'
    Assert-SaveRejected 'WeChat requires a token before save'
    $wechatToken.Text='https://www.pushplus.plus/'
    Assert-SaveRejected 'pasted URL is not a token'
    $wechatToken.Text=('W'*32)
    Save-NotificationSettings
    Assert-Setting (($script:CapturedSettings|ConvertFrom-Json).provider -eq 'wechat') 'WeChat provider saved'
    Assert-Setting (($script:CapturedSettings|ConvertFrom-Json).wechatChannel -eq 'wechat') 'public-account mode saved explicitly'
    Assert-Setting ($script:CapturedSecrets['wechatToken'] -is [Security.SecureString]) 'WeChat token uses encrypted persistence'
    Assert-Setting ($script:CapturedSettings -notmatch 'WWWW|wechatToken' -and $wechatToken.Text -eq '') 'token is absent from public snapshot and cleared from input'
    $oldWeChatToken=$script:secretValues['wechatToken']
    Save-NotificationSettings
    Assert-Setting ([object]::ReferenceEquals($oldWeChatToken,$script:secretValues['wechatToken'])) 'blank WeChat token preserves saved value'
    $wechatToken.Text=('Z'*32);$script:MockSaveFailure=$true
    Assert-SaveRejected 'WeChat save failure leaves old secret intact'
    Assert-Setting ([object]::ReferenceEquals($oldWeChatToken,$script:secretValues['wechatToken'])) 'failed WeChat update does not mutate memory'
    $script:MockSaveFailure=$false;$wechatToken.Text='';$wechatMode.SelectedIndex=1
    Save-NotificationSettings
    Assert-Setting (($script:CapturedSettings|ConvertFrom-Json).wechatChannel -eq 'clawbot') 'selected chat mode saved'
    $wechatMode.SelectedIndex=0
    if($env:RENDER_NOTIFICATION_GUI -eq '1'){
        $form.ShowInTaskbar=$false;$form.Opacity=0;$form.Show();[Windows.Forms.Application]::DoEvents()
        $bitmap=New-Object Drawing.Bitmap($form.Width,$form.Height)
        try{$form.DrawToBitmap($bitmap,(New-Object Drawing.Rectangle(0,0,$form.Width,$form.Height)));$bitmap.Save((Join-Path $script:projectRoot '04_资料\微信通知升级_20260907\微信设置界面.png'),[Drawing.Imaging.ImageFormat]::Png)}finally{$bitmap.Dispose();$form.Hide()}
    }
    $provider.SelectedIndex=0
    Assert-Setting ($from.Enabled -and -not $wechatToken.Enabled) 'QQ mail can still be selected explicitly'
    $provider.SelectedIndex = 1
    Assert-Setting (-not $from.Enabled -and $webhook.Enabled -and $keyword.Enabled) 'provider event enables only relevant input fields'
    $provider.SelectedIndex = 0
    Assert-Setting ($from.Enabled -and $to.Enabled -and $password.Enabled -and -not $signing.Enabled) 'provider can switch back to QQ mail'

    $from.Text = 'sender@example.invalid'
    $to.Text = ''
    $password.Text = 'synthetic-password'
    Click-SettingsButton $save
    $saved = $script:CapturedSettings | ConvertFrom-Json
    Assert-Setting ($saved.provider -eq 'qqmail') 'save click handler executes actual save function'
    Assert-Setting ($saved.smtpFrom -eq 'sender@example.invalid' -and $saved.smtpTo -eq 'sender@example.invalid') 'blank recipient defaults to sender'
    Assert-Setting ($saved.smtpHost -eq 'smtp.qq.com' -and $saved.smtpPort -eq 587) 'QQ SMTP defaults are serialized'
    Assert-Setting ($script:CapturedSecrets['smtpPassword'] -is [Security.SecureString]) 'SMTP authorization is exported as SecureString'
    Assert-Setting ($script:CapturedSettings -notmatch 'synthetic-password|smtpPassword|dingTalkWebhook|dingTalkSecret') 'public settings never contain notification secrets'
    Assert-Setting ([string]::IsNullOrEmpty($password.Text)) 'password is cleared after save'
    $existingPassword = $script:secretValues['smtpPassword']
    Save-NotificationSettings
    Assert-Setting ([object]::ReferenceEquals($existingPassword, $script:secretValues['smtpPassword'])) 'blank password retains saved encrypted credential'
    $from.Text = 'other@example.invalid'
    Assert-SaveRejected 'changing sender requires authorization for the new account'
    $from.Text = 'sender@example.invalid'
    $oldCredential = $script:secretValues['smtpPassword']
    $password.Text = 'replacement-password'
    $script:MockSaveFailure = $true
    Assert-SaveRejected 'failed persistence reports failure'
    Assert-Setting ([object]::ReferenceEquals($oldCredential, $script:secretValues['smtpPassword'])) 'failed persistence does not mutate in-memory credential'
    $script:MockSaveFailure = $false
    $password.Text = ''
    $from.Text = 'other@example.invalid'
    $before = $script:SettingsSends
    Click-SettingsButton $test
    Assert-Setting ($script:SettingsSends -eq $before) 'test button never sends when changed account lacks new authorization'
    Assert-Setting ($status.Text -match '邮箱已更换|新邮箱') 'test button shows actionable validation error'
    $from.Text = 'sender@example.invalid'
    $from.Text = 'not-an-email'
    Assert-SaveRejected 'malformed email rejected'
    $from.Text = 'Display Name <sender@example.invalid>'
    Assert-SaveRejected 'display-name email format rejected'
    $from.Text = 'sender@example.invalid'
    $script:secretValues = @{}
    Assert-SaveRejected 'missing saved and entered authorization rejected'
    $password.Text = '   '
    Assert-SaveRejected 'whitespace-only authorization rejected without saving'
    $password.Text = 'synthetic-password'
    Save-NotificationSettings

    $before = $script:SettingsSends
    Click-SettingsButton $test
    Assert-Setting ($script:SettingsSends -eq ($before + 1)) 'test click invokes mocked notification once'
    Assert-Setting ($save.Enabled -and $test.Enabled) 'test success re-enables both buttons'
    Assert-Setting ($status.Text -match '受理|接受|成功') 'accepted test has readable completion state'
    $script:MockAccepted = $false
    Click-SettingsButton $test
    Assert-Setting ($status.Text -match '未确认|失败') 'rejected test does not show success'
    Assert-Setting ($save.Enabled -and $test.Enabled) 'test rejection re-enables both buttons'
    $script:MockThrow = $true
    Click-SettingsButton $test
    Assert-Setting ($save.Enabled -and $test.Enabled) 'test exception re-enables both buttons'
    Assert-Setting ($status.Text -notmatch 'Synthetic notification exception') 'test exception does not expose exception contents'
    $script:MockThrow = $false
    $script:MockAccepted = $true

    $before=$script:SettingsSends
    $nightAlarm.Checked=$true
    Click-SettingsButton $save
    Assert-Setting ($script:SettingsSends -eq $before) 'enabling and saving night alarm never sends a message'
    Assert-Setting (($script:CapturedSettings|ConvertFrom-Json).nightAlarmEnabled -eq $true) 'night alarm opt-in is persisted as boolean'
    Assert-Setting $alarmTest.Enabled 'explicit opt-in enables dedicated alarm test'
    Click-SettingsButton $test
    Assert-Setting (-not $script:LastSendWasAlarm) 'ordinary test stays ordinary with night alarm enabled'
    Click-SettingsButton $alarmTest
    Assert-Setting ($script:LastSendWasAlarm -and $status.Text -match '响铃|停止') 'dedicated test explicitly requests alarm and explains stopping it'
    Assert-Setting ($save.Enabled -and $test.Enabled -and $alarmTest.Enabled) 'dedicated alarm test restores all buttons'
    $nightAlarm.Checked=$false
    $before=$script:SettingsSends
    Click-SettingsButton $alarmTest
    Assert-Setting ($script:SettingsSends -eq $before -and -not $alarmTest.Enabled) 'disabled alarm test cannot send even through programmatic click'

    $provider.SelectedIndex = 1
    $script:secretValues = @{}
    Assert-SaveRejected 'missing webhook rejected'
    $webhook.Text = 'https://example.invalid/robot/send?access_token=synthetic123'
    Assert-SaveRejected 'non-DingTalk host rejected'
    $webhook.Text = 'http://oapi.dingtalk.com/robot/send?access_token=synthetic123'
    Assert-SaveRejected 'plaintext webhook rejected'
    $webhook.Text = 'https://oapi.dingtalk.com/robot/send?access_token=synthetic123'
    $signing.Text = 'synthetic-signing-key'
    Save-NotificationSettings
    $saved = $script:CapturedSettings | ConvertFrom-Json
    Assert-Setting ($saved.provider -eq 'dingtalk') 'DingTalk selection is serialized'
    Assert-Setting ($script:CapturedSecrets['dingTalkWebhook'] -is [Security.SecureString] -and $script:CapturedSecrets['dingTalkSecret'] -is [Security.SecureString]) 'webhook and signing secret are encrypted objects'
    Assert-Setting ([string]::IsNullOrEmpty($webhook.Text) -and [string]::IsNullOrEmpty($signing.Text)) 'DingTalk secret fields clear after save'
    Save-NotificationSettings
    Assert-Setting ($script:secretValues.ContainsKey('dingTalkWebhook')) 'blank webhook retains saved encrypted URL'
    $webhook.Text = 'https://oapi.dingtalk.com/robot/send?access_token=changedSynthetic123'
    Assert-SaveRejected 'new robot cannot silently reuse prior robot signing secret'
    $clearSigning.Checked = $true
    Assert-Setting (-not $signing.Enabled) 'clearing saved signing secret disables conflicting secret input'
    Save-NotificationSettings
    Assert-Setting (-not $script:secretValues.ContainsKey('dingTalkSecret')) 'explicit clearing removes saved signing secret'
    Assert-Setting (-not $clearSigning.Checked -and $signing.Enabled) 'clear-signing control resets after successful save'
    $webhook.Text = 'https://oapi.dingtalk.com/robot/send'
    Assert-SaveRejected 'webhook without access_token rejected'
    $webhook.Text = 'https://user:pass@oapi.dingtalk.com/robot/send?access_token=synthetic123'
    Assert-SaveRejected 'webhook userinfo rejected'
    $webhook.Text = 'https://oapi.dingtalk.com:8443/robot/send?access_token=synthetic123'
    Assert-SaveRejected 'nonstandard webhook port rejected'
}
finally { $form.Dispose() }

# Exercise the GUI's actual path initialization with a custom monitor configuration.
$script:MockConfigAvailable = $true
$script:MockConfigJson = '{"notificationSettingsFile":"tests/custom-settings.json","notificationSecretsFile":"tests/custom-secrets.xml"}'
$initializers = foreach($statement in $ast.EndBlock.Statements) {
    if(($statement -is [Management.Automation.Language.AssignmentStatementAst] -and $statement.Left.Extent.Text -in @('$script:monitorConfig','$script:settingsPath','$script:secretsPath')) -or
       ($statement -is [Management.Automation.Language.IfStatementAst] -and $statement.Extent.Text -match '\$ConfigPath' -and $statement.Extent.Text -match '\$script:monitorConfig')) { $statement.Extent.Text }
}
. ([scriptblock]::Create(($initializers -join "`r`n")))
Assert-Setting ($script:settingsPath -eq (Join-Path $PSScriptRoot 'custom-settings.json')) 'GUI honors custom notification settings path from active monitor config'
Assert-Setting ($script:secretsPath -eq (Join-Path $PSScriptRoot 'custom-secrets.xml')) 'GUI honors custom notification credential path from active monitor config'

if ($script:SettingsFailures.Count -gt 0) {
    foreach ($failure in $script:SettingsFailures) { Write-Host ('FAIL: ' + $failure) }
    throw ('Settings checks failed: {0} of {1}; all UI hidden and I/O mocked.' -f $script:SettingsFailures.Count, $script:SettingsChecks)
}
Write-Host ('PASS: {0} settings GUI checks; {1} notification calls mocked; no dialog, actual files or notifications.' -f $script:SettingsChecks, $script:SettingsSends)
