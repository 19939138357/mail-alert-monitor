# One writer: the monitor owns the existing per-directory instance lock.
function Get-FoxmailQueueHash([string]$Value) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Value))).Replace('-','') }
    finally { $sha.Dispose() }
}

function Protect-FoxmailQueue([byte[]]$Bytes) {
    return ,([Security.Cryptography.ProtectedData]::Protect($Bytes,$null,[Security.Cryptography.DataProtectionScope]::CurrentUser))
}

function Unprotect-FoxmailQueue([byte[]]$Bytes) {
    return ,([Security.Cryptography.ProtectedData]::Unprotect($Bytes,$null,[Security.Cryptography.DataProtectionScope]::CurrentUser))
}

function Save-FoxmailQueue($Queue, [string]$Path) {
    $folder = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Path))
    [void][IO.Directory]::CreateDirectory($folder)
    $bytes = [Text.Encoding]::UTF8.GetBytes(($Queue | ConvertTo-Json -Compress -Depth 16))
    $cipher = Protect-FoxmailQueue $bytes
    $stage = Join-Path $folder ([guid]::NewGuid().ToString('N') + '.pending')
    try {
        $stream = [IO.File]::Open($stage,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        try { $stream.Write($cipher,0,$cipher.Length); $stream.Flush($true) } finally { $stream.Dispose() }
        if ([IO.File]::Exists($Path)) { [IO.File]::Replace($stage,$Path,[NullString]::Value) }
        else { [IO.File]::Move($stage,$Path) }
    } finally { if ([IO.File]::Exists($stage)) { [IO.File]::Delete($stage) } }
}

function Read-FoxmailQueue([string]$Path) {
    if (-not [IO.File]::Exists($Path)) { return [pscustomobject]@{Version=1;Items=@()} }
    try {
        $plain = Unprotect-FoxmailQueue ([IO.File]::ReadAllBytes($Path))
        $queue = [Text.Encoding]::UTF8.GetString($plain) | ConvertFrom-Json -ErrorAction Stop
        if ($queue.Version -ne 1 -or $null -eq $queue.Items) { throw 'format' }
        $known = @{}
        foreach ($item in $queue.Items) {
            if ($item.Key -notmatch '^[A-F0-9]{64}$' -or $known.ContainsKey($item.Key) -or
                $item.Status -notin @('queued','reading','ready','sending','accepted','uncertain','rejected','duplicate','review')) {
                throw 'record'
            }
            $known[$item.Key] = $true
            if ($item.Status -eq 'sending') { $item.Status = 'uncertain' }
        }
        return $queue
    } catch { throw '无法读取加密的未读邮件队列。请用原 Windows 用户打开并核查原文件。已停止本模式。' }
}

function Get-FoxmailDeliveryState($Queue) {
    $attention = @($Queue.Items | Where-Object { $_.Status -in @('review','rejected','uncertain') }).Count
    $waiting = @($Queue.Items | Where-Object { $_.Status -in @('queued','reading','ready') }).Count
    return "待处理 $waiting 封，待核对 $attention 封。"
}

function Send-FoxmailQueueItem($Queue,$Item,$Config,[string]$Path,[long]$Tick) {
    $Item.Status = 'sending'
    Save-FoxmailQueue $Queue $Path
    $outcome = 'Uncertain'
    $accepted = $false
    try {
        $mail = $Item.Mail
        $message = "发件人：$($mail.Sender)`n邮件时间：$($mail.Time)`n`n$($mail.Body)"
        $accepted = Send-MonitorNotification -Config $Config -Title $mail.Subject -Message $message -Outcome ([ref]$outcome) -IsAlarm -PreserveSubject
    } catch { $outcome = 'Uncertain' }
    if ($accepted -and $outcome -eq 'Success') {
        $Item.Status = 'accepted'; $Item.Mail = $null; $Item.Ticket = $null
    } elseif ($outcome -eq 'RetryableFailure') {
        $Item.Status = 'ready'; $Item.After = $Tick + 60
    } elseif ($outcome -eq 'PermanentFailure') {
        $Item.Status = 'rejected'
        $Item.Configuration = Get-NotificationConfigurationVersion -Config $Config
    } else { $Item.Status = 'uncertain' }
    Save-FoxmailQueue $Queue $Path
}

