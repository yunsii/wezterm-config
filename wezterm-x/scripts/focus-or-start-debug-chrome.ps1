param(
  [string]$ChromePath = "chrome.exe",
  [int]$RemoteDebuggingPort = 9222,
  [string]$UserDataDir = "$env:LOCALAPPDATA\ChromeDebugProfile",
  [string]$TraceId = '',
  [string]$DiagnosticsEnabled = '0',
  [string]$DiagnosticsCategoryEnabled = '0',
  [string]$DiagnosticsLevel = 'info',
  [string]$DiagnosticsFile = '',
  [int]$DiagnosticsMaxBytes = 0,
  [int]$DiagnosticsMaxFiles = 0,
  [switch]$ReturnResult
)

if (-not ([System.Management.Automation.PSTypeName]'ChromeFocusWindow').Type) {
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public static class ChromeFocusWindow {
  [DllImport("user32.dll")]
  public static extern bool IsWindow(IntPtr hWnd);

  [DllImport("user32.dll")]
  public static extern bool IsIconic(IntPtr hWnd);

  [DllImport("user32.dll")]
  public static extern bool SetForegroundWindow(IntPtr hWnd);

  [DllImport("user32.dll")]
  public static extern bool ShowWindowAsync(IntPtr hWnd, int nCmdShow);

  [DllImport("user32.dll")]
  public static extern IntPtr GetForegroundWindow();

  [DllImport("user32.dll")]
  public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);

  [DllImport("kernel32.dll")]
  public static extern uint GetCurrentThreadId();

  [DllImport("user32.dll")]
  public static extern bool AttachThreadInput(uint idAttach, uint idAttachTo, bool fAttach);

  [DllImport("user32.dll")]
  public static extern bool BringWindowToTop(IntPtr hWnd);

  [DllImport("user32.dll")]
  public static extern IntPtr SetActiveWindow(IntPtr hWnd);

  [DllImport("user32.dll")]
  public static extern IntPtr SetFocus(IntPtr hWnd);
}
"@
}

. (Join-Path (Split-Path -Parent $PSCommandPath) 'windows-structured-log.ps1')
Initialize-StructuredLog `
  -FilePath $DiagnosticsFile `
  -Enabled $DiagnosticsEnabled `
  -CategoryEnabled $DiagnosticsCategoryEnabled `
  -Level $DiagnosticsLevel `
  -Source 'windows-chrome' `
  -TraceId $TraceId `
  -MaxBytes $DiagnosticsMaxBytes `
  -MaxFiles $DiagnosticsMaxFiles

$script:ChromeStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
$script:WscriptShell = $null

function Get-WscriptShell {
  if ($null -eq $script:WscriptShell) {
    $script:WscriptShell = New-Object -ComObject WScript.Shell
  }

  return $script:WscriptShell
}

function Get-DebugChromeProcess {
  param(
    [int]$Port,
    [string]$ProfileDir
  )

  $matchingProcesses = @(Get-CimInstance Win32_Process -Filter "Name = 'chrome.exe'" | Where-Object {
    $_.CommandLine -and
    $_.CommandLine.Contains("--remote-debugging-port=$Port") -and
    $_.CommandLine.Contains($ProfileDir)
  })

  foreach ($candidate in $matchingProcesses) {
    $process = Get-Process -Id $candidate.ProcessId -ErrorAction SilentlyContinue
    if ($process -and $process.MainWindowHandle -ne 0) {
      return $process
    }
  }

  return $null
}

