param([string]$AlternateRoot = '')
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$data=Join-Path $root '04_资料\整体检查_20260907'
New-Item -ItemType Directory -Path $data -Force | Out-Null
$path=Join-Path $data 'single_instance_test_config.json'
$config=[pscustomobject]@{keywords=@('synthetic');windowTitleContains='__no_such_window_for_regression__';processNameContains='';scanFullDesktopWhenNoWindow=$false;verificationCodeEnabled=$false;ocrLanguage='zh-Hans-CN';logFile='';intervalSeconds=0.5}
$config|ConvertTo-Json|Set-Content -LiteralPath $path -Encoding UTF8
$processes=@()
try {
    foreach($index in 1..2){
        $psi=[Diagnostics.ProcessStartInfo]::new()
        $psi.FileName=Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $launchRoot=if($index -eq 2 -and $AlternateRoot){$AlternateRoot}else{$root}
        $psi.Arguments='-NoProfile -ExecutionPolicy Bypass -File "{0}" -ConfigPath "{1}" -NoCall' -f (Join-Path $launchRoot 'Monitor-WindowKeywords.ps1'),$path
        $psi.WorkingDirectory=$root;$psi.UseShellExecute=$false;$psi.CreateNoWindow=$true
        $psi.RedirectStandardOutput=$true;$psi.RedirectStandardError=$true
        $child=[Diagnostics.Process]::Start($psi)
        $processes+=,$child
        if($index -eq 1){Start-Sleep -Seconds 2}
    }
    if(-not $processes[1].WaitForExit(4000)){throw 'FAIL: starting twice leaves two live mail monitors.'}
    if($processes[1].ExitCode -ne 0){throw ('Second monitor failed unexpectedly: '+$processes[1].StandardError.ReadToEnd())}
    if($processes[0].HasExited){throw 'First monitor was interrupted by duplicate start.'}
    Write-Output 'PASS: duplicate start exits successfully without interrupting the first monitor.'
}
finally {
    foreach($child in $processes){if(-not $child.HasExited){$child.Kill();[void]$child.WaitForExit(1500)};$child.Dispose()}
}
