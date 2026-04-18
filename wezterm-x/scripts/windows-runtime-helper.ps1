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

$script:HelperScriptRoot = Split-Path -Parent $PSCommandPath
. (Join-Path $script:HelperScriptRoot 'windows-structured-log.ps1')
. (Join-Path $script:HelperScriptRoot 'windows-runtime-helper\shared.ps1')

$script:RuntimeContext = [ordered]@{
  ScriptRoot = $script:HelperScriptRoot
  PowerShellExe = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
  Port = $Port
  StatePath = $StatePath
  RequestDir = $RequestDir
  Diagnostics = [ordered]@{
    Enabled = $DiagnosticsEnabled
    CategoryEnabled = $DiagnosticsCategoryEnabled
    Level = $DiagnosticsLevel
    File = $DiagnosticsFile
    MaxBytes = $DiagnosticsMaxBytes
    MaxFiles = $DiagnosticsMaxFiles
  }
  Clipboard = [ordered]@{
    ListenerScriptPath = $ClipboardListenerScriptPath
    StatePath = $ClipboardStatePath
    LogPath = $ClipboardLogPath
    OutputDir = $ClipboardOutputDir
    WslDistro = $ClipboardWslDistro
    HeartbeatIntervalSeconds = $ClipboardHeartbeatIntervalSeconds
    HeartbeatTimeoutSeconds = $ClipboardHeartbeatTimeoutSeconds
    ImageReadRetryCount = $ClipboardImageReadRetryCount
    ImageReadRetryDelayMs = $ClipboardImageReadRetryDelayMs
    CleanupMaxAgeHours = $ClipboardCleanupMaxAgeHours
    CleanupMaxFiles = $ClipboardCleanupMaxFiles
  }
}

$script:RequestHandlers = @{}
$script:LifecycleHandlers = @()

function Register-WindowsRuntimeRequestHandler {
  param(
    [hashtable]$Handler
  )

  if ($null -eq $Handler) {
    throw 'request handler cannot be null'
  }

  $kind = [string]$Handler.Kind
  if ([string]::IsNullOrWhiteSpace($kind)) {
    throw 'request handler kind is required'
  }

  if ($script:RequestHandlers.ContainsKey($kind)) {
    throw "duplicate request handler kind: $kind"
  }

  if (-not ($Handler.Handle -is [scriptblock])) {
    throw "request handler handle callback is required for kind: $kind"
  }

  $script:RequestHandlers[$kind] = $Handler
}

function Register-WindowsRuntimeLifecycleHandler {
  param(
    [hashtable]$Handler
  )

  if ($null -eq $Handler) {
    throw 'lifecycle handler cannot be null'
  }

  if (-not ($Handler.OnStart -is [scriptblock]) -and -not ($Handler.OnHeartbeat -is [scriptblock])) {
    throw 'lifecycle handler must define OnStart or OnHeartbeat'
  }

  $script:LifecycleHandlers += ,$Handler
}

function Get-WindowsRuntimeRequestKind {
  param(
    [object]$Payload
  )

  if ($null -ne $Payload -and $Payload.kind) {
    return [string]$Payload.kind
  }

  return 'vscode_focus_or_open'
}

function Get-WindowsRuntimeRequestHandler {
  param(
    [string]$Kind
  )

  if ($script:RequestHandlers.ContainsKey($Kind)) {
    return $script:RequestHandlers[$Kind]
  }

  return $null
}

function Invoke-WindowsRuntimeRequest {
  param(
    [object]$Payload,
    [string]$TraceId
  )

  $kind = Get-WindowsRuntimeRequestKind -Payload $Payload
  $handler = Get-WindowsRuntimeRequestHandler -Kind $kind
  if ($null -eq $handler) {
    throw "unknown request kind: $kind"
  }

  $source = if ([string]::IsNullOrWhiteSpace([string]$handler.Source)) { 'windows-helper' } else { [string]$handler.Source }
  Set-WindowsRuntimeRequestLogger -RuntimeContext $script:RuntimeContext -TraceId $TraceId -Source $source
  try {
    return & $handler.Handle $script:RuntimeContext $Payload $TraceId
  } finally {
    Set-WindowsRuntimeHelperLogger -RuntimeContext $script:RuntimeContext
  }
}

function Invoke-WindowsRuntimeLifecycleHook {
  param(
    [string]$HookName
  )

  foreach ($handler in $script:LifecycleHandlers) {
    $callback = $null
    if ($handler.ContainsKey($HookName)) {
      $callback = $handler[$HookName]
    }

    if ($callback -is [scriptblock]) {
      & $callback $script:RuntimeContext
    }
  }
}

