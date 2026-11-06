# Windows PowerShell 5.1. OCR content and confirmation codes stay in memory.
function Get-MailConfirmationTitles {
    param([AllowNull()][string]$Text)
    $normal = [regex]::Replace((ConvertTo-VerificationNormalText $Text), '\s', '')
    foreach ($match in [regex]::Matches($normal, '(?<title>告警抽查邮件|电话抽查邮件|客服电话检查)(?<y>20[0-9]{2})年(?<m>[0-9]{1,2})月(?<d>[0-9]{1,2})日(?<n>[0-9]{1,3})次')) {
        try { $day = [datetime]::new([int]$match.Groups['y'].Value, [int]$match.Groups['m'].Value, [int]$match.Groups['d'].Value) } catch { continue }
        $batch = [int]$match.Groups['n'].Value
        if ($batch -lt 1) { continue }
        $date = $day.ToString('yyyy-MM-dd')
        $kind = if ($match.Groups['title'].Value -eq '告警抽查邮件') { 'alert' } else { 'phone' }
        # Keep historical alert IDs byte-for-byte stable; telephone batches have their own namespace.
        $id = $date + '/' + $batch
        if ($kind -eq 'phone') { $id = 'phone/' + $id }
        [pscustomobject]@{ Day = $date; Batch = $batch; Id = $id; Kind = $kind }
    }
}

function Test-MailConfirmationSender {
    param([AllowNull()][string]$Text, [switch]$ListOcr, [string]$ExpectedSender = 'report@example.com')
    $normal = [regex]::Replace((ConvertTo-VerificationNormalText $Text), '[^\S\r\n]', '')
    if ([string]::IsNullOrWhiteSpace($ExpectedSender)) { return $false }
    $address = [regex]::Escape($ExpectedSender.Trim())
    return $normal -match ('(?i)(?<![a-z0-9_.+\-])' + $address + '(?![a-z0-9_.\-])')
}

function Get-MailConfirmationDefinition {
    param($Event)
    if ($Event.Id -like 'phone/*') {
        return [pscustomobject]@{ Kind = 'phone'; Title = '电话抽查邮件'; ShortTitle = '电话抽查'; Digits = 4; Label = '验证码'; LabelPattern = '(?:确[ \t]*认[ \t]*码|验[ \t]*证[ \t]*码)' }
    }
    return [pscustomobject]@{ Kind = 'alert'; Title = '告警抽查邮件'; ShortTitle = '告警抽查'; Digits = 6; Label = '确认码'; LabelPattern = '确[ \t]*认[ \t]*码' }
}

function Get-MailConfirmationBaseline {
    param($State, [string]$Kind)
    if ($Kind -eq 'phone') { return [pscustomobject]@{ Day = $State.Data.PhoneDay; Batch = $State.Data.PhoneBatch } }
    return [pscustomobject]@{ Day = $State.Data.Day; Batch = $State.Data.Batch }
}

function Set-MailConfirmationBaseline {
    param($State, $Event)
    if ((Get-MailConfirmationDefinition $Event).Kind -eq 'phone') {
        $State.Data.PhoneDay = $Event.Day; $State.Data.PhoneBatch = $Event.Batch
    } else { $State.Data.Day = $Event.Day; $State.Data.Batch = $Event.Batch }
}

