Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'VerificationCode.ps1')

$script:RegressionChecks = 0
$script:RegressionFailures = New-Object 'System.Collections.Generic.List[string]'
function Assert-CodeRegression {
    param([string]$Name, [string]$Text, [string[]]$Expected)
    $result = @(Get-VerificationCodes -Text $Text)
    $actual = @($result | ForEach-Object { $_.Code })
    $script:RegressionChecks++
    if (($actual -join '|') -cne ($Expected -join '|')) {
        $script:RegressionFailures.Add($Name + ' (wrong extracted code count/value)')
    }
    foreach ($item in $result) {
        if ($item.Code -isnot [string] -or -not $Text.Contains($item.Evidence)) {
            $script:RegressionFailures.Add($Name + ' (code type or original evidence)')
        }
    }
}

# Each case is synthetic. Never load real OCR buffers, configs or credentials.
Assert-CodeRegression 'Reverse code with greeting' 'Hello, 123456 is your verification code' @('123456')
Assert-CodeRegression 'Code then countdown field' '验证码：123456 60秒后过期' @('123456')
Assert-CodeRegression 'Grouped code then separated countdown field' '验证码：123 456  60秒后过期' @('123456')
Assert-CodeRegression 'Identifier suffix is not OTP label' 'ID_OTP: 123456' @()
Assert-CodeRegression 'Email is not code' 'OTP: A1B2@example.com' @()
Assert-CodeRegression 'Underscore token must not be truncated' 'OTP: A1B2_C3' @()
Assert-CodeRegression 'Hyphen token must not be truncated' 'OTP: A1B2-C3' @()
Assert-CodeRegression 'Reverse email suffix is not code' 'foo@123456 is your OTP' @()
Assert-CodeRegression 'Narrow no break space OCR group' ("验证码：123" + [char]0x202F + '456') @('123456')
Assert-CodeRegression 'Thin space OCR group' ("验证码：123" + [char]0x2009 + '456') @('123456')
Assert-CodeRegression 'Curly quotation around explicit code' '验证码：“001234”' @('001234')
Assert-CodeRegression 'Quoted alternatives remain ambiguous' '验证码：[123456] 或 [654321]' @()

$privacyCases = @(
    @{ Name = 'Rejected long grouped run'; Text = '验证码：123 456 789'; Forbidden = '123 456' },
    @{ Name = 'Rejected multiple short groups'; Text = '验证码：12 34 56 78 90'; Forbidden = '12 34 56' },
    @{ Name = 'Thin whitespace code'; Text = ('验证码：123' + [char]0x2009 + '456'); Forbidden = '123' }
)
foreach ($case in $privacyCases) {
    $script:RegressionChecks++
    $protected = Protect-VerificationText -Text $case.Text
    if ($protected.Contains($case.Forbidden) -or -not $protected.Contains('[验证码已隐藏]')) {
        $script:RegressionFailures.Add($case.Name + ' (unredacted candidate)')
    }
}

Assert-CodeRegression 'Letter case remains significant across messages' "OTP: Ab12`r`nOTP: aB12" @('Ab12', 'aB12')
Assert-CodeRegression 'Chinese prefix before English label' '您的OTP：001234' @('001234')
Assert-CodeRegression 'English OTP substring remains rejected' 'MYOTP: 123456' @()
Assert-CodeRegression 'English label identifier remains rejected' 'security_code: 123456' @()
Assert-CodeRegression 'Ambiguous numeric run is not a countdown field' '验证码：12 34 56 seconds' @()
Assert-CodeRegression 'Grouped code and single-space countdown stay ambiguous' '验证码：123 456 60秒' @()
Assert-CodeRegression 'Unlabeled numeric tail is not a countdown field' '验证码：123456 60' @()
Assert-CodeRegression 'Reverse alternatives stay rejected' '123456 or 654321 is your verification code' @()
Assert-CodeRegression 'Reverse numeric prefix stays rejected' '123456, 654321 is your verification code' @()
Assert-CodeRegression 'Phone must not be separated into a code' '验证码：12025550100 60秒' @()
Assert-CodeRegression 'Two labeled messages each keep their own value' "验证码：001234`r`nSecurity code: A1b2" @('001234', 'A1b2')

# Seeded OCR-layout fixtures exercise public extraction and redaction together.
# These imitate OCR line/column/width variations; they do not claim real OCR accuracy.
$random = [System.Random]::new(20260908)
$spaces = @(' ', "`t", [string][char]0x00A0, [string][char]0x2009, [string][char]0x202F, [string][char]0x3000)
for ($sampleIndex = 0; $sampleIndex -lt 180; $sampleIndex++) {
    $code = $random.Next(0, 1000000).ToString('D6')
    $expectedCode = $code
    $space = $spaces[$random.Next(0, $spaces.Count)]
    switch ($sampleIndex % 6) {
        0 { $text = "登录账户`r`n验证码：$code`r`n60秒后可重发" }
        1 {
            $wide = -join @($code.ToCharArray() | ForEach-Object { [char]([int]$_ + 0xFEE0) })
            $text = '验　证　码：' + $wide.Substring(0, 3) + $space + $wide.Substring(3)
        }
        2 { $text = "Account settings`r`nHello, $code is your verification code." }
        3 { $text = '验证码：' + $code + $space + '60 seconds remaining' }
        4 { $expectedCode = 'a' + $code.Substring(0, 4) + 'Z'; $text = '手机12025550100；OTP：' + $expectedCode }
        5 { $text = 'Security code: “' + $code + '”' }
    }
    Assert-CodeRegression ('Seeded OCR layout ' + $sampleIndex) $text @($expectedCode)
    $protected = Protect-VerificationText -Text $text
    $normalProtected = [regex]::Replace((ConvertTo-VerificationNormalText $protected), '[ \t]+', '')
    $script:RegressionChecks++
    if ($normalProtected.Contains($expectedCode)) { $script:RegressionFailures.Add('Seeded OCR layout leaked extracted code ' + $sampleIndex) }
    Assert-CodeRegression ('Seeded unlabeled number ' + $sampleIndex) ('订单号：' + $code + '；剩余60秒') @()
    Assert-CodeRegression ('Seeded long phone ' + $sampleIndex) ('验证码：' + $code + '12345') @()
}

if ($script:RegressionFailures.Count -gt 0) {
    foreach ($failure in $script:RegressionFailures) { Write-Output ('FAIL: ' + $failure) }
    throw "Verification regression failures: $($script:RegressionFailures.Count) / $script:RegressionChecks checks."
}
Write-Output "PASS: $script:RegressionChecks verification regression checks (PowerShell $($PSVersionTable.PSVersion))."
