param(
  [string]$RuntimeDir = '',

  [string]$InstallRoot = "$env:LOCALAPPDATA\wezterm-runtime\bin",

  [ValidateSet('auto', 'local', 'release')]
  [string]$InstallSource = 'auto',

  [string]$Trigger = 'runtime_sync',

  [string]$DiagnosticsEnabled = '1',

  [string]$DiagnosticsCategoryEnabled = '1',

  [string]$DiagnosticsLevel = 'info',

  [string]$DiagnosticsFile = "$env:LOCALAPPDATA\wezterm-runtime\logs\helper.log",

  [int]$DiagnosticsMaxBytes = 5242880,

  [int]$DiagnosticsMaxFiles = 5
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'windows-structured-log.ps1')
Initialize-StructuredLog `
  -FilePath $DiagnosticsFile `
  -Enabled $DiagnosticsEnabled `
  -CategoryEnabled $DiagnosticsCategoryEnabled `
  -Level $DiagnosticsLevel `
  -Source 'windows-helper-installer' `
  -TraceId '' `
  -MaxBytes $DiagnosticsMaxBytes `
  -MaxFiles $DiagnosticsMaxFiles

function Get-ProjectPaths {
  param(
    [string]$RuntimeRoot
  )

  if ([string]::IsNullOrWhiteSpace($RuntimeRoot)) {
    $RuntimeRoot = Split-Path -Parent $PSScriptRoot
  }

  $projectRoot = Join-Path (Split-Path -Parent $RuntimeRoot) '.wezterm-native\host-helper\windows\src'
  $nativeRoot = Split-Path -Parent $projectRoot
  return @{
    Manager = Join-Path $projectRoot 'HelperManager\WezTerm.WindowsHostHelper.csproj'
    Client = Join-Path $projectRoot 'HelperCtl\HelperCtl.csproj'
    ReleaseManifest = Join-Path $nativeRoot 'release-manifest.json'
  }
}

function Get-DotnetPath {
  $command = Get-Command dotnet -ErrorAction SilentlyContinue
  if ($command) {
    return $command.Source
  }

  $default = 'C:\Program Files\dotnet\dotnet.exe'
  if (Test-Path -LiteralPath $default) {
    return $default
  }

  return $null
}

function Stop-InstalledHelperManagerProcesses {
  param(
    [string]$BinaryPath
  )

  $processName = [System.IO.Path]::GetFileNameWithoutExtension($BinaryPath)
  $stoppedProcessIds = @()
  foreach ($process in @(Get-Process -Name $processName -ErrorAction SilentlyContinue)) {
    try {
      Stop-Process -Id $process.Id -Force -ErrorAction Stop
      $stoppedProcessIds += [string]$process.Id
    } catch {
    } finally {
      $process.Dispose()
    }
  }

  return $stoppedProcessIds
}

function Get-InstallStatePath {
  param(
    [string]$ResolvedInstallRoot
  )

  return Join-Path $ResolvedInstallRoot 'helper-install-state.json'
}

function Read-JsonFile {
  param(
    [string]$Path
  )

  if (-not (Test-Path -LiteralPath $Path)) {
    return $null
  }

  $content = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
  if ([string]::IsNullOrWhiteSpace($content)) {
    return $null
  }

  return $content | ConvertFrom-Json -ErrorAction Stop
}

function Read-InstallState {
  param(
    [string]$ResolvedInstallRoot
  )

  $statePath = Get-InstallStatePath -ResolvedInstallRoot $ResolvedInstallRoot
  return Read-JsonFile -Path $statePath
}

function Write-InstallState {
  param(
    [string]$ResolvedInstallRoot,
    [hashtable]$State
  )

  $statePath = Get-InstallStatePath -ResolvedInstallRoot $ResolvedInstallRoot
  $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
  $json = ($State | ConvertTo-Json -Depth 5)
  [System.IO.File]::WriteAllText($statePath, $json, $utf8NoBom)
}

function Read-ReleaseManifest {
  param(
    [string]$ManifestPath
  )

  $manifest = Read-JsonFile -Path $ManifestPath
  if ($null -eq $manifest) {
    return $null
  }

  if ($manifest.schemaVersion -ne 1) {
    throw "unsupported helper release manifest schema: $($manifest.schemaVersion)"
  }

  return $manifest
}

