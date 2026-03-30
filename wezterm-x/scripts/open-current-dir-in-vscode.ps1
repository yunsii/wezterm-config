param(
  [Parameter(Mandatory = $true)]
  [string]$RequestedDir,

  [Parameter(Mandatory = $true)]
  [string]$Distro,

  [string[]]$CodeArg = @()
)

function Resolve-PrimaryWorktreeDir {
  param(
    [string]$Directory,
    [string]$Distribution
  )

  if ([string]::IsNullOrWhiteSpace($Directory)) {
    return $Directory
  }

  try {
    $commonDir = & wsl.exe --distribution $Distribution --cd $Directory git rev-parse --path-format=absolute --git-common-dir 2>$null
    if ($LASTEXITCODE -ne 0) {
      return $Directory
    }

    $commonDir = (($commonDir | Out-String).Trim())
    if ([string]::IsNullOrWhiteSpace($commonDir)) {
      return $Directory
    }

    $mainRoot = Split-Path -Parent $commonDir
    if ([string]::IsNullOrWhiteSpace($mainRoot)) {
      return $Directory
    }

    return $mainRoot
  } catch {
    return $Directory
  }
}

function Convert-ToVscodeRemotePath {
  param(
    [string]$Path
  )

  if ([string]::IsNullOrWhiteSpace($Path)) {
    return ""
  }

  $normalized = $Path -replace '\\', '/'
  $segments = $normalized -split '/'
  $encodedSegments = foreach ($segment in $segments) {
    [Uri]::EscapeDataString($segment)
  }

  return ($encodedSegments -join '/')
}

if ($CodeArg.Count -eq 0) {
  $CodeArg = @('code')
}

$targetDir = Resolve-PrimaryWorktreeDir -Directory $RequestedDir -Distribution $Distro
$folderUri = "vscode-remote://wsl+$([Uri]::EscapeDataString($Distro))$(Convert-ToVscodeRemotePath -Path $targetDir)"
$codeExecutable = $CodeArg[0]
$codeArguments = @()

if ($CodeArg.Count -gt 1) {
  $codeArguments = $CodeArg[1..($CodeArg.Count - 1)]
}

Start-Process -FilePath $codeExecutable -ArgumentList @($codeArguments + @('--folder-uri', $folderUri))
