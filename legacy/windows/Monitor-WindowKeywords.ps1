param(
    [string]$ConfigPath = ".\monitor_config.json",
    [switch]$Once,
    [switch]$NoCall,
    [switch]$ListWindows,
    [switch]$VerificationOnly,
    [int]$ParentMonitorId = 0,
    [switch]$LibraryOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

try {
    [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
    [Console]::InputEncoding = [System.Text.UTF8Encoding]::new($false)
    $OutputEncoding = [System.Text.UTF8Encoding]::new($false)
}
catch {
}

Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Runtime.WindowsRuntime

Add-Type @"
using System;
using System.Runtime.InteropServices;

public static class Win32WindowTools
{
    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();
    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT
    {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

    [DllImport("dwmapi.dll")]
    private static extern int DwmGetWindowAttribute(IntPtr window, int attribute, out int value, int bytes);

    public static bool IsCaptureVisible(IntPtr target, int left, int top, int width, int height)
    {
        if (target == IntPtr.Zero || target != GetForegroundWindow() || width <= 0 || height <= 0) return false;
        RECT bounds;
        if (!GetWindowRect(target, out bounds) || left < bounds.Left || top < bounds.Top ||
            left + width > bounds.Right || top + height > bounds.Bottom) return false;
        bool found = false;
        EnumWindows(delegate(IntPtr window, IntPtr unused) {
            if (window == target) { found = true; return false; }
            if (!IsWindowVisible(window) || IsIconic(window)) return true;
            int cloaked;
            if (DwmGetWindowAttribute(window, 14, out cloaked, sizeof(int)) == 0 && cloaked != 0) return true;
            RECT other;
            if (!GetWindowRect(window, out other)) return false;
            return other.Left >= left + width || other.Right <= left || other.Top >= top + height || other.Bottom <= top;
        }, IntPtr.Zero);
        return found && target == GetForegroundWindow();
    }

    [DllImport("user32.dll")]
    public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);

    [DllImport("user32.dll")]
    public static extern bool IsWindowVisible(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool IsIconic(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

    [DllImport("user32.dll")]
    public static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern int GetWindowText(IntPtr hWnd, System.Text.StringBuilder lpString, int nMaxCount);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern int GetWindowTextLength(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);
}
"@

[void][Windows.Media.Ocr.OcrEngine, Windows.Foundation, ContentType = WindowsRuntime]
[void][Windows.Media.Ocr.OcrResult, Windows.Foundation, ContentType = WindowsRuntime]
[void][Windows.Globalization.Language, Windows.Foundation, ContentType = WindowsRuntime]
[void][Windows.Storage.StorageFile, Windows.Storage, ContentType = WindowsRuntime]
[void][Windows.Storage.FileAccessMode, Windows.Storage, ContentType = WindowsRuntime]
[void][Windows.Storage.Streams.IRandomAccessStream, Windows.Storage.Streams, ContentType = WindowsRuntime]
[void][Windows.Graphics.Imaging.BitmapDecoder, Windows.Graphics.Imaging, ContentType = WindowsRuntime]
[void][Windows.Graphics.Imaging.SoftwareBitmap, Windows.Graphics.Imaging, ContentType = WindowsRuntime]

$script:AsTaskGeneric = ([System.WindowsRuntimeSystemExtensions].GetMethods() |
    Where-Object {
        $_.Name -eq "AsTask" -and
        $_.IsGenericMethod -and
        $_.GetParameters().Count -eq 1 -and
        $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
    } | Select-Object -First 1)

if ($null -eq $script:AsTaskGeneric) {
    throw "Cannot find Windows Runtime AsTask helper for OCR."
}

function Wait-WinRtOperation {
    param(
        [Parameter(Mandatory = $true)]$Operation,
        [Parameter(Mandatory = $true)][type]$ResultType
    )

    $asTask = $script:AsTaskGeneric.MakeGenericMethod($ResultType)
    $task = $asTask.Invoke($null, @($Operation))
    $task.Wait() | Out-Null
    return $task.Result
}

function Read-Config {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Config file not found: $Path"
    }

    return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Write-MonitorLog {
    param(
        [object]$Config,
        [string]$Message
    )

    $Message = Protect-VerificationText $Message
    $line = "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message
    Write-Host $line

    $logFile = Get-ConfigString $Config 'logFile' ''
    if ($logFile) {
        try {
            $logPath = Join-Path -Path $PSScriptRoot -ChildPath $logFile
            Add-Content -LiteralPath $logPath -Value $line -Encoding UTF8 -ErrorAction Stop
        }
        catch {
            # Logging must never undo an acknowledged send or terminate monitoring.
            Write-Host '[log] File temporarily unavailable; status was shown above.'
        }
    }
}

function Wait-MonitorInterval {
    param([object]$Config)

    $seconds = 1.0
    if ($Config.intervalSeconds) {
        $seconds = [double]$Config.intervalSeconds
    }

    $milliseconds = [Math]::Max(100, [int]($seconds * 1000))
    Start-Sleep -Milliseconds $milliseconds
}

function Normalize-Text {
    param([string]$Text)

    if ($null -eq $Text) {
        return ""
    }

    return ([regex]::Replace($Text, '[\p{P}\p{S}\p{Z}\s]+', '')).Trim()
}

function Get-ConfigInt {
    param(
        [object]$Config,
        [string]$Name,
        [int]$DefaultValue
    )

    $property = $Config.PSObject.Properties |
        Where-Object { $_.Name -eq $Name } |
        Select-Object -First 1

    if ($null -eq $property -or $null -eq $property.Value) {
        return $DefaultValue
    }

    return [int]$property.Value
}

function Get-ConfigString {
    param(
        [object]$Config,
        [string]$Name,
        [string]$DefaultValue = ""
    )

    $property = $Config.PSObject.Properties |
        Where-Object { $_.Name -eq $Name } |
        Select-Object -First 1

    if ($null -eq $property -or $null -eq $property.Value) {
        return $DefaultValue
    }

    return [string]$property.Value
}

function Get-ConfigBool {
    param(
        [object]$Config,
        [string]$Name,
        [bool]$DefaultValue = $false
    )

    $property = $Config.PSObject.Properties |
        Where-Object { $_.Name -eq $Name } |
        Select-Object -First 1

    if ($null -eq $property -or $null -eq $property.Value) {
        return $DefaultValue
    }

    try {
        return [System.Convert]::ToBoolean($property.Value)
    }
    catch {
        return $DefaultValue
    }
}

function Test-WindowTitleMatch {
    param(
        [string]$Title,
        [object[]]$Patterns
    )

    foreach ($pattern in $Patterns) {
        if ($pattern -and $Title.Contains([string]$pattern)) {
            return $true
        }
    }

    return $false
}

function Test-TextPatternMatch {
    param(
        [string]$Text,
        [object[]]$Patterns
    )

    foreach ($pattern in $Patterns) {
        if ($pattern -and $Text.Contains([string]$pattern)) {
            return $true
        }
    }

    return $false
}

function Limit-RectangleToScreen {
    param([object]$Rectangle)

    $screen = [System.Windows.Forms.SystemInformation]::VirtualScreen
    $left = [Math]::Max($Rectangle.Left, $screen.Left)
    $top = [Math]::Max($Rectangle.Top, $screen.Top)
    $right = [Math]::Min($Rectangle.Left + $Rectangle.Width, $screen.Left + $screen.Width)
    $bottom = [Math]::Min($Rectangle.Top + $Rectangle.Height, $screen.Top + $screen.Height)

    $width = $right - $left
    $height = $bottom - $top
    if ($width -le 0 -or $height -le 0) {
        return $null
    }

    return [pscustomobject]@{
        Left = $left
        Top = $top
        Width = $width
        Height = $height
        Title = $Rectangle.Title
        Handle = $Rectangle.Handle
    }
}

function Get-TopLevelWindows {
    $windows = New-Object System.Collections.Generic.List[object]

    $callback = [Win32WindowTools+EnumWindowsProc]{
        param([IntPtr]$hWnd, [IntPtr]$lParam)

        if (-not [Win32WindowTools]::IsWindowVisible($hWnd)) {
            return $true
        }

        if ([Win32WindowTools]::IsIconic($hWnd)) {
            return $true
        }

        $titleLength = [Win32WindowTools]::GetWindowTextLength($hWnd)
        if ($titleLength -le 0) {
            return $true
        }

        $titleBuilder = New-Object System.Text.StringBuilder ($titleLength + 1)
        [void][Win32WindowTools]::GetWindowText($hWnd, $titleBuilder, $titleBuilder.Capacity)
        $title = $titleBuilder.ToString()
        if (-not $title) {
            return $true
        }

        $processId = [uint32]0
        [void][Win32WindowTools]::GetWindowThreadProcessId($hWnd, [ref]$processId)
        if ($processId -eq 0) {
            return $true
        }

        $processName = ""
        try {
            $processName = (Get-Process -Id ([int]$processId) -ErrorAction Stop).ProcessName
        }
        catch {
            return $true
        }

        $rect = New-Object Win32WindowTools+RECT
        if (-not [Win32WindowTools]::GetWindowRect($hWnd, [ref]$rect)) {
            return $true
        }

        $width = $rect.Right - $rect.Left
        $height = $rect.Bottom - $rect.Top
        if ($width -le 80 -or $height -le 80) {
            return $true
        }

        $windows.Add([pscustomobject]@{
            ProcessName = $processName
            Title = $title
            Left = $rect.Left
            Top = $rect.Top
            Width = $width
            Height = $height
            Handle = $hWnd
        })

        return $true
    }

    [void][Win32WindowTools]::EnumWindows($callback, [IntPtr]::Zero)
    return $windows
}

function New-OcrEngine {
    param([string]$LanguageTag)

    $engine = $null
    if ($LanguageTag) {
        $language = [Windows.Globalization.Language]::new($LanguageTag)
        $engine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromLanguage($language)
    }

    if ($null -eq $engine) {
        $engine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromUserProfileLanguages()
    }

    if ($null -eq $engine) {
        throw "No Windows OCR engine is available. Install the Chinese OCR language pack in Windows language settings."
    }

    return $engine
}

function Get-TargetRectangle {
    param([object]$Config, [switch]$ForegroundOnly)

    $titles = @()
    if ($Config.windowTitleContains) {
        $titles = @($Config.windowTitleContains | Where-Object { $_ })
    }

    $processNames = @()
    if ($Config.processNameContains) {
        $processNames = @($Config.processNameContains | Where-Object { $_ })
    }

    if ($titles.Count -gt 0 -or $processNames.Count -gt 0) {
        $windows = Get-TopLevelWindows | Where-Object {
            (Test-TextPatternMatch $_.Title $titles) -or
                (Test-TextPatternMatch $_.ProcessName $processNames)
        }

        $best = $null
        $bestArea = 0
        foreach ($window in $windows) {
            if ($ForegroundOnly -and $window.Handle -ne [Win32WindowTools]::GetForegroundWindow()) { continue }
            $area = $window.Width * $window.Height
            if ($area -gt $bestArea) {
                $candidate = [pscustomobject]@{
                    Left = $window.Left
                    Top = $window.Top
                    Width = $window.Width
                    Height = $window.Height
                    Title = $window.Title
                    Handle = $window.Handle
                }

                $candidate = Limit-RectangleToScreen $candidate
                if ($null -ne $candidate) {
                    $bestArea = $candidate.Width * $candidate.Height
                    $best = $candidate
                }
            }
        }

        if ($null -ne $best) {
            return $best
        }
    }

    if ($Config.scanFullDesktopWhenNoWindow) {
        $screen = [System.Windows.Forms.SystemInformation]::VirtualScreen
        return [pscustomobject]@{
            Left = $screen.Left
            Top = $screen.Top
            Width = $screen.Width
            Height = $screen.Height
            Title = "full desktop"
            Handle = [IntPtr]::Zero
        }
    }

    return $null
}

function Get-CaptureRectangle {
    param(
        [object]$Config,
        [object]$Rectangle
    )

    $cropProperty = $Config.PSObject.Properties |
        Where-Object { $_.Name -eq "captureCrop" } |
        Select-Object -First 1

    if ($null -eq $cropProperty -or $null -eq $cropProperty.Value) {
        return $Rectangle
    }

    $crop = $cropProperty.Value
    $leftRatio = Get-ObjectNumberProperty $crop "leftRatio" 0.0
    $topRatio = Get-ObjectNumberProperty $crop "topRatio" 0.0
    $rightRatio = Get-ObjectNumberProperty $crop "rightRatio" 1.0
    $bottomRatio = Get-ObjectNumberProperty $crop "bottomRatio" 1.0

    $leftRatio = [Math]::Max(0.0, [Math]::Min(1.0, $leftRatio))
    $topRatio = [Math]::Max(0.0, [Math]::Min(1.0, $topRatio))
    $rightRatio = [Math]::Max($leftRatio, [Math]::Min(1.0, $rightRatio))
    $bottomRatio = [Math]::Max($topRatio, [Math]::Min(1.0, $bottomRatio))

    $candidate = [pscustomobject]@{
        Left = $Rectangle.Left + [int]($Rectangle.Width * $leftRatio)
        Top = $Rectangle.Top + [int]($Rectangle.Height * $topRatio)
        Width = [Math]::Max(1, [int]($Rectangle.Width * ($rightRatio - $leftRatio)))
        Height = [Math]::Max(1, [int]($Rectangle.Height * ($bottomRatio - $topRatio)))
        Title = $Rectangle.Title
        Handle = $Rectangle.Handle
    }

    $limited = Limit-RectangleToScreen $candidate
    if ($null -eq $limited) {
        return $Rectangle
    }

    return $limited
}

function Get-VisibleWindows {
    return Get-TopLevelWindows |
        Select-Object ProcessName, Title, Width, Height |
        Sort-Object ProcessName, Title
}

function Bring-TargetToFront {
    param([object]$Rectangle)

    if ($Rectangle.Handle -and $Rectangle.Handle -ne [IntPtr]::Zero) {
        [void][Win32WindowTools]::SetForegroundWindow($Rectangle.Handle)
        Start-Sleep -Milliseconds 600
    }
}

function Save-Screenshot {
    param(
        [object]$Rectangle,
        [string]$Path,
        [double]$Scale = 1.0
    )

    $scaledWidth = [Math]::Max(1, [int]($Rectangle.Width * $Scale))
    $scaledHeight = [Math]::Max(1, [int]($Rectangle.Height * $Scale))
    $bitmap = New-Object System.Drawing.Bitmap($Rectangle.Width, $Rectangle.Height)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)

    try {
        $graphics.CopyFromScreen($Rectangle.Left, $Rectangle.Top, 0, 0, $bitmap.Size)

        if ($Scale -gt 1.0) {
            $scaled = New-Object System.Drawing.Bitmap($scaledWidth, $scaledHeight)
            $scaledGraphics = [System.Drawing.Graphics]::FromImage($scaled)

            try {
                $scaledGraphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
                $scaledGraphics.DrawImage($bitmap, 0, 0, $scaledWidth, $scaledHeight)
                $scaled.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
            }
            finally {
                $scaledGraphics.Dispose()
                $scaled.Dispose()
            }
        }
        else {
            $bitmap.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
        }
    }
    finally {
        $graphics.Dispose()
        $bitmap.Dispose()
    }
}

function Read-OcrText {
    param(
        [object]$Engine,
        [string]$ImagePath
    )

    $file = Wait-WinRtOperation ([Windows.Storage.StorageFile]::GetFileFromPathAsync($ImagePath)) ([Windows.Storage.StorageFile])
    $stream = Wait-WinRtOperation ($file.OpenAsync([Windows.Storage.FileAccessMode]::Read)) ([Windows.Storage.Streams.IRandomAccessStream])

    try {
        $decoder = Wait-WinRtOperation ([Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($stream)) ([Windows.Graphics.Imaging.BitmapDecoder])
        $bitmap = Wait-WinRtOperation ($decoder.GetSoftwareBitmapAsync()) ([Windows.Graphics.Imaging.SoftwareBitmap])

        try {
            $result = Wait-WinRtOperation ($Engine.RecognizeAsync($bitmap)) ([Windows.Media.Ocr.OcrResult])
            return (($result.Lines | ForEach-Object {
                ($_.Words | ForEach-Object { $_.Text }) -join ""
            }) -join "`n")
        }
        finally {
            if ($bitmap -is [System.IDisposable]) {
                $bitmap.Dispose()
            }
        }
    }
    finally {
        $stream.Dispose()
    }
}

function Get-ConfigString {
    param(
        [object]$Config,
        [string]$Name
    )

    $property = $Config.PSObject.Properties |
        Where-Object { $_.Name -eq $Name } |
        Select-Object -First 1

    if ($null -eq $property -or $null -eq $property.Value) {
        return ""
    }

    return [string]$property.Value
}

function Get-ObjectNumberProperty {
    param(
        [object]$Object,
        [string]$Name,
        [double]$DefaultValue
    )

    if ($null -eq $Object) {
        return $DefaultValue
    }

    $property = $Object.PSObject.Properties |
        Where-Object { $_.Name -eq $Name } |
        Select-Object -First 1

    if ($null -eq $property -or $null -eq $property.Value) {
        return $DefaultValue
    }

    return [double]$property.Value
}

function Read-ExternalOcrText {
    param(
        [object]$Config,
        [string]$ImagePath
    )

    $apiUrl = Get-ConfigString $Config "ocrApiUrl"
    if (-not $apiUrl -or $apiUrl -like "*请填写*") {
        throw "DeepSeek OCR api url is not configured."
    }

    $apiKey = Get-ConfigString $Config "ocrApiKey"
    if (-not $apiKey -or $apiKey -like "*请填写*") {
        $apiKeyEnv = Get-ConfigString $Config "ocrApiKeyEnv"
        if ($apiKeyEnv) {
            $apiKey = [Environment]::GetEnvironmentVariable($apiKeyEnv, "User")
            if (-not $apiKey) {
                $apiKey = [Environment]::GetEnvironmentVariable($apiKeyEnv, "Process")
            }
            if (-not $apiKey) {
                $apiKey = [Environment]::GetEnvironmentVariable($apiKeyEnv, "Machine")
            }
        }
    }

    if (-not $apiKey) {
        throw "DeepSeek OCR api key is not configured."
    }

    $bytes = [System.IO.File]::ReadAllBytes($ImagePath)
    $base64 = [Convert]::ToBase64String($bytes)
    $dataUrl = "data:image/png;base64,$base64"
    $model = Get-ConfigString $Config "ocrModel"
    if (-not $model) {
        $model = "deepseek-ocr"
    }

    $prompt = Get-ConfigString $Config "ocrPrompt"
    if (-not $prompt) {
        $prompt = "请对图片进行OCR识别，只返回图片中的文字，保持原有行顺序，不要解释。"
    }

    $headers = @{
        Authorization = "Bearer $apiKey"
        "Content-Type" = "application/json"
    }

    $body = @{
        model = $model
        messages = @(
            @{
                role = "user"
                content = @(
                    @{
                        type = "text"
                        text = $prompt
                    },
                    @{
                        type = "image_url"
                        image_url = @{
                            url = $dataUrl
                        }
                    }
                )
            }
        )
        temperature = 0
    } | ConvertTo-Json -Depth 12

    $response = Invoke-RestMethod -Method Post -Uri $apiUrl -Headers $headers -Body $body -TimeoutSec 60

    if ($response.choices -and $response.choices.Count -gt 0) {
        $message = $response.choices[0].message
        if ($message.content) {
            return [string]$message.content
        }
    }

    if ($response.text) {
        return [string]$response.text
    }

    if ($response.result) {
        return [string]$response.result
    }

    return ($response | ConvertTo-Json -Depth 10)
}

$script:PaddleOcrProcess = $null
$script:PaddleOcrInput = $null
$script:PaddleOcrOutput = $null
$script:PaddleOcrScriptPath = $null
$script:NextPaddleStartAt = [datetime]::MinValue

function Read-OcrWorkerLine {
    param([System.IO.StreamReader]$Reader, [int]$TimeoutSeconds)
    $read = $Reader.ReadLineAsync()
    if (-not $read.Wait([Math]::Max(100, $TimeoutSeconds * 1000))) {
        throw [System.TimeoutException]::new('OCR worker response timed out.')
    }
    return $read.GetAwaiter().GetResult()
}

function Get-PaddleOcrScriptPath {
    param(
        [object]$Config
    )

    $scriptName = Get-ConfigString $Config "paddleOcrScript"
    if (-not $scriptName) {
        $scriptName = "paddle_ocr_runner.py"
    }

    $scriptPath = Join-Path -Path $PSScriptRoot -ChildPath $scriptName
    if (-not (Test-Path -LiteralPath $scriptPath)) {
        throw "PaddleOCR runner not found: $scriptPath"
    }

    return $scriptPath
}

function Get-PythonExecutable {
    $pythonExe = Get-Command python.exe -ErrorAction SilentlyContinue
    if ($null -ne $pythonExe -and $pythonExe.Source -like "*.exe") {
        return $pythonExe.Source
    }

    $python = Get-Command python -ErrorAction SilentlyContinue
    if ($null -eq $python) {
        throw "python was not found in PATH."
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

function Start-PaddleOcrWorker {
    param(
        [object]$Config
    )

    $scriptPath = Get-PaddleOcrScriptPath $Config

    if ($null -ne $script:PaddleOcrProcess -and -not $script:PaddleOcrProcess.HasExited -and $script:PaddleOcrScriptPath -eq $scriptPath) {
        return
    }

    if ((Get-Date) -lt $script:NextPaddleStartAt) {
        throw [System.InvalidOperationException]::new('PaddleOCR restart is cooling down; use Windows OCR.')
    }
    Stop-PaddleOcrWorker

    $pythonExe = Get-PythonExecutable

    Write-MonitorLog $Config "Starting PaddleOCR worker. First start may take a while."

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $pythonExe
    $psi.Arguments = "`"$scriptPath`" --server"
    $psi.WorkingDirectory = $PSScriptRoot
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $false
    $psi.CreateNoWindow = $true

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $psi
    [void]$process.Start()

    # Own the process before reading its protocol: failure must always clean it up.
    $script:PaddleOcrProcess = $process
    $script:PaddleOcrInput = $process.StandardInput
    $script:PaddleOcrOutput = $process.StandardOutput
    $script:PaddleOcrScriptPath = $scriptPath

    try {
        $readyLine = Read-OcrWorkerLine -Reader $process.StandardOutput -TimeoutSeconds (Get-ConfigInt $Config 'paddleStartupTimeoutSeconds' 300)
        if (-not $readyLine) { throw 'PaddleOCR worker did not return a ready message.' }
        $ready = $readyLine | ConvertFrom-Json
        if (-not $ready.ready) { throw 'PaddleOCR worker rejected startup.' }
        $script:NextPaddleStartAt = [datetime]::MinValue
        Write-MonitorLog $Config "PaddleOCR worker is ready."
    }
    catch {
        $script:NextPaddleStartAt = (Get-Date).AddSeconds([Math]::Max(1, (Get-ConfigInt $Config 'paddleRestartDelaySeconds' 60)))
        Stop-PaddleOcrWorker
        throw
    }
}

function Stop-PaddleOcrWorker {
    try {
        if ($null -ne $script:PaddleOcrProcess -and -not $script:PaddleOcrProcess.HasExited) {
            try { $script:PaddleOcrInput.WriteLine("__quit__"); $script:PaddleOcrInput.Flush() } catch { }
            if (-not $script:PaddleOcrProcess.WaitForExit(300)) {
                $script:PaddleOcrProcess.Kill()
                [void]$script:PaddleOcrProcess.WaitForExit(1500)
            }
        }
    }
    catch {
    }
    finally {
        if ($null -ne $script:PaddleOcrProcess) { $script:PaddleOcrProcess.Dispose() }
        $script:PaddleOcrProcess = $null
        $script:PaddleOcrInput = $null
        $script:PaddleOcrOutput = $null
        $script:PaddleOcrScriptPath = $null
    }
}

function Read-PaddleOcrText {
    param(
        [object]$Config,
        [string]$ImagePath
    )

    Start-PaddleOcrWorker $Config

    if ($null -eq $script:PaddleOcrProcess -or $script:PaddleOcrProcess.HasExited) {
        throw "PaddleOCR worker is not running."
    }

    try {
        $script:PaddleOcrInput.WriteLine($ImagePath)
        $script:PaddleOcrInput.Flush()
        $line = Read-OcrWorkerLine -Reader $script:PaddleOcrOutput -TimeoutSeconds (Get-ConfigInt $Config 'paddleRequestTimeoutSeconds' 90)
    }
    catch {
        $script:NextPaddleStartAt = (Get-Date).AddSeconds([Math]::Max(1, (Get-ConfigInt $Config 'paddleRestartDelaySeconds' 60)))
        Stop-PaddleOcrWorker
        throw
    }

    if (-not $line) {
        Stop-PaddleOcrWorker
        throw "PaddleOCR worker stopped before returning OCR text."
    }

    $response = $line | ConvertFrom-Json
    if (-not $response.ok) {
        throw "PaddleOCR failed: $($response.error)"
    }

    $textB64Property = $response.PSObject.Properties |
        Where-Object { $_.Name -eq "text_b64" } |
        Select-Object -First 1
    if ($null -ne $textB64Property -and -not [string]::IsNullOrEmpty([string]$textB64Property.Value)) {
        return [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String([string]$textB64Property.Value))
    }

    $textProperty = $response.PSObject.Properties |
        Where-Object { $_.Name -eq "text" } |
        Select-Object -First 1
    if ($null -ne $textProperty -and $null -ne $textProperty.Value) {
        return [string]$textProperty.Value
    }

    return ""
}

function Read-PaddleOcrTextOnce {
    param(
        [object]$Config,
        [string]$ImagePath
    )

    $scriptPath = Get-PaddleOcrScriptPath $Config
    $pythonExe = Get-PythonExecutable

    $output = & $pythonExe $scriptPath $ImagePath 2>&1
    $exitCode = $LASTEXITCODE
    $text = ($output | Out-String).Trim()

    if ($exitCode -ne 0) {
        throw "PaddleOCR failed with exit code $exitCode. $text"
    }

    return $text
}

function Read-ConfiguredOcrText {
    param(
        [object]$Config,
        [object]$Engine,
        [string]$ImagePath
    )

    $provider = (Get-ConfigString $Config "ocrProvider").ToLowerInvariant()
    if ($provider -eq "paddle" -or $provider -eq "paddleocr") {
        try {
            return Read-PaddleOcrText $Config $ImagePath
        }
        catch {
            Write-MonitorLog $Config "PaddleOCR failed: $($_.Exception.Message). Falling back to Windows OCR."
        }
    }

    if ($provider -eq "deepseek" -or $provider -eq "api") {
        try {
            return Read-ExternalOcrText $Config $ImagePath
        }
        catch {
            Write-MonitorLog $Config "External OCR failed: $($_.Exception.Message). Falling back to Windows OCR."
        }
    }

    return Read-OcrText $Engine $ImagePath
}

function Find-Keyword {
    param(
        [object]$Config,
        [string]$Text
    )

    $normalizedText = Normalize-Text $Text
    foreach ($keyword in @($Config.keywords)) {
        foreach ($term in (Get-KeywordTerms $Config $keyword)) {
            $normalizedTerm = Normalize-Text $term
            if ($normalizedTerm -and $normalizedText.Contains($normalizedTerm)) {
                return $keyword
            }
        }
    }

    return $null
}

function Test-RequiredContext {
    param(
        [object]$Config,
        [string]$Text
    )

    $property = $Config.PSObject.Properties |
        Where-Object { $_.Name -eq "requiredContextKeywords" } |
        Select-Object -First 1

    if ($null -eq $property -or $null -eq $property.Value) {
        return $true
    }

    $requiredTerms = @($property.Value | Where-Object { $_ })
    if ($requiredTerms.Count -eq 0) {
        return $true
    }

    $normalizedText = Normalize-Text $Text
    foreach ($term in $requiredTerms) {
        $normalizedTerm = Normalize-Text ([string]$term)
        if ($normalizedTerm -and $normalizedText.Contains($normalizedTerm)) {
            return $true
        }
    }

    return $false
}

function Get-KeywordTerms {
    param(
        [object]$Config,
        [string]$Keyword
    )

    $terms = New-Object System.Collections.Generic.List[string]
    $terms.Add($Keyword)

    if ($Config.keywordAliases) {
        $property = $Config.keywordAliases.PSObject.Properties |
            Where-Object { $_.Name -eq $Keyword } |
            Select-Object -First 1

        if ($null -ne $property -and $property.Value) {
            foreach ($alias in @($property.Value)) {
                if ($alias) {
                    $terms.Add([string]$alias)
                }
            }
        }
    }

    return $terms.ToArray()
}

function Count-TermOccurrences {
    param(
        [string]$NormalizedText,
        [string]$NormalizedTerm
    )

    if (-not $NormalizedText -or -not $NormalizedTerm) {
        return 0
    }

    $index = 0
    $count = 0
    while ($true) {
        $foundAt = $NormalizedText.IndexOf($NormalizedTerm, $index, [StringComparison]::Ordinal)
        if ($foundAt -lt 0) {
            break
        }

        $count += 1
        $index = $foundAt + $NormalizedTerm.Length
    }

    return $count
}

function Get-KeywordCounts {
    param(
        [object]$Config,
        [string]$Text
    )

    $counts = @{}
    $lines = @($Text -split "(`r`n|`n|`r)" | Where-Object { $_ -and $_.Trim() })

    foreach ($keyword in @($Config.keywords)) {
        $normalizedTerms = @(
            Get-KeywordTerms $Config $keyword |
                ForEach-Object { Normalize-Text $_ } |
                Where-Object { $_ }
        )

        $lineCount = 0
        foreach ($line in $lines) {
            $normalizedLine = Normalize-Text $line
            foreach ($term in $normalizedTerms) {
                if ($normalizedLine.Contains($term)) {
                    $lineCount += 1
                    break
                }
            }
        }

        $counts[$keyword] = $lineCount
    }

    return $counts
}

function Get-KeywordLineCounts {
    param(
        [object]$Config,
        [string]$Text
    )

    $counts = @{}
    $lines = @($Text -split "(`r`n|`n|`r)" | Where-Object { $_ -and $_.Trim() })

    foreach ($keyword in @($Config.keywords)) {
        $normalizedTerms = @(
            Get-KeywordTerms $Config $keyword |
                ForEach-Object { Normalize-Text $_ } |
                Where-Object { $_ }
        )

        foreach ($line in $lines) {
            $normalizedLine = Normalize-Text $line
            if (-not $normalizedLine) {
                continue
            }

            foreach ($term in $normalizedTerms) {
                if ($normalizedLine.Contains($term)) {
                    $stableLine = Get-StableKeywordLineText $keyword $normalizedLine
                    $key = "$keyword|$stableLine"
                    if (-not $counts.ContainsKey($key)) {
                        $counts[$key] = 0
                    }

                    $counts[$key] = [int]$counts[$key] + 1
                    break
                }
            }
        }
    }

    return $counts
}

function Get-StableKeywordLineText {
    param(
        [string]$Keyword,
        [string]$NormalizedLine
    )

    if (-not $NormalizedLine) {
        return ""
    }

    if ($Keyword -eq "告警抽查邮件") {
        $subjectMatch = [regex]::Match($NormalizedLine, "告警抽查邮件\d{4}年\d{1,2}月\d{1,2}日\d+次")
        if ($subjectMatch.Success) {
            return $subjectMatch.Value
        }
    }

    if ($Keyword -eq "客服电话检查") {
        $subjectMatch = [regex]::Match($NormalizedLine, "(?:客服)?电话(?:检查|检鱼)?\d{4}年\d{1,2}月\d{1,2}日\d+次(?:确认码\d+)?")
        if ($subjectMatch.Success) {
            return $subjectMatch.Value
        }
    }

    $keywordText = Normalize-Text $Keyword
    $keywordIndex = $NormalizedLine.IndexOf($keywordText, [StringComparison]::Ordinal)
    if ($keywordIndex -lt 0) {
        $keywordIndex = 0
    }

    $length = [Math]::Min(80, $NormalizedLine.Length - $keywordIndex)
    return $NormalizedLine.Substring($keywordIndex, $length)
}

function Get-KeywordFromLineKey {
    param([string]$LineKey)

    return ($LineKey -split "\|", 2)[0]
}

function Get-TotalKeywordCount {
    param([hashtable]$Counts)

    $total = 0
    foreach ($value in $Counts.Values) {
        $total += [int]$value
    }

    return $total
}

function Format-KeywordCounts {
    param([hashtable]$Counts)

    $parts = @()
    foreach ($key in $Counts.Keys) {
        $parts += ("{0}={1}" -f $key, $Counts[$key])
    }

    return ($parts -join ", ")
}

function Get-TitleEvent {
    param(
        [object]$Config,
        [string]$Title
    )

    if (-not $Title) {
        return $null
    }

    $match = [regex]::Match($Title, "事件\s*(\d+)")
    if (-not $match.Success) {
        return $null
    }

    $keyword = Find-Keyword $Config $Title
    if (-not $keyword) {
        return $null
    }

    return [pscustomobject]@{
        Id = [int]$match.Groups[1].Value
        Keyword = $keyword
    }
}

function Test-AdbDeviceConnected {
    param([string]$AdbPath)

    $state = (& $AdbPath get-state 2>$null | Select-Object -First 1)
    return ([string]$state).Trim() -eq "device"
}

function Invoke-PhoneCall {
    param(
        [object]$Config,
        [string]$Keyword
    )

    if ($NoCall) {
        Write-MonitorLog $Config "Matched '$Keyword', but -NoCall is enabled."
        return $true
    }

    if ($Config.callCommand) {
        $expanded = $Config.callCommand.
            Replace("{phone}", [string]$Config.phoneNumber).
            Replace("{keyword}", [string]$Keyword)
        Write-MonitorLog $Config "Running custom call command: $expanded"
        Invoke-Expression $expanded
        return $true
    }

    if ($Config.callMode -eq "notification") {
        $outcome = ''
        $message = "检测到监控关键词：{0}`n时间：{1}" -f $Keyword, (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        $sent = Send-MonitorNotification -Config $Config -Title ('监控提醒：' + $Keyword) -Message $message -Outcome ([ref]$outcome) -IsAlarm
        $script:LastNotificationOutcome = $outcome
        Write-MonitorLog $Config ('Notification result: ' + $outcome)
        return $sent
    }

    if ($Config.callMode -eq "adb") {
        if (-not $Config.phoneNumber -or [string]$Config.phoneNumber -like "*请改成*") {
            Write-MonitorLog $Config "Matched '$Keyword', but phoneNumber is not configured."
            return $false
        }

        $adb = Get-Command adb -ErrorAction SilentlyContinue
        if ($null -eq $adb) {
            Write-MonitorLog $Config "Matched '$Keyword', but adb was not found in PATH."
            return $false
        }

        if (-not (Test-AdbDeviceConnected $adb.Source)) {
            Write-MonitorLog $Config "Matched '$Keyword', but no adb device is connected. Will retry later."
            return $false
        }

        Write-MonitorLog $Config "Matched '$Keyword'. Calling $($Config.phoneNumber) through adb."
        & $adb.Source shell am start -a android.intent.action.CALL -d "tel:$($Config.phoneNumber)" | Out-Null
        return ($LASTEXITCODE -eq 0)
    }

    if ($Config.callMode -eq "adb-timer") {
        $adb = Get-Command adb -ErrorAction SilentlyContinue
        if ($null -eq $adb) {
            Write-MonitorLog $Config "Matched '$Keyword', but adb was not found in PATH."
            return $false
        }

        if (-not (Test-AdbDeviceConnected $adb.Source)) {
            Write-MonitorLog $Config "Matched '$Keyword', but no adb device is connected. Will retry later."
            return $false
        }

        $timerSeconds = if ($Config.timerSeconds) { [int]$Config.timerSeconds } else { 1 }
        Write-MonitorLog $Config "Matched '$Keyword'. Starting a $timerSeconds-second phone timer through adb."
        $skipUi = if ($Config.timerSkipUi) { "true" } else { "false" }

        if ($Config.timerForceStopClock -and $Config.timerClockPackages) {
            foreach ($packageName in @($Config.timerClockPackages)) {
                if ($packageName) {
                    & $adb.Source shell am force-stop $packageName 2>$null | Out-Null
                }
            }
        }

        $adbArgs = @(
            "shell",
            "am",
            "start",
            "-a",
            "android.intent.action.SET_TIMER",
            "--ei",
            "android.intent.extra.alarm.LENGTH",
            "$timerSeconds",
            "--ez",
            "android.intent.extra.alarm.SKIP_UI",
            "$skipUi"
        )
        if ($Config.timerStartTap) {
            & $adb.Source @adbArgs | Out-Null
            Start-Sleep -Milliseconds ([int]$Config.timerStartTapDelayMs)

            $sizeOutput = & $adb.Source shell wm size
            $sizeText = ($sizeOutput | Out-String)
            $match = [regex]::Match($sizeText, "(\d+)x(\d+)")
            if ($match.Success) {
                $width = [int]$match.Groups[1].Value
                $height = [int]$match.Groups[2].Value
                $xRatio = if ($Config.timerStartTapXRatio) { [double]$Config.timerStartTapXRatio } else { 0.5 }
                $yRatio = if ($Config.timerStartTapYRatio) { [double]$Config.timerStartTapYRatio } else { 0.82 }
                $x = [int]($width * $xRatio)
                $y = [int]($height * $yRatio)

                Write-MonitorLog $Config "Tapping phone timer start button at $x,$y."
                & $adb.Source shell input tap $x $y | Out-Null
                Start-Sleep -Milliseconds 250
                & $adb.Source shell input keyevent 66 | Out-Null
            }
            else {
                Write-MonitorLog $Config "Could not read phone screen size; sending Enter key instead."
                & $adb.Source shell input keyevent 66 | Out-Null
            }
        }
        else {
            $timerOutput = & $adb.Source @adbArgs 2>&1
            if ($LASTEXITCODE -ne 0) {
                Write-MonitorLog $Config "ADB timer command failed: $($timerOutput | Out-String)"
                return $false
            }
            else {
                Write-MonitorLog $Config "ADB timer command sent."
            }
        }
        return $true
    }

    Write-MonitorLog $Config "Matched '$Keyword', but callMode '$($Config.callMode)' is not supported."
    return $false
}

. (Join-Path $PSScriptRoot 'VerificationCode.ps1')
. (Join-Path $PSScriptRoot 'NotificationTransport.ps1')
. (Join-Path $PSScriptRoot 'VerificationPush.ps1')
. (Join-Path $PSScriptRoot 'VerificationMonitor.ps1')
. (Join-Path $PSScriptRoot 'MimoOCR.ps1')
. (Join-Path $PSScriptRoot 'MailConfirmation.ps1')
. (Join-Path $PSScriptRoot 'FoxmailQueue.ps1')
. (Join-Path $PSScriptRoot 'FoxmailScreen.ps1')

if ($LibraryOnly) { return }
if (-not [System.IO.Path]::IsPathRooted($ConfigPath)) {
    $ConfigPath = Join-Path $PSScriptRoot $ConfigPath
}
$config = Read-Config $ConfigPath

if ($VerificationOnly) {
    if (Get-ConfigBool $config 'foxmailUnreadEnabled' $false) { exit 0 }
    if (Get-ConfigBool $config 'mailConfirmationAutoOpenEnabled' $false) {
        Write-MonitorLog $config 'Automatic mail confirmation mode is enabled; use the main launcher to keep mail identity and type-specific code checks together.'
        exit 0
    }
    Start-VerificationMonitor -Config $config -ParentMonitorId $ParentMonitorId -Once:$Once -NoSend:$NoCall
    exit 0
}

if ($ListWindows) {
    Get-VisibleWindows | Format-Table -AutoSize
    exit 0
}

# A shared file lock identifies the same directory through its D: path or C: junction.
# Keep the legacy named mutex as well, for compatibility with an already-running build.
$instanceLockDirectory = Join-Path $PSScriptRoot '04_资料\运行缓存'
[void][IO.Directory]::CreateDirectory($instanceLockDirectory)
$instanceFileLock = $null
try {
    $instanceFileLock = [IO.File]::Open((Join-Path $instanceLockDirectory 'monitor-single-instance.lock'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
}
catch [IO.IOException] {
    if (($_.Exception.HResult -band 0xffff) -notin @(32,33)) { throw }
    Write-MonitorLog $config 'Mail monitor already running through this directory or a path alias; duplicate start ignored.'
    exit 0
}
$monitorHasher = [Security.Cryptography.SHA256]::Create()
try { $monitorIdentity = [BitConverter]::ToString($monitorHasher.ComputeHash([Text.Encoding]::UTF8.GetBytes($PSScriptRoot.ToLowerInvariant()))).Replace('-', '').Substring(0,24) }
finally { $monitorHasher.Dispose() }
$monitorMutex = [Threading.Mutex]::new($false, ('Local\MailMonitor_' + $monitorIdentity))
$monitorLocked = $false
try { $monitorLocked = $monitorMutex.WaitOne(0) }
catch [Threading.AbandonedMutexException] { $monitorLocked = $true }
if (-not $monitorLocked) {
    Write-MonitorLog $config 'Mail monitor already running; duplicate start ignored.'
    $monitorMutex.Dispose()
    $instanceFileLock.Dispose()
    exit 0
}

if (Get-ConfigBool $config 'foxmailUnreadEnabled' $false) {
    try { Start-FoxmailUnreadMonitor -Config $config -Once:$Once -NoSend:$NoCall }
    finally { $monitorMutex.ReleaseMutex(); $monitorMutex.Dispose(); $instanceFileLock.Dispose() }
    exit 0
}

if (Get-ConfigBool $config 'mailConfirmationAutoOpenEnabled' $false) {
    try { Start-MailConfirmationMonitor -Config $config -Once:$Once -NoSend:$NoCall }
    catch { Write-MonitorLog $config ('Auto mail confirmation failed (' + $_.Exception.GetType().Name + '); stopped without saving message content.'); throw }
    finally { $monitorMutex.ReleaseMutex(); $monitorMutex.Dispose(); $instanceFileLock.Dispose() }
    exit 0
}

$engine = New-OcrEngine $config.ocrLanguage
$lastCallAt = [datetime]::MinValue
$previousKeywordCounts = $null
$previousKeywordLineCounts = $null
$previousKeywordLineTotals = $null
$zeroKeywordLineTotalCycles = 0
$seenKeywordLineKeys = @{}
$lastKeywordLineAttemptAt = @{}
$lastNoNewLogAt = [datetime]::MinValue
$lastNoTargetLogAt = [datetime]::MinValue
$lastTitleEventId = 0
$runtimeDirectory = Join-Path $PSScriptRoot '04_资料\运行缓存'
[void][System.IO.Directory]::CreateDirectory($runtimeDirectory)
$tempImage = Join-Path $runtimeDirectory "window-keyword-monitor-$PID.png"
$verificationWorker = $null
if ((Get-ConfigBool $config 'verificationCodeEnabled' $false) -and -not $Once) {
    $verificationWorker = Start-VerificationWorker -ConfigPath $ConfigPath -ParentMonitorId $PID -NoSend:$NoCall
}

Write-MonitorLog $config "Monitor started. Keywords: $(@($config.keywords) -join ', ')"

try {
while ($true) {
    try {
        $rectangle = Get-TargetRectangle $config -ForegroundOnly
        if ($null -eq $rectangle) {
            $noTargetLogIntervalSeconds = Get-ConfigInt $config "noTargetLogIntervalSeconds" 60
            if (((Get-Date) - $lastNoTargetLogAt).TotalSeconds -ge $noTargetLogIntervalSeconds) {
                Write-MonitorLog $config "No target window found. Keep the Edge remote desktop/Foxmail window visible."
                $lastNoTargetLogAt = Get-Date
            }
            if ($Once) {
                break
            }

            Wait-MonitorInterval $config
            continue
        }

        if ($config.titleEventMode) {
            $titleEvent = Get-TitleEvent $config $rectangle.Title
            if ($null -ne $titleEvent -and $titleEvent.Id -gt $lastTitleEventId) {
                [void](Invoke-PhoneCall $config $titleEvent.Keyword)
                $lastCallAt = Get-Date
                $lastTitleEventId = $titleEvent.Id
                if ($Once) {
                    break
                }
                Wait-MonitorInterval $config
                continue
            }
            elseif ($null -ne $titleEvent -and $titleEvent.Id -gt $lastTitleEventId) {
                $lastTitleEventId = $titleEvent.Id
            }
        }

        if ($config.bringTargetToFront) {
            Bring-TargetToFront $rectangle
        }

        $captureRectangle = Get-CaptureRectangle $config $rectangle
        $ocrScale = if ($config.ocrScale) { [double]$config.ocrScale } else { 1.0 }
        $desktopCapture = $rectangle.Handle -eq [IntPtr]::Zero -and $config.scanFullDesktopWhenNoWindow
        try {
            if (-not $desktopCapture -and -not [Win32WindowTools]::IsCaptureVisible($rectangle.Handle,$captureRectangle.Left,$captureRectangle.Top,$captureRectangle.Width,$captureRectangle.Height)) {
                if ($Once) { break }; Wait-MonitorInterval $config; continue
            }
            $diagnostics = Get-ConfigBool $config 'saveOcrDiagnostics' $false
            $memoryOnly = -not $diagnostics -and (Get-ConfigString $config 'ocrProvider' 'windows') -ieq 'windows'
            if ($memoryOnly) {
                $text = Read-VerificationRectangleText -Engine $engine -Rectangle $captureRectangle -ScaleLimit ([Math]::Max(1.0,$ocrScale)) -WordSeparator ''
            } else { Save-Screenshot $captureRectangle $tempImage $ocrScale }
            if (-not $desktopCapture) {
                $current = Get-TargetRectangle $config -ForegroundOnly
                if ($null -eq $current -or $current.Handle -ne $rectangle.Handle -or $current.Title -cne $rectangle.Title -or
                    $current.Left -ne $rectangle.Left -or $current.Top -ne $rectangle.Top -or $current.Width -ne $rectangle.Width -or $current.Height -ne $rectangle.Height -or
                    -not [Win32WindowTools]::IsCaptureVisible($rectangle.Handle,$captureRectangle.Left,$captureRectangle.Top,$captureRectangle.Width,$captureRectangle.Height)) {
                    if ($Once) { break }; Wait-MonitorInterval $config; continue
                }
            }
            if ($diagnostics -and $config.lastScreenshotFile -and -not (Get-ConfigBool $config 'verificationCodeEnabled' $false)) {
                Copy-Item -LiteralPath $tempImage -Destination (Join-Path -Path $PSScriptRoot -ChildPath $config.lastScreenshotFile) -Force
            }
            if (-not $memoryOnly) { $text = Read-ConfiguredOcrText $config $engine $tempImage }
        } finally { Remove-Item -LiteralPath $tempImage -Force -ErrorAction SilentlyContinue }
        if ($diagnostics -and $config.ocrTextFile) {
            Set-Content -LiteralPath (Join-Path -Path $PSScriptRoot -ChildPath $config.ocrTextFile) -Value (Protect-VerificationText $text) -Encoding UTF8
        }

        if (-not (Test-RequiredContext $config $text)) {
            $noNewLogIntervalSeconds = Get-ConfigInt $config "noNewLogIntervalSeconds" 60
            if (((Get-Date) - $lastNoNewLogAt).TotalSeconds -ge $noNewLogIntervalSeconds) {
                Write-MonitorLog $config "Required monitor context not found in '$($rectangle.Title)'; skipping OCR text."
                $lastNoNewLogAt = Get-Date
            }

            if ($Once) {
                break
            }

            Wait-MonitorInterval $config
            continue
        }

        $triggerMode = if ($config.triggerMode) { [string]$config.triggerMode } else { "cooldown" }

        if ($triggerMode -eq "new-occurrence") {
            if ($config.ocrLineMode) {
                $currentLineCounts = Get-KeywordLineCounts $config $text
                $currentKeywordLineTotals = Get-KeywordCounts $config $text

                if ($null -eq $previousKeywordLineCounts) {
                    $previousKeywordLineCounts = $currentLineCounts
                    $previousKeywordLineTotals = $currentKeywordLineTotals
                    $seenKeywordLineKeys = @{}
                    foreach ($lineKey in $currentLineCounts.Keys) {
                        $seenKeywordLineKeys[$lineKey] = $true
                    }
                    $lineTotal = Get-TotalKeywordCount $currentLineCounts
                    Write-MonitorLog $config "Baseline OCR matched lines in '$($rectangle.Title)': $lineTotal."
                    if ($config.ringExistingOnStart -and $lineTotal -gt 0) {
                        foreach ($lineKey in $currentLineCounts.Keys) {
                            $keywordName = Get-KeywordFromLineKey $lineKey
                            for ($i = 0; $i -lt [int]$currentLineCounts[$lineKey]; $i++) {
                                [void](Invoke-PhoneCall $config $keywordName)
                                $lastCallAt = Get-Date
                                if ([int]$config.repeatGapSeconds -gt 0) {
                                    Start-Sleep -Seconds ([int]$config.repeatGapSeconds)
                                }
                            }
                        }
                    }
                    if ($Once) {
                        break
                    }
                    Wait-MonitorInterval $config
                    continue
                }

                $newLineOccurrences = 0
                $pendingLineOccurrences = 0
                $retryFailedTriggerSeconds = Get-ConfigInt $config "retryFailedTriggerSeconds" 120
                $zeroResetCyclesRequired = Get-ConfigInt $config "zeroResetCycles" 5
                $lineTotal = Get-TotalKeywordCount $currentKeywordLineTotals

                if ($lineTotal -eq 0) {
                    $zeroKeywordLineTotalCycles += 1
                }
                else {
                    $zeroKeywordLineTotalCycles = 0
                }

                if ($null -eq $previousKeywordLineTotals) {
                    $previousKeywordLineTotals = @{}
                }

                $updatedKeywordLineTotals = @{}
                foreach ($keywordName in @($config.keywords)) {
                    $previousKeywordTotal = 0
                    if ($previousKeywordLineTotals.ContainsKey($keywordName)) {
                        $previousKeywordTotal = [int]$previousKeywordLineTotals[$keywordName]
                    }

                    $currentKeywordTotal = 0
                    if ($currentKeywordLineTotals.ContainsKey($keywordName)) {
                        $currentKeywordTotal = [int]$currentKeywordLineTotals[$keywordName]
                    }

                    if ($lineTotal -eq 0 -and $zeroKeywordLineTotalCycles -ge $zeroResetCyclesRequired) {
                        $updatedKeywordLineTotals[$keywordName] = 0
                        continue
                    }

                    $updatedKeywordLineTotals[$keywordName] = $previousKeywordTotal
                    $addedLineCount = $currentKeywordTotal - $previousKeywordTotal
                    if ($addedLineCount -le 0) {
                        continue
                    }

                    $attemptKey = "keyword|$keywordName"
                    $now = Get-Date
                    if ($lastKeywordLineAttemptAt.ContainsKey($attemptKey)) {
                        $secondsSinceAttempt = ($now - [datetime]$lastKeywordLineAttemptAt[$attemptKey]).TotalSeconds
                        if ($secondsSinceAttempt -lt $retryFailedTriggerSeconds) {
                            $pendingLineOccurrences += 1
                            continue
                        }
                    }

                    $lastKeywordLineAttemptAt[$attemptKey] = $now
                    for ($i = 0; $i -lt $addedLineCount; $i++) {
                        $script:LastNotificationOutcome = ''
                        $callSucceeded = Invoke-PhoneCall $config $keywordName
                        if ($callSucceeded) {
                            $updatedKeywordLineTotals[$keywordName] = [int]$updatedKeywordLineTotals[$keywordName] + 1
                            $newLineOccurrences += 1
                            $lastCallAt = Get-Date
                            if ([int]$config.repeatGapSeconds -gt 0 -and $i -lt ($addedLineCount - 1)) {
                                Start-Sleep -Seconds ([int]$config.repeatGapSeconds)
                            }
                        }
                        elseif ($script:LastNotificationOutcome -eq 'Uncertain') {
                            # The service may already have accepted it. Consume only
                            # this occurrence, without reporting it as delivered.
                            $updatedKeywordLineTotals[$keywordName] = [int]$updatedKeywordLineTotals[$keywordName] + 1
                            Write-MonitorLog $config 'Alert delivery is unconfirmed; automatic resend suppressed for this occurrence.'
                        }
                        else {
                            $pendingLineOccurrences += 1
                        }
                    }
                }

                if ($newLineOccurrences -eq 0) {
                    $noNewLogIntervalSeconds = Get-ConfigInt $config "noNewLogIntervalSeconds" 60
                    if (((Get-Date) - $lastNoNewLogAt).TotalSeconds -ge $noNewLogIntervalSeconds) {
                        if ($pendingLineOccurrences -gt 0) {
                            Write-MonitorLog $config "No delivered new OCR matched line in '$($rectangle.Title)'. Current matched lines: $lineTotal. Pending retry: $pendingLineOccurrences."
                        }
                        else {
                            Write-MonitorLog $config "No new OCR matched line in '$($rectangle.Title)'. Current matched lines: $lineTotal."
                        }

                        $lastNoNewLogAt = Get-Date
                    }
                }
                elseif ($pendingLineOccurrences -gt 0) {
                    Write-MonitorLog $config "Triggered $newLineOccurrences new OCR matched line(s); $pendingLineOccurrences pending retry."
                }

                $previousKeywordLineCounts = $currentLineCounts
                $previousKeywordLineTotals = $updatedKeywordLineTotals
                if ($Once) {
                    break
                }
                Wait-MonitorInterval $config
                continue
            }

            $currentCounts = Get-KeywordCounts $config $text

            if ($null -eq $previousKeywordCounts) {
                $previousKeywordCounts = $currentCounts
                $initialCount = Get-TotalKeywordCount $currentCounts

                if ($config.ringExistingOnStart -and $initialCount -gt 0) {
                    foreach ($keywordName in @($config.keywords)) {
                        for ($i = 0; $i -lt [int]$currentCounts[$keywordName]; $i++) {
                            [void](Invoke-PhoneCall $config $keywordName)
                            $lastCallAt = Get-Date
                            if ([int]$config.repeatGapSeconds -gt 0) {
                                Start-Sleep -Seconds ([int]$config.repeatGapSeconds)
                            }
                        }
                    }
                }
                else {
                    Write-MonitorLog $config "Baseline keyword count in '$($rectangle.Title)': $initialCount. Counts: $(Format-KeywordCounts $currentCounts)."
                }
            }
            else {
                $newOccurrences = 0
                foreach ($keywordName in @($config.keywords)) {
                    $previousCount = 0
                    if ($previousKeywordCounts.ContainsKey($keywordName)) {
                        $previousCount = [int]$previousKeywordCounts[$keywordName]
                    }

                    $currentCount = [int]$currentCounts[$keywordName]
                    $addedCount = $currentCount - $previousCount
                    if ($addedCount -gt 0) {
                        $newOccurrences += $addedCount
                        for ($i = 0; $i -lt $addedCount; $i++) {
                            [void](Invoke-PhoneCall $config $keywordName)
                            $lastCallAt = Get-Date
                            if ([int]$config.repeatGapSeconds -gt 0) {
                                Start-Sleep -Seconds ([int]$config.repeatGapSeconds)
                            }
                        }
                    }
                }

                if ($newOccurrences -eq 0) {
                    $currentTotal = Get-TotalKeywordCount $currentCounts
                    Write-MonitorLog $config "No new keyword occurrence in '$($rectangle.Title)'. Current count: $currentTotal. Counts: $(Format-KeywordCounts $currentCounts)."
                }

                $previousKeywordCounts = $currentCounts
            }
        }
        else {
            $keyword = Find-Keyword $config $text

            if ($keyword) {
                $secondsSinceLastCall = ((Get-Date) - $lastCallAt).TotalSeconds
                if ($secondsSinceLastCall -ge [int]$config.cooldownSeconds) {
                    [void](Invoke-PhoneCall $config $keyword)
                    $lastCallAt = Get-Date
                }
                else {
                    Write-MonitorLog $config "Matched '$keyword' in '$($rectangle.Title)', still in cooldown."
                }
            }
            else {
                Write-MonitorLog $config "No keyword found in '$($rectangle.Title)'."
            }
        }
    }
    catch {
        Write-MonitorLog $config "Error: $($_.Exception.Message)"
    }

    if ($Once) {
        break
    }

    Wait-MonitorInterval $config
}
}
finally {
    Stop-PaddleOcrWorker
    if ($null -ne $verificationWorker -and -not $verificationWorker.HasExited) {
        $verificationWorker.Kill()
    }
    Remove-Item -LiteralPath $tempImage -Force -ErrorAction SilentlyContinue
    if ($monitorLocked) { $monitorMutex.ReleaseMutex() }
    $monitorMutex.Dispose()
    if ($null -ne $instanceFileLock) { $instanceFileLock.Dispose() }
}
