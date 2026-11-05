$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'Monitor-WindowKeywords.ps1') -LibraryOnly
$engine = New-OcrEngine 'zh-Hans-CN'
$cases = @(
    @{Text='您的验证码：083729';Code='083729'},
    @{Text='Your verification code is 582914';Code='582914'},
    @{Text="安全验证`n验证码：628517`n5分钟内有效";Code='628517'},
    @{Text='订单编号：582914';Code=''}
)
$report = @()
New-Item -ItemType Directory -Path (Join-Path $root '04_资料\验证码推送升级_20260907') -Force | Out-Null
foreach ($case in $cases) {
    $bitmap = [System.Drawing.Bitmap]::new(1150, 220)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $font = [System.Drawing.Font]::new('Microsoft YaHei', 25)
    $watch = [Diagnostics.Stopwatch]::StartNew()
    try {
        $graphics.Clear([System.Drawing.Color]::White)
        $graphics.DrawString($case.Text, $font, [System.Drawing.Brushes]::Black, 20, 15)
        $text = Read-VerificationRectangleText -Engine $engine -InputBitmap $bitmap
        $codes = @(Get-VerificationCodes -Text $text)
        $actual = ($codes | ForEach-Object Code) -join ','
        if ($actual -ne $case.Code) { throw "Synthetic OCR case failed: expected=$($case.Code); actual=$actual; OCR=$text" }
        $report += [pscustomobject]@{case=$report.Count + 1;passed=$true;elapsedMs=$watch.ElapsedMilliseconds}
    }
    finally { $watch.Stop(); $font.Dispose(); $graphics.Dispose(); $bitmap.Dispose() }
}
$report | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $root '04_资料\验证码推送升级_20260907\OCR合成样本测试.json') -Encoding UTF8
Write-Output ('PASS: {0} real Windows OCR bitmap cases; max elapsed {1} ms' -f $report.Count, ($report.elapsedMs | Measure-Object -Maximum).Maximum)
