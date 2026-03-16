[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string]$BackendTag,

  [Parameter(Mandatory = $true)]
  [string]$ImmutableTag,

  [string]$RepoRoot = (Split-Path -Parent $PSScriptRoot),

  [string]$OutputPath,

  [string]$GitHubOutputPath,

  [string]$StepSummaryPath,

  [switch]$FailIfPreparationRequired
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($BackendTag -notmatch '^v[0-9]+\.[0-9]+\.[0-9]+(?:[-+][0-9A-Za-z.-]+)?$') {
  throw "BackendTag must resolve to an immutable release tag. Actual: '$BackendTag'."
}

if ($ImmutableTag -notmatch '^v[0-9]+\.[0-9]+\.[0-9]+$') {
  throw "ImmutableTag must match v<major>.<minor>.<patch>. Actual: '$ImmutableTag'."
}

$repoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
$trackedRelativePaths = @(
  'comparevi-backend-ref.txt',
  'docs/examples/comparevi-history-comment-gated.yml',
  'docs/SAFE_PR_DIAGNOSTICS_TEMPLATES.md'
)

function Get-NormalizedTextContent {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path
  )

  $content = Get-Content -LiteralPath $Path -Raw
  $content = $content -replace "`r`n", "`n"
  $content = $content -replace "`r", "`n"
  return $content.TrimEnd("`n")
}

function Assert-Match {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Content,
    [Parameter(Mandatory = $true)]
    [string]$Pattern,
    [Parameter(Mandatory = $true)]
    [string]$Message
  )

  if ($Content -notmatch $Pattern) {
    throw $Message
  }
}

foreach ($relativePath in $trackedRelativePaths) {
  $absolutePath = Join-Path $repoRoot $relativePath
  if (-not (Test-Path -LiteralPath $absolutePath -PathType Leaf)) {
    throw "Release publish readiness input not found: $absolutePath"
  }
}

$stagingRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("comparevi-history-release-readiness-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $stagingRoot -Force | Out-Null

try {
  foreach ($relativePath in $trackedRelativePaths) {
    $sourcePath = Join-Path $repoRoot $relativePath
    $destinationPath = Join-Path $stagingRoot $relativePath
    $destinationDirectory = Split-Path -Parent $destinationPath
    if (-not (Test-Path -LiteralPath $destinationDirectory -PathType Container)) {
      New-Item -ItemType Directory -Path $destinationDirectory -Force | Out-Null
    }
    Copy-Item -LiteralPath $sourcePath -Destination $destinationPath -Force
  }

  $stagedBackendRefPath = Join-Path $stagingRoot 'comparevi-backend-ref.txt'
  Set-Content -LiteralPath $stagedBackendRefPath -Encoding utf8 -Value $BackendTag
  & (Join-Path $PSScriptRoot 'Sync-CompareVIHistoryPublishedTemplates.ps1') -ImmutableTag $ImmutableTag -RepoRoot $stagingRoot | Out-Null

  $stagedCommentTemplate = Get-Content -LiteralPath (Join-Path $stagingRoot 'docs/examples/comparevi-history-comment-gated.yml') -Raw
  $stagedSafeTemplates = Get-Content -LiteralPath (Join-Path $stagingRoot 'docs/SAFE_PR_DIAGNOSTICS_TEMPLATES.md') -Raw
  $escapedImmutableTag = [regex]::Escape($ImmutableTag)
  Assert-Match -Content $stagedCommentTemplate -Pattern "(?m)^\s*FACADE_REF:\s*$escapedImmutableTag\s*$" -Message 'Published comment-gated template sync did not stamp the requested immutable FACADE_REF.'
  Assert-Match -Content $stagedCommentTemplate -Pattern "(?m)^\s*uses:\s+LabVIEW-Community-CI-CD/comparevi-history@$escapedImmutableTag\s*$" -Message 'Published comment-gated template sync did not stamp the requested immutable uses: ref.'
  Assert-Match -Content $stagedCommentTemplate -Pattern "(?m)^\s*ACTION_REF:\s+LabVIEW-Community-CI-CD/comparevi-history@$escapedImmutableTag\s*$" -Message 'Published comment-gated template sync did not stamp the requested immutable ACTION_REF.'
  Assert-Match -Content $stagedSafeTemplates -Pattern "LabVIEW-Community-CI-CD/comparevi-history@$escapedImmutableTag" -Message 'Published safe-template docs did not stamp the requested immutable comparevi-history ref.'

  $changedFiles = New-Object System.Collections.Generic.List[string]
  foreach ($relativePath in $trackedRelativePaths) {
    $currentPath = Join-Path $repoRoot $relativePath
    $stagedPath = Join-Path $stagingRoot $relativePath
    $currentContent = Get-NormalizedTextContent -Path $currentPath
    $stagedContent = Get-NormalizedTextContent -Path $stagedPath
    if ($currentContent -ne $stagedContent) {
      $changedFiles.Add($relativePath)
    }
  }

  $currentBackendRef = (Get-Content -LiteralPath (Join-Path $repoRoot 'comparevi-backend-ref.txt') -Raw).Trim()
  $releaseContentReady = ($changedFiles.Count -eq 0)
  $preparationHint = if ($releaseContentReady) {
    $null
  } else {
    "Merge a prep PR to main that updates $($changedFiles -join ', '), then rerun release.yml with publish=true."
  }

  $receipt = [ordered]@{
    schema                 = 'comparevi-history/release-publish-readiness@v1'
    generatedAtUtc         = [DateTime]::UtcNow.ToString('o')
    repoRoot               = $repoRoot
    backendTag             = $BackendTag
    immutableTag           = $ImmutableTag
    currentBackendRef      = $currentBackendRef
    releaseContentReady    = $releaseContentReady
    preparationRequired    = (-not $releaseContentReady)
    changedFileCount       = $changedFiles.Count
    changedFiles           = @($changedFiles)
    preparationHint        = $preparationHint
  }

  if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
    $outputDirectory = Split-Path -Parent $OutputPath
    if (-not [string]::IsNullOrWhiteSpace($outputDirectory) -and -not (Test-Path -LiteralPath $outputDirectory -PathType Container)) {
      New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
    }
    $receipt | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $OutputPath -Encoding utf8
  }

  if (-not [string]::IsNullOrWhiteSpace($GitHubOutputPath)) {
    @(
      ("release-content-ready={0}" -f $receipt.releaseContentReady.ToString().ToLowerInvariant())
      ("preparation-required={0}" -f $receipt.preparationRequired.ToString().ToLowerInvariant())
      ("changed-file-count={0}" -f $receipt.changedFileCount)
      ("changed-files-json={0}" -f (($receipt.changedFiles | ConvertTo-Json -Compress)))
    ) | Out-File -FilePath $GitHubOutputPath -Encoding utf8 -Append

    if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
      ("readiness-report-path={0}" -f $OutputPath) | Out-File -FilePath $GitHubOutputPath -Encoding utf8 -Append
    }
  }

  if (-not [string]::IsNullOrWhiteSpace($StepSummaryPath)) {
    $summaryLines = @(
      '## comparevi-history release publish readiness'
      ''
      ('- Backend tag: `{0}`' -f $BackendTag)
      ('- Immutable tag: `{0}`' -f $ImmutableTag)
      ('- Current backend ref: `{0}`' -f $currentBackendRef)
      ('- Release content ready on `main`: `{0}`' -f $receipt.releaseContentReady.ToString().ToLowerInvariant())
      ('- Changed file count: `{0}`' -f $receipt.changedFileCount)
    )

    if ($changedFiles.Count -gt 0) {
      $summaryLines += ''
      $summaryLines += 'Preparation required before publish:'
      foreach ($relativePath in $changedFiles) {
        $summaryLines += ('- `{0}`' -f $relativePath)
      }
      $summaryLines += ''
      $summaryLines += $preparationHint
    }

    $summaryLines | Out-File -FilePath $StepSummaryPath -Encoding utf8 -Append
  }

  if ($FailIfPreparationRequired -and -not $releaseContentReady) {
    throw ("Release publish requires already-reviewed main content. Merge a prep PR that updates {0}, then rerun release.yml with publish=true." -f ($changedFiles -join ', '))
  }

  $receipt | ConvertTo-Json -Depth 10
} finally {
  Remove-Item -LiteralPath $stagingRoot -Recurse -Force -ErrorAction SilentlyContinue
}
