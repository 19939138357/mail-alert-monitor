# Fast verification-code OCR runs independently from the heavier mail alert OCR.
function Read-VerificationRectangleText {
    param($Engine, $Rectangle, [System.Drawing.Bitmap]$InputBitmap, [switch]$AsLayout, [double]$ScaleLimit = 2.0, [string]$WordSeparator = ' ')
    [void][Windows.Storage.Streams.InMemoryRandomAccessStream, Windows.Storage.Streams, ContentType = WindowsRuntime]
    [void][Windows.Storage.Streams.DataWriter, Windows.Storage.Streams, ContentType = WindowsRuntime]
    $bitmap = if ($null -ne $InputBitmap) { [System.Drawing.Bitmap]$InputBitmap.Clone() } else { [System.Drawing.Bitmap]::new($Rectangle.Width, $Rectangle.Height) }
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $memory = [System.IO.MemoryStream]::new()
    $stream = [Windows.Storage.Streams.InMemoryRandomAccessStream]::new()
    $scaled = $null
    $scaledGraphics = $null
    $writer = $null
    $software = $null
    try {
        if ($null -eq $InputBitmap) { $graphics.CopyFromScreen($Rectangle.Left, $Rectangle.Top, 0, 0, $bitmap.Size) }
        $limit = [Windows.Media.Ocr.OcrEngine]::MaxImageDimension
        $scale = [Math]::Min($ScaleLimit, $limit / [double][Math]::Max($bitmap.Width, $bitmap.Height))
        $scaled = [System.Drawing.Bitmap]::new([int]($bitmap.Width * $scale), [int]($bitmap.Height * $scale))
        $scaledGraphics = [System.Drawing.Graphics]::FromImage($scaled)
        $scaledGraphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $scaledGraphics.DrawImage($bitmap, 0, 0, $scaled.Width, $scaled.Height)
        $scaled.Save($memory, [System.Drawing.Imaging.ImageFormat]::Png)
        $writer = [Windows.Storage.Streams.DataWriter]::new($stream)
        $writer.WriteBytes($memory.ToArray())
        [void](Wait-WinRtOperation ($writer.StoreAsync()) ([uint32]))
        [void]$writer.DetachStream()
        $stream.Seek(0)
        $decoder = Wait-WinRtOperation ([Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($stream)) ([Windows.Graphics.Imaging.BitmapDecoder])
        $software = Wait-WinRtOperation ($decoder.GetSoftwareBitmapAsync()) ([Windows.Graphics.Imaging.SoftwareBitmap])
        $result = Wait-WinRtOperation ($Engine.RecognizeAsync($software)) ([Windows.Media.Ocr.OcrResult])
        if ($AsLayout) {
            $lines = @(foreach ($line in $result.Lines) {
                $words = @($line.Words)
                if ($words.Count -eq 0) { continue }
                $left = ($words | ForEach-Object { $_.BoundingRect.X } | Measure-Object -Minimum).Minimum / $scale
                $top = ($words | ForEach-Object { $_.BoundingRect.Y } | Measure-Object -Minimum).Minimum / $scale
                $right = ($words | ForEach-Object { $_.BoundingRect.X + $_.BoundingRect.Width } | Measure-Object -Maximum).Maximum / $scale
                $bottom = ($words | ForEach-Object { $_.BoundingRect.Y + $_.BoundingRect.Height } | Measure-Object -Maximum).Maximum / $scale
                [pscustomobject]@{ Text = ($words | ForEach-Object Text) -join ' '; Left = $left; Top = $top; Width = $right - $left; Height = $bottom - $top }
            })
            return [pscustomobject]@{ Text = ($lines | ForEach-Object Text) -join "`n"; Lines = $lines; Width = $bitmap.Width; Height = $bitmap.Height }
        }
        # Preserve word boundaries: joining every token would mix codes with English labels.
        return (($result.Lines | ForEach-Object { ($_.Words | ForEach-Object { $_.Text }) -join $WordSeparator }) -join "`n")
    }
    finally {
        if ($null -ne $software -and $software -is [IDisposable]) { $software.Dispose() }
        if ($null -ne $writer -and $writer -is [IDisposable]) { $writer.Dispose() }
        if ($stream -is [IDisposable]) { $stream.Dispose() }
        if ($null -ne $scaledGraphics) { $scaledGraphics.Dispose() }
        if ($null -ne $scaled) { $scaled.Dispose() }
        $memory.Dispose()
        $graphics.Dispose()
        $bitmap.Dispose()
    }
}

function Start-VerificationWorker {
    param([string]$ConfigPath, [int]$ParentMonitorId, [switch]$NoSend)
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $monitorPath = Join-Path $PSScriptRoot 'Monitor-WindowKeywords.ps1'
    $psi.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -ConfigPath "{1}" -VerificationOnly -ParentMonitorId {2}' -f $monitorPath, $ConfigPath, $ParentMonitorId
    if ($NoSend) { $psi.Arguments += ' -NoCall' }
    $psi.WorkingDirectory = $PSScriptRoot
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    return [System.Diagnostics.Process]::Start($psi)
}

function Start-VerificationMonitor {
    param($Config, [int]$ParentMonitorId = 0, [switch]$Once, [switch]$NoSend)
    if (-not (Get-ConfigBool $Config 'verificationCodeEnabled' $false)) { return }
    # A process-wide lock prevents a manual start and the alert worker from double-pushing.
    $hasher = [System.Security.Cryptography.SHA256]::Create()
    try { $identity = [BitConverter]::ToString($hasher.ComputeHash([Text.Encoding]::UTF8.GetBytes($PSScriptRoot.ToLowerInvariant()))).Replace('-', '').Substring(0, 24) }
    finally { $hasher.Dispose() }
    $mutex = [System.Threading.Mutex]::new($false, ('Local\VerificationMonitor_' + $identity))
    $locked = $false
    try {
        try { $locked = $mutex.WaitOne(0) }
        catch [System.Threading.AbandonedMutexException] { $locked = $true }
        if (-not $locked) { Write-MonitorLog $Config 'Verification monitor already running; duplicate start ignored.'; return }
        $parent = $null
        $parentStarted = $null
        if ($ParentMonitorId -gt 0) {
            $parent = Get-Process -Id $ParentMonitorId -ErrorAction SilentlyContinue
            if ($null -eq $parent) { return }
            $parentStarted = $parent.StartTime
        }
        $engine = New-OcrEngine (Get-ConfigString $Config 'ocrLanguage' 'zh-Hans-CN')
        $state = New-VerificationPushState
        $lastStatus = [datetime]::MinValue
        Write-MonitorLog $Config 'Verification monitor ready: independent Windows OCR, two-frame confirmation, email/DingTalk delivery.'
        do {
            if ($ParentMonitorId -gt 0) {
                $parent = Get-Process -Id $ParentMonitorId -ErrorAction SilentlyContinue
                if ($null -eq $parent -or $parent.StartTime -ne $parentStarted) { break }
            }
            try {
                # Use an isolated clone so verification cropping never changes the alert ROI.
                $scanConfig = $Config | ConvertTo-Json -Depth 16 | ConvertFrom-Json
                $scanConfig | Add-Member -NotePropertyName 'scanFullDesktopWhenNoWindow' -NotePropertyValue $false -Force
                $scanConfig | Add-Member -NotePropertyName 'processNameContains' -NotePropertyValue '' -Force
                $crop = $Config.PSObject.Properties['verificationCaptureCrop']
                $verificationCrop = if ($null -ne $crop) { $crop.Value } else { $null }
                $scanConfig | Add-Member -NotePropertyName 'captureCrop' -NotePropertyValue $verificationCrop -Force
                $rectangle = Get-TargetRectangle $scanConfig -ForegroundOnly
                if ($null -eq $rectangle -or [Win32WindowTools]::GetForegroundWindow() -ne $rectangle.Handle) {
                    # Missing/obscured target breaks consecutive-frame confirmation.
                    Reset-VerificationScanContinuity -State $state
                    if (((Get-Date) - $lastStatus).TotalSeconds -ge 60) {
                        Write-MonitorLog $Config 'Verification scan waiting: keep the configured remote window in the foreground with the code visible.'
                        $lastStatus = Get-Date
                    }
                }
                else {
                    $roi = Get-CaptureRectangle $scanConfig $rectangle
                    $text = Read-VerificationRectangleText -Engine $engine -Rectangle $roi
                    if ($ParentMonitorId -gt 0) {
                        $parent = Get-Process -Id $ParentMonitorId -ErrorAction SilentlyContinue
                        if ($null -eq $parent -or $parent.StartTime -ne $parentStarted) { $text = $null; break }
                    }
                    if ([Win32WindowTools]::GetForegroundWindow() -ne $rectangle.Handle) {
                        Reset-VerificationScanContinuity -State $state
                    }
                    else { [void](Invoke-VerificationCodeScan -Config $Config -State $state -Text $text -NoSend:$NoSend) }
                    $text = $null
                    if (((Get-Date) - $lastStatus).TotalSeconds -ge 60) {
                        Write-MonitorLog $Config 'Verification scan active; target visible. Code text and images are not saved.'
                        $lastStatus = Get-Date
                    }
                }
            }
            catch {
                Reset-VerificationScanContinuity -State $state
                if (((Get-Date) - $lastStatus).TotalSeconds -ge 60) {
                    Write-MonitorLog $Config ('Verification scan failed (' + $_.Exception.GetType().Name + '); verify Windows OCR language pack and target visibility.')
                    $lastStatus = Get-Date
                }
            }
            if ($Once) { break }
            Start-Sleep -Milliseconds ([Math]::Max(500, (Get-ConfigInt $Config 'verificationScanIntervalMs' 1000)))
        } while ($true)
    }
    finally {
        if ($locked) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}