function Get-MailConfirmationRows {
    param($Layout, [datetime]$Now = (Get-Date), [switch]$IncludePast, [string]$ExpectedSender = 'report@example.com')
    if ($null -eq $Layout) { return }
    $rows = @(foreach ($line in $Layout.Lines) {
        $titles = @(Get-MailConfirmationTitles $line.Text)
        if ($titles.Count -ne 1) { continue }
        $today = $Now.ToString('yyyy-MM-dd')
        if ($titles[0].Day -gt $today -or (-not $IncludePast -and $titles[0].Day -ne $today)) { continue }
        # Foxmail list: sender immediately above its subject. Never use the reader's sender.
        $sender = @($Layout.Lines | Where-Object {
            $_.Top -le $line.Top -and ($line.Top - $_.Top) -le [Math]::Max(32, $line.Height * 3) -and
            [Math]::Abs($_.Left - $line.Left) -le [Math]::Max(25, $line.Height * 2) -and (Test-MailConfirmationSender $_.Text -ListOcr -ExpectedSender $ExpectedSender)
        })
        if ($sender.Count -eq 0 -or $line.Width -lt 40 -or $line.Height -lt 5) { continue }
        $x = $line.Left + [Math]::Min($line.Width * 0.5, 100)
        $y = $line.Top + $line.Height * 0.5
        if ($x -le 2 -or $y -le 2 -or $x -ge $Layout.Width - 2 -or $y -ge $Layout.Height - 2) { continue }
        [pscustomobject]@{ Id = $titles[0].Id; Day = $titles[0].Day; Batch = $titles[0].Batch; Kind = $titles[0].Kind; IsCurrent = ($titles[0].Day -eq $today); X = $x; Y = $y }
    })
    foreach ($kind in @('alert', 'phone')) {
        $ordered = @($rows | Where-Object Kind -eq $kind | Sort-Object Day, Batch -Descending)
        if ($ordered.Count -eq 0) { continue }
        # Duplicate locations for one identity cannot be clicked; the other type remains independent.
        if (@($ordered | Where-Object Id -eq $ordered[0].Id).Count -ne 1) { continue }
        $ordered[0]
    }
}

function Get-MailConfirmationRow {
    param($Layout, [datetime]$Now = (Get-Date))
    return Get-MailConfirmationRows $Layout $Now | Sort-Object Batch -Descending | Select-Object -First 1
}

function Select-MailConfirmationRow {
    param([object[]]$Rows, $State)
    $eligible = @(foreach ($row in $Rows) {
        $baseline = Get-MailConfirmationBaseline $State $row.Kind
        # A complete older row may initialize an unknown stream, but must never be opened.
        if ($baseline.Day -and -not $row.IsCurrent) { continue }
        if ($State.Data.Records.ContainsKey((Get-MailConfirmationKey $row.Id))) { continue }
        if ($baseline.Day -and ($row.Day -lt $baseline.Day -or ($row.Day -eq $baseline.Day -and $row.Batch -le $baseline.Batch))) { continue }
        $row
    })
    # Alternate when both streams have work; batch numbers from different mail types are unrelated.
    return $eligible | Sort-Object @{ Expression = { $_.Kind -eq $State.LastSelectedKind } }, Y, Kind | Select-Object -First 1
}

function Update-MailConfirmationEmptyBaselines {
    param($State, $Layout, [object[]]$Rows, [datetime]$Now, [string]$ExpectedSender = 'report@example.com')
    $loadedList = $null -ne $Layout -and @($Layout.Lines | Where-Object { Test-MailConfirmationSender $_.Text -ListOcr -ExpectedSender $ExpectedSender }).Count -gt 0
    $text = if ($null -ne $Layout) { [regex]::Replace(($Layout.Lines.Text -join ''), '\s', '') } else { '' }
    $changed = $false
    foreach ($kind in @('alert', 'phone')) {
        $baseline = Get-MailConfirmationBaseline $State $kind
        $clockProperty = if ($kind -eq 'phone') { 'PhoneEmptySince' } else { 'EmptySince' }
        if ($baseline.Day) { $State.$clockProperty = $null; continue }
        $fragment = if ($kind -eq 'phone') { '(?:电话抽查|客服电话)' } else { '告警抽查' }
        # Truncated, duplicate or unreadable target rows are never evidence of an empty stream.
        if (-not $loadedList -or @($Rows | Where-Object Kind -eq $kind).Count -gt 0 -or $text -match $fragment) {
            $State.$clockProperty = $null; continue
        }
        if ($null -eq $State.$clockProperty) { $State.$clockProperty = $Now }
        if (($Now - $State.$clockProperty).TotalSeconds -ge 4) {
            $id = if ($kind -eq 'phone') { 'phone/empty' } else { 'empty' }
            Set-MailConfirmationBaseline $State ([pscustomobject]@{ Id = $id; Day = $Now.ToString('yyyy-MM-dd'); Batch = 0 })
            Save-MailConfirmationState $State
            $changed = $true
        }
    }
    return $changed
}

