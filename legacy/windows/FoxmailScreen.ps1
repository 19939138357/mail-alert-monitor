# Strict foreground Foxmail adapter. Its only disk input is the native helper source.
# All capture and OCR stays in memory; the caller owns the durable queue and transport.
function Initialize-FoxmailScreen {
    if (-not ('FoxmailScreenNative' -as [type])) {
        Add-Type -Path (Join-Path $PSScriptRoot 'FoxmailScreenNative.cs') -ReferencedAssemblies System.Drawing
    }
    Initialize-MailConfirmationNative
}

function Get-FoxmailDigest([string]$Text) {
    $sha=[Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text))).Replace('-','').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function ConvertTo-FoxmailKeyText([string]$Text) {
    return ($Text.Normalize([Text.NormalizationForm]::FormKC) -replace '\s','').ToLowerInvariant()
}

function Get-FoxmailTimeWindow([string]$Label,[datetime]$Seen,[datetime]$Day) {
    $s=ConvertTo-FoxmailKeyText $Label
    if ($s -match '^(\d{1,2})[:：](\d{2})$') {
        if ([int]$Matches[1] -gt 23 -or [int]$Matches[2] -gt 59) {return}
        $from=$Day.Date.AddHours([int]$Matches[1]).AddMinutes([int]$Matches[2])
        return @($from,$from.AddSeconds(59))
    }
    if ($s -eq '刚刚') {return @($Seen.AddSeconds(-119),$Seen.AddMinutes(1))}
    if ($s -match '^(\d{1,4})(分钟|小时|秒)前$') {
        $unit=@{'分钟'=60;'小时'=3600;'秒'=1}[$Matches[2]]
        $to=$Seen.AddSeconds(-[int]$Matches[1]*$unit)
        return @($to.AddSeconds(-$unit-59),$to.AddSeconds(59))
    }
}

function Get-FoxmailUnreadRows {
    param($Lines,$Dots,[string]$Target,[datetime]$Seen=(Get-Date))
    $ordered=@($Lines | Sort-Object Top,Left)
    $timePattern='(\d{1,2}[:：]\d{2}|\d{1,4}(?:分钟|小时|秒)前|刚刚)$'
    foreach ($dot in $Dots) {
        $senders=@($ordered | Where-Object {
            $_.Height -ge 5 -and $_.Left -gt $dot.X -and $_.Left-$dot.X -le 5*$_.Height -and
            [Math]::Abs($_.Top+$_.Height/2-$dot.Y) -lt $_.Height*0.8
        } | Sort-Object Left)
        if (!$senders.Count) {continue}
        $nameLine=$senders[0]
        $name=$nameLine.Text.Trim()
        $time=''
        $compact=ConvertTo-FoxmailKeyText $name
        if ($compact -match $timePattern) {
            $time=$Matches[1]
            $name=(($name -replace '(?:\d\s*){1,2}[:：]\s*(?:\d\s*){2}$|(?:\d\s*){1,4}(?:分\s*钟|小\s*时|秒)\s*前$|刚\s*刚$','')).Trim()
        } else {
            $timeBox=@($ordered | Where-Object {
                $_.Left -gt $nameLine.Left+$nameLine.Width*0.7 -and
                  [Math]::Abs($_.Top+$_.Height/2-$dot.Y) -lt $nameLine.Height -and (ConvertTo-FoxmailKeyText $_.Text) -match ('^'+$timePattern)
            })
            if ($timeBox.Count -eq 1) {$time=ConvertTo-FoxmailKeyText $timeBox[0].Text}
        }
        if (!$time -or !$name -or $name.Length -gt 160) {continue}
        $titles=@($ordered | Where-Object {
            $_.Top -gt $nameLine.Top+0.8*$nameLine.Height -and $_.Top -lt $nameLine.Top+3.3*$nameLine.Height -and
            [Math]::Abs($_.Left-$nameLine.Left) -le [Math]::Max(10,[double]$nameLine.Height*1.5) -and $_.Width -ge 2*$nameLine.Height
        })
        if (!$titles.Count) {continue}
        $subject=$titles[0].Text.Trim()
        if ($subject.Length -lt 2 -or $subject -match '^(未读|已读)\s*[（(]') {continue}
        $day=$Seen.Date
        foreach ($line in $ordered) {
            if ($line.Top -ge $nameLine.Top) {break}
            $heading=ConvertTo-FoxmailKeyText $line.Text
            if ($heading -match '^(今天|昨天)(?:\(|$)') {$day=if ($Matches[1] -eq '昨天') {$Seen.Date.AddDays(-1)} else {$Seen.Date}}
            elseif ($heading -match '^(20\d{2})[-年/](\d{1,2})[-月/](\d{1,2})日?(?:\(|$)') {
                try {$day=[datetime]::new([int]$Matches[1],[int]$Matches[2],[int]$Matches[3])} catch {continue}
            }
        }
        $bound=@(Get-FoxmailTimeWindow $time $Seen $day)
        if ($bound.Count -ne 2) {continue}
        $family=Get-FoxmailDigest ($Target+"|"+(ConvertTo-FoxmailKeyText $name)+"|"+(ConvertTo-FoxmailKeyText $subject))
        [pscustomobject]@{Sender=$name;Subject=$subject;Time=$time;Target=$Target;Family=$family
            Key=(Get-FoxmailDigest ($family+'|'+$bound[1].ToString('yyyy-MM-dd HH:mm')))
            Earliest=$bound[0].ToString('o');Latest=$bound[1].ToString('o')
            X=[int]($nameLine.Left+[Math]::Min(55,$nameLine.Width/2));Y=[int]($nameLine.Top+$nameLine.Height/2)}
    }
}

