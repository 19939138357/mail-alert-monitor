param([string]$Archive = 'dist/MailAlertMonitor-Windows.zip')
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
$zipPath = (Resolve-Path -LiteralPath $Archive).Path
$workspace = Join-Path $repo '.build\windows-smoke'
[void][IO.Directory]::CreateDirectory($workspace)
$extraction = Join-Path $workspace ([guid]::NewGuid().ToString('N'))
$process = $null

function Test-DesktopLaunch([string]$Exe) {
    $script:process = Start-Process -FilePath $Exe -PassThru -WorkingDirectory (Split-Path $Exe)
    $timeout = [DateTime]::UtcNow.AddSeconds(35)
    do {
        Start-Sleep -Milliseconds 250
        $script:process.Refresh()
        if ($script:process.HasExited) { throw 'Desktop process exited before showing its window.' }
        if ($script:process.MainWindowTitle -eq '邮件监控') { return }
    } while ([DateTime]::UtcNow -lt $timeout)
    throw 'The desktop window did not appear.'
}

function Stop-TestDesktop {
    if (-not $script:process.CloseMainWindow() -or -not $script:process.WaitForExit(7000)) {
        throw 'The desktop did not close normally.'
    }
    if ($script:process.ExitCode -ne 0) { throw 'The desktop exited with an error.' }
    $script:process.Dispose()
    $script:process = $null
}

try {
    Expand-Archive -LiteralPath $zipPath -DestinationPath $extraction
    $appFolder = Join-Path $extraction 'MailAlertMonitor'
    $exe = Join-Path $appFolder 'MailAlertMonitor.exe'
    $configPath = Join-Path $appFolder 'monitor_config.json'
    $privatePath = Join-Path $appFolder '04_资料'
    if ((Test-Path -LiteralPath $configPath) -or (Test-Path -LiteralPath $privatePath)) {
        throw 'ZIP contains local user data.'
    }
    Test-DesktopLaunch $exe
    if (-not (Test-Path -LiteralPath $configPath)) { throw 'First launch did not create its configuration.' }
    $config = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($config.mailConfirmationAutoOpenEnabled -or $config.ringExistingOnStart -or $config.scanFullDesktopWhenNoWindow) {
        throw 'Unexpected first-run monitoring defaults.'
    }
    Stop-TestDesktop
    $config.intervalSeconds = 7
    $config | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $configPath -Encoding UTF8
    $savedHash = (Get-FileHash -LiteralPath $configPath -Algorithm SHA256).Hash
    Test-DesktopLaunch $exe
    Stop-TestDesktop
    if ((Get-FileHash -LiteralPath $configPath -Algorithm SHA256).Hash -ne $savedHash) {
        throw 'Second launch replaced the user configuration.'
    }
    $capture = Join-Path $workspace 'overview.png'
    if (Test-Path -LiteralPath $capture) { Remove-Item -LiteralPath $capture }
    $script:process = Start-Process -FilePath $exe -ArgumentList ('--preview "{0}" 980 692' -f $capture) -PassThru
    if (-not $process.WaitForExit(30000) -or $process.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $capture)) {
        throw 'Desktop preview did not render.'
    }
    if ((Get-Item -LiteralPath $capture).Length -lt 2048) { throw 'Desktop preview was empty.' }
    if ((Test-Path -LiteralPath $privatePath) -or (Test-Path -LiteralPath (Join-Path $appFolder 'monitor.log'))) {
        throw 'Launching the desktop unexpectedly started monitoring or created private data.'
    }
    Write-Output 'PASS: complete ZIP, first and repeat GUI launch, safe defaults, retained settings and rendered overview.'
}
finally {
    if ($null -ne $process) {
        if (-not $process.HasExited) { $process.Kill(); [void]$process.WaitForExit(5000) }
        $process.Dispose()
    }
    if (Test-Path -LiteralPath $extraction) { Remove-Item -LiteralPath $extraction -Recurse -Force }
}
