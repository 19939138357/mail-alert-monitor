param(
    [string]$ConfigPath = '.\monitor_config.json',
    [ValidateRange(1024,65535)][int]$Port = 17368,
    [string]$StateDirectory = '',
    [switch]$NoSend,
    [switch]$LibraryOnly
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'NotificationTransport.ps1')
. (Join-Path $PSScriptRoot 'BrowserAlertSupport.ps1')
if ($LibraryOnly) { return }
if (-not [IO.Path]::IsPathRooted($ConfigPath)) { $ConfigPath=Join-Path $PSScriptRoot $ConfigPath }
if (-not $StateDirectory) { $StateDirectory=Join-Path $PSScriptRoot '04_资料/私密配置' }
$mutex=[Threading.Mutex]::new($false,('Local\BrowserMailReceiver-'+$Port))
$locked=$false; $listener=$null
try {
    try {$locked=$mutex.WaitOne(0)} catch [Threading.AbandonedMutexException] {$locked=$true}
    if (-not $locked) { Write-Host '网页告警接收端已运行。'; exit 0 }
    $token=Get-BrowserPairingToken (Join-Path $StateDirectory 'browser_pairing.xml')
    $ledgerPath=Join-Path $StateDirectory 'browser_events.json'
    $ledger=Read-BrowserLedger $ledgerPath
    $listener=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,$Port)
    $listener.Start()
    Write-Host "网页告警接收端已启动，端口 $Port。请使用「网页告警设置」复制配对码。"
    if ($NoSend) { Write-Host '模拟模式：不会发送手机通知。' }
    while ($true) {
        $client=$listener.AcceptTcpClient()
        try {
            $client.ReceiveTimeout=1500; $client.SendTimeout=3000
            $stream=$client.GetStream(); $stream.ReadTimeout=1500; $stream.WriteTimeout=3000
            $request=Read-BrowserHttpRequest $stream
            $origin=[string]$request.Headers['origin']
            if ($request.Headers['host'] -cne "127.0.0.1:$Port" -or ($origin -and $origin -cnotmatch '^chrome-extension://[a-p]{32}$')) {
                Write-BrowserHttpResponse $stream 403 @{status='PermanentFailure';message='不允许的请求来源'}; continue
            }
            if ($request.Method -eq 'OPTIONS') {
                if (-not $origin) { Write-BrowserHttpResponse $stream 403 @{status='PermanentFailure'}; continue }
                Write-BrowserHttpResponse $stream 200 @{status='Ready'} $origin; continue
            }
            if ($request.Headers['x-monitor-token'] -cne $token) {
                Write-BrowserHttpResponse $stream 401 @{status='PermanentFailure';message='本机配对码不正确'} $origin; continue
            }
            $config=Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($request.Method -eq 'GET' -and $request.Path -eq '/status') {
                $configured=$false; $night=$false
                try { $settings=Read-NotificationConfiguration $config; $configured=$true; $night=[bool](Get-NotificationValue $settings.Settings 'nightAlarmEnabled' $false) } catch { }
                $message=if ($configured) {'接收端已就绪'} else {'请先通过「设置手机推送」保存微信、QQ邮箱或钉钉配置'}
                Write-BrowserHttpResponse $stream 200 @{status='Ready';configured=$configured;nightAlarmEnabled=$night;keywords=@(Get-BrowserKeywords $config);message=$message;simulation=[bool]$NoSend} $origin
            } elseif ($request.Method -eq 'POST' -and $request.Path -eq '/stop') {
                Write-BrowserHttpResponse $stream 200 @{status='Stopped';message='本机接收端已停止'} $origin
                break
            } elseif ($request.Method -eq 'POST' -and $request.Path -eq '/trigger') {
                if ($request.Headers['content-type'] -notmatch '^application/json(?:;|$)') { throw 'Invalid content type' }
                $event=$request.Body | ConvertFrom-Json -ErrorAction Stop
                $result=Invoke-BrowserAlertEvent -Event $event -Config $config -Ledger $ledger -LedgerPath $ledgerPath -NoSend:$NoSend
                Write-BrowserHttpResponse $stream $result.Code $result $origin
                # Never put mailbox contents, event keywords, pairing token or destination in logs.
                Write-Host ('[{0}] 网页告警处理结果：{1}' -f (Get-Date -Format 'HH:mm:ss'),$result.status)
            } else { Write-BrowserHttpResponse $stream 404 @{status='PermanentFailure';message='请求路径不存在'} $origin }
        } catch {
            try {
                $errorStream=$client.GetStream()
                # Discard a bounded amount already buffered so a small rejected body
                # does not reset the connection before the error response is read.
                $discard=New-Object byte[] 1024; $discarded=0
                while ($errorStream.DataAvailable -and $discarded -lt 8192) {
                    $discarded += $errorStream.Read($discard,0,$discard.Length)
                }
                Write-BrowserHttpResponse $errorStream 400 @{status='PermanentFailure';message='请求无效或处理失败，请检查本机配置'}
            } catch { }
        } finally { $client.Close() }
    }
} finally {
    if ($listener) {$listener.Stop()}
    if ($locked) {$mutex.ReleaseMutex()}
    $mutex.Dispose()
}
