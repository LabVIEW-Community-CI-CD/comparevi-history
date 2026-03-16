Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptPath = Join-Path $PSScriptRoot 'Resolve-CompareVIHistoryReleasePublishReadiness.ps1'
$repoRoot = Split-Path -Parent $PSScriptRoot
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("comparevi-history-release-publish-ready-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

function Assert-Equal {
  param(
    [Parameter(Mandatory = $true)]
    [object]$Actual,
    [Parameter(Mandatory = $true)]
    [object]$Expected,
    [Parameter(Mandatory = $true)]
    [string]$Message
  )

  if ($Actual -ne $Expected) {
    throw "$Message Expected '$Expected', actual '$Actual'."
  }
}

try {
  $trackedRelativePaths = @(
    'comparevi-backend-ref.txt',
    'docs/examples/comparevi-history-comment-gated.yml',
    'docs/SAFE_PR_DIAGNOSTICS_TEMPLATES.md'
  )
  foreach ($relativePath in $trackedRelativePaths) {
    $sourcePath = Join-Path $repoRoot $relativePath
    $destinationPath = Join-Path $tempRoot $relativePath
    $destinationDirectory = Split-Path -Parent $destinationPath
    if (-not (Test-Path -LiteralPath $destinationDirectory -PathType Container)) {
      New-Item -ItemType Directory -Path $destinationDirectory -Force | Out-Null
    }
    Copy-Item -LiteralPath $sourcePath -Destination $destinationPath -Force
  }

  $currentBackendRef = (Get-Content -LiteralPath (Join-Path $repoRoot 'comparevi-backend-ref.txt') -Raw).Trim()
  $commentTemplate = Get-Content -LiteralPath (Join-Path $repoRoot 'docs/examples/comparevi-history-comment-gated.yml') -Raw
  $immutableTagMatch = [regex]::Match($commentTemplate, '(?m)^\s*FACADE_REF:\s*(v[0-9]+\.[0-9]+\.[0-9]+)\s*$')
  if (-not $immutableTagMatch.Success) {
    throw 'Failed to resolve the current immutable tag from the published comment-gated template.'
  }
  $currentImmutableTag = $immutableTagMatch.Groups[1].Value
  $readinessOutputPath = Join-Path $tempRoot 'release-readiness.json'
  $githubOutputPath = Join-Path $tempRoot 'github-output.txt'

  $readyReceiptJson = & $scriptPath `
    -BackendTag $currentBackendRef `
    -ImmutableTag $currentImmutableTag `
    -RepoRoot $tempRoot `
    -OutputPath $readinessOutputPath `
    -GitHubOutputPath $githubOutputPath

  $readyReceipt = $readyReceiptJson | ConvertFrom-Json
  Assert-Equal -Actual $readyReceipt.schema -Expected 'comparevi-history/release-publish-readiness@v1' -Message 'Readiness schema mismatch.'
  Assert-Equal -Actual $readyReceipt.releaseContentReady -Expected $true -Message 'Expected repo copy to already be publish-ready.'
  Assert-Equal -Actual $readyReceipt.preparationRequired -Expected $false -Message 'Preparation should not be required for current repo state.'
  Assert-Equal -Actual $readyReceipt.changedFileCount -Expected 0 -Message 'Current repo state should not need content changes.'

  $writtenReceipt = Get-Content -LiteralPath $readinessOutputPath -Raw | ConvertFrom-Json
  Assert-Equal -Actual $writtenReceipt.releaseContentReady -Expected $true -Message 'Written readiness receipt mismatch.'

  $githubOutput = Get-Content -LiteralPath $githubOutputPath
  if (-not ($githubOutput -contains 'release-content-ready=true')) {
    throw 'GitHub output did not include release-content-ready=true.'
  }
  if (-not ($githubOutput -contains 'preparation-required=false')) {
    throw 'GitHub output did not include preparation-required=false.'
  }

  $driftReceipt = (& $scriptPath -BackendTag 'v9.9.9' -ImmutableTag 'v9.9.9' -RepoRoot $tempRoot) | ConvertFrom-Json
  Assert-Equal -Actual $driftReceipt.releaseContentReady -Expected $false -Message 'Expected synthetic drift to require prep.'
  Assert-Equal -Actual $driftReceipt.preparationRequired -Expected $true -Message 'PreparationRequired mismatch for synthetic drift.'
  if ($driftReceipt.changedFiles.Count -lt 3) {
    throw 'Expected synthetic drift to touch the backend pin and published template files.'
  }

  $failed = $false
  try {
    & $scriptPath -BackendTag 'v9.9.9' -ImmutableTag 'v9.9.9' -RepoRoot $tempRoot -FailIfPreparationRequired | Out-Null
  } catch {
    $failed = $_.Exception.Message -match 'already-reviewed main content'
  }

  if (-not $failed) {
    throw 'Expected -FailIfPreparationRequired to throw for synthetic drift.'
  }

  $corruptTemplatePath = Join-Path $tempRoot 'docs/examples/comparevi-history-comment-gated.yml'
  $corruptTemplate = Get-Content -LiteralPath $corruptTemplatePath -Raw
  $corruptTemplate = $corruptTemplate -replace '(?m)^\s*FACADE_REF:\s*v[0-9]+\.[0-9]+\.[0-9]+\s*$', '      # FACADE_REF removed for readiness failure coverage'
  $corruptTemplate | Set-Content -LiteralPath $corruptTemplatePath -Encoding utf8

  $syncValidationFailed = $false
  try {
    & $scriptPath -BackendTag $currentBackendRef -ImmutableTag $currentImmutableTag -RepoRoot $tempRoot | Out-Null
  } catch {
    $syncValidationFailed = $_.Exception.Message -match 'did not stamp the requested immutable'
  }

  if (-not $syncValidationFailed) {
    throw 'Expected readiness helper to fail when template sync cannot stamp the requested immutable tag.'
  }
} finally {
  Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
