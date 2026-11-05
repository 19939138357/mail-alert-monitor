$taskRoot = $PSScriptRoot
$taskStop = Join-Path $taskRoot '04_资料\运行缓存\mail-confirmation.stop'
[void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($taskStop))
[IO.File]::WriteAllText($taskStop, 'stop', [Text.UTF8Encoding]::new($false))
Write-Host '已请求停止自动取确认码。当前识别或发送结束后停止，不再点击新邮件。'