function Invoke-FoxmailQueueTick($Queue,$Config,$Engine,[string]$Path,[long]$Tick) {
    # A notification already in the outbox can be delivered while the mailbox is offline.
    $known = @{}
    foreach ($item in $Queue.Items) { $known[$item.Key] = $true }
    $screenFailed = $false
    $script:FoxmailListAttention = $false
    try { $visible = @(Get-FoxmailScreenUnread -Config $Config -Engine $Engine) }
    catch { $visible = @(); $screenFailed = $true }
    $added = @()
    $ambiguous = $script:FoxmailListAttention
    foreach ($group in @($visible | Where-Object { $_ -and $_.Key } | Group-Object Key)) {
        if ($group.Count -ne 1) { $ambiguous = $true; continue }
        $ticket = $group.Group[0]
        $key = Get-FoxmailQueueHash ([string]$ticket.Key)
        if ($known.ContainsKey($key)) { continue }
        if ($ticket.PSObject.Properties['Family'] -and $ticket.PSObject.Properties['Earliest'] -and $ticket.PSObject.Properties['Latest']) {
            $overlaps = @($Queue.Items | Where-Object { $_.Ticket -and $_.Ticket.Family -eq $ticket.Family -and
                [datetime]$_.Ticket.Earliest -le [datetime]$ticket.Latest -and [datetime]$_.Ticket.Latest -ge [datetime]$ticket.Earliest })
            if ($overlaps.Count -gt 0) { continue }
        }
        $added += [pscustomobject]@{Key=$key;Ticket=$ticket;Identity='';Mail=$null;Status='queued';After=0L;Attempts=0;Configuration=''}
        $known[$key]=$true
    }
    if ($added.Count -gt 0) {
        $Queue.Items = @($Queue.Items) + $added
        Save-FoxmailQueue $Queue $Path
    }

    $ready = $Queue.Items | Where-Object { $_.Status -eq 'ready' -and $_.After -le $Tick } | Select-Object -First 1
    if ($null -eq $ready) {
        $rejected = @($Queue.Items | Where-Object { $_.Status -eq 'rejected' })
        if ($rejected.Count -gt 0) {
            $revision = Get-NotificationConfigurationVersion -Config $Config
            $ready = $rejected | Where-Object { $_.Configuration -ne $revision } | Select-Object -First 1
        }
    }
    $attentionHint = if ($ambiguous) { '部分未读标记尚未认清，请检查列表区域。' } else { '' }
    if ($null -ne $ready) {
        Send-FoxmailQueueItem $Queue $ready $Config $Path $Tick
        return $attentionHint
    }
    if ($screenFailed) { return '窗口未就绪，已保留队列。' }
    $candidate = $Queue.Items | Where-Object { $_.Status -in @('reading','queued','review') -and $_.After -le $Tick } | Select-Object -First 1
    if ($null -eq $candidate) { return $attentionHint }
    $bodyEngine=$Config.PSObject.Properties['foxmailBodyOcr']
    if ($bodyEngine -and $bodyEngine.Value -eq 'mimo-local' -and -not (Test-MimoReady)) {
        return '小米本地模型尚未就绪。已保留未读队列，请在监控设置启动模型。'
    }
    $resume = $candidate.Status -ne 'queued'
    $candidate.Status = 'reading'
    Save-FoxmailQueue $Queue $Path
    $mail = $null
    try { $mail = Get-FoxmailOpenContent -Config $Config -Engine $Engine -Ticket $candidate.Ticket -ResumeOnly:$resume }
    catch { $mail = $null }
    if ($null -eq $mail -or $mail.Complete -isnot [bool] -or -not $mail.Complete -or [string]::IsNullOrWhiteSpace($mail.Body) -or
        [string]::IsNullOrWhiteSpace($mail.Subject) -or [string]::IsNullOrWhiteSpace($mail.Sender) -or
        [string]::IsNullOrWhiteSpace($mail.Time) -or [string]::IsNullOrWhiteSpace($mail.Identity)) {
        $candidate.Attempts++
        $candidate.Status = 'review'
        $candidate.After = $Tick + [Math]::Min(120, 4 * $candidate.Attempts)
        Save-FoxmailQueue $Queue $Path
        return
    }
    $identity = Get-FoxmailQueueHash $mail.Identity
    $other = $Queue.Items | Where-Object { $_.Key -ne $candidate.Key -and $_.Identity -eq $identity } | Select-Object -First 1
    $candidate.Identity = $identity
    if ($other) {
        $candidate.Status = 'duplicate'; $candidate.Ticket = $null
    } else {
        $candidate.Mail = [pscustomobject]@{Sender=$mail.Sender;Subject=$mail.Subject;Time=$mail.Time;Body=$mail.Body}
        $candidate.Status = 'ready'; $candidate.After = 0
    }
    Save-FoxmailQueue $Queue $Path
    return $attentionHint
}

function Start-FoxmailUnreadMonitor($Config,[switch]$Once,[switch]$NoSend) {
    if ($NoSend) { Write-MonitorLog $Config '只读检查：未打开邮件、未发送。'; return }
    Add-Type -AssemblyName System.Security
    $path = Join-Path $PSScriptRoot '04_资料\私密配置\foxmail-unread.dpapi'
    $Config = $Config | ConvertTo-Json -Depth 16 | ConvertFrom-Json
    $Config.scanFullDesktopWhenNoWindow = $false
    $Config.processNameContains = @()
    $queue = Read-FoxmailQueue $path
    $engine = New-OcrEngine (Get-ConfigString $Config 'ocrLanguage' 'zh-Hans-CN')
    $last = ''; $loggedAt = 0L
    do {
        $tick = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        $reason = Invoke-FoxmailQueueTick $queue $Config $engine $path $tick
        $message = "未读邮件正文 · $(Get-FoxmailDeliveryState $queue) $reason [FoxmailQueue]"
        if ($message -ne $last -or $tick - $loggedAt -ge 30) {
            Write-MonitorLog $Config $message; $last = $message; $loggedAt = $tick
        }
        if (-not $Once) { Start-Sleep -Seconds ([Math]::Max(1,[Math]::Min(60,(Get-ConfigInt $Config 'intervalSeconds' 2)))) }
    } while (-not $Once)
}
