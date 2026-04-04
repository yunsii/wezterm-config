param(
  [Parameter(Mandatory = $true)]
  [string]$RequestedDir,

  [Parameter(Mandatory = $true)]
  [string]$Distro,

  [string[]]$CodeArg = @()
)

function Normalize-WslPath {
  param(
    [string]$Path
  )

  if ([string]::IsNullOrWhiteSpace($Path)) {
    return ""
  }

  $normalized = ($Path -replace '\\', '/').Trim()
  if ([string]::IsNullOrWhiteSpace($normalized)) {
    return ""
  }

  if ($normalized.Length -gt 1) {
    $normalized = $normalized.TrimEnd('/')
  }

  if ([string]::IsNullOrWhiteSpace($normalized)) {
    return "/"
  }

  return $normalized
}

function Get-WslParentPath {
  param(
    [string]$Path
  )

  $normalized = Normalize-WslPath -Path $Path
  if ([string]::IsNullOrWhiteSpace($normalized) -or $normalized -eq "/") {
    return $null
  }

  $lastSlash = $normalized.LastIndexOf('/')
  if ($lastSlash -le 0) {
    return "/"
  }

  return $normalized.Substring(0, $lastSlash)
}

function Convert-ToWslUncPath {
  param(
    [string]$Path,
    [string]$Distribution
  )

  $normalized = Normalize-WslPath -Path $Path
  if ([string]::IsNullOrWhiteSpace($normalized) -or -not $normalized.StartsWith('/')) {
    return $null
  }

  $uncRoot = '\\wsl$\{0}' -f $Distribution
  $relative = $normalized.TrimStart('/') -replace '/', '\'
  if ([string]::IsNullOrWhiteSpace($relative)) {
    return "$uncRoot\"
  }

  return '{0}\{1}' -f $uncRoot, $relative
}

function Resolve-WorktreeRootFromUnc {
  param(
    [string]$Directory,
    [string]$Distribution
  )

  $currentPath = Normalize-WslPath -Path $Directory
  if ([string]::IsNullOrWhiteSpace($currentPath) -or -not $currentPath.StartsWith('/')) {
    return $null
  }

  while ($true) {
    $uncPath = Convert-ToWslUncPath -Path $currentPath -Distribution $Distribution
    if (-not [string]::IsNullOrWhiteSpace($uncPath)) {
      $dotGitPath = Join-Path $uncPath '.git'
      if (Test-Path -LiteralPath $dotGitPath) {
        return $currentPath
      }
    }

    if ($currentPath -eq "/") {
      break
    }

    $currentPath = Get-WslParentPath -Path $currentPath
    if ([string]::IsNullOrWhiteSpace($currentPath)) {
      break
    }
  }

  return $null
}

function Resolve-WorktreeRoot {
  param(
    [string]$Directory,
    [string]$Distribution
  )

  $normalizedDirectory = Normalize-WslPath -Path $Directory
  if ([string]::IsNullOrWhiteSpace($normalizedDirectory)) {
    return $Directory
  }

  $fastPathRoot = Resolve-WorktreeRootFromUnc -Directory $normalizedDirectory -Distribution $Distribution
  if (-not [string]::IsNullOrWhiteSpace($fastPathRoot)) {
    return $fastPathRoot
  }

  try {
    $repoRoot = & wsl.exe --distribution $Distribution --cd $normalizedDirectory git rev-parse --path-format=absolute --show-toplevel 2>$null
    if ($LASTEXITCODE -ne 0) {
      return $normalizedDirectory
    }

    $repoRoot = Normalize-WslPath -Path (($repoRoot | Out-String).Trim())
    if ([string]::IsNullOrWhiteSpace($repoRoot)) {
      return $normalizedDirectory
    }

    return $repoRoot
  } catch {
    return $normalizedDirectory
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

$targetDir = Resolve-WorktreeRoot -Directory $RequestedDir -Distribution $Distro
$folderUri = "vscode-remote://wsl+$([Uri]::EscapeDataString($Distro))$(Convert-ToVscodeRemotePath -Path $targetDir)"
$codeExecutable = $CodeArg[0]
$codeArguments = @()

if ($CodeArg.Count -gt 1) {
  $codeArguments = $CodeArg[1..($CodeArg.Count - 1)]
}

Start-Process -FilePath $codeExecutable -ArgumentList @($codeArguments + @('--folder-uri', $folderUri))
