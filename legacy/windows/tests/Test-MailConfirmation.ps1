param([switch]$Ocr)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'Monitor-WindowKeywords.ps1') -LibraryOnly
$script:checks = 0
function Assert($Condition, [string]$Name) { if (-not $Condition) { throw ('FAIL: ' + $Name) }; $script:checks++ }
Assert (Test-MailConfirmationSender 'alerts+noc@example.org' -ExpectedSender 'alerts+noc@example.org') 'configured sender supports literal plus'
Assert (-not (Test-MailConfirmationSender 'alerts+noc@example.org.invalid' -ExpectedSender 'alerts+noc@example.org')) 'configured sender rejects suffix'
Assert (-not (Test-MailConfirmationSender 'report@example.com' -ExpectedSender 'alerts+noc@example.org')) 'configured sender excludes fixture address'
$now = [datetime]'2026-09-08T10:00:00'
$script:clicks = 0; $script:sends = @(); $script:outcome = 'Success'; $script:allowClick = $true
function Invoke-MailConfirmationClick { param($Rectangle,$Roi,$Row); if ($script:allowClick) { $script:clicks++; return $true }; return $false }
function Send-MailConfirmationMessage {
    param($Config,$Event,$Code,[ref]$Outcome)
    $script:sends += [pscustomobject]@{Id=$Event.Id;Code=$Code}
    $Outcome.Value = $script:outcome
    return $script:outcome -eq 'Success'
}
function Layout([int]$Batch=8, [double]$Y=100, [string]$Subject='告警抽查邮件', [string]$Sender='report@example.com') {
    [pscustomobject]@{Width=350;Height=700;Lines=@(
        [pscustomobject]@{Text=$Sender;Left=20;Top=$Y-20;Width=250;Height=14},
        [pscustomobject]@{Text=($Subject+'2026年09月08日'+$Batch+'次');Left=20;Top=$Y;Width=260;Height=14}
    )}
}
function Body([int]$Batch=9,[string]$Code='063827',[string]$Sender='report@example.com') { "告警抽查邮件2026年09月08日${Batch}次`n$Sender`n2026-09-08 10:00`n确认码：$Code`n请在15分钟内完成" }
function PhoneBody([int]$Batch=9,[string]$Code='0843',[string]$Subject='电话抽查邮件',[string]$Label='验证码') {
    "$($Subject)2026年09月08日${Batch}次`nreport@example.com`n2026-09-08 10:00`n$($Label)：$Code`n请及时查看"
}
function BothLayout([int]$AlertBatch=8,[int]$PhoneBatch=8) {
    $layout = Layout $AlertBatch 100
    $layout.Lines += (Layout $PhoneBatch 300 '电话抽查邮件').Lines
    return $layout
}
function Frame($State,[int]$Seconds,$Layout,[string]$Text='', [bool]$Active=$true) {
    Invoke-MailConfirmationFrame -State $State -Config @{} -ListLayout $Layout -BodyText $Text -CanOperate $Active -Now $now.AddSeconds($Seconds)
}
function Ready {
    $s=New-MailConfirmationState -Now $now
    Assert ((Frame $s 0 (Layout)) -eq 'ConfirmingRow') 'first list frame does not click'
    Assert ((Frame $s 1 (Layout)) -eq 'BaselineReady') 'existing mail is baseline'
    return $s
}
function Open-New($State) {
    [void](Frame $State 2 (Layout 9)); Assert ((Frame $State 3 (Layout 9)) -eq 'OpenedNewMail') 'stable new batch opens once'
}
function PhoneReady {
    $s=New-MailConfirmationState -Now $now
    Assert ((Frame $s 0 (Layout 8 100 '电话抽查邮件')) -eq 'ConfirmingRow') 'phone first row frame does not click'
    Assert ((Frame $s 1 (Layout 8 100 '电话抽查邮件')) -eq 'BaselineReady') 'phone existing mail gets its own baseline'
    return $s
}
function Open-NewPhone($State) {
    [void](Frame $State 2 (Layout 9 100 '电话抽查邮件'))
    Assert ((Frame $State 3 (Layout 9 100 '电话抽查邮件')) -eq 'OpenedNewMail') 'phone stable new batch opens once'
}

