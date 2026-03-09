[CmdletBinding()]
param(
  [AllowNull()]
  [AllowEmptyString()]
  [string]$Mode
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$defaultModes = @('attributes', 'front-panel', 'block-diagram')
$supportedModes = [ordered]@{
  'attributes'    = 'attributes'
  'front-panel'   = 'front-panel'
  'block-diagram' = 'block-diagram'
}
$rejectedModes = [ordered]@{
  'default' = "Mode 'default' is not supported by comparevi-history public diagnostics because it masks scoped evidence. Use explicit modes: attributes, front-panel, block-diagram."
  'full'    = "Mode 'full' is not supported by comparevi-history public diagnostics because it collapses scoped evidence into one aggregate lane. Use explicit modes: attributes, front-panel, block-diagram."
  'all'     = "Mode 'all' is not supported by comparevi-history public diagnostics because it aliases the aggregate full lane. Use explicit modes: attributes, front-panel, block-diagram."
}

$requestedModes = New-Object System.Collections.Generic.List[string]
$seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)

$tokens = @(
  $Mode -split '[,;]'
  | ForEach-Object { $_.Trim() }
  | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
)

if ($tokens.Count -eq 0) {
  foreach ($defaultMode in $defaultModes) {
    $requestedModes.Add($defaultMode) | Out-Null
  }
} else {
  foreach ($token in $tokens) {
    $normalized = $token.ToLowerInvariant()
    if ($rejectedModes.Contains($normalized)) {
      throw $rejectedModes[$normalized]
    }
    if (-not $supportedModes.Contains($normalized)) {
      throw ("Unsupported comparevi-history public mode '{0}'. Supported modes: {1}" -f $token, ([string]::Join(', ', $defaultModes)))
    }
    if ($seen.Add($supportedModes[$normalized])) {
      $requestedModes.Add($supportedModes[$normalized]) | Out-Null
    }
  }
}

[pscustomobject]@{
  schema        = 'comparevi-history/public-mode-bundle@v1'
  requestedMode = $Mode
  defaultModes  = @($defaultModes)
  modes         = @($requestedModes.ToArray())
  modeList      = [string]::Join(', ', @($requestedModes.ToArray()))
  modeCount     = $requestedModes.Count
}
