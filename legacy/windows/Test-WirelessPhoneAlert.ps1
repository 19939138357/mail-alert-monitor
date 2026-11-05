param(
    [switch]$NoPause
)

$ErrorActionPreference = "Stop"

try {
    [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
    [Console]::InputEncoding = [System.Text.UTF8Encoding]::new($false)
    $OutputEncoding = [System.Text.UTF8Encoding]::new($false)
}
catch {
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

function Get-ConfigInt {
    param(
        [object]$Config,
        [string]$Name,
        [int]$DefaultValue = 0
    )

    $property = $Config.PSObject.Properties |
        Where-Object { $_.Name -eq $Name } |
        Select-Object -First 1

    if ($null -eq $property -or $null -eq $property.Value) {
        return $DefaultValue
    }

    try {
        return [int]$property.Value
    }
    catch {
        return $DefaultValue
    }
}

$configPath = Join-Path -Path $PSScriptRoot -ChildPath "monitor_config.json"
if (-not (Test-Path -LiteralPath $configPath)) {
    throw "Cannot find monitor_config.json. Put this file in the monitor folder."
}

$config = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
$server = (Get-ConfigString $config "ntfyServer" "https://ntfy.sh").TrimEnd("/")
$topic = Get-ConfigString $config "ntfyTopic" ""
$priority = Get-ConfigString $config "ntfyPriority" "urgent"
$delaySeconds = Get-ConfigInt $config "ntfyDelaySeconds" 0

if ([string]::IsNullOrWhiteSpace($topic)) {
    throw "monitor_config.json does not contain ntfyTopic."
}

$uri = "{0}/{1}" -f $server, [uri]::EscapeDataString($topic)
$message = "Wireless phone alert test`nTime: {0}`nIf the phone receives this notification, monitor alerts will work too." -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
$headers = @{
    "Title" = "Mail monitor alert - test - $(Get-Date -Format 'HH:mm:ss')"
    "Priority" = $priority
    "Tags" = "warning"
}

if ($delaySeconds -gt 0) {
    $headers["Delay"] = "{0}s" -f $delaySeconds
}

if (Get-ConfigBool $config "ntfyInsistent" $false) {
    $headers["Insistent"] = "yes"
}

$token = Get-ConfigString $config "ntfyToken" ""
if (-not [string]::IsNullOrWhiteSpace($token)) {
    $headers["Authorization"] = "Bearer $token"
}

try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $body = [System.Text.Encoding]::UTF8.GetBytes($message)
    Invoke-RestMethod -Method Post -Uri $uri -Headers $headers -Body $body -ContentType "text/plain; charset=utf-8" | Out-Null
    if ($delaySeconds -gt 0) {
        Write-Host "Wireless push scheduled after $delaySeconds seconds."
    }
    else {
        Write-Host "Wireless push sent."
    }
    Write-Host "Topic: $topic"
    Write-Host "If the phone did not ring, check ntfy subscription, notification sound, and battery settings."
}
catch {
    Write-Host "Wireless push failed: $($_.Exception.Message)"
}

if (-not $NoPause) {
    Read-Host "Press Enter to exit"
}