$expected = @(Get-MailConfirmationTitles '告警抽查邮件2026年09月08日9次')[0]
Assert (@(Get-VerificationCodes '确认码：063827').Count -eq 1) 'confirmation label supported'
Assert ((Get-MailConfirmationCode (Body) $expected) -ceq '063827') 'six digits preserve leading zero'
foreach ($invalid in @('8943','12345','1234567','12345678','12345678901','A12345','063827 或 582914','063827 582914','063827.9','063827@x.com')) {
    Assert (-not (Get-MailConfirmationCode (Body 9 $invalid) $expected)) 'invalid or ambiguous code rejected'
}
Assert ((Get-MailConfirmationCode (Body 9 '０６３８２７') $expected) -eq '063827') 'full width digits'
Assert ((Get-MailConfirmationCode (Body 9 '063 827') $expected) -eq '063827') 'grouped digits'
Assert (-not (Get-MailConfirmationCode (Body 8) $expected)) 'old preview is rejected'
Assert (-not (Get-MailConfirmationCode (Body 9 '063827' 'another@example.com') $expected)) 'wrong sender rejected'
Assert (-not (Get-MailConfirmationCode ((Body)+"`n告警抽查邮件2026年09月08日8次") $expected)) 'quoted older subject rejected'
Assert (-not (Get-MailConfirmationCode ((Body) -replace '确认码','订单编号') $expected)) 'unlabelled number rejected'
Assert (-not (Get-MailConfirmationCode ((Body) -replace '确认码','验证码') $expected)) 'generic login code excluded from business flow'
Assert ((Protect-VerificationText '确认码：063827') -notmatch '063827') 'confirmation code log redaction'
Assert ((Get-MailConfirmationDateStatus (Body) $expected $now) -eq 'Current') 'header time is current'
Assert ((Get-MailConfirmationDateStatus ((Body) -replace '10:00','09:44') $expected $now) -eq 'Expired') 'old confirmation mail expires after fifteen minutes'
Assert ((Get-MailConfirmationDateStatus ((Body) -replace '10:00','10:03') $expected $now) -eq 'Missing') 'future clock is not trusted'
Assert ((Get-MailConfirmationDateStatus ((Body) -replace '2026-09-08 10:00','') $expected $now) -eq 'Missing') 'unreadable header age is not guessed'
Assert ((Get-MailConfirmationDateStatus ((Body 8) -replace '10:00','09:44') $expected $now) -eq 'Missing') 'stale old preview cannot expire the new event'
Assert ($null -ne (Get-MailConfirmationRow (Layout) $now)) 'exact subject and adjacent sender'
Assert ($null -ne (Get-MailConfirmationRow (Layout 8 100 '告警抽查邮件' 'report@example.com/cn') $now)) 'observed list OCR punctuation artifact'
Assert ((Get-MailConfirmationCode (Body 9 '063827' 'report@example.com/cn') $expected) -eq '063827') 'reproduced body OCR punctuation artifact'
Assert (-not (Get-MailConfirmationCode (Body 9 '063827' 'report@example.com.other') $expected)) 'domain suffix remains rejected'
Assert ((Get-MailConfirmationRow (Layout 8 100 '客服电话检查') $now).Kind -eq 'phone') 'documented exact customer phone title is supported'
Assert ($null -eq (Get-MailConfirmationRow (Layout 8 100 '告警抽查邮件' 'xreport@example.com') $now)) 'sender suffix cannot match'
Assert ($null -eq (Get-MailConfirmationRow (Layout) $now.AddDays(1))) 'old date excluded'
$duplicate=Layout; $duplicate.Lines += $duplicate.Lines
Assert ($null -eq (Get-MailConfirmationRow $duplicate $now)) 'duplicate positions not clicked'

$s=Ready
Assert ($script:clicks -eq 0) 'startup does not click old mail'
Open-New $s
Assert ((Frame $s 5 (Layout 9) (Body 8)) -eq 'ReadingPreview') 'delayed old body waits'
Assert ($script:sends.Count -eq 0) 'old body never sent'
[void](Frame $s 6 (Layout 9) (Body))
Assert ($script:sends.Count -eq 0) 'one OCR result not enough'
Assert ((Frame $s 7 (Layout 9) (Body)) -eq 'Sent') 'second matching body sends'
Assert ($script:sends.Count -eq 1 -and $script:sends[0].Code -ceq '063827') 'only requested six digits sent'
[void](Frame $s 8 (Layout 9) (Body)); [void](Frame $s 9 (Layout 8) (Body 8))
Assert ($script:clicks -eq 1 -and $script:sends.Count -eq 1) 'repeat and older mail do not reopen'