function Test-FoxmailMatch($Ticket,$Row) {
    return $Ticket.Family -eq $Row.Family -and [datetime]$Ticket.Earliest -le [datetime]$Row.Latest -and [datetime]$Ticket.Latest -ge [datetime]$Row.Earliest
}

function Get-FoxmailHeader {
    param([string[]]$Lines,$Ticket)
    $normalized=@($Lines | ForEach-Object {ConvertTo-FoxmailKeyText $_})
    $sizeIndex=-1
    for ($i=1;$i -lt [Math]::Min(64,$Lines.Count);$i++) {
        if ($normalized[$i] -match '^(大小|size):\d') {$sizeIndex=$i;break}
    }
    # Expanded Foxmail headers delimit their end with Size. Refuse collapsed
    # or ambiguous headers rather than extracting dates or addresses from a message.
    if ($sizeIndex -lt 2) {return}
    $prefix=(ConvertTo-FoxmailKeyText $Ticket.Subject) -replace '(?:\.{2,}|…+)$',''
    if ($prefix.Length -lt 2) {return}
    $fromIndex=-1;$fullSubject='';$date=$null
    for ($i=1;$i -lt $sizeIndex;$i++) {
        if ($normalized[$i] -match '^(?:发件人|from):') {$fromIndex=$i;break}
    }
    if ($fromIndex -lt 1) {return}
    $first=(ConvertTo-FoxmailKeyText $Lines[0]) -replace '^(?:主题|subject):',''
    if (!$first.StartsWith($prefix) -and !$prefix.StartsWith($first)) {return}
    $fullSubject=($Lines[0] -replace '^(?:主题|Subject)\s*[:：]\s*','').Trim()
    for ($i=1;$i -lt $fromIndex;$i++) {
        $part=$normalized[$i]
        if ($part -eq (ConvertTo-FoxmailKeyText $Ticket.Sender) -or $part.Contains('@') -or
            $part -match '^(?:发给|收件人:|隐藏信息|显示信息|to:|20\d\d[-年/])') {break}
        $fullSubject+=' '+$Lines[$i].Trim()
    }
    if (!(ConvertTo-FoxmailKeyText $fullSubject).StartsWith($prefix) -or $fullSubject -match '(?:\.{2,}|…+)\s*$') {return}
    $sender=''
    for ($i=$fromIndex;$i -lt $sizeIndex;$i++) {
        if ($i -gt $fromIndex -and $normalized[$i] -match '^(?:收件人|发给|抄送|密送|时间|发送时间|to:|cc:|date:)') {break}
        $sender+=$normalized[$i]
    }
    $sender=$sender -replace '^(?:发件人|from):',''
    $expected=ConvertTo-FoxmailKeyText $Ticket.Sender
    if ($expected.Contains('@')) {
        $emails=@([regex]::Matches($sender,'[a-z0-9_+.%-]+@[a-z0-9.-]+\.[a-z]{2,}') | ForEach-Object Value)
        if ($expected -notin $emails) {return}
    } elseif ($sender -ne $expected -and !$sender.StartsWith($expected+'<')) {return}
    $dateTexts=@($normalized[($fromIndex+1)..$sizeIndex] | Where-Object {$_ -match '^(?:时间|发送时间|date):'})
    if ($dateTexts.Count -ne 1 -or $dateTexts[0] -notmatch '(20\d\d)[-/年](\d{1,2})[-/月](\d{1,2})日?(?:\([^)]{1,8}\))?(\d{1,2}):(\d\d)(?::(\d\d))?$') {return}
    try { $date=[datetime]::new([int]$Matches[1],[int]$Matches[2],[int]$Matches[3],[int]$Matches[4],[int]$Matches[5],[int]$Matches[6]) } catch {return}
    $headerEnd=if ($Matches[6]) {$date} else {$date.AddSeconds(59)}
    if ($date -gt [datetime]$Ticket.Latest -or $headerEnd -lt [datetime]$Ticket.Earliest) {return}
    [pscustomobject]@{Sender=$Ticket.Sender;Subject=$fullSubject;Time=$date.ToString('yyyy-MM-dd HH:mm:ss');Start=$sizeIndex+1
        Identity=(Get-FoxmailDigest ($sender+'|'+$date.ToString('s')+'|'+(ConvertTo-FoxmailKeyText $fullSubject)))}
}