function Get-MailConfirmationCode {
    param([AllowNull()][string]$Text, $Expected, [string]$ExpectedSender = 'report@example.com')
    if ($null -eq $Expected -or -not (Test-MailConfirmationSender $Text -ExpectedSender $ExpectedSender)) { return }
    $titles = @(Get-MailConfirmationTitles $Text | Select-Object -ExpandProperty Id -Unique)
    if ($titles.Count -ne 1 -or $titles[0] -ne $Expected.Id) { return }
    $definition = Get-MailConfirmationDefinition $Expected
    # Labels and code lengths are selected by the verified mail identity, never by a number alone.
    $normal = ConvertTo-VerificationNormalText $Text
    $codes = @()
    foreach ($hit in @(Get-VerificationCodeMatches $normal)) {
        if ($hit.Evidence -match $definition.LabelPattern) { $codes += $hit.Code }
    }
    $codes = @($codes | Select-Object -Unique)
    if ($codes.Count -eq 1 -and $codes[0] -cmatch ('^[0-9]{' + $definition.Digits + '}$')) { return [string]$codes[0] }
}

function Get-MailConfirmationPaths {
    $dir = Join-Path $PSScriptRoot '04_资料\运行缓存'
    [pscustomobject]@{ State = Join-Path $dir 'mail-confirmation-state.json'; Stop = Join-Path $dir 'mail-confirmation.stop' }
}

function Get-MailConfirmationDateStatus {
    param([AllowNull()][string]$Text, $Expected, [datetime]$Now, [string]$ExpectedSender = 'report@example.com')
    $titles = @(Get-MailConfirmationTitles $Text | Select-Object -ExpandProperty Id -Unique)
    if ($titles.Count -ne 1 -or $titles[0] -ne $Expected.Id -or -not (Test-MailConfirmationSender $Text -ExpectedSender $ExpectedSender)) { return 'Missing' }
    $normal = [regex]::Replace((ConvertTo-VerificationNormalText $Text), '\s', '')
    $definition = Get-MailConfirmationDefinition $Expected
    $label = [regex]::Match($normal, $definition.LabelPattern)
    if (-not $label.Success) { return 'Missing' }
    $codeLabel = $label.Index
    # Only the header before the first confirmation label can establish the mail's age.
    $header = $normal.Substring(0, $codeLabel)
    # Reproduced Windows OCR artifact: date hyphens rendered in a Chinese UI font become 一.
    # Normalize only separators in a complete numeric date+time; never infer missing digits.
    $header = [regex]::Replace($header, '(?<![0-9])(?<y>20[0-9]{2})[-一](?<m>[0-9]{2})[-一](?<d>[0-9]{2})(?<t>[0-9]{2}:[0-9]{2})(?![0-9])', '${y}-${m}-${d}${t}')
    $dates = @([regex]::Matches($header, '(?<![0-9])(?<d>20[0-9]{2}-[0-9]{2}-[0-9]{2})(?<t>[0-9]{2}:[0-9]{2})(?![0-9])'))
    if ($dates.Count -ne 1 -or $dates[0].Groups['d'].Value -ne $Expected.Day) { return 'Missing' }
    $sent = [datetime]::MinValue
    if (-not [datetime]::TryParseExact(($dates[0].Groups['d'].Value + ' ' + $dates[0].Groups['t'].Value), 'yyyy-MM-dd HH:mm', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$sent)) { return 'Missing' }
    $age = ($Now - $sent).TotalSeconds
    if ($age -lt -120) { return 'Missing' }
    if ($age -ge 900) { return 'Expired' }
    return 'Current'
}