function Get-ReleaseAssetName {
  param(
    [pscustomobject]$Manifest
  )

  if (-not [string]::IsNullOrWhiteSpace([string]$Manifest.assetName)) {
    return [string]$Manifest.assetName
  }

  if ([string]::IsNullOrWhiteSpace([string]$Manifest.downloadUrl)) {
    return ''
  }

  try {
    $uri = [System.Uri]::new([string]$Manifest.downloadUrl)
    return [System.IO.Path]::GetFileName($uri.AbsolutePath)
  } catch {
    return ''
  }
}

function Resolve-InstallSource {
  param(
    [string]$RequestedSource,
    [string]$DotnetPath,
    [pscustomobject]$ReleaseManifest
  )

  switch ($RequestedSource) {
    'local' {
      if ([string]::IsNullOrWhiteSpace($DotnetPath)) {
        throw 'dotnet SDK is not installed on Windows'
      }
      return 'local'
    }
    'release' {
      if ($null -eq $ReleaseManifest -or $ReleaseManifest.enabled -ne $true) {
        throw 'release fallback is not configured in native/host-helper/windows/release-manifest.json'
      }
      return 'release'
    }
    default {
      if (-not [string]::IsNullOrWhiteSpace($DotnetPath)) {
        return 'local'
      }
      if ($null -ne $ReleaseManifest -and $ReleaseManifest.enabled -eq $true) {
        return 'release'
      }
      throw 'dotnet SDK is not installed on Windows and no host-helper release package is configured'
    }
  }
}

function Test-ReleaseInstallCurrent {
  param(
    [string]$ResolvedInstallRoot,
    [pscustomobject]$Manifest
  )

  $state = Read-InstallState -ResolvedInstallRoot $ResolvedInstallRoot
  if ($null -eq $state) {
    return $false
  }

  $managerPath = Join-Path $ResolvedInstallRoot 'helper-manager.exe'
  $clientPath = Join-Path $ResolvedInstallRoot 'helperctl.exe'
  if (-not (Test-Path -LiteralPath $managerPath) -or -not (Test-Path -LiteralPath $clientPath)) {
    return $false
  }

  return (
    [string]$state.source -eq 'release' -and
    [string]$state.version -eq [string]$Manifest.version -and
    [string]$state.sha256 -eq ([string]$Manifest.sha256).ToLowerInvariant()
  )
}

function Get-ReleaseDownloadCacheRoot {
  return Join-Path $env:LOCALAPPDATA 'wezterm-runtime\cache\downloads'
}

function Get-ReleasePreloadRoot {
  return Join-Path $env:LOCALAPPDATA 'wezterm-runtime\artifacts\host-helper'
}

function Get-FileSha256 {
  param(
    [string]$Path
  )

  return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path -ErrorAction Stop).Hash.ToLowerInvariant()
}

function Invoke-ReleaseDownloadWithCurl {
  param(
    [string]$Url,
    [string]$OutFile
  )

  $curl = Get-Command curl.exe -ErrorAction SilentlyContinue
  if ($null -eq $curl) {
    return $false
  }

  & $curl.Source `
    --location `
    --fail `
    --silent `
    --show-error `
    --output $OutFile `
    $Url

  if ($LASTEXITCODE -ne 0) {
    throw "curl.exe download failed with exit code $LASTEXITCODE"
  }

  return $true
}

function Invoke-ReleaseDownloadWithPowerShell {
  param(
    [string]$Url,
    [string]$OutFile
  )

  Invoke-WebRequest -Uri $Url -OutFile $OutFile -ErrorAction Stop | Out-Null
}

function Invoke-ReleaseDownload {
  param(
    [string]$Url,
    [string]$OutFile
  )

  $downloaders = @(
    @{ Name = 'curl.exe'; Action = { Invoke-ReleaseDownloadWithCurl -Url $Url -OutFile $OutFile } },
    @{ Name = 'Invoke-WebRequest'; Action = { Invoke-ReleaseDownloadWithPowerShell -Url $Url -OutFile $OutFile; $true } }
  )

  $lastError = $null
  foreach ($downloader in $downloaders) {
    try {
      $result = & $downloader.Action
      if ($result) {
        return [string]$downloader.Name
      }
    } catch {
      $lastError = $_
      Write-Output ("[helper-install] download_attempt_failed=" + [string]$downloader.Name)
      Write-Output ("[helper-install] download_attempt_error=" + $_.Exception.Message)
    }
  }

  if ($null -ne $lastError) {
    throw $lastError
  }

  throw 'no release downloader is available'
}

