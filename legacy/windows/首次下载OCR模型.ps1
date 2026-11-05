$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location -LiteralPath $root

Write-Host ""
Write-Host "Initializing PaddleOCR models..."
Write-Host "The first run may download model files and take several minutes. Do not close this window."
Write-Host ""

$runner = Join-Path -Path $root -ChildPath "paddle_ocr_runner.py"
$image = Join-Path -Path $root -ChildPath "last_screenshot.png"
$asciiTempDir = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "window_keyword_ocr_cache\input"
$asciiInitImage = Join-Path -Path $asciiTempDir -ChildPath "init_test.png"

function Get-PythonExe {
    $pythonExe = Get-Command python.exe -ErrorAction SilentlyContinue
    if ($null -ne $pythonExe -and $pythonExe.Source -like "*.exe") {
        return $pythonExe.Source
    }

    $python = Get-Command python -ErrorAction SilentlyContinue
    if ($null -eq $python) {
        throw "python was not found."
    }

    if ($python.Source -like "*.exe") {
        return $python.Source
    }

    $resolved = & $python.Source -c "import sys; print(sys.executable)" 2>$null | Select-Object -First 1
    if ($resolved -and (Test-Path -LiteralPath $resolved)) {
        return [string]$resolved
    }

    $toolRoot = Split-Path -Parent (Split-Path -Parent $python.Source)
    $servbayPython = Join-Path -Path $toolRoot -ChildPath "packages\python\current\python.exe"
    if (Test-Path -LiteralPath $servbayPython) {
        return $servbayPython
    }

    return $python.Source
}

function Invoke-PythonRunner {
    param(
        [string]$PythonExe,
        [string]$Runner,
        [string]$ImagePath
    )

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $PythonExe
    $psi.Arguments = "`"$Runner`" `"$ImagePath`""
    $psi.WorkingDirectory = $root
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $psi
    [void]$process.Start()

    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()

    return [pscustomobject]@{
        ExitCode = $process.ExitCode
        Output = ($stdout + "`n" + $stderr).Trim()
    }
}

if (-not (Test-Path -LiteralPath $runner)) {
    Write-Host "Failed: paddle_ocr_runner.py was not found." -ForegroundColor Red
    Read-Host "Press Enter to exit"
    exit 1
}

if (-not (Test-Path -LiteralPath $image)) {
    Write-Host "last_screenshot.png was not found. Creating a temporary image..."
    Add-Type -AssemblyName System.Drawing
    $bitmap = New-Object System.Drawing.Bitmap(900, 260)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    try {
        $graphics.Clear([System.Drawing.Color]::White)
        $font = New-Object System.Drawing.Font("Microsoft YaHei", 28)
        $brush = [System.Drawing.Brushes]::Black
        $graphics.DrawString("PaddleOCR model init test", $font, $brush, 30, 90)
        $bitmap.Save($image, [System.Drawing.Imaging.ImageFormat]::Png)
    }
    finally {
        $graphics.Dispose()
        $bitmap.Dispose()
    }
}

if (-not (Test-Path -LiteralPath $asciiTempDir)) {
    New-Item -ItemType Directory -Path $asciiTempDir -Force | Out-Null
}
Copy-Item -LiteralPath $image -Destination $asciiInitImage -Force

try {
    $pythonExe = Get-PythonExe
    Write-Host "Using Python: $pythonExe"

    $result = Invoke-PythonRunner $pythonExe $runner $asciiInitImage
    $exitCode = $result.ExitCode
    $outputText = $result.Output

    if ($outputText) {
        Write-Host $outputText
    }

    if ($exitCode -ne 0 -or $outputText -match "PaddleOCR import failed|No model source is available|parse error") {
        throw "PaddleOCR init failed. Python exit code: $exitCode"
    }

    Write-Host ""
    Write-Host "PaddleOCR model initialization succeeded." -ForegroundColor Green
    Write-Host "Now double-click OCR画面监控.exe to start monitoring."
}
catch {
    Write-Host ""
    Write-Host "PaddleOCR model initialization failed:" -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    Write-Host ""
    Write-Host "Common cause: this PC cannot access the PaddleOCR model download site."
    Write-Host "Check the network, then run this exe again."
}

Write-Host ""
Read-Host "Press Enter to exit"