function Join-FoxmailPage {
    param([string[]]$Before,[string[]]$After)
    # At least two overlapping lines, or one long unique anchor, are required.
    for ($n=[Math]::Min($Before.Count,$After.Count);$n -ge 1;$n--) {
        $same=$true
        for ($i=0;$i -lt $n;$i++) {
            if ((ConvertTo-FoxmailKeyText $Before[$Before.Count-$n+$i]) -cne (ConvertTo-FoxmailKeyText $After[$i])) {$same=$false;break}
        }
        if (!$same) {continue}
        $anchor=ConvertTo-FoxmailKeyText ($After[0..($n-1)] -join '')
        if (!$anchor -or ($n -lt 2 -and $anchor.Length -lt 12)) {continue}
        # A repeated block cannot identify where this page belongs.
        $both=@($Before,$After)
        $ambiguous=$false
        foreach ($chunk in $both) {
            $occurrences=0
            for ($start=0;$start -le $chunk.Count-$n;$start++) {
                if ((ConvertTo-FoxmailKeyText ($chunk[$start..($start+$n-1)] -join '')) -eq $anchor) {$occurrences++}
            }
            if ($occurrences -ne 1) {$ambiguous=$true;break}
        }
        if ($ambiguous) {return}
        return @($Before)+@($After | Select-Object -Skip $n)
    }
}

function Get-FoxmailContext($Config) {
    # Ignore the desktop fallback even when legacy modes use it.
    $window=Get-TargetRectangle $Config -ForegroundOnly
    if (!$window -or !$window.Handle -or $window.Handle -eq [IntPtr]::Zero) {return}
    $snap=Get-TopLevelWindows | Where-Object {$_.Handle -eq $window.Handle} | Select-Object -First 1
    if (!$snap -or !$snap.ProcessName -or !$snap.Title -or $snap.Left -ne $window.Left -or $snap.Top -ne $window.Top -or $snap.Width -ne $window.Width -or $snap.Height -ne $window.Height) {return}
    $regions=@()
    foreach ($field in 'mailConfirmationListCrop','mailConfirmationBodyCrop') {
        $crop=$Config.$field
        if (!$crop -or $crop.leftRatio -lt 0 -or $crop.topRatio -lt 0 -or $crop.rightRatio -gt 1 -or $crop.bottomRatio -gt 1 -or
            $crop.leftRatio -ge $crop.rightRatio -or $crop.topRatio -ge $crop.bottomRatio) {return}
        $r=Get-CaptureRectangle ([pscustomobject]@{captureCrop=$crop}) $window
        if (!$r -or $r.Width -lt 80 -or $r.Height -lt 100 -or $r.Width*$r.Height -gt 16000000) {return}
        $regions+=@($r)
    }
    $list=$regions[0];$body=$regions[1]
    if ($list.Left+$list.Width -gt $body.Left+2) {return}
    [pscustomobject]@{Window=$window;Process=$snap.ProcessName;List=$list;Body=$body;Target=(Get-FoxmailDigest ($snap.ProcessName+'|'+$snap.Title))}
}

