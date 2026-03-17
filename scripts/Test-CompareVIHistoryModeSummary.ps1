Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptPath = Join-Path $PSScriptRoot 'Format-CompareVIHistoryModeSummary.ps1'
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("comparevi-history-mode-summary-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

function New-CaptureArtifact {
  param(
    [Parameter(Mandatory = $true)]
    [string]$ArtifactDir
  )

  $imagesDir = Join-Path $ArtifactDir 'cli-images'
  New-Item -ItemType Directory -Path $imagesDir -Force | Out-Null
  [System.IO.File]::WriteAllBytes((Join-Path $imagesDir 'cli-image-00.png'), @(0xCA, 0xFE, 0xBA, 0xBE))

  [ordered]@{
    schema = 'lvcompare-capture-v1'
    environment = [ordered]@{
      cli = [ordered]@{
        artifacts = [ordered]@{
          images = @(
            [ordered]@{
              index = 0
              mimeType = 'image/png'
              byteLength = 4
              savedPath = (Join-Path $imagesDir 'cli-image-00.png')
            }
          )
        }
      }
    }
  } | ConvertTo-Json -Depth 32 | Set-Content -LiteralPath (Join-Path $ArtifactDir 'lvcompare-capture.json') -Encoding utf8
}

try {
  $outputPath = Join-Path $tempRoot 'mode-summary.md'
  $jsonOutputPath = Join-Path $tempRoot 'mode-summary.json'
  $githubOutputPath = Join-Path $tempRoot 'github-output.txt'

  $fullDir = Join-Path $tempRoot 'full'
  $fullArtifactDir = Join-Path $fullDir 'pair-001-artifacts'
  New-Item -ItemType Directory -Path $fullDir -Force | Out-Null
  New-CaptureArtifact -ArtifactDir $fullArtifactDir
  $fullManifestPath = Join-Path $fullDir 'manifest.json'
  [ordered]@{
    schema = 'vi-compare/history@v1'
    flags = @()
    comparisons = @(
      [ordered]@{
        result = [ordered]@{
          artifactDir = $fullArtifactDir
        }
      }
    )
    stats = [ordered]@{
      categoryCounts = [ordered]@{
        '<div class="dropdown-left">First VI: /compare/m0/Base.vi</div><div class="dropdown-right">Second VI: /compare/m0/Head.vi</div>' = 2
        'Block Diagram Cosmetic' = 1
        'Block Diagram objects' = 2
      }
      bucketCounts = [ordered]@{
        'metadata-rich' = 1
      }
    }
  } | ConvertTo-Json -Depth 32 | Set-Content -LiteralPath $fullManifestPath -Encoding utf8

  $modeJson = @(
    [ordered]@{
      mode = 'full'
      processed = 2
      diffs = 1
      signalDiffs = 1
      noiseCollapsed = 0
      errors = 0
      status = 'ok'
      manifest = $fullManifestPath
      flags = @()
      categoryCounts = [ordered]@{
        '<div class="dropdown-left">First VI: /compare/m0/Base.vi</div><div class="dropdown-right">Second VI: /compare/m0/Head.vi</div>' = 2
        'Block Diagram Cosmetic' = 1
        'Block Diagram objects' = 2
      }
      bucketCounts = [ordered]@{
        'metadata-rich' = 1
      }
    }
    [ordered]@{
      mode = 'attributes'
      processed = 2
      diffs = 0
      signalDiffs = 0
      noiseCollapsed = 0
      errors = 0
      status = 'ok'
      flags = @('-noattr')
    }
  ) | ConvertTo-Json -Depth 32 -Compress

  $summary = & $scriptPath `
    -RequestedModeList 'full,attributes' `
    -ExecutedModeList 'attributes,full' `
    -ModeManifestsJson $modeJson `
    -TotalProcessed '2' `
    -TotalDiffs '1' `
    -StopReason 'max-pairs' `
    -NoisePolicy 'include' `
    -OutputPath $outputPath `
    -JsonOutputPath $jsonOutputPath `
    -GitHubOutputPath $githubOutputPath

  if ($summary -notmatch 'Requested modes: `attributes, full`') {
    throw 'Summary did not include normalized requested modes.'
  }
  if ($summary -notmatch 'Noise policy: `include`') {
    throw 'Summary did not surface the requested noise policy.'
  }
  if ($summary -notmatch 'Suppression profile: `mixed`') {
    throw 'Summary did not surface the aggregate suppression profile.'
  }
  if ($summary -notmatch 'Metadata surfaces: `captures=1, images=1, artifact-dirs=1, mime-types=image/png`') {
    throw 'Summary did not surface the aggregate capture metadata.'
  }
  if ($summary -notmatch 'Category counts: `Block Diagram Cosmetic \(1\), Block Diagram objects \(2\)`') {
    throw 'Summary did not surface normalized category counts.'
  }
  if ($summary -notmatch 'Comparison pairs: `/compare/m0/Base\.vi -> /compare/m0/Head\.vi \(2\)`') {
    throw 'Summary did not surface structured comparison pairs.'
  }
  if ($summary -notmatch 'Bucket counts: `metadata-rich \(1\)`') {
    throw 'Summary did not surface bucket counts.'
  }
  if ($summary -match '<div class=') {
    throw 'Summary must not leak raw HTML category markup.'
  }
  if ($summary -notmatch '\| full \| unsuppressed \| none \| 2 \| 1 \| 1 \| in-band \| captures=1; images=1 \| ok \|') {
    throw 'Summary did not include the raw full-mode row.'
  }
  if ($summary -notmatch '- full: `categories=Block Diagram Cosmetic \(1\), Block Diagram objects \(2\); comparison-pairs=/compare/m0/Base\.vi -> /compare/m0/Head\.vi \(2\); buckets=metadata-rich \(1\); metadata=captures:1, images:1, artifact-dirs:1, mime-types:image/png`') {
    throw 'Summary did not include the per-mode metadata detail line.'
  }
  if (-not (Test-Path -LiteralPath $outputPath -PathType Leaf)) {
    throw 'Mode summary output file was not written.'
  }
  if (-not (Test-Path -LiteralPath $jsonOutputPath -PathType Leaf)) {
    throw 'Mode summary JSON output file was not written.'
  }

  $modeSummaryJson = Get-Content -LiteralPath $jsonOutputPath -Raw | ConvertFrom-Json -Depth 64
  if ($modeSummaryJson.schema -ne 'comparevi-history/mode-summary@v1') {
    throw 'Mode summary JSON schema mismatch.'
  }
  if ($modeSummaryJson.suppressionProfile -ne 'mixed') {
    throw 'Mode summary JSON suppression profile mismatch.'
  }
  if ($modeSummaryJson.metadata.captureCount -ne 1 -or $modeSummaryJson.metadata.imageArtifactCount -ne 1) {
    throw 'Mode summary JSON metadata counts mismatch.'
  }
  if ($modeSummaryJson.categoryCounts.PSObject.Properties.Name -match 'First VI') {
    throw 'Mode summary JSON category counts must not retain comparison identity fragments.'
  }
  if ($modeSummaryJson.categoryCounts.'Block Diagram Cosmetic' -ne 1 -or $modeSummaryJson.categoryCounts.'Block Diagram objects' -ne 2) {
    throw 'Mode summary JSON normalized category counts mismatch.'
  }
  if ($modeSummaryJson.comparisonPairs.Count -ne 1) {
    throw 'Mode summary JSON comparison pair count mismatch.'
  }
  if ($modeSummaryJson.comparisonPairs[0].firstPath -ne '/compare/m0/Base.vi' -or $modeSummaryJson.comparisonPairs[0].secondPath -ne '/compare/m0/Head.vi' -or $modeSummaryJson.comparisonPairs[0].count -ne 2) {
    throw 'Mode summary JSON comparison pair normalization mismatch.'
  }
  if (($modeSummaryJson.metadata.imageMimeTypes -join ',') -ne 'image/png') {
    throw 'Mode summary JSON mime-type aggregation mismatch.'
  }

  $githubOutput = Get-Content -LiteralPath $githubOutputPath -Raw
  if ($githubOutput -notmatch 'mode-summary-markdown<<') {
    throw 'GitHub output did not include mode-summary-markdown.'
  }
  if ($githubOutput -notmatch 'mode-summary-json-path=') {
    throw 'GitHub output did not include mode-summary-json-path.'
  }

  $legacyModeJson = [ordered]@{
    mode = 'default'
    processed = 1
    diffs = 1
    status = 'ok'
  } | ConvertTo-Json -Depth 8 -Compress

  $legacySummary = & $scriptPath `
    -RequestedModeList '' `
    -ExecutedModeList '' `
    -ModeManifestsJson $legacyModeJson `
    -TotalProcessed '1' `
    -TotalDiffs '1'

  if ($legacySummary -notmatch 'Requested modes: `default`') {
    throw 'Legacy summary did not derive requested modes from mode-manifests-json.'
  }
  if ($legacySummary -notmatch '\| default \| unsuppressed \| none \| 1 \| 1 \| 0 \| 0 \| captures=0; images=0 \| ok \|') {
    throw 'Legacy summary did not fall back missing per-mode fields to zero.'
  }

  $emptyJsonOutputPath = Join-Path $tempRoot 'empty-mode-summary.json'
  $emptySummary = & $scriptPath `
    -RequestedModeList 'full' `
    -ExecutedModeList '' `
    -ModeManifestsJson '' `
    -TotalProcessed '' `
    -TotalDiffs '' `
    -StopReason 'facade-step-failed' `
    -NoisePolicy 'include' `
    -JsonOutputPath $emptyJsonOutputPath

  if ($emptySummary -notmatch 'Requested modes: `full`') {
    throw 'Empty mode summary did not preserve the requested mode list.'
  }
  if ($emptySummary -notmatch 'Executed modes: `n/a`') {
    throw 'Empty mode summary did not keep executed modes empty.'
  }
  if ($emptySummary -notmatch 'Suppression profile: `unknown`') {
    throw 'Empty mode summary did not degrade suppression profile to unknown.'
  }
  if ($emptySummary -notmatch 'Total processed: `0`') {
    throw 'Empty mode summary did not fall back total processed to zero.'
  }
  if ($emptySummary -notmatch 'Total diffs: `0`') {
    throw 'Empty mode summary did not fall back total diffs to zero.'
  }
  if ($emptySummary -notmatch 'Stop reason: `facade-step-failed`') {
    throw 'Empty mode summary did not preserve the stop reason.'
  }

  $emptySummaryJson = Get-Content -LiteralPath $emptyJsonOutputPath -Raw | ConvertFrom-Json -Depth 64
  if ($emptySummaryJson.suppressionProfile -ne 'unknown') {
    throw 'Empty mode summary JSON suppression profile mismatch.'
  }
  if ($emptySummaryJson.totalProcessed -ne 0 -or $emptySummaryJson.totalDiffs -ne 0) {
    throw 'Empty mode summary JSON totals mismatch.'
  }
  if ($emptySummaryJson.metadata.captureCount -ne 0 -or $emptySummaryJson.metadata.imageArtifactCount -ne 0) {
    throw 'Empty mode summary JSON metadata counts mismatch.'
  }
} finally {
  Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