function Write-HelperState {
  param(
    [string]$Ready = '1',
    [string]$LastError = ''
  )

  $stateDir = Split-Path -Parent $StatePath
  Ensure-WindowsRuntimeDirectory -Path $stateDir

  $lines = @(
    'version=2',
    "ready=$Ready",
    "pid=$PID",
    "started_at_ms=$script:StartedAtMs",
    "heartbeat_at_ms=$(Get-WindowsRuntimeEpochMilliseconds)",
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
    $requestKind = 'vscode_focus_or_open'
    $requestCategory = 'alt_o'
    try {
      $requestText = [System.IO.File]::ReadAllText($requestFile.FullName, [System.Text.Encoding]::UTF8)
      if ([string]::IsNullOrWhiteSpace($requestText)) {
        Remove-RequestFile -Path $requestFile.FullName
        continue
      }

      $payload = ConvertFrom-Json -InputObject $requestText
      $requestTraceId = if ($null -ne $payload -and $payload.trace_id) { [string]$payload.trace_id } else { $requestFile.BaseName }
      $requestKind = Get-WindowsRuntimeRequestKind -Payload $payload
      $requestHandler = Get-WindowsRuntimeRequestHandler -Kind $requestKind
      if ($null -eq $requestHandler) {
        throw "unknown request kind: $requestKind"
      }

      $requestCategory = if ([string]::IsNullOrWhiteSpace([string]$requestHandler.Category)) { 'alt_o' } else { [string]$requestHandler.Category }
      $result = Invoke-WindowsRuntimeRequest -Payload $payload -TraceId $requestTraceId
      Write-StructuredLog -Level 'info' -Category $requestCategory -Message 'helper processed request' -Fields @{
        trace_id = $requestTraceId
        request_path = $requestFile.FullName
        kind = $requestKind
        status = if ($null -ne $result -and $result.status) { [string]$result.status } else { 'unknown' }
      }
      Remove-RequestFile -Path $requestFile.FullName
    } catch {
      Write-HelperState -Ready '1' -LastError $_.Exception.Message
      Write-StructuredLog -Level 'error' -Category $requestCategory -Message 'helper request failed' -Fields @{
        request_path = $requestFile.FullName
        kind = $requestKind
        error = $_.Exception.Message
      }
      Remove-RequestFile -Path $requestFile.FullName
      Set-WindowsRuntimeHelperLogger -RuntimeContext $script:RuntimeContext
    }
  }
}

$pluginDir = Join-Path $script:HelperScriptRoot 'windows-runtime-helper\plugins'
$pluginFiles = @(Get-ChildItem -LiteralPath $pluginDir -Filter '*.plugin.ps1' -File -ErrorAction Stop | Sort-Object Name)
foreach ($pluginFile in $pluginFiles) {
  . $pluginFile.FullName
}

$script:StartedAtMs = Get-WindowsRuntimeEpochMilliseconds
Set-WindowsRuntimeHelperLogger -RuntimeContext $script:RuntimeContext

$requestKinds = @($script:RequestHandlers.Keys | Sort-Object)
$lifecycleNames = @($script:LifecycleHandlers | ForEach-Object {
  if ([string]::IsNullOrWhiteSpace([string]$_.Name)) {
    'unnamed'
  } else {
    [string]$_.Name
  }
})
Write-StructuredLog -Level 'info' -Category 'alt_o' -Message 'helper plugins loaded' -Fields @{
  request_kinds = ($requestKinds -join ',')
  lifecycle_handlers = ($lifecycleNames -join ',')
}

$watcher = $null
$eventIds = @()
try {
  Ensure-WindowsRuntimeDirectory -Path (Split-Path -Parent $StatePath)
  Ensure-WindowsRuntimeDirectory -Path $RequestDir

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
  Invoke-WindowsRuntimeLifecycleHook -HookName 'OnStart'
  Write-StructuredLog -Level 'info' -Category 'alt_o' -Message 'helper request directory watcher active' -Fields @{
    request_dir = $RequestDir
  }

  $lastHeartbeatMs = Get-WindowsRuntimeEpochMilliseconds
  Process-PendingRequests
  while ($true) {
    $nowMs = Get-WindowsRuntimeEpochMilliseconds
    if ($nowMs - $lastHeartbeatMs -ge $HeartbeatIntervalMs) {
      Write-HelperState -Ready '1'
      $lastHeartbeatMs = $nowMs
      Invoke-WindowsRuntimeLifecycleHook -HookName 'OnHeartbeat'
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
