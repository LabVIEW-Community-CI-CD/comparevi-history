Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptPath = Join-Path $PSScriptRoot 'Resolve-CompareVIHistoryPublicModes.ps1'

function Assert-Equal {
  param(
    [Parameter(Mandatory = $true)]$Actual,
    [Parameter(Mandatory = $true)]$Expected,
    [Parameter(Mandatory = $true)][string]$Message
  )

  if ($Actual -is [System.Array] -or $Expected -is [System.Array]) {
    $actualArray = @($Actual)
    $expectedArray = @($Expected)
    if ($actualArray.Count -ne $expectedArray.Count) {
      throw "$Message Expected count $($expectedArray.Count), actual $($actualArray.Count)."
    }
    for ($idx = 0; $idx -lt $expectedArray.Count; $idx++) {
      if ([string]$actualArray[$idx] -ne [string]$expectedArray[$idx]) {
        throw "$Message Expected '$($expectedArray[$idx])' at index $idx, actual '$($actualArray[$idx])'."
      }
    }
    return
  }

  if ($Actual -ne $Expected) {
    throw "$Message Expected '$Expected', actual '$Actual'."
  }
}

function Assert-ThrowsLike {
  param(
    [Parameter(Mandatory = $true)][scriptblock]$ScriptBlock,
    [Parameter(Mandatory = $true)][string]$Pattern,
    [Parameter(Mandatory = $true)][string]$Message
  )

  try {
    & $ScriptBlock
  } catch {
    if ($_.Exception.Message -match $Pattern) {
      return
    }
    throw "$Message Unexpected error: $($_.Exception.Message)"
  }

  throw "$Message Expected an exception matching '$Pattern'."
}

$defaultBundle = & $scriptPath
Assert-Equal -Actual $defaultBundle.schema -Expected 'comparevi-history/public-mode-bundle@v1' -Message 'Default bundle schema mismatch.'
Assert-Equal -Actual @($defaultBundle.modes) -Expected @('attributes', 'front-panel', 'block-diagram') -Message 'Default bundle modes mismatch.'
Assert-Equal -Actual $defaultBundle.modeList -Expected 'attributes, front-panel, block-diagram' -Message 'Default bundle modeList mismatch.'

$normalizedBundle = & $scriptPath -Mode ' Front-Panel ; attributes ; BLOCK-DIAGRAM ; attributes '
Assert-Equal -Actual @($normalizedBundle.modes) -Expected @('front-panel', 'attributes', 'block-diagram') -Message 'Normalized bundle modes mismatch.'
Assert-Equal -Actual $normalizedBundle.modeCount -Expected 3 -Message 'Normalized bundle count mismatch.'

Assert-ThrowsLike -ScriptBlock { & $scriptPath -Mode 'default' | Out-Null } -Pattern "Mode 'default' is not supported" -Message 'Default mode rejection mismatch.'
Assert-ThrowsLike -ScriptBlock { & $scriptPath -Mode 'full' | Out-Null } -Pattern "Mode 'full' is not supported" -Message 'Full mode rejection mismatch.'
Assert-ThrowsLike -ScriptBlock { & $scriptPath -Mode 'custom' | Out-Null } -Pattern 'Unsupported comparevi-history public mode' -Message 'Unknown mode rejection mismatch.'