$s=Ready; $before=$script:clicks
[void](Frame $s 2 (Layout 9 100)); [void](Frame $s 3 (Layout 9 140))
Assert ($script:clicks -eq $before) 'moving list breaks click confirmation'
[void](Frame $s 4 (Layout 9 140) '' $false)
[void](Frame $s 5 (Layout 9 140))
Assert ($script:clicks -eq $before) 'focus loss breaks click confirmation'
$script:allowClick=$false; [void](Frame $s 6 (Layout 9 140))
Assert ($script:clicks -eq $before -and $s.Data.Batch -eq 8) 'input guard denial does not consume event'
$script:allowClick=$true
Assert ((Frame $s 7 (Layout 9 140)) -eq 'OpenedNewMail') 'retry only when input guard ready'
[void](Frame $s 9 (Layout 9) (Body)); [void](Frame $s 10 (Layout 9) (Body) $false)
$before=$script:sends.Count; [void](Frame $s 11 (Layout 9) (Body))
Assert ($script:sends.Count -eq $before) 'focus loss breaks code confirmation'
[void](Frame $s 12 (Layout 9) (Body)); Assert ($script:sends.Count -eq $before+1) 'fresh body pair after focus return'

$s=Ready; Open-New $s; $before=$script:sends.Count
Assert ((Frame $s 43 (Layout 9) (Body 8)) -eq 'NoCode') 'missing body yields manual alert'
Assert ($script:sends.Count -eq $before+1 -and $script:sends[-1].Code -eq '') 'fallback has no guessed code'
[void](Frame $s 44 (Layout 9)); Assert ($script:sends.Count -eq $before+1) 'manual alert once'

foreach($outcome in @('Uncertain','PermanentFailure','RetryableFailure')) {
    $script:outcome=$outcome; $s=Ready; Open-New $s
    [void](Frame $s 5 (Layout 9) (Body)); $before=$script:sends.Count
    Assert ((Frame $s 6 (Layout 9) (Body)) -eq $outcome) 'transport outcome retained'
    [void](Frame $s 7 (Layout 9) (Body)); Assert ($script:sends.Count -eq $before+1) 'no immediate retry'
    for($t=8;$t -le 30;$t++) { [void](Frame $s $t (Layout 9) (Body)) }
    $expectedCount=if($outcome -eq 'RetryableFailure'){3}else{1}
    Assert ($script:sends.Count -eq $before+$expectedCount) 'bounded definite retries and no uncertain retry'
}
$script:outcome='Success'
$stale=Ready; Open-New $stale; $before=$script:sends.Count
Assert ((Frame $stale 5 (Layout 9) ((Body) -replace '10:00','09:44')) -eq 'Expired') 'expired preview never forwards a code'
Assert ($script:sends.Count -eq $before) 'expired mail causes no phone alert'
$empty=New-MailConfirmationState -Now $now
for($t=0;$t -le 4;$t++){ [void](Frame $empty $t (Layout 1 100 '普通业务邮件')) }
Assert ($empty.Data.Day -eq '2026-09-08' -and $empty.Data.Batch -eq 0) 'loaded list without target establishes empty baseline'
[void](Frame $empty 5 (Layout 1))
Assert ((Frame $empty 6 (Layout 1)) -eq 'OpenedNewMail') 'first future alert is not swallowed as startup baseline'
$s=Ready; Open-New $s; $before=$script:sends.Count
[void](Frame $s 5 (Layout 9) (Body)); [void](Frame $s 20 (Layout 9) (Body))
Assert ($script:sends.Count -eq $before) 'stale OCR pair rejected'
[void](Frame $s 4 (Layout 9) (Body)); Assert ($script:sends.Count -eq $before) 'clock rollback breaks confirmation'

