param([switch]$Quiet)
$ErrorActionPreference = 'Stop'
try {
    . (Join-Path $PSScriptRoot 'VerificationCode.ps1')
    . (Join-Path $PSScriptRoot 'NotificationTransport.ps1')
    . (Join-Path $PSScriptRoot 'VerificationPush.ps1')
    $config = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'monitor_config.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $sent = Send-VerificationNotification -Config $config -Code '083729' -IsTest
    if ($sent) { $message = '测试通知已交给微信/邮箱/钉钉推送服务。请在手机查看“测试验证码 083729”。服务端受理不等于手机已收到。' }
    else { $message = '测试推送未确认成功。请先打开“设置手机推送”填写微信Token、邮箱或钉钉设置，并检查网络。' }
    if (-not $Quiet) {
        Add-Type -AssemblyName System.Windows.Forms
        [void][System.Windows.Forms.MessageBox]::Show($message, '验证码手机推送测试')
    }
    Write-Output $message
    if (-not $sent) { exit 1 }
}
catch {
    Write-Output ('测试未完成：' + $_.Exception.GetType().Name)
    exit 1
}
