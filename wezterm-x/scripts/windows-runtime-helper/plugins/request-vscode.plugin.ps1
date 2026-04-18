function Invoke-WindowsRuntimeVscodeRequestImpl {
  param(
    [hashtable]$RuntimeContext,
    [object]$Payload,
    [string]$TraceId
  )

  $codeArgs = @()
  foreach ($item in @($Payload.code_command)) {
    $codeArgs += [string]$item
  }

  $scriptPath = Join-Path $RuntimeContext.ScriptRoot 'focus-or-open-vscode.ps1'
  return & $scriptPath `
    -RequestedDir ([string]$Payload.requested_dir) `
    -Distro ([string]$Payload.distro) `
    -CodeArg $codeArgs `
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
  Name = 'vscode'
  Kind = 'vscode_focus_or_open'
  Category = 'alt_o'
  Source = 'windows-alt-o'
  Handle = {
    param($RuntimeContext, $Payload, $TraceId)
    Invoke-WindowsRuntimeVscodeRequestImpl -RuntimeContext $RuntimeContext -Payload $Payload -TraceId $TraceId
  }
}