function New-MailConfirmationState {
    param([string]$Path = '', [datetime]$Now = (Get-Date))
    $data = @{ Version = 2; Day = ''; Batch = 0; PhoneDay = ''; PhoneBatch = 0; Records = @{} }
    if ($Path -and (Test-Path -LiteralPath $Path)) {
        $loaded = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        if ($loaded.Version -notin @(1, 2) -or $null -eq $loaded.Records -or $loaded.Batch -lt 0 -or $loaded.Batch -gt 999 -or $loaded.Day -notmatch '^$|^20[0-9]{2}-[0-9]{2}-[0-9]{2}$') { throw 'Invalid mail confirmation state. Keep the file for diagnosis.' }
        $data.Day = [string]$loaded.Day; $data.Batch = [int]$loaded.Batch
        if ($loaded.Version -eq 2) {
            if ($loaded.PhoneBatch -lt 0 -or $loaded.PhoneBatch -gt 999 -or $loaded.PhoneDay -notmatch '^$|^20[0-9]{2}-[0-9]{2}-[0-9]{2}$') { throw 'Invalid telephone mail confirmation state. Keep the file for diagnosis.' }
            $data.PhoneDay = [string]$loaded.PhoneDay; $data.PhoneBatch = [int]$loaded.PhoneBatch
        }
        foreach ($property in $loaded.Records.PSObject.Properties) {
            $record = $property.Value
            if ($property.Name -notmatch '^[a-f0-9]{64}$' -or $record.Status -notin @('Baseline','Reading','Sending','Sent','Uncertain','RetryableFailure','PermanentFailure','NoCode','Expired')) { throw 'Invalid mail confirmation record.' }
            if (($Now - [datetime]::Parse($record.At)).TotalDays -le 7) { $data.Records[$property.Name] = $record }
        }
    }
    [pscustomobject]@{ Path = $Path; Data = $data; Candidate = $null; Frames = 0; EmptySince = $null; PhoneEmptySince = $null; LastSelectedKind = ''; Pending = $null; LastFrameAt = $null; Scope = ''; LastStatus = ''; LastStatusAt = [datetime]::MinValue }
}

