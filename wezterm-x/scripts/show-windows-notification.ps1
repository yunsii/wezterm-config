param(
  [string]$Title = 'WezTerm',
  [string]$Message = '',
  [int]$TimeoutMs = 5000
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$notifyIcon = New-Object System.Windows.Forms.NotifyIcon
try {
  $notifyIcon.Icon = [System.Drawing.SystemIcons]::Warning
  $notifyIcon.Visible = $true
  $notifyIcon.BalloonTipTitle = $Title
  $notifyIcon.BalloonTipText = $Message
  $notifyIcon.ShowBalloonTip([Math]::Max($TimeoutMs, 1000))
  Start-Sleep -Milliseconds ([Math]::Min([Math]::Max($TimeoutMs, 1000), 6000))
} finally {
  $notifyIcon.Dispose()
}
