param(
  [string]$RuntimeDir = '',

  [string]$InstallRoot = "$env:LOCALAPPDATA\wezterm-runtime\bin",

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
  return @{
    Manager = Join-Path $projectRoot 'HelperManager\WezTerm.WindowsHostHelper.csproj'
    Client = Join-Path $projectRoot 'HelperCtl\HelperCtl.csproj'
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

$projectPaths = Get-ProjectPaths -RuntimeRoot $RuntimeDir
if (-not (Test-Path -LiteralPath $projectPaths.Manager)) {
  throw "helper manager project missing: $($projectPaths.Manager)"
}
if (-not (Test-Path -LiteralPath $projectPaths.Client)) {
  throw "helper client project missing: $($projectPaths.Client)"
}

$dotnet = Get-DotnetPath
if ([string]::IsNullOrWhiteSpace($dotnet)) {
  throw 'dotnet SDK is not installed on Windows'
}

$tempOutput = Join-Path ([System.IO.Path]::GetTempPath()) ("wezterm-helper-manager-" + [guid]::NewGuid().ToString('N'))
$tempClientOutput = Join-Path ([System.IO.Path]::GetTempPath()) ("wezterm-helperctl-" + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Force -Path $tempOutput
$null = New-Item -ItemType Directory -Force -Path $tempClientOutput
$null = New-Item -ItemType Directory -Force -Path $InstallRoot

Write-Output ("[helper-install] manager_project=" + $projectPaths.Manager)
Write-Output ("[helper-install] client_project=" + $projectPaths.Client)
Write-Output ("[helper-install] dotnet=" + $dotnet)
Write-Output ("[helper-install] install_root=" + $InstallRoot)
Write-Output ("[helper-install] temp_output=" + $tempOutput)
Write-Output ("[helper-install] temp_client_output=" + $tempClientOutput)
Write-StructuredLog -Level 'info' -Category 'host_helper' -Message 'starting windows helper install' -Fields @{
  trigger = $Trigger
  runtime_dir = $RuntimeDir
  install_root = $InstallRoot
  manager_project = $projectPaths.Manager
  client_project = $projectPaths.Client
}

try {
  & $dotnet publish $projectPaths.Manager `
    -c Release `
    -r win-x64 `
    --self-contained false `
    /p:PublishSingleFile=false `
    -o $tempOutput

  if ($LASTEXITCODE -ne 0) {
    throw "dotnet publish failed with exit code $LASTEXITCODE"
  }

  & $dotnet publish $projectPaths.Client `
    -c Release `
    -r win-x64 `
    --self-contained false `
    /p:PublishSingleFile=false `
    -o $tempClientOutput

  if ($LASTEXITCODE -ne 0) {
    throw "dotnet publish failed with exit code $LASTEXITCODE"
  }

  Write-Output "[helper-install] publish_succeeded=1"
  $installedManagerPath = Join-Path $InstallRoot 'helper-manager.exe'
  $stoppedProcessIds = @(Stop-InstalledHelperManagerProcesses -BinaryPath $installedManagerPath)
  Write-StructuredLog -Level 'info' -Category 'host_helper' -Message 'stopping existing helper manager for install' -Fields @{
    trigger = $Trigger
    restart_reason = 'sync_install'
    binary_path = $installedManagerPath
    stopped_existing_manager = if ($stoppedProcessIds.Count -gt 0) { '1' } else { '0' }
    stopped_process_ids = ($stoppedProcessIds -join ',')
  }
  Write-Output "[helper-install] stopped_existing_manager=1"
  Get-ChildItem -LiteralPath $InstallRoot -Force -ErrorAction SilentlyContinue | Remove-Item -Force -Recurse -ErrorAction SilentlyContinue
  Copy-Item -Path (Join-Path $tempOutput '*') -Destination $InstallRoot -Recurse -Force
  Copy-Item -Path (Join-Path $tempClientOutput '*') -Destination $InstallRoot -Recurse -Force
  Write-Output ("[helper-install] installed_binary=" + (Join-Path $InstallRoot 'helper-manager.exe'))
  Write-Output ("[helper-install] installed_client=" + (Join-Path $InstallRoot 'helperctl.exe'))
  Write-StructuredLog -Level 'info' -Category 'host_helper' -Message 'installed windows helper manager build' -Fields @{
    trigger = $Trigger
    restart_reason = 'sync_install'
    runtime_dir = $RuntimeDir
    install_root = $InstallRoot
    installed_binary = (Join-Path $InstallRoot 'helper-manager.exe')
    installed_client = (Join-Path $InstallRoot 'helperctl.exe')
  }
  Write-Output (Join-Path $InstallRoot 'helper-manager.exe')
} finally {
  Remove-Item -LiteralPath $tempOutput -Force -Recurse -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $tempClientOutput -Force -Recurse -ErrorAction SilentlyContinue
}