function Get-MailConfirmationKey {
    param([string]$Id)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes('mail-confirmation/' + $Id))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Save-MailConfirmationState {
    param($State)
    if (-not $State.Path) { return }
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($State.Path))
    $temp = $State.Path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    try {
        [IO.File]::WriteAllText($temp, ($State.Data | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
        Set-NotificationAtomicFile -StagedPath $temp -DestinationPath $State.Path
    }
    finally { if ([IO.File]::Exists($temp)) { [IO.File]::Delete($temp) } }
}

function Set-MailConfirmationRecord {
    param($State, $Event, [string]$Status, [datetime]$Now)
    $State.Data.Records[(Get-MailConfirmationKey $Event.Id)] = @{ Status = $Status; At = $Now.ToString('o') }
    if ($State.Data.Records.Count -gt 1024) {
        $oldest = @($State.Data.Records.GetEnumerator() | Sort-Object { [datetime]::Parse($_.Value.At) } | Select-Object -First ($State.Data.Records.Count - 1024))
        foreach ($item in $oldest) { $State.Data.Records.Remove($item.Key) }
    }
    Save-MailConfirmationState $State
}

function Send-MailConfirmationMessage {
    param($Config, $Event, [AllowEmptyString()][string]$Code, [ref]$Outcome)
    $definition = Get-MailConfirmationDefinition $Event
    $title = if ($Code) { $definition.ShortTitle + $definition.Label + '：' + $Code } else { $definition.Title + '：未能读取' + $definition.Digits + '位' + $definition.Label }
    $body = $definition.Title + ' ' + $Event.Day + ' 第' + $Event.Batch + '次'
    if ($Code) { $body += "`n" + $definition.Label + '：' + $Code }
    else { $body += "`n已发现新邮件，但未能核对正文中的" + $definition.Digits + '位' + $definition.Label + '，请及时手动查看邮件。' }
    $body += "`n识别时间：" + (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    # The alert and its code share one notification and the existing optional night marker.
    return Send-MonitorNotification -Config $Config -Title $title -Message $body -IsAlarm -Outcome $Outcome
}

function Invoke-MailConfirmationDelivery {
    param($State, $Config, [AllowEmptyString()][string]$Code, [datetime]$Now)
    $pending = $State.Pending
    # Commit before the external effect; after a crash a Sending record is never replayed.
    Set-MailConfirmationRecord $State $pending.Event 'Sending' $Now
    $outcome = 'Uncertain'
    $pending.Attempts++; $pending.LastAttempt = $Now
    try { $success = Send-MailConfirmationMessage -Config $Config -Event $pending.Event -Code $Code -Outcome ([ref]$outcome) }
    catch { $success = $false; $outcome = 'Uncertain' }
    if ($success -and $outcome -eq 'Success') { $status = if ($Code) { 'Sent' } else { 'NoCode' } }
    elseif ($outcome -in @('RetryableFailure','PermanentFailure')) { $status = $outcome }
    else { $status = 'Uncertain' }
    Set-MailConfirmationRecord $State $pending.Event $status $Now
    if ($status -ne 'RetryableFailure' -or -not $Code -or $pending.Attempts -ge 3) { $State.Pending = $null }
    return $status
}

function Invoke-MailConfirmationFrame {
    param($State, $Config, $ListLayout, [AllowNull()][string]$BodyText, $Rectangle, $ListRoi,
        [bool]$CanOperate = $true, [datetime]$Now = (Get-Date), [switch]$NoSend)
    if ($NoSend) { return 'DryRun' }
    $expectedSender = [string](Get-VerificationSetting $Config 'mailConfirmationSender' 'report@example.com')
    if ($null -ne $State.LastFrameAt -and (($Now - $State.LastFrameAt).TotalSeconds -lt 0 -or ($Now - $State.LastFrameAt).TotalSeconds -gt 8)) {
        $State.Candidate = $null; $State.Frames = 0; $State.EmptySince = $null; $State.PhoneEmptySince = $null
        if ($null -ne $State.Pending) { $State.Pending.Code = ''; $State.Pending.CodeFrames = 0 }
    }
    $State.LastFrameAt = $Now
    if (-not $CanOperate) {
        $State.Candidate = $null; $State.Frames = 0; $State.EmptySince = $null; $State.PhoneEmptySince = $null
        if ($null -ne $State.Pending) { $State.Pending.Code = ''; $State.Pending.CodeFrames = 0 }
        return 'WaitingForTarget'
    }
    if ($null -ne $State.Pending) {
        $pending = $State.Pending
        $elapsed = ($Now - $pending.Started).TotalSeconds
        if ($elapsed -lt 0 -or $elapsed -ge 120) {
            Set-MailConfirmationRecord $State $pending.Event 'Expired' $Now; $State.Pending = $null
            return 'Expired'
        }
        if ($elapsed -lt 2) { return 'WaitingForPreview' }
        $dateStatus = Get-MailConfirmationDateStatus -Text $BodyText -Expected $pending.Event -Now $Now -ExpectedSender $expectedSender
        if ($dateStatus -eq 'Expired') {
            Set-MailConfirmationRecord $State $pending.Event 'Expired' $Now; $State.Pending = $null
            return 'Expired'
        }
        $code = if ($dateStatus -eq 'Current') { Get-MailConfirmationCode -Text $BodyText -Expected $pending.Event -ExpectedSender $expectedSender } else { $null }
        if (-not $code) { $pending.Code = ''; $pending.CodeFrames = 0 }
        elseif ($code -ceq $pending.Code) { $pending.CodeFrames++ }
        else { $pending.Code = $code; $pending.CodeFrames = 1 }
        if ($pending.CodeFrames -ge 2 -and ($null -eq $pending.LastAttempt -or ($Now - $pending.LastAttempt).TotalSeconds -ge 10)) {
            return Invoke-MailConfirmationDelivery $State $Config $code $Now
        }
        if ($elapsed -ge 40 -and $pending.Attempts -eq 0) { return Invoke-MailConfirmationDelivery $State $Config '' $Now }
        return 'ReadingPreview'
    }
    $rows = @(Get-MailConfirmationRows $ListLayout $Now -IncludePast -ExpectedSender $expectedSender)
    $baselineChanged = Update-MailConfirmationEmptyBaselines $State $ListLayout $rows $Now -ExpectedSender $expectedSender
    $row = Select-MailConfirmationRow $rows $State
    if ($null -eq $row) {
        $State.Candidate = $null; $State.Frames = 0
        if ($baselineChanged) { return 'BaselineReady' }
        if ($rows.Count -gt 0) { return 'Watching' }
        return 'WaitingForCompleteSubject'
    }
    if ($null -ne $State.Candidate -and $State.Candidate.Id -eq $row.Id -and
        [Math]::Abs($State.Candidate.X - $row.X) -lt 5 -and [Math]::Abs($State.Candidate.Y - $row.Y) -lt 5) { $State.Frames++ }
    else { $State.Candidate = $row; $State.Frames = 1 }
    if ($State.Frames -lt 2) { return 'ConfirmingRow' }
    $baseline = Get-MailConfirmationBaseline $State $row.Kind
    if (-not $baseline.Day) {
        Set-MailConfirmationBaseline $State $row
        $State.LastSelectedKind = $row.Kind
        Set-MailConfirmationRecord $State $row 'Baseline' $Now
        return 'BaselineReady'
    }
    if (-not (Invoke-MailConfirmationClick -Rectangle $Rectangle -Roi $ListRoi -Row $row)) { return 'WaitingForIdle' }
    Set-MailConfirmationBaseline $State $row
    $State.LastSelectedKind = $row.Kind
    Set-MailConfirmationRecord $State $row 'Reading' $Now
    $State.Pending = [pscustomobject]@{ Event = $row; Started = $Now; Code = ''; CodeFrames = 0; Attempts = 0; LastAttempt = $null }
    return 'OpenedNewMail'
}

function Initialize-MailConfirmationNative {
    if ('MailConfirmationInput' -as [type]) { return }
    Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class MailConfirmationInput {
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X,Y; }
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left,Top,Right,Bottom; }
    [StructLayout(LayoutKind.Sequential)] struct LASTINPUTINFO { public uint cbSize,dwTime; }
    [StructLayout(LayoutKind.Sequential)] struct MOUSEINPUT { public int dx,dy; public uint mouseData,dwFlags,time; public UIntPtr extra; }
    [StructLayout(LayoutKind.Sequential)] struct INPUT { public uint type; public MOUSEINPUT mouse; }
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern IntPtr WindowFromPoint(POINT p);
    [DllImport("user32.dll")] static extern IntPtr GetAncestor(IntPtr h,uint flag);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h,out RECT r);
    [DllImport("user32.dll")] static extern bool GetCursorPos(out POINT p);
    [DllImport("user32.dll")] static extern bool SetCursorPos(int x,int y);
    [DllImport("user32.dll")] static extern bool GetLastInputInfo(ref LASTINPUTINFO info);
    [DllImport("user32.dll")] static extern short GetAsyncKeyState(int key);
    [DllImport("user32.dll")] static extern uint SendInput(uint count,INPUT[] input,int size);
    public static bool Idle() {
        var info = new LASTINPUTINFO { cbSize=(uint)Marshal.SizeOf(typeof(LASTINPUTINFO)) };
        if (!GetLastInputInfo(ref info) || unchecked((uint)Environment.TickCount-info.dwTime)<2000) return false;
        foreach(int key in new int[]{1,2,4,16,17,18}) if((GetAsyncKeyState(key)&0x8000)!=0) return false;
        return true;
    }
    public static bool Click(IntPtr handle,int left,int top,int width,int height,int x,int y) {
        RECT r; POINT old;
        if(!Idle() || GetForegroundWindow()!=handle || !GetWindowRect(handle,out r)) return false;
        if(r.Left!=left || r.Top!=top || r.Right-r.Left!=width || r.Bottom-r.Top!=height) return false;
        var p=new POINT{X=x,Y=y};
        if(GetAncestor(WindowFromPoint(p),2)!=handle || !GetCursorPos(out old)) return false;
        if(!SetCursorPos(x,y)) return false;
        if(GetForegroundWindow()!=handle || GetAncestor(WindowFromPoint(p),2)!=handle) return false;
        var inputs=new INPUT[]{new INPUT{mouse=new MOUSEINPUT{dwFlags=2}},new INPUT{mouse=new MOUSEINPUT{dwFlags=4}}};
        uint sent=SendInput(2,inputs,Marshal.SizeOf(typeof(INPUT)));
        if(sent==1) SendInput(1,new INPUT[]{inputs[1]},Marshal.SizeOf(typeof(INPUT)));
        // Restore only if the pointer still belongs to this click.
        POINT current; if(GetCursorPos(out current)&&current.X==x&&current.Y==y) SetCursorPos(old.X,old.Y);
        return sent==2;
    }
}
'@
}

