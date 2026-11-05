param([string]$OutputPath = '')
$ErrorActionPreference = 'Stop'
$source = Join-Path $PSScriptRoot 'AlertSpotCheckDesktop.cs'
$login = Join-Path $PSScriptRoot 'EdgeSystemLogin.cs'
$library = Join-Path $PSScriptRoot 'AntdUI.dll'
$icon = Join-Path $PSScriptRoot 'assets\screen-alert.ico'
$theme = Join-Path $PSScriptRoot 'DesktopTheme.cs'
$output = if ($OutputPath) { [IO.Path]::GetFullPath($OutputPath) } else { Join-Path $PSScriptRoot 'AlertSpotCheckDesktop.exe' }
$compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path -LiteralPath $compiler)) {
    $compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe'
}
if (-not (Test-Path -LiteralPath $compiler)) {
    throw 'System C# compiler was not found.'
}

& $compiler /nologo /target:winexe /platform:anycpu /optimize+ /codepage:65001 /utf8output `
    "/out:$output" "/win32icon:$icon" "/reference:$library" /reference:System.Windows.Forms.dll /reference:System.Drawing.dll /reference:System.Management.dll /reference:System.Web.Extensions.dll /reference:System.Security.dll $source $theme $login
if ($LASTEXITCODE -ne 0) {
    throw "Compilation failed with exit code $LASTEXITCODE."
}
if ((Split-Path $output) -ne $PSScriptRoot) { Copy-Item -LiteralPath $library -Destination (Join-Path (Split-Path $output) "AntdUI.dll") -Force }
Write-Output "Built $output"
