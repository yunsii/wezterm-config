function Invoke-WindowsRuntimeChromeRequestImpl {
  param(
    [hashtable]$RuntimeContext,
    [object]$Payload,
    [string]$TraceId
  )

  $scriptPath = Join-Path $RuntimeContext.ScriptRoot 'focus-or-start-debug-chrome.ps1'
  return & $scriptPath `
    -ChromePath ([string]$Payload.chrome_path) `
    -RemoteDebuggingPort ([int]$Payload.remote_debugging_port) `
    -UserDataDir ([string]$Payload.user_data_dir) `
    -TraceId $TraceId `
    -DiagnosticsEnabled $RuntimeContext.Diagnostics.Enabled `
    -DiagnosticsCategoryEnabled $RuntimeContext.Diagnostics.CategoryEnabled `
    -DiagnosticsLevel $RuntimeContext.Diagnostics.Level `
    -DiagnosticsFile $RuntimeContext.Diagnostics.File `
    -DiagnosticsMaxBytes $RuntimeContext.Diagnostics.MaxBytes `
    -DiagnosticsMaxFiles $RuntimeContext.Diagnostics.MaxFiles `
    -ReturnResult
}

Register-WindowsRuntimeRequestHandler @{
  Name = 'chrome_debug'
  Kind = 'chrome_focus_or_start'
  Category = 'chrome'
  Source = 'windows-chrome'
  Handle = {
    param($RuntimeContext, $Payload, $TraceId)
    Invoke-WindowsRuntimeChromeRequestImpl -RuntimeContext $RuntimeContext -Payload $Payload -TraceId $TraceId
  }
}
