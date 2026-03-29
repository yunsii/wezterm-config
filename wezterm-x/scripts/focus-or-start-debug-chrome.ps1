param(
  [string]$ChromePath = "chrome.exe",
  [int]$RemoteDebuggingPort = 9222,
  [string]$UserDataDir = "$env:LOCALAPPDATA\ChromeDebugProfile"
)

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public static class ChromeWindow {
  [DllImport("user32.dll")]
  public static extern bool IsIconic(IntPtr hWnd);

  [DllImport("user32.dll")]
  public static extern bool SetForegroundWindow(IntPtr hWnd);

  [DllImport("user32.dll")]
  public static extern bool ShowWindowAsync(IntPtr hWnd, int nCmdShow);
}
"@

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
  $showCode = if ([ChromeWindow]::IsIconic($windowHandle)) { 9 } else { 5 }
  [ChromeWindow]::ShowWindowAsync($windowHandle, $showCode) | Out-Null
  Start-Sleep -Milliseconds 50

  if ([ChromeWindow]::SetForegroundWindow($windowHandle)) {
    return $true
  }

  $wshell = New-Object -ComObject WScript.Shell
  return [bool]$wshell.AppActivate($Process.Id)
}

try {
  $existingWindow = Get-DebugChromeProcess -Port $RemoteDebuggingPort -ProfileDir $UserDataDir

  if ($existingWindow) {
    if (Restore-AndActivateWindow -Process $existingWindow) {
      exit 0
    }
  }

  Start-Process -FilePath $ChromePath -ArgumentList @(
    "--remote-debugging-port=$RemoteDebuggingPort",
    "--user-data-dir=$UserDataDir"
  )
} catch {
  exit 1
}
