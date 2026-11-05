$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$source=Get-Content -LiteralPath (Join-Path $root 'Configure-BrowserAlert.ps1') -Raw -Encoding UTF8
$source=$source.Replace('$token=Get-BrowserPairingToken', '$token=(''0''*64)')
$source=$source.Replace(". (Join-Path `$PSScriptRoot 'BrowserAlertSupport.ps1')", '')
$source=$source.Replace('[void]$form.ShowDialog();$form.Dispose()', 'return $form')
$form=& ([scriptblock]::Create($source)) -NoStart
$checks=0
try {
    if($form.Controls.Count -ne 9){throw 'Unexpected control count'};$checks++
    foreach($control in $form.Controls){
        if($control.Right -gt $form.ClientSize.Width -or $control.Bottom -gt $form.ClientSize.Height){throw 'Control overflows form'}
        $checks++
    }
    $form.ShowInTaskbar=$false; $form.Opacity=0
    $form.Show(); [Windows.Forms.Application]::DoEvents()
    $bitmap=New-Object Drawing.Bitmap($form.Width,$form.Height)
    try {
        $form.DrawToBitmap($bitmap,(New-Object Drawing.Rectangle(0,0,$form.Width,$form.Height)))
        $output=Join-Path $root '04_资料/夜间告警升级_20260907/网页设置界面.png'
        $bitmap.Save($output,[Drawing.Imaging.ImageFormat]::Png)
    }finally{$bitmap.Dispose()}
    Write-Output "PASS: $checks browser setup UI checks; hidden form rendered without copying credentials or starting processes"
}finally{$form.Dispose()}