function Test-FoxmailVisible($Context,$Roi) {
    $w=$Context.Window
    $bounds=New-Object Win32WindowTools+RECT
    if (![Win32WindowTools]::GetWindowRect($w.Handle,[ref]$bounds) -or $bounds.Left -ne $w.Left -or $bounds.Top -ne $w.Top -or
        $bounds.Right-$bounds.Left -ne $w.Width -or $bounds.Bottom-$bounds.Top -ne $w.Height) {return $false}
    $length=[Win32WindowTools]::GetWindowTextLength($w.Handle)
    $buffer=[Text.StringBuilder]::new($length+1)
    [void][Win32WindowTools]::GetWindowText($w.Handle,$buffer,$buffer.Capacity)
    if ($buffer.ToString() -cne $w.Title) {return $false}
    return [Win32WindowTools]::IsCaptureVisible($w.Handle,$Roi.Left,$Roi.Top,$Roi.Width,$Roi.Height)
}

function Test-FoxmailNativeEnd($Context) {
    # A browser's accessibility tree describes its outer canvas, not the remote
    # mail application. Use UI Automation evidence only for a native Foxmail document.
    if ($Context.Process -ine 'Foxmail') {return $false}
    try {
        Add-Type -AssemblyName UIAutomationClient,UIAutomationTypes,WindowsBase
        $r=$Context.Body
        $point=[Windows.Point]::new($r.Left+$r.Width*0.55,$r.Top+$r.Height*0.60)
        $el=[Windows.Automation.AutomationElement]::FromPoint($point)
        $owner=[Windows.Automation.AutomationElement]::FromHandle($Context.Window.Handle)
        for($i=0;$el -and $i -lt 10;$i++) {
            $info=$el.Current
            if ($info.ProcessId -ne $owner.Current.ProcessId) {return $false}
            $bounds=$info.BoundingRectangle
            if (!$info.IsOffscreen -and $info.ControlType -eq [Windows.Automation.ControlType]::Document -and
                [Math]::Abs($bounds.Left-$r.Left) -lt 18 -and [Math]::Abs($bounds.Right-($r.Left+$r.Width)) -lt 18 -and
                [Math]::Abs($bounds.Bottom-($r.Top+$r.Height)) -lt 10 -and $bounds.Height -gt $r.Height*0.65) {
                $pattern=$null
                if ($el.TryGetCurrentPattern([Windows.Automation.TextPattern]::Pattern,[ref]$pattern)) {
                    $end=[Windows.Automation.Text.TextPatternRangeEndpoint]::End
                    foreach ($visible in $pattern.GetVisibleRanges()) {
                        if ($visible.CompareEndpoints($end,$pattern.DocumentRange,$end) -eq 0) {return $true}
                    }
                }
                $pattern=$null
                if ($el.TryGetCurrentPattern([Windows.Automation.ScrollPattern]::Pattern,[ref]$pattern)) {
                    return !$pattern.Current.VerticallyScrollable -or $pattern.Current.VerticalScrollPercent -ge 99.999
                }
            }
            if ($el.Equals($owner)) {break}
            $el=[Windows.Automation.TreeWalker]::ControlViewWalker.GetParent($el)
        }
    } catch {return $false}
    return $false
}

function Read-FoxmailFrame($Context,$Engine,[ValidateSet('List','Body','Window')]$Pane) {
    $roi=$Context.$Pane
    if (!(Test-FoxmailVisible $Context $roi)) {throw '邮箱已离开前台或被遮挡。'}
    $bmp=[Drawing.Bitmap]::new($roi.Width,$roi.Height,[Drawing.Imaging.PixelFormat]::Format32bppArgb)
    try {
        $gfx=[Drawing.Graphics]::FromImage($bmp)
        try {$gfx.CopyFromScreen($roi.Left,$roi.Top,0,0,$bmp.Size)} finally {$gfx.Dispose()}
        if (!(Test-FoxmailVisible $Context $roi)) {throw '捕获期间窗口变化。'}
        $layout=Read-VerificationRectangleText $Engine $roi -InputBitmap $bmp -AsLayout
        $lines=@($layout.Lines | Sort-Object Top,Left)
        $dots=@();$rows=@();$atEnd=$false
        if ($Pane -eq 'List') {
            $dots=[FoxmailScreenNative]::Dots($bmp)
            $rows=@(Get-FoxmailUnreadRows $lines $dots $Context.Target)
        } elseif ($Pane -eq 'Body' -and $lines.Count) {
            $atEnd=[FoxmailScreenNative]::ScrollbarAtEnd($bmp) -or (Test-FoxmailNativeEnd $Context)
        }
        if (!(Test-FoxmailVisible $Context $roi)) {throw '识别期间目标窗口已变化。'}
        return [pscustomobject]@{Rows=$rows;Lines=$lines;DotCount=$dots.Count;AtEnd=$atEnd;Text=[string[]]@($lines | ForEach-Object Text)}
    } finally {$bmp.Dispose()}
}

