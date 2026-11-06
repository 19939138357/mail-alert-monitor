$ErrorActionPreference='Stop'
Set-StrictMode -Version 2
. (Join-Path $PSScriptRoot '../FoxmailScreen.ps1')
$script:count=0
function Assert-Screen($ok,$name) {if (!$ok) {throw "Screen assertion failed: $name"};$script:count++}
function New-Line($text,$x,$y,$w) {[pscustomobject]@{Text=$text;Left=$x;Top=$y;Width=$w;Height=12}}
$lines=@((New-Line 'Demo Service' 32 20 90),(New-Line '12:45' 210 20 35),(New-Line 'Quarterly report' 32 37 110),
    (New-Line 'Demo Service' 32 66 90),(New-Line '12:41' 210 66 35),(New-Line 'Prior report' 32 84 110))
$dots=@([pscustomobject]@{X=20;Y=26})
$seen=[datetime]'2026-05-10T12:51:00'
$t=@(Get-FoxmailUnreadRows $lines $dots 'fixture' $seen)
Assert-Screen ($t.Count -eq 1 -and $t[0].Subject -eq 'Quarterly report' -and $t[0].Sender -eq 'Demo Service') 'unread only'
Assert-Screen (@(Get-FoxmailUnreadRows $lines @() 'fixture' $seen).Count -eq 0) 'read rows omitted'
$ticket=$t[0]
$header=@('Quarterly report','Demo Service','发送给 值班','发件人：','Demo Service <test@example.org>','收件人：','User','时间：2026年05月10日 (周日) 12:45','大小：2 KB','Hello, example!')
$receipt=Get-FoxmailHeader $header $ticket
Assert-Screen ($receipt -and $receipt.Start -eq 9 -and $receipt.Subject -eq 'Quarterly report') 'complete verified header'
$wrong=[string[]]$header.Clone();$wrong[4]='Another <other@example.org>'
Assert-Screen (!(Get-FoxmailHeader $wrong $ticket)) 'wrong sender'
$wrong=[string[]]$header.Clone();$wrong[7]='时间：2026年05月10日 (周日) 12:43'
Assert-Screen (!(Get-FoxmailHeader $wrong $ticket)) 'wrong time'
$wrong=[string[]]$header.Clone();$wrong[0]='Quarterly budget'
Assert-Screen (!(Get-FoxmailHeader $wrong $ticket)) 'wrong subject'
Assert-Screen (!(Get-FoxmailHeader $header[0..7] $ticket)) 'wait for complete metadata'
$wrong=[string[]]$header.Clone();$wrong[7]='时间：2026-05-10 12:44:58'
Assert-Screen (!(Get-FoxmailHeader $wrong $ticket)) 'exact header seconds cannot leak into next minute'
$rel=@(Get-FoxmailTimeWindow '3分钟前' $seen $seen)
Assert-Screen ($rel.Count -eq 2 -and $rel[0] -le $seen.AddMinutes(-3) -and $rel[1] -ge $seen.AddMinutes(-3)) 'relative time interval'
$merged=@(Join-FoxmailPage @('header','alpha','beta') @('alpha','beta','gamma'))
Assert-Screen (($merged -join ' ') -eq 'header alpha beta gamma') 'verified page overlap'
Assert-Screen (@(Join-FoxmailPage @('a','b','c') @('c','d')).Count -eq 0) 'a single weak match is rejected'
Assert-Screen (@(Join-FoxmailPage @('first') @('unrelated','new')).Count -eq 0) 'broken page overlap is rejected'
if ($env:OS -eq 'Windows_NT') {
    Add-Type -AssemblyName System.Drawing
    Add-Type -Path (Join-Path $PSScriptRoot '../FoxmailScreenNative.cs') -ReferencedAssemblies System.Drawing
    $image=[Drawing.Bitmap]::new(340,180)
    $g=[Drawing.Graphics]::FromImage($image)
    try {
        $g.Clear([Drawing.Color]::White);$g.FillEllipse([Drawing.Brushes]::DodgerBlue,12,20,9,9)
        $g.FillRectangle([Drawing.Brushes]::DodgerBlue,1,80,250,40)
        $dots=[FoxmailScreenNative]::Dots($image)
        Assert-Screen ($dots.Count -eq 1 -and [Math]::Abs($dots[0].Y-24) -le 1) 'small marker vs blue selected row'
        Assert-Screen (![FoxmailScreenNative]::ScrollbarAtEnd($image)) 'arbitrary blank margin is not proof of EOF'
        $x=327;$top=19;$end=170
        foreach ($i in 0..3) {
            $g.FillRectangle([Drawing.Brushes]::DimGray,$x-$i,$top+$i,1+2*$i,1)
            $g.FillRectangle([Drawing.Brushes]::DimGray,$x-$i,$end-$i,1+2*$i,1)
        }
        $g.FillRectangle([Drawing.Brushes]::DarkGray,$x-4,54,9,56)
        Assert-Screen (![FoxmailScreenNative]::ScrollbarAtEnd($image)) 'middle thumb cannot verify bottom'
        $g.FillRectangle([Drawing.Brushes]::DarkGray,$x-4,136,9,25)
        Assert-Screen ([FoxmailScreenNative]::ScrollbarAtEnd($image)) 'paired arrows plus bottom thumb'
        $g.FillRectangle([Drawing.Brushes]::White,$x-7,$end-4,15,8)
        Assert-Screen (![FoxmailScreenNative]::ScrollbarAtEnd($image)) 'cropped scrollbar cannot verify end'
    } finally {$g.Dispose();$image.Dispose()}
}
# Drive the production coordinator against deterministic screen frames. No desktop,
# clicks, notifications, network calls or credentials are used by these scenarios.
function Initialize-FoxmailScreen {}
function Get-FoxmailContext($Config) {[pscustomobject]@{Target='fixture';Window=1;List=1}}
function Test-FoxmailScene {return $true}
function Get-FoxmailInputStamp {return 7}
function Test-FoxmailInputIdle {return $true}
function Test-FoxmailVisible {return $true}
function Start-Sleep {}
function Read-FoxmailFrame($Context,$Engine,$Pane) {
    if ($script:clicked -or $script:resumed) {return [pscustomobject]@{Rows=@()}}
    return [pscustomobject]@{Rows=@($ticket)}
}
function Invoke-MailConfirmationClick {$script:clicked=$true;return $true}
# Match the production signature: PS 5.1 can pass a bare -120 as text to an
# untyped mock, making the direction test a locale-dependent string comparison.
function Invoke-FoxmailWheel($Context,[int]$Delta,[long]$Stamp) {
    if ($Delta -gt 0){$script:pageNo=0}
    elseif ($script:pageNo -lt $script:pages.Count-1){$script:pageNo++}
    $script:furthestPage=[Math]::Max($script:furthestPage,$script:pageNo)
    return 7
}
function Get-FoxmailStableBody($Context,$Engine,$Stamp) {
    $isLastPage=$script:pageNo -eq ($script:pages.Count-1)
    return [pscustomobject]@{Text=$script:pages[$script:pageNo].Text;AtEnd=($script:positiveEnd -and $isLastPage)}
}
function Run-ScreenFixture($pages,$positive,$resume) {
    $script:pages=$pages;$script:positiveEnd=$positive;$script:clicked=$false;$script:resumed=$resume;$script:pageNo=0;$script:furthestPage=0
    return Get-FoxmailOpenContent -Config @{} -Engine 1 -Ticket $ticket -ResumeOnly:$resume
}
$single=[pscustomobject]@{Text=[string[]]$header.Clone()}
$r=Run-ScreenFixture @($single) $true $false
Assert-Screen ($r.Complete -and $r.Body -eq 'Hello, example!' -and $r.Sender -eq 'Demo Service' -and $script:clicked) 'first-time unread click and verified short body'
$r=Run-ScreenFixture @($single) $false $false
Assert-Screen (!$r.Complete) 'two unchanged wheel results without independent EOF cannot send'
$r=Run-ScreenFixture @($single) $true $true
Assert-Screen ($r.Complete -and !$script:clicked) 'resume same verified already-open message without reopening it'
$wrong=[string[]]$header.Clone();$wrong[0]='Other message'
$r=Run-ScreenFixture @([pscustomobject]@{Text=$wrong}) $true $true
Assert-Screen (!$r.Complete -and !$script:clicked) 'cannot resume an unrelated open message'
Assert-Screen ($header[0] -eq 'Quarterly report' -and $header[4] -eq 'Demo Service <test@example.org>') 'negative fixture must leave the canonical header intact'
$first=[pscustomobject]@{Text=[string[]]($header+@('overlap one','overlap two'))}
$last=[pscustomobject]@{Text=@('overlap one','overlap two','last paragraph')}
$r=Run-ScreenFixture @($first,$last) $true $false
Assert-Screen ($script:furthestPage -eq 1) 'wheel reached second page of synthetic mail'
if (!$r.Complete) {
    throw ("synthetic multipage read incomplete; current page {0}; outcome {1}; diagnostic {2}" -f $script:pageNo,$r.Reason,$r.Trace)
}
$expectedLines=[string[]]@('Hello, example!','overlap one','overlap two','last paragraph')
$actualLines=[string[]]@($r.Body -split '\r?\n')
Assert-Screen ($actualLines.Count -eq $expectedLines.Count) ("multipage synthetic line count: " + ($actualLines -join '|'))
for($lineIndex=0;$lineIndex -lt $expectedLines.Count;$lineIndex++) {
    Assert-Screen ($actualLines[$lineIndex] -ceq $expectedLines[$lineIndex]) ("synthetic multipage text differed at line " + $lineIndex + ' ' + $actualLines[$lineIndex])
}
Assert-Screen ($script:pageNo -eq 0) 'returned to first page and rechecked identity after multipage read'
$last=[pscustomobject]@{Text=@('no matching line','another ending')}
$r=Run-ScreenFixture @($first,$last) $true $false
Assert-Screen (!$r.Complete -and $script:pageNo -eq 0) 'interrupted merge withholds and restores same opened mail'
Write-Output "PASS: $script:count Foxmail screen adapter checks"
