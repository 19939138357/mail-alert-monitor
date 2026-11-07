$ErrorActionPreference='Stop'
Set-StrictMode -Version 2
$folder=Join-Path $PSScriptRoot 'MiMo'
[void][IO.Directory]::CreateDirectory($folder)
$manifest=Get-Content -LiteralPath (Join-Path $folder 'model.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$mutex=[Threading.Mutex]::new($false,'Local\MailAlertMimoModel')
$locked=$false
function Get-MimoFile($Item) {
    $destination=Join-Path $folder $Item.name
    if ((Test-Path -LiteralPath $destination) -and (Get-Item -LiteralPath $destination).Length -eq $Item.size -and
        (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToLowerInvariant() -eq $Item.sha256) {return $destination}
    $partial=$destination+'.partial'
    if ((Test-Path -LiteralPath $partial) -and (Get-Item -LiteralPath $partial).Length -ge $Item.size) {
        if ((Get-Item -LiteralPath $partial).Length -eq $Item.size -and (Get-FileHash -LiteralPath $partial -Algorithm SHA256).Hash.ToLowerInvariant() -eq $Item.sha256) {
            Move-Item -LiteralPath $partial -Destination $destination -Force;return $destination
        }
        Remove-Item -LiteralPath $partial -Force
    }
    $urls=@([string]$Item.url)
    if ($Item.url.StartsWith('https://huggingface.co/')) { $urls+= $Item.url.Replace('https://huggingface.co/','https://hf-mirror.com/') }
    for ($round=0;$round -lt 3;$round++) {
        foreach ($url in $urls) {
            Write-Host ('下载 '+$Item.name+'，中断后可重新打开继续。')
            & curl.exe --fail --location --show-error --connect-timeout 15 --speed-limit 1024 --speed-time 60 --retry 2 --continue-at - --output $partial $url
            if ($LASTEXITCODE -ne 0) {continue}
            if ((Get-Item -LiteralPath $partial).Length -eq $Item.size -and (Get-FileHash -LiteralPath $partial -Algorithm SHA256).Hash.ToLowerInvariant() -eq $Item.sha256) {
                Move-Item -LiteralPath $partial -Destination $destination -Force
                return $destination
            }
            Remove-Item -LiteralPath $partial -Force
            Write-Host '校验未通过，重新获取文件。'
        }
    }
    throw '模型下载尚未完成，请检查网络后重开。已下载的部分会保留。'
}
try {
    try { $locked=$mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $locked=$true }
    if (-not $locked) { throw '已有小米模型窗口，请查看原来的窗口。' }
    Write-Host '小米 MiMo 本地免费识别。首次下载约 5.4 GB，建议 16 GB 或更多内存。'
    $runtime=$manifest.runtime.'windows-x64'
    $package=Get-MimoFile $runtime
    $destination=Join-Path $folder 'runtime'
    $stamp=Join-Path $destination '.archive-sha256'
    if (-not (Test-Path -LiteralPath $stamp) -or (Get-Content -LiteralPath $stamp -Raw).Trim() -ne $runtime.sha256) {
        $stage=Join-Path $folder ('runtime-'+[guid]::NewGuid().ToString('N'))
        try {
            Expand-Archive -LiteralPath $package -DestinationPath $stage
            if (Test-Path -LiteralPath $destination) {Remove-Item -LiteralPath $destination -Recurse -Force}
            Move-Item -LiteralPath $stage -Destination $destination
            Set-Content -LiteralPath $stamp -Value $runtime.sha256 -Encoding ASCII
        } finally {if (Test-Path -LiteralPath $stage) {Remove-Item -LiteralPath $stage -Recurse -Force}}
    }
    $model=Get-MimoFile $manifest.files[0]
    $projector=Get-MimoFile $manifest.files[1]
    $servers=@(Get-ChildItem -LiteralPath $destination -Filter llama-server.exe -Recurse)
    if ($servers.Count -ne 1) {throw '模型程序不完整，请移除 MiMo/runtime 文件夹后重开。'}
    $tokenFile=Join-Path $folder 'service.token'
    if (-not (Test-Path -LiteralPath $tokenFile)) {
        $bytes=New-Object byte[] 32;$rng=[Security.Cryptography.RandomNumberGenerator]::Create()
        try {$rng.GetBytes($bytes)} finally {$rng.Dispose()}
        $secret=[BitConverter]::ToString($bytes).Replace('-','').ToLowerInvariant()
        [IO.File]::WriteAllText($tokenFile,$secret,[Text.Encoding]::ASCII)
        $acl=[Security.AccessControl.FileSecurity]::new()
        $acl.SetAccessRuleProtection($true,$false)
        $user=[Security.Principal.WindowsIdentity]::GetCurrent().User
        $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($user,'FullControl','Allow'))
        Set-Acl -LiteralPath $tokenFile -AclObject $acl
    }
    $secret=(Get-Content -LiteralPath $tokenFile -Raw -Encoding ASCII).Trim()
    if ($secret -cnotmatch '^[a-f0-9]{64}$') {throw '本机连接凭据无效，请移除 MiMo/service.token 后重开。'}
    $probe=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,48765)
    try {$probe.Start()} finally {$probe.Stop()}
    Write-Host '正在加载模型。关闭此窗口会停止小米识别，监控队列会保留。'
    $arguments='--model "'+$model+'" --mmproj "'+$projector+'" --api-key '+$secret+' --alias mimo-vl-local --host 127.0.0.1 --port 48765 --jinja --reasoning-budget 0 --ctx-size 8192 --parallel 1 --batch-size 256 --ubatch-size 128 --threads 4 --n-gpu-layers 0 --log-disable'
    $process=Start-Process -FilePath $servers[0].FullName -ArgumentList $arguments -NoNewWindow -PassThru
    try {
        $ready=$false
        for ($attempt=0;$attempt -lt 180;$attempt++) {
            if ($process.HasExited) {throw '模型程序已退出，请检查电脑可用内存。'}
            try {
                $health=[Net.HttpWebRequest]::Create('http://127.0.0.1:48765/health');$health.Proxy=$null;$health.Timeout=2000
                $reply=$health.GetResponse();$reply.Close();$ready=$true;break
            } catch {Start-Sleep -Seconds 1}
        }
        if (-not $ready) {throw '模型加载超时，请检查可用内存后重开。'}
        Write-Host '小米模型已就绪。回到监控设置选择“小米 MiMo 本地”。'
        $process.WaitForExit()
    } finally {if (-not $process.HasExited){$process.Kill()};$process.Dispose()}
} catch {Write-Host $_.Exception.Message;[void](Read-Host '按回车关闭')}
finally {if ($locked){$mutex.ReleaseMutex()};$mutex.Dispose()}