function Test-ValidatedReleaseArchive {
  param(
    [string]$Path,
    [string]$ExpectedSha,
    [string]$Source,
    [switch]$RequirePath
  )

  if ([string]::IsNullOrWhiteSpace($Path)) {
    if ($RequirePath) {
      throw "release archive path is required for source: $Source"
    }
    return $null
  }

  if (-not (Test-Path -LiteralPath $Path)) {
    if ($RequirePath) {
      throw "release archive path does not exist for source ${Source}: $Path"
    }
    return $null
  }

  $actualSha = Get-FileSha256 -Path $Path
  if ($actualSha -ne $ExpectedSha) {
    if ($RequirePath) {
      throw "release archive checksum mismatch for source ${Source}: expected $ExpectedSha, got $actualSha"
    }

    Write-Output ("[helper-install] skipped_archive_path=" + $Path)
    Write-Output ("[helper-install] skipped_archive_source=" + $Source)
    Write-Output ("[helper-install] skipped_archive_reason=checksum_mismatch")
    return $null
  }

  return @{
    Path = $Path
    Source = $Source
  }
}

function Resolve-ReleaseDownloadUrl {
  param(
    [pscustomobject]$Manifest,
    [string]$AssetName
  )

  $overrideUrl = [string]$env:WEZTERM_WINDOWS_HELPER_RELEASE_URL
  if (-not [string]::IsNullOrWhiteSpace($overrideUrl)) {
    return @{
      Url = $overrideUrl
      Source = 'override_url'
    }
  }

  $baseUrl = [string]$env:WEZTERM_WINDOWS_HELPER_RELEASE_BASE_URL
  if (-not [string]::IsNullOrWhiteSpace($baseUrl)) {
    $trimmed = $baseUrl.TrimEnd('/', '\')
    return @{
      Url = "$trimmed/$AssetName"
      Source = 'base_url'
    }
  }

  return @{
    Url = [string]$Manifest.downloadUrl
    Source = 'manifest_url'
  }
}

function Ensure-ReleaseArchive {
  param(
    [pscustomobject]$Manifest
  )

  $assetName = Get-ReleaseAssetName -Manifest $Manifest
  if ([string]::IsNullOrWhiteSpace($assetName)) {
    throw 'release manifest assetName or downloadUrl filename is required'
  }
  if ([string]::IsNullOrWhiteSpace([string]$Manifest.version)) {
    throw 'release manifest version is required'
  }
  if ([string]::IsNullOrWhiteSpace([string]$Manifest.downloadUrl)) {
    throw 'release manifest downloadUrl is required'
  }
  if ([string]::IsNullOrWhiteSpace([string]$Manifest.sha256)) {
    throw 'release manifest sha256 is required'
  }

  $cacheRoot = Get-ReleaseDownloadCacheRoot
  $versionDir = Join-Path $cacheRoot ([string]$Manifest.version)
  $archivePath = Join-Path $versionDir $assetName
  $preloadRoot = Get-ReleasePreloadRoot
  $versionedPreloadPath = Join-Path (Join-Path $preloadRoot ([string]$Manifest.version)) $assetName
  $flatPreloadPath = Join-Path $preloadRoot $assetName
  $expectedSha = ([string]$Manifest.sha256).ToLowerInvariant()

  $null = New-Item -ItemType Directory -Force -Path $versionDir

  $explicitArchivePath = [string]$env:WEZTERM_WINDOWS_HELPER_RELEASE_ARCHIVE
  if (-not [string]::IsNullOrWhiteSpace($explicitArchivePath)) {
    $resolvedExplicitArchive = Test-ValidatedReleaseArchive `
      -Path $explicitArchivePath `
      -ExpectedSha $expectedSha `
      -Source 'explicit_archive' `
      -RequirePath
    return @{
      Path = $resolvedExplicitArchive.Path
      Source = $resolvedExplicitArchive.Source
      DownloadUrl = ''
    }
  }

  foreach ($candidate in @(
    @{ Path = $versionedPreloadPath; Source = 'preload_versioned' },
    @{ Path = $flatPreloadPath; Source = 'preload_flat' },
    @{ Path = $archivePath; Source = 'cache' }
  )) {
    $resolvedCandidate = Test-ValidatedReleaseArchive `
      -Path ([string]$candidate.Path) `
      -ExpectedSha $expectedSha `
      -Source ([string]$candidate.Source)
    if ($null -ne $resolvedCandidate) {
      return @{
        Path = $resolvedCandidate.Path
        Source = $resolvedCandidate.Source
        DownloadUrl = ''
      }
    }
  }

  $tempArchivePath = "$archivePath.download"
  Remove-Item -LiteralPath $tempArchivePath -Force -ErrorAction SilentlyContinue

  $download = Resolve-ReleaseDownloadUrl -Manifest $Manifest -AssetName $assetName
  $downloadUrl = [string]$download.Url
  if ([string]::IsNullOrWhiteSpace($downloadUrl)) {
    throw 'release download URL is empty after applying overrides'
  }

  $downloadedBy = ''
  try {
    $downloadedBy = Invoke-ReleaseDownload -Url $downloadUrl -OutFile $tempArchivePath
    $actualSha = Get-FileSha256 -Path $tempArchivePath
    if ($actualSha -ne $expectedSha) {
      throw "downloaded helper release checksum mismatch: expected $expectedSha, got $actualSha"
    }
    Move-Item -Force -LiteralPath $tempArchivePath -Destination $archivePath
  } finally {
    Remove-Item -LiteralPath $tempArchivePath -Force -ErrorAction SilentlyContinue
  }

  return @{
    Path = $archivePath
    Source = [string]$download.Source
    DownloadUrl = $downloadUrl
    DownloadedBy = $downloadedBy
  }
}

function Resolve-ExpandedPackageRoot {
  param(
    [string]$ExpandedDir
  )

  $managerPath = Join-Path $ExpandedDir 'helper-manager.exe'
  $clientPath = Join-Path $ExpandedDir 'helperctl.exe'
  if ((Test-Path -LiteralPath $managerPath) -and (Test-Path -LiteralPath $clientPath)) {
    return $ExpandedDir
  }

  $children = @(Get-ChildItem -LiteralPath $ExpandedDir -Directory -Force -ErrorAction Stop)
  if ($children.Count -eq 1) {
    $nestedRoot = $children[0].FullName
    $nestedManagerPath = Join-Path $nestedRoot 'helper-manager.exe'
    $nestedClientPath = Join-Path $nestedRoot 'helperctl.exe'
    if ((Test-Path -LiteralPath $nestedManagerPath) -and (Test-Path -LiteralPath $nestedClientPath)) {
      return $nestedRoot
    }
  }

  throw "expanded helper package missing helper-manager.exe or helperctl.exe: $ExpandedDir"
}

function Install-FromLocalBuild {
  param(
    [string]$DotnetPath,
    [hashtable]$ResolvedProjectPaths,
    [string]$ResolvedInstallRoot,
    [string]$ResolvedRuntimeDir
  )

  $tempOutput = Join-Path ([System.IO.Path]::GetTempPath()) ("wezterm-helper-manager-" + [guid]::NewGuid().ToString('N'))
  $tempClientOutput = Join-Path ([System.IO.Path]::GetTempPath()) ("wezterm-helperctl-" + [guid]::NewGuid().ToString('N'))
  $null = New-Item -ItemType Directory -Force -Path $tempOutput
  $null = New-Item -ItemType Directory -Force -Path $tempClientOutput

  try {
    & $DotnetPath publish $ResolvedProjectPaths.Manager `
      -c Release `
      -r win-x64 `
      --self-contained false `
      /p:PublishSingleFile=false `
      -o $tempOutput

    if ($LASTEXITCODE -ne 0) {
      throw "dotnet publish failed with exit code $LASTEXITCODE"
    }

    & $DotnetPath publish $ResolvedProjectPaths.Client `
      -c Release `
      -r win-x64 `
      --self-contained false `
      /p:PublishSingleFile=false `
      -o $tempClientOutput

    if ($LASTEXITCODE -ne 0) {
      throw "dotnet publish failed with exit code $LASTEXITCODE"
    }

    Write-Output "[helper-install] publish_succeeded=1"
    $installedManagerPath = Join-Path $ResolvedInstallRoot 'helper-manager.exe'
    $stoppedProcessIds = @(Stop-InstalledHelperManagerProcesses -BinaryPath $installedManagerPath)
    Write-StructuredLog -Level 'info' -Category 'host_helper' -Message 'stopping existing helper manager for install' -Fields @{
      trigger = $Trigger
      restart_reason = 'sync_install'
      install_source = 'local'
      binary_path = $installedManagerPath
      stopped_existing_manager = if ($stoppedProcessIds.Count -gt 0) { '1' } else { '0' }
      stopped_process_ids = ($stoppedProcessIds -join ',')
    }
    Write-Output "[helper-install] stopped_existing_manager=1"
    Get-ChildItem -LiteralPath $ResolvedInstallRoot -Force -ErrorAction SilentlyContinue | Remove-Item -Force -Recurse -ErrorAction SilentlyContinue
    Copy-Item -Path (Join-Path $tempOutput '*') -Destination $ResolvedInstallRoot -Recurse -Force
    Copy-Item -Path (Join-Path $tempClientOutput '*') -Destination $ResolvedInstallRoot -Recurse -Force
    Write-InstallState -ResolvedInstallRoot $ResolvedInstallRoot -State @{
      source = 'local'
      runtimeDir = $ResolvedRuntimeDir
      installedAt = [DateTimeOffset]::UtcNow.ToString('o')
    }
  } finally {
    Remove-Item -LiteralPath $tempOutput -Force -Recurse -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $tempClientOutput -Force -Recurse -ErrorAction SilentlyContinue
  }
}

function Install-FromRelease {
  param(
    [pscustomobject]$Manifest,
    [string]$ResolvedInstallRoot
  )

  if (Test-ReleaseInstallCurrent -ResolvedInstallRoot $ResolvedInstallRoot -Manifest $Manifest) {
    Write-Output '[helper-install] install_skipped=1'
    return
  }

  $archive = Ensure-ReleaseArchive -Manifest $Manifest
  $archivePath = [string]$archive.Path
  $archiveSource = [string]$archive.Source
  $archiveDownloadUrl = [string]$archive.DownloadUrl
  $archiveDownloadedBy = [string]$archive.DownloadedBy
  $expandedDir = Join-Path ([System.IO.Path]::GetTempPath()) ("wezterm-helper-release-" + [guid]::NewGuid().ToString('N'))
  $null = New-Item -ItemType Directory -Force -Path $expandedDir

  try {
    Expand-Archive -LiteralPath $archivePath -DestinationPath $expandedDir -Force
    $packageRoot = Resolve-ExpandedPackageRoot -ExpandedDir $expandedDir
    $installedManagerPath = Join-Path $ResolvedInstallRoot 'helper-manager.exe'
    $stoppedProcessIds = @(Stop-InstalledHelperManagerProcesses -BinaryPath $installedManagerPath)
    Write-StructuredLog -Level 'info' -Category 'host_helper' -Message 'stopping existing helper manager for release install' -Fields @{
      trigger = $Trigger
      restart_reason = 'release_install'
      install_source = 'release'
      binary_path = $installedManagerPath
      release_version = [string]$Manifest.version
      archive_source = $archiveSource
      archive_path = $archivePath
      download_url = $archiveDownloadUrl
      downloaded_by = $archiveDownloadedBy
      stopped_existing_manager = if ($stoppedProcessIds.Count -gt 0) { '1' } else { '0' }
      stopped_process_ids = ($stoppedProcessIds -join ',')
    }

    Get-ChildItem -LiteralPath $ResolvedInstallRoot -Force -ErrorAction SilentlyContinue | Remove-Item -Force -Recurse -ErrorAction SilentlyContinue
    Copy-Item -Path (Join-Path $packageRoot '*') -Destination $ResolvedInstallRoot -Recurse -Force
    Write-InstallState -ResolvedInstallRoot $ResolvedInstallRoot -State @{
      source = 'release'
      version = [string]$Manifest.version
      sha256 = ([string]$Manifest.sha256).ToLowerInvariant()
      assetName = Get-ReleaseAssetName -Manifest $Manifest
      downloadUrl = [string]$Manifest.downloadUrl
      archiveSource = $archiveSource
      archivePath = $archivePath
      resolvedDownloadUrl = $archiveDownloadUrl
      downloadedBy = $archiveDownloadedBy
      installedAt = [DateTimeOffset]::UtcNow.ToString('o')
    }
  } finally {
    Remove-Item -LiteralPath $expandedDir -Force -Recurse -ErrorAction SilentlyContinue
  }
}

$projectPaths = Get-ProjectPaths -RuntimeRoot $RuntimeDir
$dotnet = Get-DotnetPath
$releaseManifest = Read-ReleaseManifest -ManifestPath $projectPaths.ReleaseManifest
$resolvedInstallSource = Resolve-InstallSource -RequestedSource $InstallSource -DotnetPath $dotnet -ReleaseManifest $releaseManifest
$null = New-Item -ItemType Directory -Force -Path $InstallRoot

Write-Output ("[helper-install] manager_project=" + $projectPaths.Manager)
Write-Output ("[helper-install] client_project=" + $projectPaths.Client)
Write-Output ("[helper-install] dotnet=" + $dotnet)
Write-Output ("[helper-install] release_manifest=" + $projectPaths.ReleaseManifest)
Write-Output ("[helper-install] install_source=" + $resolvedInstallSource)
Write-Output ("[helper-install] install_root=" + $InstallRoot)
Write-StructuredLog -Level 'info' -Category 'host_helper' -Message 'starting windows helper install' -Fields @{
  trigger = $Trigger
  runtime_dir = $RuntimeDir
  install_root = $InstallRoot
  install_source = $resolvedInstallSource
  manager_project = $projectPaths.Manager
  client_project = $projectPaths.Client
  release_manifest = $projectPaths.ReleaseManifest
}

if ($resolvedInstallSource -eq 'local') {
  if (-not (Test-Path -LiteralPath $projectPaths.Manager)) {
    throw "helper manager project missing: $($projectPaths.Manager)"
  }
  if (-not (Test-Path -LiteralPath $projectPaths.Client)) {
    throw "helper client project missing: $($projectPaths.Client)"
  }
  Install-FromLocalBuild -DotnetPath $dotnet -ResolvedProjectPaths $projectPaths -ResolvedInstallRoot $InstallRoot -ResolvedRuntimeDir $RuntimeDir
} else {
  Install-FromRelease -Manifest $releaseManifest -ResolvedInstallRoot $InstallRoot
}

Write-Output ("[helper-install] installed_source=" + $resolvedInstallSource)
Write-Output ("[helper-install] install_state=" + (Get-InstallStatePath -ResolvedInstallRoot $InstallRoot))
if ($resolvedInstallSource -eq 'release' -and $null -ne $releaseManifest) {
  Write-Output ("[helper-install] release_version=" + [string]$releaseManifest.version)
}
$releaseInstallState = Read-InstallState -ResolvedInstallRoot $InstallRoot
if ($resolvedInstallSource -eq 'release' -and $null -ne $releaseInstallState) {
  Write-Output ("[helper-install] release_archive_source=" + [string]$releaseInstallState.archiveSource)
  Write-Output ("[helper-install] release_archive_path=" + [string]$releaseInstallState.archivePath)
  Write-Output ("[helper-install] release_download_url=" + [string]$releaseInstallState.resolvedDownloadUrl)
  Write-Output ("[helper-install] release_downloaded_by=" + [string]$releaseInstallState.downloadedBy)
}
Write-Output ("[helper-install] installed_binary=" + (Join-Path $InstallRoot 'helper-manager.exe'))
Write-Output ("[helper-install] installed_client=" + (Join-Path $InstallRoot 'helperctl.exe'))
Write-StructuredLog -Level 'info' -Category 'host_helper' -Message 'installed windows helper manager build' -Fields @{
  trigger = $Trigger
  restart_reason = if ($resolvedInstallSource -eq 'local') { 'sync_install' } else { 'release_install' }
  runtime_dir = $RuntimeDir
  install_root = $InstallRoot
  install_source = $resolvedInstallSource
  installed_binary = (Join-Path $InstallRoot 'helper-manager.exe')
  installed_client = (Join-Path $InstallRoot 'helperctl.exe')
}
Write-Output (Join-Path $InstallRoot 'helper-manager.exe')