function Test-FoxmailScene($Context,$Engine) {
    $text=ConvertTo-FoxmailKeyText ((Read-FoxmailFrame $Context $Engine Window).Text -join ' ')
    $actions=@(@('回复','收取','转发','删除') | Where-Object {$text.Contains($_)})
    return $text.Contains('排序') -and $actions.Count -ge 2 -and ($text.Contains('foxmail') -or $text.Contains('收件箱'))
}

function Get-FoxmailScreenUnread {
    param($Config,$Engine)
    Initialize-FoxmailScreen
    $ctx=Get-FoxmailContext $Config
    $script:FoxmailListAttention=$false
    if (!$ctx -or !(Test-FoxmailScene $ctx $Engine)) {throw '目标邮箱窗口未就绪或版式无法核对。'}
    $frame=Read-FoxmailFrame $ctx $Engine List
    $script:FoxmailListAttention=$frame.DotCount -gt $frame.Rows.Count
    foreach ($row in $frame.Rows) {
        # Ambiguous equal-looking simultaneous rows cannot safely be distinguished.
        if (@($frame.Rows | Where-Object {Test-FoxmailMatch $row $_}).Count -eq 1) {$row}
        else {$script:FoxmailListAttention=$true}
    }
}

function Get-FoxmailInputStamp {return [FoxmailScreenNative]::InputStamp()}
function Test-FoxmailInputIdle {return [MailConfirmationInput]::Idle()}

function Get-FoxmailStableBody($Context,$Engine,[long]$Stamp) {
    if ((Get-FoxmailInputStamp) -ne $Stamp) {throw '读取期间有其他输入。'}
    $first=Read-FoxmailFrame $Context $Engine Body
    Start-Sleep -Milliseconds 400
    $next=Read-FoxmailFrame $Context $Engine Body
    if ((Get-FoxmailInputStamp) -ne $Stamp -or !$next.Text.Count -or ($first.Text -join "`n") -cne ($next.Text -join "`n")) {throw '等待正文稳定。'}
    return $next
}

function Invoke-FoxmailWheel($Context,[int]$Delta,[long]$Stamp) {
    $roi=$Context.Body;$w=$Context.Window
    # Every synthesis must wait for the input idle gate. Previous wheel/move events count too.
    for($attempt=0;$attempt -lt 24 -and !(Test-FoxmailInputIdle);$attempt++) {
        if ((Get-FoxmailInputStamp) -ne $Stamp) {throw '鼠标或键盘正在操作。'}
        Start-Sleep -Milliseconds 100
    }
    if (!(Test-FoxmailInputIdle) -or (Get-FoxmailInputStamp) -ne $Stamp -or !(Test-FoxmailVisible $Context $roi)) {throw '无法安全滚动。'}
    $x=$roi.Left+[int]($roi.Width*0.62);$y=$roi.Top+[int]($roi.Height*0.72)
    if (![FoxmailScreenNative]::Wheel($w.Handle,$w.Left,$w.Top,$w.Width,$w.Height,$x,$y,$Delta)) {throw '邮箱未接受滚动。'}
    $after=(Get-FoxmailInputStamp)
    Start-Sleep -Milliseconds 420
    return $after
}