function Invoke-MailConfirmationClick {
    param($Rectangle, $Roi, $Row)
    if ($null -eq $Rectangle -or $null -eq $Roi) { return $false }
    $x = $Roi.Left + [int]$Row.X; $y = $Roi.Top + [int]$Row.Y
    if ($x -le $Roi.Left + 2 -or $x -ge $Roi.Left + $Roi.Width - 2 -or $y -le $Roi.Top + 2 -or $y -ge $Roi.Top + $Roi.Height - 2) { return $false }
    return [MailConfirmationInput]::Click($Rectangle.Handle, $Rectangle.Left, $Rectangle.Top, $Rectangle.Width, $Rectangle.Height, $x, $y)
}

function Get-MailConfirmationScanDelayMs {
    param($Config, $State, [string]$Status)
    # Keep baseline discovery, adjacent candidate frames and preview reads on the fast cadence.
    if ($null -ne $State.Pending -or -not $State.Data.Day -or -not $State.Data.PhoneDay -or
        $Status -notin @('Watching', 'BaselineReady', 'WaitingForCompleteSubject')) { return 1000 }
    return 1000 * [Math]::Max(1, [Math]::Min(300, (Get-ConfigInt $Config 'mailConfirmationListCheckIntervalSeconds' 30)))
}

function Wait-MailConfirmationInterval {
    param([int]$DelayMs, [string]$StopPath)
    for ($remaining = $DelayMs; $remaining -gt 0; $remaining -= $step) {
        if (Test-Path -LiteralPath $StopPath) { return $false }
        $step = [Math]::Min(1000, $remaining)
        Start-Sleep -Milliseconds $step
    }
    return -not (Test-Path -LiteralPath $StopPath)
}