function Restore-AndActivateWindow {
  param(
    [System.Diagnostics.Process]$Process
  )

  if (-not $Process -or $Process.MainWindowHandle -eq 0) {
    return $false
  }

  $windowHandle = [IntPtr]$Process.MainWindowHandle
  if ($windowHandle -eq [IntPtr]::Zero -or -not [ChromeFocusWindow]::IsWindow($windowHandle)) {
    return $false
  }

  $showCode = if ([ChromeFocusWindow]::IsIconic($windowHandle)) { 9 } else { 5 }
  [ChromeFocusWindow]::ShowWindowAsync($windowHandle, $showCode) | Out-Null
  Start-Sleep -Milliseconds 5

  $foregroundWindow = [ChromeFocusWindow]::GetForegroundWindow()
  [uint32]$foregroundProcessId = 0
  $foregroundThreadId = 0
  if ($foregroundWindow -ne [IntPtr]::Zero) {
    $foregroundThreadId = [ChromeFocusWindow]::GetWindowThreadProcessId($foregroundWindow, [ref]$foregroundProcessId)
  }

  [uint32]$targetProcessId = 0
  $targetThreadId = [ChromeFocusWindow]::GetWindowThreadProcessId($windowHandle, [ref]$targetProcessId)
  $currentThreadId = [ChromeFocusWindow]::GetCurrentThreadId()

  $attachedToForeground = $false
  $attachedToTarget = $false

  try {
    if ($foregroundThreadId -ne 0 -and $foregroundThreadId -ne $currentThreadId) {
      $attachedToForeground = [ChromeFocusWindow]::AttachThreadInput($currentThreadId, $foregroundThreadId, $true)
    }

    if ($targetThreadId -ne 0 -and $targetThreadId -ne $currentThreadId) {
      $attachedToTarget = [ChromeFocusWindow]::AttachThreadInput($currentThreadId, $targetThreadId, $true)
    }

    [ChromeFocusWindow]::BringWindowToTop($windowHandle) | Out-Null
    [ChromeFocusWindow]::SetActiveWindow($windowHandle) | Out-Null
    [ChromeFocusWindow]::SetFocus($windowHandle) | Out-Null

    $wshell = Get-WscriptShell
    $wshell.SendKeys('%')
    Start-Sleep -Milliseconds 5

    if ([ChromeFocusWindow]::SetForegroundWindow($windowHandle)) {
      return $true
    }
  } finally {
    if ($attachedToTarget) {
      [ChromeFocusWindow]::AttachThreadInput($currentThreadId, $targetThreadId, $false) | Out-Null
    }

    if ($attachedToForeground) {
      [ChromeFocusWindow]::AttachThreadInput($currentThreadId, $foregroundThreadId, $false) | Out-Null
    }
  }

  $wshell = Get-WscriptShell
  return [bool]$wshell.AppActivate($Process.Id)
}

try {
  $existingWindow = Get-DebugChromeProcess -Port $RemoteDebuggingPort -ProfileDir $UserDataDir

  if ($existingWindow) {
    if (Restore-AndActivateWindow -Process $existingWindow) {
      Write-StructuredLog -Level 'info' -Category 'chrome' -Message 'focused cached debug chrome window' -Fields @{
        pid = $existingWindow.Id
        port = $RemoteDebuggingPort
        user_data_dir = $UserDataDir
        total_duration_ms = $script:ChromeStopwatch.ElapsedMilliseconds
      }
      if ($ReturnResult) {
        return @{
          status = 'focused_cached_window'
          pid = $existingWindow.Id
          total_duration_ms = $script:ChromeStopwatch.ElapsedMilliseconds
        }
      }
      exit 0
    }
  }

  Start-Process -FilePath $ChromePath -ArgumentList @(
    "--remote-debugging-port=$RemoteDebuggingPort",
    "--user-data-dir=$UserDataDir"
  )
  Write-StructuredLog -Level 'info' -Category 'chrome' -Message 'launched debug chrome' -Fields @{
    chrome_path = $ChromePath
    port = $RemoteDebuggingPort
    user_data_dir = $UserDataDir
    total_duration_ms = $script:ChromeStopwatch.ElapsedMilliseconds
  }
  if ($ReturnResult) {
    return @{
      status = 'launched'
      total_duration_ms = $script:ChromeStopwatch.ElapsedMilliseconds
    }
  }
} catch {
  Write-StructuredLog -Level 'error' -Category 'chrome' -Message 'failed to focus or start debug chrome' -Fields @{
    chrome_path = $ChromePath
    port = $RemoteDebuggingPort
    user_data_dir = $UserDataDir
    error = $_.Exception.Message
    total_duration_ms = $script:ChromeStopwatch.ElapsedMilliseconds
  }
  if ($ReturnResult) {
    return @{
      status = 'failed'
      error = $_.Exception.Message
      total_duration_ms = $script:ChromeStopwatch.ElapsedMilliseconds
    }
  }
  exit 1
}
