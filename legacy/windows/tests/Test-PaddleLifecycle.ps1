param([string]$PythonPath = '')
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'Monitor-WindowKeywords.ps1') -LibraryOnly
if(-not $PythonPath){$PythonPath=Get-PythonExecutable}
$fixture = Join-Path $root '04_资料\整体检查_20260907\paddle_startup_failure.py'
New-Item -ItemType Directory -Path (Split-Path $fixture -Parent) -Force | Out-Null
[IO.File]::WriteAllText($fixture, "import json,time`nprint(json.dumps({'ready':False,'error':'synthetic startup failure'}),flush=True)`ntime.sleep(15)`n", [Text.UTF8Encoding]::new($false))
$script:fixturePath = $fixture
$script:pythonPathForTest = $PythonPath
function Get-PythonExecutable { return $script:pythonPathForTest }
function Get-PaddleOcrScriptPath { param($Config); return $script:fixturePath }
function Write-MonitorLog { param($Config,$Message) }
$config=[pscustomobject]@{paddleStartupTimeoutSeconds=1;paddleRequestTimeoutSeconds=1}
$failure=$null
try {
    try { Start-PaddleOcrWorker $config }
    catch { $failure=$_.Exception }
    if($null -eq $failure){throw 'Expected synthetic startup rejection.'}
    $leaked=@(Get-CimInstance Win32_Process | Where-Object {$_.Name -eq 'python.exe' -and $_.CommandLine -like ('*'+$fixture+'*')})
    if($leaked.Count -gt 0){throw ('FAIL: rejected OCR startup left '+$leaked.Count+' Python worker(s) alive.')}
    Write-Output 'PASS: failed Paddle startup releases its Python process.'
    foreach($mode in @('startup_timeout','request_timeout','healthy')) {
        $script:NextPaddleStartAt=[datetime]::MinValue
        $source="import json,time,sys,base64`n"
        if($mode -eq 'startup_timeout'){$source+="time.sleep(15)`n"}
        elseif($mode -eq 'request_timeout'){$source+="print(json.dumps({'ready':True}),flush=True)`nsys.stdin.readline()`ntime.sleep(15)`n"}
        else{$source+="print(json.dumps({'ready':True}),flush=True)`nfor line in sys.stdin:`n if line.strip()=='__quit__': break`n print(json.dumps({'ok':True,'text_b64':base64.b64encode(b'Synthetic OCR result').decode('ascii')}),flush=True)`n"}
        [IO.File]::WriteAllText($fixture,$source,[Text.UTF8Encoding]::new($false))
        $watch=[Diagnostics.Stopwatch]::StartNew()
        $caseFailure=$null
        try {
            if($mode -eq 'startup_timeout'){Start-PaddleOcrWorker $config}
            else{$recognized=Read-PaddleOcrText $config 'synthetic.png'}
        } catch {$caseFailure=$_.Exception}
        if($mode -eq 'healthy') {
            if($caseFailure -or $recognized -ne 'Synthetic OCR result'){throw 'Healthy worker protocol regressed.'}
            Stop-PaddleOcrWorker
        } else {
            if($null -eq $caseFailure -or $watch.Elapsed.TotalSeconds -gt 3){throw ($mode+' did not respect its one-second timeout.')}
            if($null -ne $script:PaddleOcrProcess){throw ($mode+' did not release its process.')}
        }
        $leaked=@(Get-CimInstance Win32_Process | Where-Object {$_.Name -eq 'python.exe' -and $_.CommandLine -like ('*'+$fixture+'*')})
        if($leaked.Count -gt 0){throw ($mode+' left a Python process.')}
        Write-Output ('PASS: '+$mode+' bounded protocol and cleanup.')
    }
}
finally {
    Stop-PaddleOcrWorker
    foreach($owned in @(Get-CimInstance Win32_Process | Where-Object {$_.Name -eq 'python.exe' -and $_.CommandLine -like ('*'+$fixture+'*')})) {Stop-Process -Id $owned.ProcessId -Force -ErrorAction SilentlyContinue}
}