$dir=Join-Path $root ('04_资料\电话抽查扩展_20260926\测试-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($dir)
$s=Ready; $s.Path=Join-Path $dir 'state.json'; Save-MailConfirmationState $s
$loaded=New-MailConfirmationState -Path $s.Path -Now $now
Assert ($loaded.Data.Batch -eq 8) 'baseline survives restart'
Open-New $loaded; [void](Frame $loaded 5 (Layout 9) (Body)); [void](Frame $loaded 6 (Layout 9) (Body))
$json=[IO.File]::ReadAllText($s.Path)
Assert ($json -notmatch '063827|report@|确认码') 'journal does not contain code sender or body'
$again=New-MailConfirmationState -Path $s.Path -Now $now; $before=$script:clicks
[void](Frame $again 8 (Layout 9)); [void](Frame $again 9 (Layout 9))
Assert ($script:clicks -eq $before) 'restart after send never reopens event'
$s=Ready; $s.Path=Join-Path $dir 'uncertain.json'; Open-New $s
Set-MailConfirmationRecord $s $s.Pending.Event 'Sending' $now
$again=New-MailConfirmationState -Path $s.Path -Now $now; $before=$script:sends.Count
[void](Frame $again 8 (Layout 9) (Body)); [void](Frame $again 9 (Layout 9) (Body))
Assert ($script:sends.Count -eq $before) 'crash after sending commit never replays'
$s=New-MailConfirmationState; $before=$script:clicks
[void](Invoke-MailConfirmationFrame -State $s -Config @{} -ListLayout (Layout 9) -NoSend)
Assert ($s.Data.Day -eq '' -and $script:clicks -eq $before) 'dry run changes neither journal nor UI'

# Telephone extraction is constrained by a matching type/date/batch and an explicit label.
$phoneExpected = @(Get-MailConfirmationTitles '电话抽查邮件2026年09月08日9次')[0]
$phoneAlias = @(Get-MailConfirmationTitles '客服电话检查2026年09月08日9次')[0]
Assert ($expected.Id -eq '2026-09-08/9') 'legacy alert identity remains byte-for-byte stable'
Assert ($phoneExpected.Id -eq 'phone/2026-09-08/9' -and $phoneAlias.Id -eq $phoneExpected.Id) 'phone title aliases share one separate identity'
Assert ((Get-MailConfirmationKey $expected.Id) -ne (Get-MailConfirmationKey $phoneExpected.Id)) 'same day and batch cannot collide across mail types'
foreach($title in @('电话抽查邮件','客服电话检查')) {
    Assert ((Get-MailConfirmationRow (Layout 9 100 $title) $now).Kind -eq 'phone') 'exact dated telephone title is recognized'
    foreach($label in @('验证码','确认码')) {
        Assert ((Get-MailConfirmationCode (PhoneBody 9 '0843' $title $label) $phoneExpected) -ceq '0843') 'telephone four digits preserve leading zero'
        Assert ((Get-MailConfirmationDateStatus (PhoneBody 9 '0843' $title $label) $phoneExpected $now) -eq 'Current') 'telephone age uses the header before its eligible label'
    }
}
foreach($unknown in @('电话抽查','电话检查','客服电话检鱼','告警检查邮件')) {
    Assert (@(Get-MailConfirmationTitles ($unknown+'2026年09月08日9次')).Count -eq 0) 'unverified subject variants remain excluded'
}
Assert (@(Get-MailConfirmationTitles '电话抽查邮件 验证码0843').Count -eq 0) 'undated telephone title cannot establish an identity'
foreach($invalid in @('843','08430','063827','0843000','A843','0843 或 1234','0843 1234','0843.2','0843@x.com')) {
    Assert (-not (Get-MailConfirmationCode (PhoneBody 9 $invalid) $phoneExpected)) 'telephone wrong length or ambiguous token rejected'
}
Assert ((Get-MailConfirmationCode (PhoneBody 9 '０８４３') $phoneExpected) -ceq '0843') 'telephone full width digits normalize without guessing'
Assert (-not (Get-MailConfirmationCode (PhoneBody 8) $phoneExpected)) 'older telephone body rejected'
Assert (-not (Get-MailConfirmationCode ((PhoneBody) -replace 'report@example.com','another@example.com') $phoneExpected)) 'telephone wrong sender rejected'
Assert (-not (Get-MailConfirmationCode (PhoneBody 9 '0843' '电话抽查邮件' '动态码') $phoneExpected)) 'unapproved telephone label rejected'
Assert (-not (Get-MailConfirmationCode (Body 9 '0843') $phoneExpected)) 'alert preview never supplies a telephone code'
Assert (-not (Get-MailConfirmationCode (PhoneBody 9 '063827') $expected)) 'telephone preview never supplies an alert code'
Assert (-not (Get-MailConfirmationCode ((PhoneBody)+"`n告警抽查邮件2026年09月08日9次") $phoneExpected)) 'mixed mail type body is ambiguous even with the same batch'
Assert ((Get-MailConfirmationDateStatus ((PhoneBody) -replace '10:00','09:44') $phoneExpected $now) -eq 'Expired') 'old telephone preview is not forwarded'
Assert ((Get-MailConfirmationDateStatus ((PhoneBody) -replace '2026-09-08 10:00','') $phoneExpected $now) -eq 'Missing') 'telephone time is not inferred from the subject date'
Assert ((Get-MailConfirmationDateStatus ((PhoneBody) -replace '2026-09-08 10:00','2026一09一08 10:00') $phoneExpected $now) -eq 'Current') 'reproduced OCR date separator artifact retains exact numeric time'
Assert ((Get-MailConfirmationDateStatus ((PhoneBody) -replace '2026-09-08 10:00','2026一09一08 10:O0') $phoneExpected $now) -eq 'Missing') 'date separator normalization never guesses a timestamp digit'
Assert ((Get-MailConfirmationDateStatus ((PhoneBody) -replace '2026-09-08 10:00','2026一09一08 09:44') $phoneExpected $now) -eq 'Expired') 'normalized date separator cannot bypass expiry'
Assert ((Get-MailConfirmationDateStatus ((PhoneBody) -replace '2026-09-08 10:00','2026一09一09 10:00') $phoneExpected $now) -eq 'Missing') 'normalized separator cannot bypass expected day identity'

$s=PhoneReady; $before=$script:sends.Count; Open-NewPhone $s
[void](Frame $s 5 (Layout 9 100 '电话抽查邮件') (Body 9 '0843'))
Assert ($script:sends.Count -eq $before) 'telephone refuses a stale alert preview'
[void](Frame $s 6 (Layout 9 100 '电话抽查邮件') (PhoneBody))
Assert ($script:sends.Count -eq $before) 'telephone one preview frame cannot send'
Assert ((Frame $s 7 (Layout 9 100 '电话抽查邮件') (PhoneBody)) -eq 'Sent') 'telephone second matching preview sends'
Assert ($script:sends.Count -eq $before+1 -and $script:sends[-1].Code -ceq '0843') 'telephone sends the exact four-digit code once'
$clicksBefore=$script:clicks
[void](Frame $s 8 (Layout 9 100 '客服电话检查')); [void](Frame $s 9 (Layout 9 100 '客服电话检查'))
Assert ($script:clicks -eq $clicksBefore) 'telephone aliases do not reopen an already handled event'

# Each type establishes its own initial baseline; future simultaneous work does not share batch order.
$s=New-MailConfirmationState -Now $now; $clicksBefore=$script:clicks
for($t=0;$t -le 3;$t++){ [void](Frame $s $t (BothLayout 8 8)) }
Assert ($s.Data.Batch -eq 8 -and $s.Data.PhoneBatch -eq 8 -and $script:clicks -eq $clicksBefore) 'both visible old streams baseline without clicks'
$before=$script:sends.Count
[void](Frame $s 4 (BothLayout 9 9)); Assert ((Frame $s 5 (BothLayout 9 9)) -eq 'OpenedNewMail') 'first independent stream opens'
Assert ($s.Pending.Event.Kind -eq 'alert') 'round robin next stream follows prior telephone baseline'
[void](Frame $s 7 (BothLayout 9 9) (Body)); [void](Frame $s 8 (BothLayout 9 9) (Body))
[void](Frame $s 9 (BothLayout 9 9)); Assert ((Frame $s 10 (BothLayout 9 9)) -eq 'OpenedNewMail') 'same numeric telephone batch remains eligible after alert delivery'
Assert ($s.Pending.Event.Kind -eq 'phone') 'second independent type selected'
[void](Frame $s 12 (BothLayout 9 9) (PhoneBody)); [void](Frame $s 13 (BothLayout 9 9) (PhoneBody))
Assert ($script:sends.Count -eq $before+2) 'same-day same-batch alert and phone both deliver exactly once'

$s=New-MailConfirmationState -Now $now
$s.Data.Day='2026-09-08'; $s.Data.Batch=998; $s.Data.PhoneDay='2026-09-08'; $s.Data.PhoneBatch=8
$s.LastSelectedKind='alert'
$selected=Select-MailConfirmationRow @(Get-MailConfirmationRows (BothLayout 999 9) $now) $s
Assert ($selected.Kind -eq 'phone') 'larger alert batch does not starve a new telephone batch'
$s.LastSelectedKind='phone'
$selected=Select-MailConfirmationRow @(Get-MailConfirmationRows (BothLayout 999 9) $now) $s
Assert ($selected.Kind -eq 'alert') 'round robin also preserves alert delivery'
$s.Data.Batch=999
$selected=Select-MailConfirmationRow @(Get-MailConfirmationRows (BothLayout 999 9) $now) $s
Assert ($selected.Kind -eq 'phone') 'already processed larger alert batch cannot hide a pending phone batch'

$s=New-MailConfirmationState -Now $now
for($t=0;$t -le 5;$t++){ [void](Frame $s $t (Layout 8)) }
Assert ($s.Data.Batch -eq 8 -and $s.Data.PhoneDay -eq '2026-09-08' -and $s.Data.PhoneBatch -eq 0) 'absent phone stream establishes an empty baseline while alert is visible'
[void](Frame $s 6 (BothLayout 8 1))
Assert ((Frame $s 7 (BothLayout 8 1)) -eq 'OpenedNewMail') 'first future telephone mail is not swallowed as a startup baseline'
$s=New-MailConfirmationState -Now $now
$truncated=Layout; $truncated.Lines += [pscustomobject]@{Text='客服电话检查2026年';Left=20;Top=300;Width=160;Height=14}
for($t=0;$t -le 5;$t++){ [void](Frame $s $t $truncated) }
Assert ($s.Data.PhoneDay -eq '') 'truncated telephone title never proves that the stream is empty'

# Complete previous-day mail establishes a historical baseline, never swallowing today's first batch.
$yesterdayPhone=Layout 99 100 '客服电话检查'
$yesterdayPhone.Lines[1].Text=$yesterdayPhone.Lines[1].Text -replace '2026年09月08日','2026年09月07日'
$s=New-MailConfirmationState -Now $now; $clicksBefore=$script:clicks
for($t=0;$t -le 5;$t++){ [void](Frame $s $t $yesterdayPhone) }
Assert ($s.Data.PhoneDay -eq '2026-09-07' -and $s.Data.PhoneBatch -eq 99 -and $script:clicks -eq $clicksBefore) 'complete yesterday telephone row baselines without clicks'
Assert ((Get-MailConfirmationScanDelayMs @{} $s 'Watching') -eq 30000) 'complete historical telephone baseline permits slow list checks'
$s.Path=Join-Path $dir 'cross-day-phone.json'; Save-MailConfirmationState $s
$s=New-MailConfirmationState -Path $s.Path -Now $now
$todayWithYesterday=Layout 1 300 '电话抽查邮件'; $todayWithYesterday.Lines += $yesterdayPhone.Lines
[void](Frame $s 30 $todayWithYesterday)
Assert ((Frame $s 31 $todayWithYesterday) -eq 'OpenedNewMail') 'persisted yesterday batch 99 does not swallow current day batch 1'
Assert ($s.Pending.Event.Kind -eq 'phone' -and $s.Pending.Event.Day -eq '2026-09-08' -and $s.Pending.Event.Batch -eq 1) 'current-day phone identity wins over larger historical batch'
$s.Pending=$null; $clicksBefore=$script:clicks
[void](Frame $s 32 $yesterdayPhone); [void](Frame $s 33 $yesterdayPhone)
Assert ($script:clicks -eq $clicksBefore) 'historical telephone rows never reopen after stream initialization'

# Legacy v1 state upgrades in memory without replaying either old baselines or uncertain sends.
$legacyPath=Join-Path $dir 'legacy-v1.json'
$legacy=@{Version=1;Day='2026-09-08';Batch=8;Records=@{}}
$legacy.Records[(Get-MailConfirmationKey $expected.Id)]=@{Status='Sending';At=$now.ToString('o')}
[IO.File]::WriteAllText($legacyPath,($legacy|ConvertTo-Json -Depth 6),[Text.UTF8Encoding]::new($false))
$s=New-MailConfirmationState -Path $legacyPath -Now $now; $clicksBefore=$script:clicks
Assert ($s.Data.Version -eq 2 -and $s.Data.Batch -eq 8 -and $s.Data.PhoneDay -eq '') 'v1 alert state migrates without fabricating a telephone baseline'
[void](Frame $s 0 (BothLayout 9 8)); [void](Frame $s 1 (BothLayout 9 8))
Assert ($s.Data.PhoneBatch -eq 8 -and $script:clicks -eq $clicksBefore) 'legacy Sending alert is not replayed while phone baselines normally'
[void](Frame $s 2 (BothLayout 9 9)); [void](Frame $s 3 (BothLayout 9 9))
Assert ($s.Pending.Event.Kind -eq 'phone') 'legacy alert record does not block equal numbered phone event'
Set-MailConfirmationRecord $s $s.Pending.Event 'Sending' $now
$again=New-MailConfirmationState -Path $legacyPath -Now $now; $clicksBefore=$script:clicks; $before=$script:sends.Count
[void](Frame $again 4 (BothLayout 9 9) (PhoneBody)); [void](Frame $again 5 (BothLayout 9 9) (PhoneBody))
Assert ($script:clicks -eq $clicksBefore -and $script:sends.Count -eq $before) 'telephone in-flight journal record survives restart without replay'
$json=[IO.File]::ReadAllText($legacyPath)
Assert ($json -notmatch '063827|0843|report@|验证码|确认码') 'v2 journal contains neither codes nor mail content'
foreach($outcome in @('Uncertain','PermanentFailure','RetryableFailure')) {
    $script:outcome=$outcome; $s=PhoneReady; Open-NewPhone $s; $before=$script:sends.Count
    for($t=5;$t -le 30;$t++){ [void](Frame $s $t (Layout 9 100 '电话抽查邮件') (PhoneBody)) }
    $count=if($outcome -eq 'RetryableFailure'){3}else{1}
    Assert ($script:sends.Count -eq $before+$count) 'telephone retains bounded definite retries and suppresses uncertain retries'
}
$script:outcome='Success'

# Slow list checks do not weaken fast consecutive-frame confirmation or delay stop requests.
$s=New-MailConfirmationState -Now $now
Assert ((Get-MailConfirmationScanDelayMs @{} $s 'BaselineReady') -eq 1000) 'incomplete two-stream baseline stays on fast cadence'
$s.Data.Day='2026-09-08'; $s.Data.PhoneDay='2026-09-08'
Assert ((Get-MailConfirmationScanDelayMs @{} $s 'Watching') -eq 30000) 'stable list uses thirty seconds by default'
Assert ((Get-MailConfirmationScanDelayMs ([pscustomobject]@{mailConfirmationListCheckIntervalSeconds=20}) $s 'Watching') -eq 20000) 'list cadence can be configured'
Assert ((Get-MailConfirmationScanDelayMs @{} $s 'ConfirmingRow') -eq 1000) 'candidate confirmation stays one second'
Assert ((Get-MailConfirmationScanDelayMs @{} $s 'ReadingPreview') -eq 1000) 'preview confirmation stays one second'
$s.Pending=[pscustomobject]@{Event=$phoneExpected}
Assert ((Get-MailConfirmationScanDelayMs @{} $s 'Watching') -eq 1000) 'pending delivery always stays on fast cadence'
$stopPath=Join-Path $dir 'stop-test.flag'; [IO.File]::WriteAllText($stopPath,'stop')
$stopwatch=[Diagnostics.Stopwatch]::StartNew()
Assert (-not (Wait-MailConfirmationInterval -DelayMs 30000 -StopPath $stopPath)) 'existing stop signal interrupts a long wait immediately'
Assert ($stopwatch.Elapsed.TotalSeconds -lt 2) 'stop check does not sleep through the list interval'
$s=Ready
[void](Frame $s 30 (Layout 9))
Assert ($null -eq $s.Pending -and $s.Frames -eq 1) 'thirty second list gap resets old frame continuity'
Assert ((Frame $s 31 (Layout 9)) -eq 'OpenedNewMail') 'fresh adjacent frame after slow poll permits the guarded click'

if($Ocr) {
    $engine=New-OcrEngine 'zh-Hans-CN'
    # Public OCR tests use generated images only; no user mailbox fixture.
    foreach($code in @('063827','8943')) {
        $bmp=[Drawing.Bitmap]::new(700,300); $g=[Drawing.Graphics]::FromImage($bmp); $font=[Drawing.Font]::new('Microsoft YaHei',14)
        try { $g.Clear([Drawing.Color]::White); $g.DrawString((Body 9 $code),$font,[Drawing.Brushes]::Black,10,10); $read=Read-VerificationRectangleText -Engine $engine -InputBitmap $bmp }
        finally { $font.Dispose(); $g.Dispose(); $bmp.Dispose() }
        $actual=Get-MailConfirmationCode $read $expected
        if($code.Length -eq 6){ Assert ($actual -ceq $code) 'real Windows OCR extracts six digit body' }
        else { Assert (-not $actual) 'real Windows OCR rejects four digit body' }
    }
    foreach($subject in @('电话抽查邮件','客服电话检查')) {
        $bmp=[Drawing.Bitmap]::new(750,300); $g=[Drawing.Graphics]::FromImage($bmp); $font=[Drawing.Font]::new('Microsoft YaHei',14)
        try { $g.Clear([Drawing.Color]::White); $g.DrawString((PhoneBody 9 '0843' $subject),$font,[Drawing.Brushes]::Black,10,10); $read=Read-VerificationRectangleText -Engine $engine -InputBitmap $bmp }
        finally { $font.Dispose(); $g.Dispose(); $bmp.Dispose() }
        Assert ((Get-MailConfirmationCode $read $phoneExpected) -ceq '0843') 'real Windows OCR extracts exact four-digit telephone code'
        $dateStatus=Get-MailConfirmationDateStatus $read $phoneExpected $now
        if($dateStatus -ne 'Current') { Write-Host ('Synthetic telephone OCR diagnostic: ' + ($read -replace '[0-9]{4,8}','[synthetic-number]')) }
        Assert ($dateStatus -eq 'Current') 'real Windows OCR preserves telephone identity and header time'
    }
}
# Exercise the real business-message adapter, replacing only the external transport.
. (Join-Path $root 'MailConfirmation.ps1')
$script:captured = $null
function Send-MonitorNotification {
    param($Config,$Title,$Message,[switch]$IsAlarm,[ref]$Outcome)
    $script:captured = [pscustomobject]@{Title=$Title;Message=$Message;IsAlarm=[bool]$IsAlarm}
    $Outcome.Value='Success'; return $true
}
$delivery='NotSent'
Assert (Send-MailConfirmationMessage -Config @{} -Event $expected -Code '063827' -Outcome ([ref]$delivery)) 'business adapter accepts transport success'
Assert ($delivery -eq 'Success' -and $script:captured.IsAlarm) 'one business alarm with optional night marker'
Assert ($script:captured.Title -match '063827' -and $script:captured.Message -match '确认码：063827') 'code survives into actual notification title and content'
Assert ($script:captured.Message -notmatch 'report@|验证码|密码') 'raw mail and generic credentials not included'
Assert (Send-MailConfirmationMessage -Config @{} -Event $phoneExpected -Code '0843' -Outcome ([ref]$delivery)) 'telephone adapter uses the existing mocked transport'
Assert ($script:captured.IsAlarm -and $script:captured.Title -match '电话抽查验证码：0843' -and $script:captured.Message -match '验证码：0843') 'telephone notification is typed and carries exactly four digits'
Assert (Send-MailConfirmationMessage -Config @{} -Event $phoneExpected -Code '' -Outcome ([ref]$delivery)) 'telephone no-code fallback uses the existing transport'
Assert ($script:captured.Title -match '4位验证码' -and $script:captured.Message -notmatch '0843|6位') 'telephone fallback never claims a six-digit code'
Initialize-MailConfirmationNative
Assert ($null -ne ('MailConfirmationInput' -as [type])) 'production native adapter compiles without sending input'
'PASS: '+$script:checks+' mail confirmation checks; all delivery and clicks mocked.'
