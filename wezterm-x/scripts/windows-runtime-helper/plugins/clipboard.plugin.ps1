function Get-WindowsRuntimeClipboardListenerState {
  param(
    [hashtable]$RuntimeContext
  )

  $statePath = [string]$RuntimeContext.Clipboard.StatePath
  if ([string]::IsNullOrWhiteSpace($statePath) -or -not (Test-Path -LiteralPath $statePath)) {
    return $null
  }

  try {
    $state = @{}
    foreach ($line in Get-Content -LiteralPath $statePath -ErrorAction Stop) {
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

function Get-WindowsRuntimeStandaloneClipboardListenerProcesses {
  param(
    [hashtable]$RuntimeContext
  )

  $listenerScriptPath = [string]$RuntimeContext.Clipboard.ListenerScriptPath
  if ([string]::IsNullOrWhiteSpace($listenerScriptPath)) {
    return @()
  }

  return @(Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" | Where-Object {
    if (-not $_.CommandLine) {
      return $false
    }

    return $_.CommandLine.Contains("-File $listenerScriptPath")
  })
}

function Test-WindowsRuntimeClipboardListenerStateFresh {
  param(
    [hashtable]$RuntimeContext,
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

  if ((Get-WindowsRuntimeEpochMilliseconds) - $heartbeatAtMs -gt ([int]$RuntimeContext.Clipboard.HeartbeatTimeoutSeconds * 1000)) {
    return $false
  }

  return $true
}

function Stop-WindowsRuntimeStandaloneClipboardListenerProcesses {
  param(
    [hashtable]$RuntimeContext
  )

  $listenerScriptPath = [string]$RuntimeContext.Clipboard.ListenerScriptPath
  $processes = @(Get-WindowsRuntimeStandaloneClipboardListenerProcesses -RuntimeContext $RuntimeContext)
  foreach ($process in $processes) {
    try {
      Stop-Process -Id $process.ProcessId -Force -ErrorAction Stop
      Write-StructuredLog -Level 'info' -Category 'clipboard' -Message 'host stopped standalone clipboard listener process' -Fields @{
        pid = $process.ProcessId
        listener_script_path = $listenerScriptPath
      }
    } catch {
      Write-StructuredLog -Level 'warn' -Category 'clipboard' -Message 'host failed to stop standalone clipboard listener process' -Fields @{
        pid = $process.ProcessId
        listener_script_path = $listenerScriptPath
        error = $_.Exception.Message
      }
    }
  }
}

function Ensure-WindowsRuntimeClipboardListenerRunning {
  param(
    [hashtable]$RuntimeContext
  )

  $clipboard = $RuntimeContext.Clipboard
  $listenerScriptPath = [string]$clipboard.ListenerScriptPath
  if ([string]::IsNullOrWhiteSpace($listenerScriptPath) -or -not (Test-Path -LiteralPath $listenerScriptPath)) {
    return
  }

  $state = Get-WindowsRuntimeClipboardListenerState -RuntimeContext $RuntimeContext
  if (Test-WindowsRuntimeClipboardListenerStateFresh -RuntimeContext $RuntimeContext -State $state) {
    return
  }

  Stop-WindowsRuntimeStandaloneClipboardListenerProcesses -RuntimeContext $RuntimeContext

  $arguments = @(
    '-NoProfile',
    '-NonInteractive',
    '-STA',
    '-WindowStyle', 'Hidden',
    '-ExecutionPolicy', 'Bypass',
    '-File', $listenerScriptPath
  )

  if (-not [string]::IsNullOrWhiteSpace([string]$clipboard.WslDistro)) {
    $arguments += @('-WslDistro', [string]$clipboard.WslDistro)
  }
  if (-not [string]::IsNullOrWhiteSpace([string]$clipboard.StatePath)) {
    $arguments += @('-StatePath', [string]$clipboard.StatePath)
  }
  if (-not [string]::IsNullOrWhiteSpace([string]$clipboard.LogPath)) {
    $arguments += @('-LogPath', [string]$clipboard.LogPath)
  }
  if (-not [string]::IsNullOrWhiteSpace([string]$clipboard.OutputDir)) {
    $arguments += @('-OutputDir', [string]$clipboard.OutputDir)
  }
  $arguments += @(
    '-HeartbeatIntervalSeconds', [string]$clipboard.HeartbeatIntervalSeconds,
    '-ImageReadRetryCount', [string]$clipboard.ImageReadRetryCount,
    '-ImageReadRetryDelayMs', [string]$clipboard.ImageReadRetryDelayMs,
    '-CleanupMaxAgeHours', [string]$clipboard.CleanupMaxAgeHours,
    '-CleanupMaxFiles', [string]$clipboard.CleanupMaxFiles
  )

  $child = Start-Process -FilePath $RuntimeContext.PowerShellExe -ArgumentList $arguments -PassThru
  Write-StructuredLog -Level 'info' -Category 'clipboard' -Message 'host started clipboard listener' -Fields @{
    child_pid = $child.Id
    listener_script_path = $listenerScriptPath
    state_path = [string]$clipboard.StatePath
  }
}

Register-WindowsRuntimeLifecycleHandler @{
  Name = 'clipboard_listener'
  OnStart = {
    param($RuntimeContext)
    Ensure-WindowsRuntimeClipboardListenerRunning -RuntimeContext $RuntimeContext
  }
  OnHeartbeat = {
    param($RuntimeContext)
    Ensure-WindowsRuntimeClipboardListenerRunning -RuntimeContext $RuntimeContext
  }
}
