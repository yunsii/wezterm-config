function Get-WindowsRuntimeEpochMilliseconds {
  return [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
}

function Ensure-WindowsRuntimeDirectory {
  param(
    [string]$Path
  )

  if (-not [string]::IsNullOrWhiteSpace($Path)) {
    $null = New-Item -ItemType Directory -Force -Path $Path
  }
}

function Set-WindowsRuntimeHelperLogger {
  param(
    [hashtable]$RuntimeContext
  )

  $diagnostics = $RuntimeContext.Diagnostics
  Initialize-StructuredLog `
    -FilePath $diagnostics.File `
    -Enabled $diagnostics.Enabled `
    -CategoryEnabled $diagnostics.CategoryEnabled `
    -Level $diagnostics.Level `
    -Source 'windows-helper' `
    -TraceId '' `
    -MaxBytes $diagnostics.MaxBytes `
    -MaxFiles $diagnostics.MaxFiles
}

function Set-WindowsRuntimeRequestLogger {
  param(
    [hashtable]$RuntimeContext,
    [string]$TraceId,
    [string]$Source = 'windows-helper'
  )

  $diagnostics = $RuntimeContext.Diagnostics
  Initialize-StructuredLog `
    -FilePath $diagnostics.File `
    -Enabled $diagnostics.Enabled `
    -CategoryEnabled $diagnostics.CategoryEnabled `
    -Level $diagnostics.Level `
    -Source $Source `
    -TraceId $TraceId `
    -MaxBytes $diagnostics.MaxBytes `
    -MaxFiles $diagnostics.MaxFiles
}
