$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'Monitor-WindowKeywords.ps1') -LibraryOnly
$relative='04_资料\整体检查_20260907\locked_test.log'
$path=Join-Path $root $relative
New-Item -ItemType Directory -Path (Split-Path $path -Parent) -Force | Out-Null
$handle=[IO.File]::Open($path,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
try {
    Write-MonitorLog ([pscustomobject]@{logFile=$relative}) 'Synthetic delivery succeeded.'
    Write-Output 'PASS: a busy log file cannot turn an accepted delivery into a retry or crash.'
} finally {$handle.Dispose()}
