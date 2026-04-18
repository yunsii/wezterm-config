param(
  [Parameter(Mandatory = $true)]
  [string]$WorkerScriptPath,

  [int]$Port = 0,

  [string]$StatePath = "$env:LOCALAPPDATA\wezterm-runtime-helper\state.env",

  [string]$RequestDir = "$env:LOCALAPPDATA\wezterm-runtime-helper\requests",

  [string]$ClipboardListenerScriptPath = '',

  [string]$ClipboardStatePath = '',

  [string]$ClipboardLogPath = '',

  [string]$ClipboardOutputDir = '',

  [string]$ClipboardWslDistro = '',

  [int]$ClipboardHeartbeatIntervalSeconds = 1,

  [int]$ClipboardHeartbeatTimeoutSeconds = 3,

  [int]$ClipboardImageReadRetryCount = 12,

  [int]$ClipboardImageReadRetryDelayMs = 100,

  [int]$ClipboardCleanupMaxAgeHours = 48,

  [int]$ClipboardCleanupMaxFiles = 32,

  [int]$HeartbeatTimeoutSeconds = 5,

  [int]$HeartbeatIntervalMs = 1000,

  [int]$PollIntervalMs = 25,

  [string]$DiagnosticsEnabled = '0',

  [string]$DiagnosticsCategoryEnabled = '0',

  [string]$DiagnosticsLevel = 'info',

  [string]$DiagnosticsFile = '',

  [int]$DiagnosticsMaxBytes = 0,

  [int]$DiagnosticsMaxFiles = 0
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

. (Join-Path (Split-Path -Parent $PSCommandPath) 'windows-structured-log.ps1')
Initialize-StructuredLog `
  -FilePath $DiagnosticsFile `
  -Enabled $DiagnosticsEnabled `
  -CategoryEnabled $DiagnosticsCategoryEnabled `
  -Level $DiagnosticsLevel `
  -Source 'windows-helper-launcher' `
  -TraceId '' `
  -MaxBytes $DiagnosticsMaxBytes `
  -MaxFiles $DiagnosticsMaxFiles

function Get-NowEpochMilliseconds {
  return [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
}

function Read-HelperState {
  if ([string]::IsNullOrWhiteSpace($StatePath) -or -not (Test-Path -LiteralPath $StatePath)) {
    return $null
  }

  $state = @{}
  foreach ($line in Get-Content -LiteralPath $StatePath -ErrorAction Stop) {
    if ([string]::IsNullOrWhiteSpace($line)) {
      continue
    }

    $parts = $line.Split('=', 2)
    if (@($parts).Length -eq 2) {
      $state[$parts[0]] = $parts[1]
    }
  }

  if (@($state.Keys).Length -eq 0) {
    return $null
  }

  return $state
}

function Get-HelperProcesses {
  $launcherScriptPath = $PSCommandPath

  return @(Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" | Where-Object {
    if (-not $_.CommandLine) {
      return $false
    }

    if ($_.CommandLine.Contains($launcherScriptPath)) {
      return $false
    }

    return $_.CommandLine.Contains("-File $WorkerScriptPath")
  })
}

function Test-HelperStateFresh {
  param(
    [hashtable]$State
  )

  if ($null -eq $State) {
    return $false
  }

  if ([string]$State.ready -ne '1') {
    return $false
  }

  $helperPid = 0
  [void][int]::TryParse([string]$State.pid, [ref]$helperPid)
  if ($helperPid -le 0) {
    return $false
  }

  $heartbeatAtMs = 0
  [void][long]::TryParse([string]$State.heartbeat_at_ms, [ref]$heartbeatAtMs)
  if ($heartbeatAtMs -le 0) {
    return $false
  }

  if ((Get-NowEpochMilliseconds) - $heartbeatAtMs -gt ($HeartbeatTimeoutSeconds * 1000)) {
    return $false
  }

  foreach ($process in Get-HelperProcesses) {
    if ([int]$process.ProcessId -eq $helperPid) {
      return $true
    }
  }

  return $false
}

function Stop-HelperProcesses {
  $processes = @(Get-HelperProcesses)
  Write-StructuredLog -Level 'info' -Category 'alt_o' -Message 'launcher enumerated helper processes' -Fields @{
    count = @($processes).Length
    worker_script_path = $WorkerScriptPath
  }
  foreach ($process in $processes) {
    try {
      Stop-Process -Id $process.ProcessId -Force -ErrorAction Stop
      Write-StructuredLog -Level 'warn' -Category 'alt_o' -Message 'stopped windows runtime helper process' -Fields @{
        pid = $process.ProcessId
        worker_script_path = $WorkerScriptPath
      }
    } catch {
      Write-StructuredLog -Level 'warn' -Category 'alt_o' -Message 'failed to stop windows runtime helper process' -Fields @{
        pid = $process.ProcessId
        worker_script_path = $WorkerScriptPath
        error = $_.Exception.Message
      }
    }
  }
}

try {
  Write-StructuredLog -Level 'info' -Category 'alt_o' -Message 'launcher checking helper state' -Fields @{
    state_path = $StatePath
    request_dir = $RequestDir
    worker_script_path = $WorkerScriptPath
  }

  if (-not (Test-Path -LiteralPath $WorkerScriptPath)) {
    throw "worker script missing: $WorkerScriptPath"
  }

  $state = Read-HelperState
  if (Test-HelperStateFresh -State $state) {
    Write-StructuredLog -Level 'info' -Category 'alt_o' -Message 'launcher found healthy helper' -Fields @{
      state_path = $StatePath
      request_dir = $RequestDir
      pid = $state.pid
    }
    exit 0
  }

  Write-StructuredLog -Level 'info' -Category 'alt_o' -Message 'launcher cleaning stale helper processes' -Fields @{
    state_path = $StatePath
    request_dir = $RequestDir
  }
  Stop-HelperProcesses
  Start-Sleep -Milliseconds 100

  $arguments = @(
    '-NoProfile',
    '-NonInteractive',
    '-WindowStyle', 'Hidden',
    '-ExecutionPolicy', 'Bypass',
    '-File', $WorkerScriptPath,
    '-Port', [string]$Port,
    '-StatePath', $StatePath,
    '-RequestDir', $RequestDir,
    '-ClipboardListenerScriptPath', $ClipboardListenerScriptPath,
    '-ClipboardStatePath', $ClipboardStatePath,
    '-ClipboardLogPath', $ClipboardLogPath,
    '-ClipboardOutputDir', $ClipboardOutputDir,
    '-ClipboardWslDistro', $ClipboardWslDistro,
    '-ClipboardHeartbeatIntervalSeconds', [string]$ClipboardHeartbeatIntervalSeconds,
    '-ClipboardHeartbeatTimeoutSeconds', [string]$ClipboardHeartbeatTimeoutSeconds,
    '-ClipboardImageReadRetryCount', [string]$ClipboardImageReadRetryCount,
    '-ClipboardImageReadRetryDelayMs', [string]$ClipboardImageReadRetryDelayMs,
    '-ClipboardCleanupMaxAgeHours', [string]$ClipboardCleanupMaxAgeHours,
    '-ClipboardCleanupMaxFiles', [string]$ClipboardCleanupMaxFiles,
    '-HeartbeatIntervalMs', [string]$HeartbeatIntervalMs,
    '-PollIntervalMs', [string]$PollIntervalMs,
    '-DiagnosticsEnabled', $DiagnosticsEnabled,
    '-DiagnosticsCategoryEnabled', $DiagnosticsCategoryEnabled,
    '-DiagnosticsLevel', $DiagnosticsLevel,
    '-DiagnosticsFile', $DiagnosticsFile,
    '-DiagnosticsMaxBytes', [string]$DiagnosticsMaxBytes,
    '-DiagnosticsMaxFiles', [string]$DiagnosticsMaxFiles
  )

  Write-StructuredLog -Level 'info' -Category 'alt_o' -Message 'launcher about to start helper worker' -Fields @{
    state_path = $StatePath
    request_dir = $RequestDir
    worker_script_path = $WorkerScriptPath
  }
  $child = Start-Process -FilePath 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' -ArgumentList $arguments -PassThru
  Write-StructuredLog -Level 'info' -Category 'alt_o' -Message 'launcher started helper worker' -Fields @{
    state_path = $StatePath
    request_dir = $RequestDir
    worker_script_path = $WorkerScriptPath
    child_pid = $child.Id
  }

  Write-StructuredLog -Level 'info' -Category 'alt_o' -Message 'launcher waiting for helper heartbeat' -Fields @{
    state_path = $StatePath
    request_dir = $RequestDir
  }
  for ($attempt = 0; $attempt -lt 40; $attempt++) {
    Start-Sleep -Milliseconds 100
    $state = Read-HelperState
    if (Test-HelperStateFresh -State $state) {
      Write-StructuredLog -Level 'info' -Category 'alt_o' -Message 'launcher observed healthy helper' -Fields @{
        state_path = $StatePath
        request_dir = $RequestDir
        pid = $state.pid
      }
      exit 0
    }
  }

  Write-StructuredLog -Level 'error' -Category 'alt_o' -Message 'launcher timed out waiting for helper heartbeat' -Fields @{
    state_path = $StatePath
    request_dir = $RequestDir
  }
  exit 1
} catch {
  Write-StructuredLog -Level 'error' -Category 'alt_o' -Message 'launcher failed' -Fields @{
    state_path = $StatePath
    request_dir = $RequestDir
    worker_script_path = $WorkerScriptPath
    error = $_.Exception.Message
  }
  exit 1
}
