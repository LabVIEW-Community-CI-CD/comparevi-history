Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptPath = Join-Path $PSScriptRoot 'Write-CompareVIHistoryCorpusIndex.ps1'
$schemaPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'docs' 'schemas' 'comparevi-history-corpus-index-v1.schema.json'
$pageSchemaPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'docs' 'schemas' 'comparevi-history-corpus-page-v1.schema.json'
$manifestSchemaPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'docs' 'schemas' 'comparevi-history-downstream-processing-manifest-v1.schema.json'
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("comparevi-history-corpus-index-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

function New-SharedEvidenceJson {
  param(
    [string]$ConsumerRepository,
    [string]$ConsumerRef,
    [string]$TargetPath,
    [AllowNull()][string]$TargetId,
    [string]$SourceSchema,
    [string]$SourcePath,
    [string]$NoisePolicy,
    [string]$FinalStatus,
    [string]$FinalReason,
    [string]$ReplayStatus,
    [string]$ReplayReason,
    [string]$SuppressionProfile,
    [int]$PreviewImageCount,
    [int]$ComparisonArtifactCount,
    [int]$ImageArtifactCount,
    [int]$CaptureCount,
    [int]$TotalDiffs,
    [int]$TotalProcessed
  )

  $previewImages = @()
  for ($i = 0; $i -lt $PreviewImageCount; $i++) {
    $previewImages += [ordered]@{
      scope = 'run'
      chunkId = $null
      mode = 'attributes'
      category = 'Block Diagram objects'
      comparisonPair = [ordered]@{ firstPath = '/compare/base.vi'; secondPath = '/compare/head.vi' }
      mimeType = 'image/png'
      byteLength = 4
      relativePath = ('preview-images/image-{0:d2}.png' -f $i)
      sortKey = ('attributes|preview-images/image-{0:d2}.png' -f $i)
    }
  }

  return [ordered]@{
    schema = 'comparevi-history/shared-evidence@v1'
    generatedAtUtc = '2026-03-17T00:00:00Z'
    source = [ordered]@{ schema = $SourceSchema; path = $SourcePath }
    consumer = [ordered]@{ repository = $ConsumerRepository; ref = $ConsumerRef }
    target = [ordered]@{ path = $TargetPath; selectedRef = 'HEAD'; extension = '.vi'; targetId = $TargetId }
    configuration = [ordered]@{ requestedModes = @('attributes', 'front-panel', 'block-diagram'); noisePolicy = $NoisePolicy; includeMergeParents = $false }
    summary = [ordered]@{ modeCount = 3; totalProcessed = $TotalProcessed; totalDiffs = $TotalDiffs; stopReason = 'completed' }
    surfaces = [ordered]@{
      suppressionProfile = $SuppressionProfile
      comparisonArtifactCount = $ComparisonArtifactCount
      captureCount = $CaptureCount
      imageArtifactCount = $ImageArtifactCount
      imageMimeTypes = @('image/png')
      categoryCounts = [ordered]@{ 'Block Diagram objects' = $TotalDiffs }
      comparisonPairs = @([ordered]@{ firstPath = '/compare/base.vi'; secondPath = '/compare/head.vi'; count = [Math]::Max(1, $TotalDiffs) })
      bucketCounts = [ordered]@{ 'metadata-rich' = $PreviewImageCount }
      previewImages = $previewImages
      renderSurfaces = @([ordered]@{ scope = 'run'; kind = 'index-html'; chunkId = $null; relativePath = 'index.html'; pathType = 'file'; contentType = 'text/html' })
      artifactSurfaces = @([ordered]@{ scope = 'run'; kind = 'bundle-zip'; chunkId = $null; relativePath = 'manual-vi-exploration-bundle.zip'; pathType = 'file'; contentType = 'application/zip' })
    }
    completeness = [ordered]@{ finalStatus = $FinalStatus; finalReason = $FinalReason; replayStatus = $ReplayStatus; replayReason = $ReplayReason }
  }
}

function New-EvidenceGraphJson {
  param(
    [string]$ConsumerRepository,
    [string]$ConsumerRef,
    [string]$TargetPath,
    [string]$Status,
    [string]$Reason,
    [bool]$CatalogComplete,
    [string]$CatalogCompletenessReason,
    [string]$ContinuityStatus,
    [int]$BreakCount,
    [int]$SegmentCount
  )

  return [ordered]@{
    schema = 'comparevi-history/evidence-graph@v1'
    generatedAtUtc = '2026-03-17T00:00:00Z'
    consumer = [ordered]@{ repository = $ConsumerRepository; ref = $ConsumerRef }
    target = [ordered]@{ path = $TargetPath; selectedRef = 'HEAD'; extension = '.vi' }
    configuration = [ordered]@{ requestedModes = @('attributes', 'front-panel', 'block-diagram'); noisePolicy = 'include'; includeMergeParents = $false }
    discovery = [ordered]@{ revisionCatalogPath = 'revision-catalog.json'; revisionCount = 12; historyMode = 'selected-ref-lineage'; followRenames = $true; catalogComplete = $CatalogComplete; catalogCompletenessReason = $CatalogCompletenessReason }
    continuity = [ordered]@{ status = $ContinuityStatus; breakCount = $BreakCount; segmentCount = $SegmentCount; segments = @(); breaks = @() }
    execution = [ordered]@{ chunkPlanPath = 'chunk-plan.json'; chunkReceiptsRoot = 'chunk-receipts'; chunkPairLimit = 5; pairCount = 5; chunkCount = 1; plannedChunkCount = 1; completedChunkCount = $(if ($Status -eq 'complete') { 1 } else { 0 }); failedChunkCount = $(if ($Status -eq 'complete') { 0 } else { 1 }); skippedChunkCount = 0; status = $(if ($Status -eq 'complete') { 'complete' } else { 'failed' }); reason = $Reason; chunks = @() }
    surfaces = [ordered]@{ suppressionProfile = 'unsuppressed'; comparisonArtifactCount = 2; captureCount = 2; imageArtifactCount = 2; imageMimeTypes = @('image/png'); categoryCounts = [ordered]@{ 'Block Diagram objects' = 2 }; comparisonPairs = @(); bucketCounts = [ordered]@{ 'metadata-rich' = 2 }; previewImages = @(); renderSurfaces = @(); artifactSurfaces = @() }
    completeness = [ordered]@{ status = $Status; reason = $Reason }
  }
}

try {
  $resultsRoot = Join-Path $tempRoot 'results'
  New-Item -ItemType Directory -Path $resultsRoot -Force | Out-Null
  $targetAPath = Join-Path $resultsRoot 'target-a'
  $targetBPath = Join-Path $resultsRoot 'target-b'
  $targetCPath = Join-Path $resultsRoot 'target-c'
  foreach ($path in @($targetAPath, $targetBPath, $targetCPath)) {
    New-Item -ItemType Directory -Path $path -Force | Out-Null
  }

  $graphAPath = Join-Path $targetAPath 'evidence-graph.json'
  $sharedAPath = Join-Path $targetAPath 'shared-evidence.json'
  $graphCPath = Join-Path $targetCPath 'evidence-graph.json'
  $sharedCPath = Join-Path $targetCPath 'shared-evidence.json'
  $sharedBPath = Join-Path $targetBPath 'shared-evidence.json'

  (New-EvidenceGraphJson -ConsumerRepository 'LabVIEW-Community-CI-CD/labview-icon-editor-demo' -ConsumerRef 'develop' -TargetPath 'Tooling/deployment/VIP_Post-Install Custom Action.vi' -Status 'complete' -Reason 'all-chunks-succeeded' -CatalogComplete $true -CatalogCompletenessReason 'selected-ref-lineage' -ContinuityStatus 'continuous' -BreakCount 0 -SegmentCount 1) | ConvertTo-Json -Depth 64 | Set-Content -LiteralPath $graphAPath -Encoding utf8
  (New-EvidenceGraphJson -ConsumerRepository 'LabVIEW-Community-CI-CD/labview-icon-editor-demo' -ConsumerRef 'develop' -TargetPath 'Tooling/deployment/VIP_Uninstall Custom Action.vi' -Status 'incomplete' -Reason 'chunk-failed' -CatalogComplete $true -CatalogCompletenessReason 'selected-ref-lineage' -ContinuityStatus 'break-detected' -BreakCount 1 -SegmentCount 2) | ConvertTo-Json -Depth 64 | Set-Content -LiteralPath $graphCPath -Encoding utf8

  (New-SharedEvidenceJson -ConsumerRepository 'LabVIEW-Community-CI-CD/labview-icon-editor-demo' -ConsumerRef 'develop' -TargetPath 'Tooling/deployment/VIP_Post-Install Custom Action.vi' -TargetId $null -SourceSchema 'comparevi-history/evidence-graph@v1' -SourcePath $graphAPath -NoisePolicy 'include' -FinalStatus 'succeeded' -FinalReason 'completed' -ReplayStatus 'ready' -ReplayReason 'history-summary-present' -SuppressionProfile 'unsuppressed' -PreviewImageCount 2 -ComparisonArtifactCount 3 -ImageArtifactCount 2 -CaptureCount 2 -TotalDiffs 4 -TotalProcessed 12) | ConvertTo-Json -Depth 64 | Set-Content -LiteralPath $sharedAPath -Encoding utf8
  (New-SharedEvidenceJson -ConsumerRepository 'LabVIEW-Community-CI-CD/labview-icon-editor-demo' -ConsumerRef 'develop' -TargetPath 'Tooling/deployment/VIP_Pre-Install Custom Action.vi' -TargetId 'vip-pre-install' -SourceSchema 'comparevi-history/public-run@v1' -SourcePath 'history/public/public-run.json' -NoisePolicy 'collapse' -FinalStatus 'succeeded' -FinalReason 'completed' -ReplayStatus 'ready' -ReplayReason 'history-summary-present' -SuppressionProfile 'unknown' -PreviewImageCount 0 -ComparisonArtifactCount 1 -ImageArtifactCount 0 -CaptureCount 0 -TotalDiffs 1 -TotalProcessed 5) | ConvertTo-Json -Depth 64 | Set-Content -LiteralPath $sharedBPath -Encoding utf8
  (New-SharedEvidenceJson -ConsumerRepository 'LabVIEW-Community-CI-CD/labview-icon-editor-demo' -ConsumerRef 'develop' -TargetPath 'Tooling/deployment/VIP_Uninstall Custom Action.vi' -TargetId $null -SourceSchema 'comparevi-history/evidence-graph@v1' -SourcePath $graphCPath -NoisePolicy 'include' -FinalStatus 'failed' -FinalReason 'chunk-failed' -ReplayStatus 'partial' -ReplayReason 'chunk-artifacts-present' -SuppressionProfile 'unsuppressed' -PreviewImageCount 1 -ComparisonArtifactCount 2 -ImageArtifactCount 1 -CaptureCount 1 -TotalDiffs 3 -TotalProcessed 8) | ConvertTo-Json -Depth 64 | Set-Content -LiteralPath $sharedCPath -Encoding utf8

  $outputDir = Join-Path $resultsRoot 'corpus'
  $githubOutputPath = Join-Path $tempRoot 'corpus-output.txt'
  $summaryPath = Join-Path $tempRoot 'corpus-summary.md'
  $corpusJson = & $scriptPath -SharedEvidencePaths @($sharedAPath, $sharedBPath, $sharedCPath) -EvidenceGraphPaths @($graphAPath) -OutputDir $outputDir -PageSize 2 -GitHubOutputPath $githubOutputPath -StepSummaryPath $summaryPath

  $corpusIndex = $corpusJson | ConvertFrom-Json -Depth 100
  if ($corpusIndex.schema -ne 'comparevi-history/corpus-index@v1') { throw 'Corpus index schema mismatch.' }
  if (-not (Test-Path -LiteralPath $schemaPath -PathType Leaf)) { throw 'Corpus index schema file is missing.' }
  if (-not (Test-Path -LiteralPath $pageSchemaPath -PathType Leaf)) { throw 'Corpus page schema file is missing.' }
  if (-not (Test-Path -LiteralPath $manifestSchemaPath -PathType Leaf)) { throw 'Downstream manifest schema file is missing.' }
  if ($corpusIndex.corpus.targetCount -ne 3) { throw 'Corpus target count mismatch.' }
  if ($corpusIndex.corpus.evidenceGraphCount -ne 2) { throw 'Corpus evidence graph count mismatch.' }
  if ($corpusIndex.paging.pageCount -ne 2) { throw 'Corpus page count mismatch.' }
  if ($corpusIndex.summary.incompleteTargetCount -ne 1) { throw 'Corpus incomplete target count mismatch.' }
  if ($corpusIndex.summary.degradedTargetCount -ne 1) { throw 'Corpus degraded target count mismatch.' }
  if ($corpusIndex.summary.unsuppressedTargetCount -ne 2) { throw 'Corpus unsuppressed target count mismatch.' }
  if ($corpusIndex.downstream.schema -ne 'comparevi-history/downstream-processing-manifest@v1') { throw 'Corpus downstream schema mismatch.' }

  $pageOnePath = Join-Path $outputDir ([string]$corpusIndex.paging.pages[0].relativePath)
  $pageTwoPath = Join-Path $outputDir ([string]$corpusIndex.paging.pages[1].relativePath)
  if (-not (Test-Path -LiteralPath $pageOnePath -PathType Leaf) -or -not (Test-Path -LiteralPath $pageTwoPath -PathType Leaf)) { throw 'Corpus page files were not written.' }

  $pageOne = Get-Content -LiteralPath $pageOnePath -Raw | ConvertFrom-Json -Depth 100
  $pageTwo = Get-Content -LiteralPath $pageTwoPath -Raw | ConvertFrom-Json -Depth 100
  if ($pageOne.schema -ne 'comparevi-history/corpus-page@v1' -or $pageTwo.schema -ne 'comparevi-history/corpus-page@v1') { throw 'Corpus page schema mismatch.' }
  if ($pageOne.page.targetCount -ne 2 -or $pageTwo.page.targetCount -ne 1) { throw 'Corpus page target counts mismatch.' }
  if ($pageOne.targets[0].entrypoint -ne 'manual-exploration') { throw 'Corpus page manual-exploration entrypoint mismatch.' }
  if ($pageOne.targets[1].entrypoint -ne 'curated-public-run') { throw 'Corpus page curated entrypoint mismatch.' }
  if ($null -eq $pageTwo.targets[0].sources.evidenceGraphPath) { throw 'Corpus page should derive evidence graph path from shared evidence source.' }

  $downstreamManifestPath = Join-Path $outputDir 'downstream-processing-manifest.json'
  $downstreamManifest = Get-Content -LiteralPath $downstreamManifestPath -Raw | ConvertFrom-Json -Depth 100
  if ($downstreamManifest.schema -ne 'comparevi-history/downstream-processing-manifest@v1') { throw 'Downstream processing manifest schema mismatch.' }
  if ($downstreamManifest.processingModel.continuationMode -ne 'page-ordinal') { throw 'Downstream continuation mode mismatch.' }
  if ($downstreamManifest.units.Count -ne 2) { throw 'Downstream processing unit count mismatch.' }
  if ($downstreamManifest.pilotRecommendation.candidateTargetPaths.Count -ne 3) { throw 'Downstream pilot recommendation target count mismatch.' }

  $githubOutputs = Get-Content -LiteralPath $githubOutputPath -Raw
  foreach ($requiredKey in @('corpus-index-path=', 'corpus-pages-root=', 'downstream-processing-manifest-path=', 'page-count=2', 'target-count=3', 'continuation-mode=page-ordinal', 'corpus-complete=false', 'corpus-reason=target-degradation-present')) {
    if ($githubOutputs -notmatch [regex]::Escape($requiredKey)) { throw "Expected GitHub output '$requiredKey'." }
  }

  $summary = Get-Content -LiteralPath $summaryPath -Raw
  if ($summary -notmatch 'comparevi-history corpus index') { throw 'Corpus step summary was not written.' }

  $mixedRoot = Join-Path $resultsRoot 'mixed'
  New-Item -ItemType Directory -Path $mixedRoot -Force | Out-Null
  $mixedSharedPath = Join-Path $mixedRoot 'shared-evidence.json'
  (New-SharedEvidenceJson -ConsumerRepository 'Other/repo' -ConsumerRef 'develop' -TargetPath 'Tooling/deployment/Other.vi' -TargetId $null -SourceSchema 'comparevi-history/public-run@v1' -SourcePath 'history/public/public-run.json' -NoisePolicy 'collapse' -FinalStatus 'succeeded' -FinalReason 'completed' -ReplayStatus 'ready' -ReplayReason 'history-summary-present' -SuppressionProfile 'unknown' -PreviewImageCount 0 -ComparisonArtifactCount 1 -ImageArtifactCount 0 -CaptureCount 0 -TotalDiffs 1 -TotalProcessed 1) | ConvertTo-Json -Depth 64 | Set-Content -LiteralPath $mixedSharedPath -Encoding utf8

  $failedMixed = $false
  try {
    & $scriptPath -SharedEvidencePaths @($sharedAPath, $mixedSharedPath) -OutputDir (Join-Path $resultsRoot 'mixed-output') | Out-Null
  } catch {
    $failedMixed = $_.Exception.Message -match 'one consumer repository and one consumer ref'
  }
  if (-not $failedMixed) { throw 'Expected mixed consumer repository validation failure.' }
} finally {
  Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

