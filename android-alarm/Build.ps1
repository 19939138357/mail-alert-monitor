param([string]$SdkRoot = '', [string]$JdkHome = '', [string]$OutputPath = '', [switch]$SkipTests)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$taskRoot = [System.IO.Path]::GetFullPath($PSScriptRoot)
if ([string]::IsNullOrWhiteSpace($SdkRoot)) { $SdkRoot = [Environment]::GetEnvironmentVariable('ANDROID_SDK_ROOT') }
if ([string]::IsNullOrWhiteSpace($SdkRoot)) { $SdkRoot = [Environment]::GetEnvironmentVariable('ANDROID_HOME') }
if ([string]::IsNullOrWhiteSpace($SdkRoot)) { throw 'Pass -SdkRoot or set ANDROID_SDK_ROOT / ANDROID_HOME. No SDK downloads are performed.' }
$taskSdk = [IO.Path]::GetFullPath($SdkRoot)
$taskBuildTools = Join-Path $taskSdk 'build-tools\35.0.0'
$taskAndroidJar = Join-Path $taskSdk 'platforms\android-35\android.jar'
if ([string]::IsNullOrWhiteSpace($JdkHome)) { $JdkHome = [Environment]::GetEnvironmentVariable('JAVA_HOME') }
if ([string]::IsNullOrWhiteSpace($JdkHome)) {
    $taskCompiler = (Get-Command javac.exe -ErrorAction Stop).Source
    $JdkHome = Split-Path (Split-Path $taskCompiler -Parent) -Parent
}
$JdkHome = [IO.Path]::GetFullPath($JdkHome)
$taskJava = Join-Path $JdkHome 'bin\java.exe'
$taskJavac = Join-Path $JdkHome 'bin\javac.exe'
$taskKeytool = Join-Path $JdkHome 'bin\keytool.exe'
$taskJar = Join-Path $JdkHome 'bin\jar.exe'
foreach ($taskRequired in @($taskJava, $taskJavac, $taskKeytool, $taskJar, $taskAndroidJar, (Join-Path $taskBuildTools 'aapt.exe'), (Join-Path $taskBuildTools 'lib\d8.jar'), (Join-Path $taskBuildTools 'lib\apksigner.jar'))) {
    if (-not (Test-Path -LiteralPath $taskRequired -PathType Leaf)) { throw ('Missing local build dependency: ' + $taskRequired) }
}
$taskRun = Join-Path $taskRoot ('build\run-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
$taskRunRelative = 'build/' + (Split-Path $taskRun -Leaf)
foreach ($taskSub in @('', 'gen', 'classes', 'dex', 'tests', 'temp')) { New-Item -ItemType Directory -Path (Join-Path $taskRun $taskSub) -Force | Out-Null }
$taskTempOption = '-Djava.io.tmpdir=' + (Join-Path $taskRun 'temp')
function Invoke-LocalBuildTool {
    param([string]$Executable, [string[]]$ToolArguments)
    if ([IO.Path]::GetFileName($Executable) -eq 'java.exe') { $ToolArguments = @('-Duser.language=en', '-Duser.country=US') + $ToolArguments }
    if ([IO.Path]::GetFileName($Executable) -in @('javac.exe', 'keytool.exe', 'jar.exe')) { $ToolArguments = @('-J-Duser.language=en', '-J-Duser.country=US', ('-J' + $taskTempOption)) + $ToolArguments }
    $taskOldErrorAction = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        & $Executable @ToolArguments 2>&1 | ForEach-Object { $_.ToString() }
        $taskExitCode = $LASTEXITCODE
    } finally { $ErrorActionPreference = $taskOldErrorAction }
    if ($taskExitCode -ne 0) { throw ('Local build tool failed with exit code ' + $taskExitCode + ': ' + [IO.Path]::GetFileName($Executable)) }
}