function Get-FoxmailOpenContent {
    param($Config,$Engine,$Ticket,[switch]$ResumeOnly)
    $needsRestore=$false
    $pending=[pscustomobject]@{Complete=$false;Reason='等待核对同一封未读邮件。'}
    try {
        Initialize-FoxmailScreen
        $ctx=Get-FoxmailContext $Config
        if (!$ctx -or $ctx.Target -ne $Ticket.Target -or !(Test-FoxmailScene $ctx $Engine)) {return $pending}
        $stamp=(Get-FoxmailInputStamp)
        if ($stamp -lt 0 -or !(Test-FoxmailInputIdle)) {return $pending}
        $first=@((Read-FoxmailFrame $ctx $Engine List).Rows | Where-Object {Test-FoxmailMatch $Ticket $_})
        $needsRestore=$false
        if ($first.Count -gt 1) {return $pending}
        if ($first.Count -eq 1) {
            $again=@((Read-FoxmailFrame $ctx $Engine List).Rows | Where-Object {Test-FoxmailMatch $Ticket $_})
            if ($again.Count -ne 1 -or [Math]::Abs($again[0].X-$first[0].X) -gt 3 -or [Math]::Abs($again[0].Y-$first[0].Y) -gt 3 -or
                $stamp -ne (Get-FoxmailInputStamp) -or !(Test-FoxmailVisible $ctx $ctx.List)) {return $pending}
            if (!(Invoke-MailConfirmationClick $ctx.Window $ctx.List $again[0])) {return $pending}
            $stamp=(Get-FoxmailInputStamp)
            Start-Sleep -Milliseconds 1200
            if (@((Read-FoxmailFrame $ctx $Engine List).Rows | Where-Object {Test-FoxmailMatch $Ticket $_}).Count) {return $pending}
        } elseif (!$ResumeOnly) {return $pending}
        # Recover only from the same verified header. Never scroll through another open mail to look for it.
        $frame=Get-FoxmailStableBody $ctx $Engine $stamp
        $receipt=Get-FoxmailHeader $frame.Text $Ticket
        if (!$receipt -or $receipt.Start -ge $frame.Text.Count) {return $pending}
        $lines=[string[]]@($frame.Text)
        $previous=$frame.Text -join "`n";$endCount=0;$moved=$false
        for($n=0;$n -lt 75;$n++) {
            $stamp=Invoke-FoxmailWheel $ctx -120 $stamp
            $needsRestore=$true
            $page=Get-FoxmailStableBody $ctx $Engine $stamp
            $key=$page.Text -join "`n"
            if ($key -ceq $previous) {
                # Positive end evidence is independent of OCR and wheel delivery.
                if (!$page.AtEnd) {return $pending}
                $endCount++; if ($endCount -ge 2) {break};continue
            }
            $moved=$true;$endCount=0;$previous=$key
            $visibleReceipt=Get-FoxmailHeader $page.Text $Ticket
            if ($visibleReceipt -and $visibleReceipt.Identity -ne $receipt.Identity) {return $pending}
            $next=if ($visibleReceipt) {@($page.Text | Select-Object -Skip $visibleReceipt.Start)} else {@($page.Text)}
            $merged=@(Join-FoxmailPage $lines $next)
            if (!$merged.Count -or ($merged -join "`n").Length -gt 19000) {return $pending}
            $lines=[string[]]$merged
        }
        if ($endCount -lt 2) {return $pending}
        if ($moved) {
            $restored=$false
            for ($n=0;$n -lt 14;$n++) {
                $stamp=Invoke-FoxmailWheel $ctx 720 $stamp
                $page=Get-FoxmailStableBody $ctx $Engine $stamp
                $header=Get-FoxmailHeader $page.Text $Ticket
                if ($header) {$restored=$header.Identity -eq $receipt.Identity;break}
            }
            if (!$restored) {return $pending}
        } else {
            $header=Get-FoxmailHeader $page.Text $Ticket
            if (!$header -or $header.Identity -ne $receipt.Identity) {return $pending}
        }
        $needsRestore=$false
        $body=(($lines | Select-Object -Skip $receipt.Start) -join "`n").Trim()
        if (!$body -or $body.Length -gt 19000 -or $stamp -ne (Get-FoxmailInputStamp)) {return $pending}
        return [pscustomobject]@{Complete=$true;Subject=$receipt.Subject;Body=$body;Sender=$receipt.Sender;Time=$receipt.Time
            Identity=(Get-FoxmailDigest ($receipt.Identity+'|'+(ConvertTo-FoxmailKeyText $body)))}
    } catch {
        # No OCR text, addresses, headers, or notification contents in diagnostics.
        $pending.Reason='未能连续核对前台邮箱、邮件身份与正文末尾。请保持目标窗口可见，展开邮件头。'
        return $pending
    } finally {
        if ($needsRestore -and $stamp -eq (Get-FoxmailInputStamp)) {
            try {
                for ($back=0;$back -lt 12;$back++) {
                    $top=Get-FoxmailStableBody $ctx $Engine $stamp
                    if (Get-FoxmailHeader $top.Text $Ticket) {break}
                    $stamp=Invoke-FoxmailWheel $ctx 720 $stamp
                }
            } catch { }
        }
    }
}
