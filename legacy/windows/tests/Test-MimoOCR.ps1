$ErrorActionPreference='Stop'
Set-StrictMode -Version 2
. (Join-Path $PSScriptRoot '../MimoOCR.ps1')
$checks=0
function Envelope($Content,$Finish='stop') {
    return @{choices=@(@{finish_reason=$Finish;message=@{content=$Content}})} | ConvertTo-Json -Depth 7 -Compress
}
$json='{"lines":["示例邮件","确认码：063827","状态：异常"]}'
$lines=@(ConvertFrom-MimoResponse (Envelope $json))
if ($lines.Count -ne 3 -or $lines[1] -cne '确认码：063827') {throw 'Exact code was changed'}
$checks++
foreach ($case in @((Envelope $json 'length'),(Envelope '{"lines":[]}'),(Envelope '{"lines":[12]}'),(Envelope '{"lines":["a\nb"]}'),(Envelope 'not JSON'))) {
    $rejected=$false
    try {ConvertFrom-MimoResponse $case | Out-Null} catch {$rejected=$true}
    if (-not $rejected) {throw 'Invalid model output was accepted'}
    $checks++
}
Write-Output "PASS: $checks MiMo response integrity checks; local synthetic data only."
