param(
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

function Set-HelperLogger {
  Initialize-StructuredLog `
    -FilePath $DiagnosticsFile `
    -Enabled $DiagnosticsEnabled `
    -CategoryEnabled $DiagnosticsCategoryEnabled `
    -Level $DiagnosticsLevel `
    -Source 'windows-helper' `
    -TraceId '' `
    -MaxBytes $DiagnosticsMaxBytes `
    -MaxFiles $DiagnosticsMaxFiles
}

function Set-RequestLogger {
  param(
    [string]$TraceId
  )

  Initialize-StructuredLog `
    -FilePath $DiagnosticsFile `
    -Enabled $DiagnosticsEnabled `
    -CategoryEnabled $DiagnosticsCategoryEnabled `
    -Level $DiagnosticsLevel `
    -Source 'windows-alt-o' `
    -TraceId $TraceId `
    -MaxBytes $DiagnosticsMaxBytes `
    -MaxFiles $DiagnosticsMaxFiles
}

function Get-NowEpochMilliseconds {
  return [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
}

function Ensure-Directory {
  param(
    [string]$Path
  )

  if (-not [string]::IsNullOrWhiteSpace($Path)) {
    $null = New-Item -ItemType Directory -Force -Path $Path
  }
}

function Read-ClipboardListenerState {
  if ([string]::IsNullOrWhiteSpace($ClipboardStatePath) -or -not (Test-Path -LiteralPath $ClipboardStatePath)) {
    return $null
  }

  try {
    $state = @{}
    foreach ($line in Get-Content -LiteralPath $ClipboardStatePath -ErrorAction Stop) {
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
  } catch {
    return $null
  }
}

function Get-StandaloneClipboardListenerProcesses {
  if ([string]::IsNullOrWhiteSpace($ClipboardListenerScriptPath)) {
    return @()
  }

  return @(Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" | Where-Object {
    if (-not $_.CommandLine) {
      return $false
    }

    return $_.CommandLine.Contains("-File $ClipboardListenerScriptPath")
  })
}

function Stop-StandaloneClipboardListenerProcesses {
  $processes = @(Get-StandaloneClipboardListenerProcesses)
  foreach ($process in $processes) {
    try {
      Stop-Process -Id $process.ProcessId -Force -ErrorAction Stop
      Write-StructuredLog -Level 'info' -Category 'clipboard' -Message 'host stopped standalone clipboard listener process' -Fields @{
        pid = $process.ProcessId
        listener_script_path = $ClipboardListenerScriptPath
      }
    } catch {
      Write-StructuredLog -Level 'warn' -Category 'clipboard' -Message 'host failed to stop standalone clipboard listener process' -Fields @{
        pid = $process.ProcessId
        listener_script_path = $ClipboardListenerScriptPath
        error = $_.Exception.Message
      }
    }
  }
}

function ClipboardListenerStateIsFresh {
  param(
    [hashtable]$State
  )

  if ($null -eq $State) {
    return $false
  }

  $heartbeatAtMs = 0
  [void][long]::TryParse([string]$State.heartbeat_at_ms, [ref]$heartbeatAtMs)
  if ($heartbeatAtMs -le 0) {
    return $false
  }

  if ((Get-NowEpochMilliseconds) - $heartbeatAtMs -gt ($ClipboardHeartbeatTimeoutSeconds * 1000)) {
    return $false
  }

  return $true
}

function Ensure-ClipboardListenerRunning {
  if ([string]::IsNullOrWhiteSpace($ClipboardListenerScriptPath) -or -not (Test-Path -LiteralPath $ClipboardListenerScriptPath)) {
    return
  }

  $state = Read-ClipboardListenerState
  if (ClipboardListenerStateIsFresh -State $state) {
    return
  }
  Stop-StandaloneClipboardListenerProcesses

  $arguments = @(
    '-NoProfile',
    '-NonInteractive',
    '-STA',
    '-WindowStyle', 'Hidden',
    '-ExecutionPolicy', 'Bypass',
    '-File', $ClipboardListenerScriptPath
  )

  if (-not [string]::IsNullOrWhiteSpace($ClipboardWslDistro)) {
    $arguments += @('-WslDistro', $ClipboardWslDistro)
  }
  if (-not [string]::IsNullOrWhiteSpace($ClipboardStatePath)) {
    $arguments += @('-StatePath', $ClipboardStatePath)
  }
  if (-not [string]::IsNullOrWhiteSpace($ClipboardLogPath)) {
    $arguments += @('-LogPath', $ClipboardLogPath)
  }
  if (-not [string]::IsNullOrWhiteSpace($ClipboardOutputDir)) {
    $arguments += @('-OutputDir', $ClipboardOutputDir)
  }
  $arguments += @(
    '-HeartbeatIntervalSeconds', [string]$ClipboardHeartbeatIntervalSeconds,
    '-ImageReadRetryCount', [string]$ClipboardImageReadRetryCount,
    '-ImageReadRetryDelayMs', [string]$ClipboardImageReadRetryDelayMs,
    '-CleanupMaxAgeHours', [string]$ClipboardCleanupMaxAgeHours,
    '-CleanupMaxFiles', [string]$ClipboardCleanupMaxFiles
  )

  $child = Start-Process -FilePath 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' -ArgumentList $arguments -PassThru
  Write-StructuredLog -Level 'info' -Category 'clipboard' -Message 'host started clipboard listener' -Fields @{
    child_pid = $child.Id
    listener_script_path = $ClipboardListenerScriptPath
    state_path = $ClipboardStatePath
  }
}

function Write-HelperState {
  param(
    [string]$Ready = '1',
    [string]$LastError = ''
  )

  $stateDir = Split-Path -Parent $StatePath
  Ensure-Directory -Path $stateDir

  $lines = @(
    'version=2',
    "ready=$Ready",
    "pid=$PID",
    "started_at_ms=$script:StartedAtMs",
    "heartbeat_at_ms=$(Get-NowEpochMilliseconds)",
    "request_dir=$RequestDir",
    "last_error=$LastError"
  )

  $tempPath = "$StatePath.tmp"
  $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($tempPath, ($lines -join "`r`n") + "`r`n", $utf8NoBom)
  Move-Item -Force -LiteralPath $tempPath -Destination $StatePath
}

function Remove-RequestFile {
  param(
    [string]$Path
  )

  if (-not [string]::IsNullOrWhiteSpace($Path) -and (Test-Path -LiteralPath $Path)) {
    Remove-Item -Force -LiteralPath $Path -ErrorAction SilentlyContinue
  }
}

function Process-PendingRequests {
  $requestFiles = @(Get-ChildItem -LiteralPath $RequestDir -Filter '*.json' -File -ErrorAction SilentlyContinue | Sort-Object Name)
  foreach ($requestFile in $requestFiles) {
    try {
      $requestText = [System.IO.File]::ReadAllText($requestFile.FullName, [System.Text.Encoding]::UTF8)
      if ([string]::IsNullOrWhiteSpace($requestText)) {
        Remove-RequestFile -Path $requestFile.FullName
        continue
      }

      $payload = ConvertFrom-Json -InputObject $requestText
      $requestTraceId = if ($null -ne $payload -and $payload.trace_id) { [string]$payload.trace_id } else { $requestFile.BaseName }
      $requestKind = if ($null -ne $payload -and $payload.kind) { [string]$payload.kind } else { 'vscode_focus_or_open' }
      $requestCategory = if ($requestKind -eq 'chrome_focus_or_start') { 'chrome' } else { 'alt_o' }
      $result = Invoke-HostRequest -Payload $payload
      Write-StructuredLog -Level 'info' -Category $requestCategory -Message 'helper processed request' -Fields @{
        trace_id = $requestTraceId
        request_path = $requestFile.FullName
        kind = $requestKind
        status = if ($null -ne $result -and $result.status) { [string]$result.status } else { 'unknown' }
      }
      Remove-RequestFile -Path $requestFile.FullName
    } catch {
      Write-HelperState -Ready '1' -LastError $_.Exception.Message
      $requestCategory = 'alt_o'
      if ($requestFile.BaseName -match 'chrome') {
        $requestCategory = 'chrome'
      }
      Write-StructuredLog -Level 'error' -Category $requestCategory -Message 'helper request failed' -Fields @{
        request_path = $requestFile.FullName
        error = $_.Exception.Message
      }
      Remove-RequestFile -Path $requestFile.FullName
      Set-HelperLogger
    }
  }
}

function Invoke-VscodeRequest {
  param(
    [object]$Payload
  )

  $traceId = ''
  if ($null -ne $Payload -and $Payload.trace_id) {
    $traceId = [string]$Payload.trace_id
  }

  Set-RequestLogger -TraceId $traceId

  $codeArgs = @()
  foreach ($item in @($Payload.code_command)) {
    $codeArgs += [string]$item
  }

  $scriptPath = Join-Path (Split-Path -Parent $PSCommandPath) 'focus-or-open-vscode.ps1'
  $result = & $scriptPath `
    -RequestedDir ([string]$Payload.requested_dir) `
    -Distro ([string]$Payload.distro) `
    -CodeArg $codeArgs `
    -TraceId $traceId `
    -DiagnosticsEnabled $DiagnosticsEnabled `
    -DiagnosticsCategoryEnabled $DiagnosticsCategoryEnabled `
    -DiagnosticsLevel $DiagnosticsLevel `
    -DiagnosticsFile $DiagnosticsFile `
    -DiagnosticsMaxBytes $DiagnosticsMaxBytes `
    -DiagnosticsMaxFiles $DiagnosticsMaxFiles `
    -ReturnResult

  Set-HelperLogger
  return $result
}

function Invoke-ChromeRequest {
  param(
    [object]$Payload
  )

  $traceId = ''
  if ($null -ne $Payload -and $Payload.trace_id) {
    $traceId = [string]$Payload.trace_id
  }

  $scriptPath = Join-Path (Split-Path -Parent $PSCommandPath) 'focus-or-start-debug-chrome.ps1'
  $result = & $scriptPath `
    -ChromePath ([string]$Payload.chrome_path) `
    -RemoteDebuggingPort ([int]$Payload.remote_debugging_port) `
    -UserDataDir ([string]$Payload.user_data_dir) `
    -TraceId $traceId `
    -DiagnosticsEnabled $DiagnosticsEnabled `
    -DiagnosticsCategoryEnabled $DiagnosticsCategoryEnabled `
    -DiagnosticsLevel $DiagnosticsLevel `
    -DiagnosticsFile $DiagnosticsFile `
    -DiagnosticsMaxBytes $DiagnosticsMaxBytes `
    -DiagnosticsMaxFiles $DiagnosticsMaxFiles `
    -ReturnResult

  Set-HelperLogger
  return $result
}

function Invoke-HostRequest {
  param(
    [object]$Payload
  )

  $kind = if ($null -ne $Payload -and $Payload.kind) { [string]$Payload.kind } else { 'vscode_focus_or_open' }
  switch ($kind) {
    'vscode_focus_or_open' {
      return Invoke-VscodeRequest -Payload $Payload
    }
    'chrome_focus_or_start' {
      return Invoke-ChromeRequest -Payload $Payload
    }
    default {
      throw "unknown request kind: $kind"
    }
  }
}

$script:StartedAtMs = Get-NowEpochMilliseconds
Set-HelperLogger

$watcher = $null
$eventIds = @()
try {
  Ensure-Directory -Path (Split-Path -Parent $StatePath)
  Ensure-Directory -Path $RequestDir

  $watcher = New-Object System.IO.FileSystemWatcher
  $watcher.Path = $RequestDir
  $watcher.Filter = '*.json'
  $watcher.IncludeSubdirectories = $false
  $watcher.NotifyFilter = [System.IO.NotifyFilters]'FileName, LastWrite, CreationTime'
  $watcher.EnableRaisingEvents = $true
  $eventIds = @(
    'wezterm-helper-request-created',
    'wezterm-helper-request-changed',
    'wezterm-helper-request-renamed'
  )
  Register-ObjectEvent -InputObject $watcher -EventName Created -SourceIdentifier $eventIds[0] | Out-Null
  Register-ObjectEvent -InputObject $watcher -EventName Changed -SourceIdentifier $eventIds[1] | Out-Null
  Register-ObjectEvent -InputObject $watcher -EventName Renamed -SourceIdentifier $eventIds[2] | Out-Null

  Write-HelperState -Ready '1'
  Write-StructuredLog -Level 'info' -Category 'alt_o' -Message 'helper started' -Fields @{
    state_path = $StatePath
    request_dir = $RequestDir
    pid = $PID
  }
  Ensure-ClipboardListenerRunning
  Write-StructuredLog -Level 'info' -Category 'alt_o' -Message 'helper request directory watcher active' -Fields @{
    request_dir = $RequestDir
  }

  $lastHeartbeatMs = Get-NowEpochMilliseconds
  Process-PendingRequests
  while ($true) {
    $nowMs = Get-NowEpochMilliseconds
    if ($nowMs - $lastHeartbeatMs -ge $HeartbeatIntervalMs) {
      Write-HelperState -Ready '1'
      $lastHeartbeatMs = $nowMs
      Ensure-ClipboardListenerRunning
    }

    $timeoutSeconds = [Math]::Max([Math]::Ceiling(($HeartbeatIntervalMs - ([Math]::Max(0, ($nowMs - $lastHeartbeatMs)))) / 1000.0), 1)
    $event = Wait-Event -Timeout $timeoutSeconds
    if ($null -ne $event) {
      Remove-Event -EventIdentifier $event.EventIdentifier -ErrorAction SilentlyContinue
      Process-PendingRequests
      continue
    }

    Process-PendingRequests
  }
} catch {
  Write-HelperState -Ready '0' -LastError $_.Exception.Message
  Write-StructuredLog -Level 'error' -Category 'alt_o' -Message 'helper failed' -Fields @{
    state_path = $StatePath
    request_dir = $RequestDir
    error = $_.Exception.Message
  }
  throw
} finally {
  foreach ($eventId in $eventIds) {
    Unregister-Event -SourceIdentifier $eventId -ErrorAction SilentlyContinue
  }

  Get-EventSubscriber | Where-Object { $_.SourceObject -eq $watcher } | Unregister-Event -ErrorAction SilentlyContinue

  if ($watcher) {
    $watcher.EnableRaisingEvents = $false
    $watcher.Dispose()
  }
}