# Generate the bundled two-tone PCM alarm locally; no media download is needed.
$taskRaw = Join-Path $taskRoot 'res\raw'
New-Item -ItemType Directory -Path $taskRaw -Force | Out-Null
$taskWave = Join-Path $taskRaw 'night_alarm.wav'
if (-not (Test-Path -LiteralPath $taskWave)) {
    $taskRate = 16000; $taskSamples = $taskRate * 2; $taskDataLength = $taskSamples * 2
    $taskWaveStream = [IO.File]::Create($taskWave)
    $taskWriter = [IO.BinaryWriter]::new($taskWaveStream)
    try {
        $taskWriter.Write([Text.Encoding]::ASCII.GetBytes('RIFF')); $taskWriter.Write([int](36 + $taskDataLength)); $taskWriter.Write([Text.Encoding]::ASCII.GetBytes('WAVEfmt '))
        $taskWriter.Write([int]16); $taskWriter.Write([int16]1); $taskWriter.Write([int16]1); $taskWriter.Write([int]$taskRate); $taskWriter.Write([int]($taskRate * 2)); $taskWriter.Write([int16]2); $taskWriter.Write([int16]16)
        $taskWriter.Write([Text.Encoding]::ASCII.GetBytes('data')); $taskWriter.Write([int]$taskDataLength)
        for ($taskIndex = 0; $taskIndex -lt $taskSamples; $taskIndex++) {
            $taskSegment = [int][Math]::Floor($taskIndex / ($taskRate / 2))
            $taskFrequency = if (($taskSegment % 2) -eq 0) { 660.0 } else { 880.0 }
            $taskWithin = ($taskIndex % ($taskRate / 2)) / ($taskRate / 2)
            $taskEnvelope = [Math]::Min(1.0, [Math]::Min($taskWithin * 25.0, (1.0 - $taskWithin) * 25.0))
            $taskWriter.Write([int16](15000 * $taskEnvelope * [Math]::Sin(2 * [Math]::PI * $taskFrequency * $taskIndex / $taskRate)))
        }
    } finally { $taskWriter.Dispose(); $taskWaveStream.Dispose() }
}

