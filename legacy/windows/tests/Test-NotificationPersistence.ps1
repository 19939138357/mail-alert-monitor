# Real local persistence with synthetic credentials. No network or live configuration.
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'NotificationTransport.ps1')
$script:PersistenceChecks = 0
function Assert-Persistence { param([bool]$Condition,[string]$Label) if(-not $Condition){throw ('FAIL: '+$Label)};$script:PersistenceChecks++ }
function Assert-PersistenceRejected { param([scriptblock]$Action,[string]$Label) $failed=$false;try{[void](& $Action)}catch{$failed=$true};Assert-Persistence $failed $Label }
$fixture = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot ('notification-fixture-' + [guid]::NewGuid().ToString('N'))))
[void][IO.Directory]::CreateDirectory($fixture)
$script:FixtureSettings = Join-Path $fixture 'settings.json'
$script:FixtureSecrets = Join-Path $fixture 'secrets.xml'
$script:FixtureConfig = @{ notificationSettingsFile=$script:FixtureSettings;notificationSecretsFile=$script:FixtureSecrets }
$settings = @{provider='qqmail';smtpHost='smtp.qq.com';smtpPort=587;smtpFrom='first@example.invalid';smtpTo='recipient@example.invalid'}
$secrets = @{smtpPassword=(ConvertTo-SecureString 'SYNTHETIC_PASSWORD_NEVER_SEND' -AsPlainText -Force)}
$script:OriginalAtomicFile = ${function:Set-NotificationAtomicFile}
$script:AtomicFailure = ''
$script:ObserveCommit = $false
$script:ObservedSender = ''
function Set-NotificationAtomicFile {
    param([string]$StagedPath,[string]$DestinationPath)
    if(($script:AtomicFailure -eq 'secret' -and $DestinationPath -eq $script:FixtureSecrets) -or
       ($script:AtomicFailure -eq 'mirror' -and $DestinationPath -eq $script:FixtureSettings)){throw 'Synthetic replacement failure.'}
    & $script:OriginalAtomicFile -StagedPath $StagedPath -DestinationPath $DestinationPath
    if($script:ObserveCommit -and $DestinationPath -eq $script:FixtureSecrets){
        $observed=Read-NotificationConfiguration $script:FixtureConfig
        $script:ObservedSender=[string](Get-NotificationValue $observed.Settings 'smtpFrom')
    }
}
try {
    $missingVersion=Get-NotificationConfigurationVersion $script:FixtureConfig
    Assert-Persistence ($missingVersion -cmatch '^[0-9A-F]{64}$') 'configuration version exposes only a hash'
    Assert-Persistence ($missingVersion -ceq (Get-NotificationConfigurationVersion $script:FixtureConfig)) 'unchanged missing configuration has stable version'
    $commit=Save-NotificationConfiguration -Settings $settings -Secrets $secrets -SettingsPath $script:FixtureSettings -SecretsPath $script:FixtureSecrets -ExpectedRevision 'missing'
    $loaded=Read-NotificationConfiguration $script:FixtureConfig
    Assert-Persistence ($loaded.Settings.smtpFrom -eq 'first@example.invalid' -and $loaded.Revision -eq $commit.Revision) 'full snapshot can be read from custom paths'
    Assert-Persistence ($loaded.Secrets.smtpPassword -is [Security.SecureString]) 'DPAPI roundtrip retains SecureString'
    Assert-Persistence ((ConvertFrom-NotificationSecureValue $loaded.Secrets.smtpPassword) -ceq 'SYNTHETIC_PASSWORD_NEVER_SEND') 'DPAPI roundtrip preserves synthetic authorization'
    Assert-Persistence (-not ([IO.File]::ReadAllText($script:FixtureSecrets).Contains('SYNTHETIC_PASSWORD_NEVER_SEND'))) 'encrypted file has no plaintext authorization'
    Assert-Persistence (-not ([IO.File]::ReadAllText($script:FixtureSettings).Contains('smtpPassword'))) 'public mirror has no credential fields'
    $version=Get-NotificationConfigurationVersion $script:FixtureConfig
    Assert-Persistence ($version -cne $missingVersion) 'creating configuration updates observed version'
    Assert-Persistence ($version -ceq (Get-NotificationConfigurationVersion $script:FixtureConfig)) 'unchanged saved configuration has stable version'

    $settings.smtpFrom='second@example.invalid'
    $settings.nightAlarmEnabled=$true
    $script:ObserveCommit=$true
    $newCommit=Save-NotificationConfiguration -Settings $settings -Secrets $secrets -SettingsPath $script:FixtureSettings -SecretsPath $script:FixtureSecrets -ExpectedRevision $commit.Revision
    $script:ObserveCommit=$false
    Assert-Persistence ($script:ObservedSender -eq 'second@example.invalid') 'reader between XML and mirror replacement sees complete new snapshot'
    Assert-Persistence ($newCommit.Revision -ne $commit.Revision) 'successful save changes revision'
    Assert-Persistence (Test-NotificationNightAlarmEnabled (Read-NotificationConfiguration $script:FixtureConfig).Settings) 'night alarm opt-in survives atomic encrypted snapshot roundtrip'
    Assert-Persistence ((Get-NotificationConfigurationVersion $script:FixtureConfig) -cne $version) 'atomic save updates configuration metadata version'
    Assert-PersistenceRejected {Save-NotificationConfiguration -Settings $settings -Secrets $secrets -SettingsPath $script:FixtureSettings -SecretsPath $script:FixtureSecrets -ExpectedRevision $commit.Revision} 'stale second settings window cannot overwrite a newer save'

    $beforeXml=[IO.File]::ReadAllText($script:FixtureSecrets)
    $beforeJson=[IO.File]::ReadAllText($script:FixtureSettings)
    $script:AtomicFailure='secret'
    $settings.smtpFrom='should-not-save@example.invalid'
    Assert-PersistenceRejected {Save-NotificationConfiguration -Settings $settings -Secrets $secrets -SettingsPath $script:FixtureSettings -SecretsPath $script:FixtureSecrets -ExpectedRevision $newCommit.Revision} 'canonical commit failure reports failure'
    Assert-Persistence ([IO.File]::ReadAllText($script:FixtureSecrets) -ceq $beforeXml -and [IO.File]::ReadAllText($script:FixtureSettings) -ceq $beforeJson) 'failed canonical commit leaves both previous files intact'
    Assert-Persistence ((Read-NotificationConfiguration $script:FixtureConfig).Settings.smtpFrom -eq 'second@example.invalid') 'failed commit preserves previous working sender'

    $script:AtomicFailure='mirror'
    $settings.smtpFrom='third@example.invalid'
    $mirrorCommit=Save-NotificationConfiguration -Settings $settings -Secrets $secrets -SettingsPath $script:FixtureSettings -SecretsPath $script:FixtureSecrets -ExpectedRevision $newCommit.Revision
    Assert-Persistence (-not $mirrorCommit.MirrorUpdated) 'mirror error is explicitly reported after canonical commit'
    Assert-Persistence ((Read-NotificationConfiguration $script:FixtureConfig).Settings.smtpFrom -eq 'third@example.invalid') 'mirror failure cannot produce mixed sender and credential state'
    $script:AtomicFailure=''
    [IO.File]::WriteAllText($script:FixtureSettings,'{invalid json')
    Assert-Persistence ((Read-NotificationConfiguration $script:FixtureConfig).Settings.smtpFrom -eq 'third@example.invalid') 'damaged public mirror does not interrupt notification sending'
    [IO.File]::Delete($script:FixtureSettings)
    Assert-Persistence ((Read-NotificationConfiguration $script:FixtureConfig).Settings.smtpFrom -eq 'third@example.invalid') 'missing public mirror does not interrupt notification sending'
    Assert-Persistence (@([IO.Directory]::GetFiles($fixture,'*.tmp')).Count -eq 0) 'success and failure clean every staged secret file'

    # The original two-file format remains readable until the first atomic GUI save.
    $secrets | Export-Clixml -LiteralPath $script:FixtureSecrets
    $settings | ConvertTo-Json | Set-Content -LiteralPath $script:FixtureSettings -Encoding UTF8
    $legacy=Read-NotificationConfiguration $script:FixtureConfig
    Assert-Persistence ($legacy.Revision -eq 'legacy' -and $legacy.Settings.smtpFrom -eq 'third@example.invalid') 'legacy separate files remain compatible'
    $migrated=Save-NotificationConfiguration -Settings $settings -Secrets $secrets -SettingsPath $script:FixtureSettings -SecretsPath $script:FixtureSecrets -ExpectedRevision $legacy.Revision
    Assert-Persistence ((Read-NotificationConfiguration $script:FixtureConfig).Revision -eq $migrated.Revision) 'legacy settings upgrade on save'
    Assert-PersistenceRejected {Save-NotificationConfiguration -Settings $settings -Secrets $secrets -SettingsPath $script:FixtureSecrets -SecretsPath $script:FixtureSecrets} 'configuration cannot overwrite its own credential file'
}
finally {
    # Verify the exact resolved test fixture stays under tests before recursive cleanup.
    $testsRoot=[IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\')+'\'
    if(-not $fixture.StartsWith($testsRoot,[StringComparison]::OrdinalIgnoreCase)){throw 'Unexpected fixture cleanup target.'}
    Remove-Item -LiteralPath $fixture -Recurse -Force
}
Write-Host ('PASS: {0} persistence checks; synthetic local encrypted files only; no network.' -f $script:PersistenceChecks)
