param(
  [Parameter(Mandatory = $true)]
  [string]$WslDistro,

  [string]$OutputDir = "$env:LOCALAPPDATA\wezterm-clipboard-images"
)

function Convert-WindowsPathToWsl {
  param(
    [Parameter(Mandatory = $true)]
    [string]$WindowsPath,

    [string]$Distribution
  )

  if (-not [string]::IsNullOrWhiteSpace($Distribution)) {
    try {
      $converted = & wsl.exe --distribution $Distribution wslpath -a -u $WindowsPath 2>$null
      if ($LASTEXITCODE -eq 0) {
        $converted = (($converted | Out-String).Trim())
        if (-not [string]::IsNullOrWhiteSpace($converted)) {
          return $converted
        }
      }
    } catch {
    }
  }

  $normalized = $WindowsPath -replace '\\', '/'
  if ($normalized -match '^([A-Za-z]):/(.*)$') {
    $drive = $Matches[1].ToLowerInvariant()
    $remainder = $Matches[2]
    if ([string]::IsNullOrWhiteSpace($remainder)) {
      return "/mnt/$drive"
    }

    return "/mnt/$drive/$remainder"
  }

  return $normalized
}

try {
  Add-Type -AssemblyName System.Runtime.WindowsRuntime
  Add-Type -AssemblyName System.Windows.Forms
  Add-Type -AssemblyName System.Drawing

  $null = [Windows.ApplicationModel.DataTransfer.Clipboard,Windows.ApplicationModel.DataTransfer,ContentType=WindowsRuntime]
  $null = [Windows.ApplicationModel.DataTransfer.StandardDataFormats,Windows.ApplicationModel.DataTransfer,ContentType=WindowsRuntime]
  $content = [Windows.ApplicationModel.DataTransfer.Clipboard]::GetContent()

  if (-not $content.Contains([Windows.ApplicationModel.DataTransfer.StandardDataFormats]::Bitmap)) {
    Write-Output "NO_IMAGE"
    exit 0
  }

  if ([string]::IsNullOrWhiteSpace($OutputDir)) {
    $OutputDir = "$env:LOCALAPPDATA\wezterm-clipboard-images"
  }

  $null = New-Item -ItemType Directory -Force -Path $OutputDir

  $image = [Windows.Forms.Clipboard]::GetImage()
  if (-not $image) {
    Write-Output "NO_IMAGE"
    exit 0
  }

  $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
  $fileName = "clipboard-$timestamp-$([guid]::NewGuid().ToString('N').Substring(0, 8)).png"
  $windowsPath = Join-Path $OutputDir $fileName
  $image.Save($windowsPath, [System.Drawing.Imaging.ImageFormat]::Png)

  Write-Output (Convert-WindowsPathToWsl -WindowsPath $windowsPath -Distribution $WslDistro)
} catch {
  Write-Error $_
  exit 1
}