if (-not $SkipTests) {
    Invoke-LocalBuildTool $taskJavac @('-encoding', 'UTF-8', '--release', '8', '-Xlint:-options', '-d', (Join-Path $taskRun 'tests'), (Join-Path $taskRoot 'src\org\example\mailalertalarm\AlertPolicy.java'), (Join-Path $taskRoot 'src\org\example\mailalertalarm\AlarmPlaybackState.java'), (Join-Path $taskRoot 'tests\AlertPolicyTest.java'), (Join-Path $taskRoot 'tests\AlarmPlaybackStateTest.java'))
    Invoke-LocalBuildTool $taskJava @($taskTempOption, '-cp', (Join-Path $taskRun 'tests'), 'org.example.mailalertalarm.AlertPolicyTest')
    Invoke-LocalBuildTool $taskJava @($taskTempOption, '-cp', (Join-Path $taskRun 'tests'), 'org.example.mailalertalarm.AlarmPlaybackStateTest')
    & (Join-Path $taskRoot 'tests\Test-Static.ps1')
}
$taskResourceApk = Join-Path $taskRun 'resources.apk'
Push-Location -LiteralPath $taskRoot
try {
    # Native aapt on Windows mishandles non-ASCII absolute arguments; use ASCII
    # relative paths while all files remain inside this existing project.
    Invoke-LocalBuildTool (Join-Path $taskBuildTools 'aapt.exe') @('package', '-f', '-M', 'AndroidManifest.xml', '-S', 'res', '-I', $taskAndroidJar, '-J', ($taskRunRelative + '/gen'), '-F', ($taskRunRelative + '/resources.apk'), '--min-sdk-version', '26', '--target-sdk-version', '35')
} finally { Pop-Location }
$taskSources = @(Get-ChildItem -LiteralPath (Join-Path $taskRoot 'src'), (Join-Path $taskRun 'gen') -Recurse -Filter '*.java' -File | ForEach-Object { $_.FullName })
$taskSourceArgs = Join-Path $taskRun 'sources.args'
[IO.File]::WriteAllLines($taskSourceArgs, @($taskSources | ForEach-Object { '"' + $_.Replace('\', '/') + '"' }), [Text.UTF8Encoding]::new($false))
Invoke-LocalBuildTool $taskJavac @('-encoding', 'UTF-8', '--release', '8', '-Xlint:-options', '-classpath', $taskAndroidJar, '-d', (Join-Path $taskRun 'classes'), ('@' + $taskSourceArgs))
$taskClassesJar = Join-Path $taskRun 'classes.jar'
Invoke-LocalBuildTool $taskJar @('--create', '--file', $taskClassesJar, '-C', (Join-Path $taskRun 'classes'), '.')
Invoke-LocalBuildTool $taskJava @($taskTempOption, '-cp', (Join-Path $taskBuildTools 'lib\d8.jar'), 'com.android.tools.r8.D8', '--lib', $taskAndroidJar, '--min-api', '26', '--output', (Join-Path $taskRun 'dex'), $taskClassesJar)

Add-Type -AssemblyName System.IO.Compression.FileSystem
Add-Type -AssemblyName System.IO.Compression
$taskUnaligned = Join-Path $taskRun 'unaligned.apk'
Copy-Item -LiteralPath $taskResourceApk -Destination $taskUnaligned
$taskZip = [IO.Compression.ZipFile]::Open($taskUnaligned, [IO.Compression.ZipArchiveMode]::Update)
try { [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($taskZip, (Join-Path $taskRun 'dex\classes.dex'), 'classes.dex', [IO.Compression.CompressionLevel]::Optimal) | Out-Null } finally { $taskZip.Dispose() }
$taskAligned = Join-Path $taskRun 'aligned.apk'
Push-Location -LiteralPath $taskRoot
try { Invoke-LocalBuildTool (Join-Path $taskBuildTools 'zipalign.exe') @('-f', '4', ($taskRunRelative + '/unaligned.apk'), ($taskRunRelative + '/aligned.apk')) } finally { Pop-Location }
$taskSigning = Join-Path $taskRoot 'signing'
New-Item -ItemType Directory -Path $taskSigning -Force | Out-Null
$taskKeystore = Join-Path $taskSigning 'local-debug.keystore'
if (-not (Test-Path -LiteralPath $taskKeystore)) {
    Invoke-LocalBuildTool $taskKeytool @('-genkeypair', '-alias', 'local-debug', '-keyalg', 'RSA', '-keysize', '2048', '-validity', '3650', '-keystore', $taskKeystore, '-storepass', 'android', '-keypass', 'android', '-dname', 'CN=Local Notification Alarm Test,O=Local Development,C=CN', '-noprompt')
}
$taskApk = Join-Path $taskRun 'notification-alarm.apk'
Invoke-LocalBuildTool $taskJava @($taskTempOption, '-jar', (Join-Path $taskBuildTools 'lib\apksigner.jar'), 'sign', '--ks', $taskKeystore, '--ks-key-alias', 'local-debug', '--ks-pass', 'pass:android', '--key-pass', 'pass:android', '--out', $taskApk, $taskAligned)
Invoke-LocalBuildTool $taskJava @('-jar', (Join-Path $taskBuildTools 'lib\apksigner.jar'), 'verify', '--verbose', $taskApk)
Push-Location -LiteralPath $taskRoot
try { Invoke-LocalBuildTool (Join-Path $taskBuildTools 'zipalign.exe') @('-c', '4', ($taskRunRelative + '/notification-alarm.apk')) } finally { Pop-Location }
$taskDelivery = if ($OutputPath) { [IO.Path]::GetFullPath($OutputPath) } else { Join-Path $taskRoot 'dist\notification-alarm.apk' }
New-Item -ItemType Directory -Path (Split-Path $taskDelivery -Parent) -Force | Out-Null
Copy-Item -LiteralPath $taskApk -Destination $taskDelivery -Force
Push-Location -LiteralPath $taskRoot
try { $taskBadging = & (Join-Path $taskBuildTools 'aapt.exe') dump badging ($taskRunRelative + '/notification-alarm.apk') } finally { Pop-Location }
$taskBadging | Set-Content -LiteralPath (Join-Path $taskRun 'apk-badging.txt') -Encoding UTF8
$taskResult = [ordered]@{ package = 'org.example.mailalertalarm'; version = '1.1.0'; minSdk = 26; targetSdk = 35; apk = $taskDelivery; sha256 = (Get-FileHash -LiteralPath $taskDelivery -Algorithm SHA256).Hash; bytes = (Get-Item -LiteralPath $taskDelivery).Length; buildDirectory = $taskRun; realDeviceTested = $false; networkUsed = $false }
$taskResult | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $taskRun 'build-result.json') -Encoding UTF8
$taskResult | ConvertTo-Json
