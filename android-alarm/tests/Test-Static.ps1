Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$taskRoot = Split-Path $PSScriptRoot -Parent
[xml]$taskManifest = Get-Content -LiteralPath (Join-Path $taskRoot 'AndroidManifest.xml') -Raw -Encoding UTF8
$taskNamespace = 'http://schemas.android.com/apk/res/android'
$taskChecks = 0
function Assert-Static { param([bool]$Condition, [string]$Name) if (-not $Condition) { throw ('FAILED static check: ' + $Name) }; $script:taskChecks++ }
Assert-Static ($taskManifest.manifest.package -ceq 'org.example.mailalertalarm') 'unique package'
$taskPermissions = @($taskManifest.manifest.'uses-permission' | ForEach-Object { $_.GetAttribute('name', $taskNamespace) })
Assert-Static (-not ($taskPermissions -contains 'android.permission.INTERNET')) 'no Internet permission'
Assert-Static (-not ($taskPermissions -contains 'android.permission.READ_SMS')) 'no SMS access'
Assert-Static ($taskPermissions -contains 'android.permission.FOREGROUND_SERVICE_SPECIAL_USE') 'special-use permission'
Assert-Static ($taskPermissions -contains 'android.permission.FOREGROUND_SERVICE_MEDIA_PLAYBACK') 'media playback permission'
Assert-Static ($taskPermissions -contains 'android.permission.POST_NOTIFICATIONS') 'runtime notification declaration'
Assert-Static ($taskManifest.manifest.application.GetAttribute('allowBackup', $taskNamespace) -eq 'false') 'no private-state backups'
$taskService = @($taskManifest.manifest.application.service | Where-Object { $_.GetAttribute('name', $taskNamespace) -eq '.AlarmService' })[0]
Assert-Static ($taskService.GetAttribute('foregroundServiceType', $taskNamespace) -eq 'specialUse|mediaPlayback') 'explicit foreground types'
Assert-Static ($taskService.property.GetAttribute('name', $taskNamespace) -eq 'android.app.PROPERTY_SPECIAL_USE_FGS_SUBTYPE') 'special-use explanation property'
$taskListener = @($taskManifest.manifest.application.service | Where-Object { $_.GetAttribute('name', $taskNamespace) -eq '.AlertListener' })[0]
Assert-Static ($taskListener.GetAttribute('permission', $taskNamespace) -eq 'android.permission.BIND_NOTIFICATION_LISTENER_SERVICE') 'system-protected notification listener'
$taskSourceFiles = @(Get-ChildItem -LiteralPath (Join-Path $taskRoot 'src') -Recurse -Filter '*.java' -File)
$taskAllSource = ($taskSourceFiles | ForEach-Object { [IO.File]::ReadAllText($_.FullName) }) -join "`n"
Assert-Static ($taskAllSource -notmatch 'java\.net|HttpURLConnection|Socket\(|android\.util\.Log|System\.out') 'no networking or body logging in application code'
Assert-Static ($taskAllSource -notmatch '(?i)ntfy') 'no old notification channel dependency'
$taskListenerSource = [IO.File]::ReadAllText((Join-Path $taskRoot 'src\org\example\mailalertalarm\AlertListener.java'))
Assert-Static ($taskListenerSource -notmatch 'startForegroundService|startService|startActivity') 'listener never starts a background service or activity'
foreach ($taskExtra in @('EXTRA_TITLE', 'EXTRA_TEXT', 'EXTRA_BIG_TEXT', 'EXTRA_TEXT_LINES')) { Assert-Static ($taskListenerSource.Contains($taskExtra)) ('reads notification ' + $taskExtra) }
$taskServiceSource = [IO.File]::ReadAllText((Join-Path $taskRoot 'src\org\example\mailalertalarm\AlarmService.java'))
Assert-Static ($taskServiceSource.Contains('setLooping(true)')) 'alarm audio loops'
Assert-Static ($taskServiceSource.Contains('USAGE_ALARM')) 'uses alarm audio stream'
Assert-Static (-not $taskServiceSource.Contains('setStreamVolume')) 'does not change system volume'
Assert-Static ($taskServiceSource.Contains('canUseFullScreenIntent') -or $taskServiceSource.Contains('LocalState.fullScreen')) 'checks full screen access'
Assert-Static ($taskServiceSource.Contains('handler.removeCallbacks(keepAwake)') -and $taskServiceSource.Contains('vibrator.cancel()') -and $taskServiceSource.Contains('wakeLock.release()')) 'acknowledgement releases alarm resources'
Assert-Static ($taskServiceSource.Contains('setAcceptsDelayedFocusGain(true)')) 'allows delayed audio focus'
Assert-Static ($taskServiceSource.Contains('handler.removeCallbacks(audioRetry)') -and $taskServiceSource.Contains('playback.stop()')) 'stop cancels retry and delayed focus state'
Assert-Static ($taskServiceSource.Contains('playback.mayRequest(android.os.SystemClock.elapsedRealtime())')) 'focus retry uses monotonic bounded interval'
Assert-Static ($taskServiceSource.Contains('if (player == null)') -and $taskServiceSource.Contains('playFocusedAudio()')) 'delayed gain can initialize missing player'
Write-Output "PASS: $script:taskChecks Android static checks; these do not replace device validation."
