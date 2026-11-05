Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'VerificationCode.ps1')

$cases = @(
    @{ Name = 'Chinese leading zero'; Text = '您的验证码为 001234，请勿告诉他人。'; Expected = @('001234') }
    @{ Name = 'Dynamic code'; Text = '动态码：7865'; Expected = @('7865') }
    @{ Name = 'Check code'; Text = '校验码是 87654321'; Expected = @('87654321') }
    @{ Name = 'Full width and spaced label'; Text = '验 证 码：００１２３４'; Expected = @('001234') }
    @{ Name = 'Grouped digits'; Text = '验证码: 123 456'; Expected = @('123456') }
    @{ Name = 'Single digit groups'; Text = '验证码: 0 1 2 3 4 5'; Expected = @('012345') }
    @{ Name = 'Two digit groups'; Text = '动态码: 01 23 45'; Expected = @('012345') }
    @{ Name = 'Next line'; Text = "验证码：`r`n001234"; Expected = @('001234') }
    @{ Name = 'Too many lines'; Text = "验证码：`r`n`r`n001234"; Expected = @() }
    @{ Name = 'English OTP'; Text = 'Your OTP is 095321'; Expected = @('095321') }
    @{ Name = 'English mixed'; Text = 'Verification code: A1B2C3'; Expected = @('A1B2C3') }
    @{ Name = 'Digit first mixed'; Text = 'Security code is 1A2B3C'; Expected = @('1A2B3C') }
    @{ Name = 'One time password'; Text = 'One-time password: 01234567'; Expected = @('01234567') }
    @{ Name = 'Reverse English'; Text = '021934 is your verification code'; Expected = @('021934') }
    @{ Name = 'Reverse Chinese'; Text = '021934 是您的验证码'; Expected = @('021934') }
    @{ Name = 'Do not substitute O and I'; Text = 'OTP: O1I2'; Expected = @('O1I2') }
    @{ Name = 'Full width mixed'; Text = '验证码：Ａ１Ｂ２'; Expected = @('A1B2') }
    @{ Name = 'No label'; Text = '登录：123456'; Expected = @() }
    @{ Name = 'English ordinary word'; Text = 'OTP: security'; Expected = @() }
    @{ Name = 'Phone'; Text = '验证码：12025550100'; Expected = @() }
    @{ Name = 'Grouped phone'; Text = '验证码：138 0013 8000'; Expected = @() }
    @{ Name = 'Phone destination'; Text = '验证码已发送至12025550100，请在5分钟内输入'; Expected = @() }
    @{ Name = 'Long order'; Text = '验证码：2026090712345678'; Expected = @() }
    @{ Name = 'Order context'; Text = '验证码，订单号：123456'; Expected = @() }
    @{ Name = 'Date dash'; Text = '验证码：2026-09-07'; Expected = @() }
    @{ Name = 'Date slash'; Text = '验证码：2026/09/07'; Expected = @() }
    @{ Name = 'Date Chinese'; Text = '验证码：2026年9月7日'; Expected = @() }
    @{ Name = 'Seconds'; Text = '验证码：1234秒后重试'; Expected = @() }
    @{ Name = 'English seconds'; Text = 'OTP: 1234 seconds remaining'; Expected = @() }
    @{ Name = 'Count'; Text = '验证码：1234个'; Expected = @() }
    @{ Name = 'Length only'; Text = '验证码为6位数字'; Expected = @() }
    @{ Name = 'Length then real code'; Text = '验证码 6位：023456'; Expected = @('023456') }
    @{ Name = 'Too short'; Text = '验证码：123'; Expected = @() }
    @{ Name = 'Too long'; Text = '验证码：123456789'; Expected = @() }
    @{ Name = 'Ambiguous spaced'; Text = '验证码：1234 5678'; Expected = @() }
    @{ Name = 'Ambiguous slash'; Text = '验证码：123456 / 654321'; Expected = @() }
    @{ Name = 'Ambiguous Chinese'; Text = '验证码：123456 或 654321'; Expected = @() }
    @{ Name = 'Ambiguous English'; Text = 'OTP: 123456 or 654321'; Expected = @() }
    @{ Name = 'Reverse ambiguity'; Text = '123456 or 654321 is your verification code'; Expected = @() }
    @{ Name = 'Multiple labeled'; Text = "验证码：001234`r`nOTP: A1B2"; Expected = @('001234', 'A1B2') }
    @{ Name = 'Duplicate'; Text = "验证码：001234`nOTP: 001234"; Expected = @('001234') }
    @{ Name = 'Countdown after valid'; Text = '验证码：123456，5分钟内有效'; Expected = @('123456') }
    @{ Name = 'OTP not substring'; Text = 'NOTP: 123456'; Expected = @() }
    @{ Name = 'Blank'; Text = '  '; Expected = @() }
    @{ Name = 'Null'; Text = $null; Expected = @() }
)

$passed = 0
foreach ($case in $cases) {
    $result = @(Get-VerificationCodes -Text $case.Text)
    $actual = @($result | ForEach-Object { $_.Code })
    if (($actual -join '|') -cne ($case.Expected -join '|')) {
        throw "FAILED: $($case.Name): expected $($case.Expected -join ',') but got $($actual -join ',')"
    }
    foreach ($item in $result) {
        if ($item.Code -isnot [string]) { throw "Code must be string: $($case.Name)" }
        if ($item.Evidence.Length -gt 180 -or [string]::IsNullOrWhiteSpace($item.Evidence)) { throw "Bad evidence: $($case.Name)" }
        if (-not $case.Text.Contains($item.Evidence)) { throw "Evidence is not original text: $($case.Name)" }
        $expectedKind = if ($item.Code -cmatch '[A-Za-z]') { 'alphanumeric' } else { 'numeric' }
        if ($item.Kind -cne $expectedKind) { throw "Bad kind: $($case.Name)" }
    }
    $passed++
}

$privacyCases = @(
    @{ Text = '验证码：001234'; Forbidden = @('001234') }
    @{ Text = '验证码：００１２３４'; Forbidden = @('００１２３４') }
    @{ Text = 'OTP: A1B2C3'; Forbidden = @('A1B2C3') }
    @{ Text = '验证码：123 456'; Forbidden = @('123 456') }
    @{ Text = '验证码：123456 或 654321'; Forbidden = @('123456', '654321') }
    @{ Text = '验证码：123456 654321'; Forbidden = @('123456', '654321') }
    @{ Text = '123456 is your verification code'; Forbidden = @('123456') }
    @{ Text = "验证码：123456`nOTP：654321"; Forbidden = @('123456', '654321') }
)
foreach ($case in $privacyCases) {
    $protected = Protect-VerificationText -Text $case.Text
    foreach ($value in $case.Forbidden) {
        if ($protected.Contains($value)) { throw 'FAILED: privacy redaction left a candidate value visible.' }
    }
    if (-not $protected.Contains('[验证码已隐藏]')) { throw 'FAILED: privacy replacement missing.' }
    $passed++
}
if ((Protect-VerificationText -Text '普通状态：就绪') -cne '普通状态：就绪') { throw 'FAILED: ordinary log changed.' }
if ((Protect-VerificationText -Text $null) -cne '') { throw 'FAILED: null redaction.' }
$passed += 2
Write-Output "PASS: $passed verification extraction, evidence, kind and privacy cases (PowerShell $($PSVersionTable.PSVersion))."