function Start-MailConfirmationMonitor {
    param($Config, [switch]$Once, [switch]$NoSend)
    Initialize-MailConfirmationNative
    $paths = Get-MailConfirmationPaths
    if (-not $NoSend -and (Test-Path -LiteralPath $paths.Stop)) { [IO.File]::Delete($paths.Stop) }
    $statePath = if ($NoSend) { '' } else { $paths.State }
    $state = New-MailConfirmationState -Path $statePath
    $engine = New-OcrEngine (Get-ConfigString $Config 'ocrLanguage' 'zh-Hans-CN')
    $scan = $Config | ConvertTo-Json -Depth 16 | ConvertFrom-Json
    $scan.scanFullDesktopWhenNoWindow = $false
    $scan.processNameContains = @()
    $bodyScan = $scan | ConvertTo-Json -Depth 16 | ConvertFrom-Json
    $bodyScan.captureCrop = Get-VerificationSetting $Config 'mailConfirmationBodyCrop' ([pscustomobject]@{ leftRatio=0.56; topRatio=0.12; rightRatio=0.99; bottomRatio=0.96 })
    $scan.captureCrop = Get-VerificationSetting $Config 'mailConfirmationListCrop' $Config.captureCrop
    $messages = @{
        WaitingForTarget='等待远程邮箱处于前台，并停止操作鼠标键盘2秒。'; WaitingForCompleteSubject='等待完整的告警/电话抽查邮件标题和发件人，请保持邮件列表可见。'
        ConfirmingRow='正在连续核对邮件位置。'; BaselineReady='已建立当前邮件类型的基线，开始等待新批次。'; Watching='正在监控，等待新的告警或电话抽查邮件。'
        WaitingForIdle='等待鼠标键盘空闲或窗口恢复。'; OpenedNewMail='已单击新抽查邮件，正在核对右侧正文。'; WaitingForPreview='等待邮件预览加载。'
        ReadingPreview='正在核对邮件类型、日期、批次及对应位数的验证码。'; Sent='验证码已被手机推送服务受理，请以手机收件为准。'
        NoCode='未能核对对应位数的验证码，手动查看提醒已被推送服务受理。'; Uncertain='推送结果不确定，已停止重复发送此邮件。'
        PermanentFailure='推送被拒绝，请检查微信通知设置。'; RetryableFailure='发送前失败，将按次数和时间限制重试。'; Expired='本次处理超时，已停止发送过期确认码。'
        OcrRetry='本轮识别失败，稍后重新识别；未点击或发送。'; DryRun='只读检查，未点击、未发送、未修改去重记录。'
    }
    Write-MonitorLog $Config '自动取确认码已启动。请将远程Foxmail保持前台；告警6位、电话4位，各自首次已有邮件只建立基线，后续新批次自动单击取码。'
    try {
        do {
            if (Test-Path -LiteralPath $paths.Stop) { break }
            $rectangle = Get-TargetRectangle $scan -ForegroundOnly
            $layout = $null; $body = ''; $roi = $null; $canOperate = $false; $ocrFailed = $false
            if ($null -ne $rectangle) {
                $scope = '{0}/{1}/{2}/{3}/{4}' -f $rectangle.Handle,$rectangle.Left,$rectangle.Top,$rectangle.Width,$rectangle.Height
                if ($state.Scope -and $state.Scope -ne $scope) {
                    $state.Candidate = $null; $state.Frames = 0; $state.EmptySince = $null; $state.PhoneEmptySince = $null
                    if ($null -ne $state.Pending) { $state.Pending.Code = ''; $state.Pending.CodeFrames = 0 }
                }
                $state.Scope = $scope
                $roi = Get-CaptureRectangle $scan $rectangle
                try {
                    $layout = Read-VerificationRectangleText -Engine $engine -Rectangle $roi -AsLayout
                    if ($null -ne $state.Pending) { $body = Read-VerificationRectangleText -Engine $engine -Rectangle (Get-CaptureRectangle $bodyScan $rectangle) }
                }
                catch {
                    $ocrFailed = $true; $state.Candidate = $null; $state.Frames = 0; $state.EmptySince = $null; $state.PhoneEmptySince = $null
                    if ($null -ne $state.Pending) { $state.Pending.Code = ''; $state.Pending.CodeFrames = 0 }
                }
                $current = Get-TargetRectangle $scan -ForegroundOnly
                $canOperate = $null -ne $current -and $current.Handle -eq $rectangle.Handle -and $current.Left -eq $rectangle.Left -and $current.Top -eq $rectangle.Top -and $current.Width -eq $rectangle.Width -and $current.Height -eq $rectangle.Height -and [MailConfirmationInput]::Idle() -and -not (Test-Path -LiteralPath $paths.Stop)
            }
            $status = if ($ocrFailed) { 'OcrRetry' } else { Invoke-MailConfirmationFrame -State $state -Config $Config -ListLayout $layout -BodyText $body -Rectangle $rectangle -ListRoi $roi -CanOperate $canOperate -NoSend:$NoSend }
            if ($status -ne $state.LastStatus -or ((Get-Date) - $state.LastStatusAt).TotalSeconds -ge 60) {
                Write-MonitorLog $Config ('自动取确认码：' + $messages[$status] + ' [' + $status + ']')
                $state.LastStatus = $status; $state.LastStatusAt = Get-Date
            }
            $body = $null; $layout = $null
            if (-not $Once -and -not (Wait-MailConfirmationInterval -DelayMs (Get-MailConfirmationScanDelayMs $Config $state $status) -StopPath $paths.Stop)) { break }
        } while (-not $Once)
    }
    finally { Write-MonitorLog $Config 'Auto mail confirmation stopped.' }
}
