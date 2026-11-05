param([switch]$NoStart)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()
. (Join-Path $PSScriptRoot 'BrowserAlertSupport.ps1')
$token=Get-BrowserPairingToken
$psExe=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
if (-not $NoStart) {
    $receiver=Join-Path $PSScriptRoot 'BrowserKeywordReceiver.ps1'
    Start-Process -FilePath $psExe -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $receiver) -WorkingDirectory $PSScriptRoot -WindowStyle Hidden | Out-Null
}
$form=New-Object Windows.Forms.Form
$form.Text='网页告警设置';$form.ClientSize=New-Object Drawing.Size(640,555)
$form.StartPosition='CenterScreen';$form.FormBorderStyle='FixedDialog';$form.MaximizeBox=$false
$form.Font=New-Object Drawing.Font('Microsoft YaHei UI',10)
$intro=New-Object Windows.Forms.Label
$intro.SetBounds(22,18,596,100)
$intro.Text="普通网页邮箱：装好扩展后，在邮箱页面点「开启当前页」。`r`n远程桌面里的 Foxmail：请使用「一键启动监控.exe」。`r`n这两个入口均使用已配置的 微信／QQ 邮箱／钉钉推送。"
$form.Controls.Add($intro)
$copy=New-Object Windows.Forms.Button;$copy.SetBounds(22,125,180,38);$copy.Text='复制本机配对码'
$copy.Add_Click({[Windows.Forms.Clipboard]::SetText($token);$status.Text='配对码已复制，请粘贴到扩展的「本机配对码」并点击连接。'})
$form.Controls.Add($copy)
$folder=New-Object Windows.Forms.Button;$folder.SetBounds(218,125,180,38);$folder.Text='打开扩展文件夹'
$folder.Add_Click({Start-Process explorer.exe -ArgumentList ('"{0}"' -f ([IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\browser-extension'))))})
$form.Controls.Add($folder)
$settings=New-Object Windows.Forms.Button;$settings.SetBounds(414,125,202,38);$settings.Text='设置手机推送／响铃'
$settings.Add_Click({Start-Process -FilePath $psExe -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "{0}"' -f (Join-Path $PSScriptRoot 'Configure-PhoneNotification.ps1')) -WindowStyle Hidden})
$form.Controls.Add($settings)
$steps=New-Object Windows.Forms.Label;$steps.SetBounds(22,182,596,205)
$steps.Text="首次安装：`r`n1. Edge 地址栏打开 edge://extensions，打开开发人员模式。`r`n2. 点「加载解压缩的扩展」，选择公开仓库的 browser-extension 文件夹。`r`n3. 打开邮箱收件列表，点扩展图标，粘贴配对码并连接。`r`n4. 页面加载完成后点「开启当前页」。旧邮件默认不会推送。`r`n`r`n夜间响铃：安卓安装「安卓告警响铃助手.apk」，授权并开启守护；电脑推送设置勾选持续响铃。先完成手机锁屏测试。"
$form.Controls.Add($steps)
$status=New-Object Windows.Forms.Label;$status.SetBounds(22,395,596,65);$status.Text='本机接收端已请求启动。扩展的「刷新状态」可检查实际连接。'
$form.Controls.Add($status)
$note=New-Object Windows.Forms.Label;$note.SetBounds(22,460,596,35);$note.Text='电脑、邮箱与网络需持续可用；刷新网页后需要重新开启监控。';$note.ForeColor=[Drawing.Color]::DimGray
$form.Controls.Add($note)
$stop=New-Object Windows.Forms.Button;$stop.SetBounds(22,503,180,35);$stop.Text='停止本机接收端'
$stop.Add_Click({
    try {
        $reply=Invoke-RestMethod -Uri 'http://127.0.0.1:17368/stop' -Method Post -Headers @{'X-Monitor-Token'=$token} -ContentType 'application/json' -Body '{}' -TimeoutSec 5
        $status.Text='接收端已停止。需要监控时重新打开本设置窗口。'
    } catch { $status.Text='接收端未响应，可能已停止。扩展中也请点击停止监控。' }
})
$form.Controls.Add($stop)
$running=New-Object Windows.Forms.Label;$running.SetBounds(218,508,395,35);$running.Text='关闭此设置窗口后，接收端继续在后台运行。'
$form.Controls.Add($running)
[void]$form.ShowDialog();$form.Dispose()
