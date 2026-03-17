Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptPath = Join-Path $PSScriptRoot 'Write-CompareVIHistoryDownstreamProcessorSummary.ps1'
$schemaPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'docs' 'schemas' 'comparevi-history-downstream-processor-summary-v1.schema.json'
$fixtureRoot = Join-Path (Split-Path -Parent $PSScriptRoot) 'tests' 'fixtures' 'corpus-pilot-v1' 'corpus'
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('comparevi-history-downstream-processor-summary-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

function New-SyntheticPage {
  param(
    [int]$PageOrdinal,
    [int]$TargetOrdinal,
    [string]$TargetPath,
    [string]$Entrypoint,
    [string]$FinalStatus,
    [AllowNull()][string]$GraphStatus,
    [string]$ReplayStatus,
    [string]$SuppressionProfile,
    [int]$PreviewImageCount,
    [int]$ImageArtifactCount,
    [int]$ComparisonArtifactCount
  )

  return [ordered]@{
    schema = 'comparevi-history/corpus-page@v1'
    generatedAtUtc = '2026-03-17T00:00:00Z'
    corpus = [ordered]@{
      repository = 'LabVIEW-Community-CI-CD/labview-icon-editor-demo'
      ref = 'develop'
      indexPath = '../corpus-index.json'
    }
    page = [ordered]@{
      pageOrdinal = $PageOrdinal
      pageSize = 1
      targetCount = 1
      targetOrdinalStart = $TargetOrdinal
      targetOrdinalEnd = $TargetOrdinal
    }
    targets = @(
      [ordered]@{
        targetOrdinal = $TargetOrdinal
        targetKey = ('LabVIEW-Community-CI-CD/labview-icon-editor-demo|develop|HEAD|{0}' -f $TargetPath)
        entrypoint = $Entrypoint
        target = [ordered]@{
          path = $TargetPath
          selectedRef = 'HEAD'
          extension = '.vi'
          targetId = $null
        }
        sources = [ordered]@{
          sharedEvidenceSchema = 'comparevi-history/shared-evidence@v1'
          sharedEvidencePath = ('../../targets/page-{0:d3}/shared-evidence.json' -f $PageOrdinal)
          sourceSchema = $(if ($Entrypoint -eq 'manual-exploration') { 'comparevi-history/evidence-graph@v1' } else { 'comparevi-history/public-run@v1' })
          sourcePath = ('targets/page-{0:d3}/source.json' -f $PageOrdinal)
          evidenceGraphSchema = $(if ($Entrypoint -eq 'manual-exploration') { 'comparevi-history/evidence-graph@v1' } else { $null })
          evidenceGraphPath = $(if ($Entrypoint -eq 'manual-exploration') { ('../../targets/page-{0:d3}/evidence-graph.json' -f $PageOrdinal) } else { $null })
        }
        summary = [ordered]@{
          modeCount = 1
          totalProcessed = 2
          totalDiffs = 2
          stopReason = 'complete'
          suppressionProfile = $SuppressionProfile
          comparisonArtifactCount = $ComparisonArtifactCount
          captureCount = 1
          imageArtifactCount = $ImageArtifactCount
          previewImageCount = $PreviewImageCount
          comparisonPairCount = 1
        }
        completeness = [ordered]@{
          finalStatus = $FinalStatus
          finalReason = $(if ($FinalStatus -eq 'succeeded') { 'all-chunks-succeeded' } else { 'chunk-failed' })
          replayStatus = $ReplayStatus
          replayReason = $(if ($ReplayStatus -eq 'ready') { 'all-chunks-executed' } else { 'chunk-artifacts-present' })
          graphStatus = $GraphStatus
          graphReason = $(if ([string]::IsNullOrWhiteSpace($GraphStatus)) { $null } else { 'chunk-failed' })
          catalogComplete = $true
          catalogCompletenessReason = 'selected-ref-lineage'
          continuityStatus = $(if ($FinalStatus -eq 'succeeded') { 'continuous' } else { 'break-detected' })
          continuityBreakCount = $(if ($FinalStatus -eq 'succeeded') { 0 } else { 1 })
          segmentCount = $(if ($FinalStatus -eq 'succeeded') { 1 } else { 2 })
        }
        surfaces = [ordered]@{
          categoryCounts = [ordered]@{ 'Block Diagram objects' = 2 }
          bucketCounts = [ordered]@{ 'functional-behavior' = 2 }
          renderSurfacesCount = 2
          artifactSurfacesCount = 3
        }
      }
    )
    completeness = [ordered]@{
      isComplete = ($FinalStatus -eq 'succeeded' -and [string]::IsNullOrWhiteSpace($GraphStatus))
      reason = $(if ($FinalStatus -eq 'succeeded' -and [string]::IsNullOrWhiteSpace($GraphStatus)) { 'all-targets-complete' } else { 'target-degradation-present' })
    }
  }
}

try {
  if (-not (Test-Path -LiteralPath $schemaPath -PathType Leaf)) {
    throw 'Downstream processor schema file is missing.'
  }

  $fixtureManifestPath = Join-Path $fixtureRoot 'downstream-processing-manifest.json'
  $fixtureOraclePath = Join-Path $fixtureRoot 'corpus-index.json'
  if (-not (Test-Path -LiteralPath $fixtureManifestPath -PathType Leaf)) {
    throw 'Fixture downstream processing manifest is missing.'
  }

  $realOutputPath = Join-Path $tempRoot 'real-summary.json'
  $realGitHubOutputPath = Join-Path $tempRoot 'real-github-output.txt'
  $realStepSummaryPath = Join-Path $tempRoot 'real-step-summary.md'
  $realJson = & $scriptPath -DownstreamProcessingManifestPath $fixtureManifestPath -OutputPath $realOutputPath -GitHubOutputPath $realGitHubOutputPath -StepSummaryPath $realStepSummaryPath
  $realSummary = $realJson | ConvertFrom-Json -Depth 100
  $realOracle = Get-Content -LiteralPath $fixtureOraclePath -Raw | ConvertFrom-Json -Depth 100

  if ($realSummary.schema -ne 'comparevi-history/downstream-processor-summary@v1') { throw 'Real summary schema mismatch.' }
  if ($realSummary.corpus.repository -ne 'LabVIEW-Community-CI-CD/labview-icon-editor-demo') { throw 'Real summary repository mismatch.' }
  if ($realSummary.corpus.ref -ne 'develop') { throw 'Real summary ref mismatch.' }
  if ($realSummary.selection.continuationMode -ne 'page-ordinal') { throw 'Real summary continuation mode mismatch.' }
  if ($realSummary.selection.processedPageCount -ne 1) { throw 'Real summary processed page count mismatch.' }
  if ($realSummary.selection.processedTargetCount -ne 2) { throw 'Real summary processed target count mismatch.' }
  if ($realSummary.summary.completeTargetCount -ne 2) { throw 'Real summary complete target count mismatch.' }
  if ($realSummary.summary.incompleteTargetCount -ne 0) { throw 'Real summary incomplete target count mismatch.' }
  if ($realSummary.summary.unsuppressedTargetCount -ne 2) { throw 'Real summary unsuppressed target count mismatch.' }
  if ($realSummary.summary.totalComparisonArtifactCount -ne 4) { throw 'Real summary comparison artifact count mismatch.' }
  if ($realSummary.summary.entrypointCounts.'manual-exploration' -ne 2) { throw 'Real summary entrypoint count mismatch.' }
  if ($realSummary.summary.finalStatusCounts.succeeded -ne 2) { throw 'Real summary final status count mismatch.' }
  if ($realSummary.summary.graphStatusCounts.none -ne 2) { throw 'Real summary graph status count mismatch.' }
  if (-not $realSummary.completeness.isComplete -or $realSummary.completeness.reason -ne 'all-targets-complete') { throw 'Real summary completeness mismatch.' }
  if ($realSummary.summary.totalPreviewImageCount -ne [int]$realOracle.summary.totalPreviewImageCount) { throw 'Real summary preview image count should match the real oracle.' }
  if ($realSummary.selection.availableTargetCount -ne [int]$realOracle.corpus.targetCount) { throw 'Real summary available target count mismatch.' }
  if ($realSummary.inventory.targets.Count -ne 2) { throw 'Real target inventory count mismatch.' }
  if ($realSummary.inventory.targets[0].path -ne 'Tooling/deployment/VIP_Post-Install Custom Action.vi') { throw 'Real target ordering mismatch.' }
  if ($realSummary.inventory.targets[1].path -ne 'Tooling/deployment/VIP_Pre-Install Custom Action.vi') { throw 'Real target ordering mismatch for second target.' }

  $realGitHubOutputs = Get-Content -LiteralPath $realGitHubOutputPath -Raw
  foreach ($requiredKey in @('downstream-processor-summary-path=', 'processed-page-count=1', 'processed-target-count=2', 'selection-complete=true', 'selection-reason=all-targets-complete')) {
    if ($realGitHubOutputs -notmatch [regex]::Escape($requiredKey)) {
      throw "Expected real GitHub output '$requiredKey'."
    }
  }

  $realStepSummary = Get-Content -LiteralPath $realStepSummaryPath -Raw
  if ($realStepSummary -notmatch 'comparevi-history downstream processor summary') {
    throw 'Real step summary was not written.'
  }

  $syntheticRoot = Join-Path $tempRoot 'synthetic'
  $syntheticPagesRoot = Join-Path $syntheticRoot 'pages'
  New-Item -ItemType Directory -Path $syntheticPagesRoot -Force | Out-Null
  $pageOnePath = Join-Path $syntheticPagesRoot 'corpus-page-001.json'
  $pageTwoPath = Join-Path $syntheticPagesRoot 'corpus-page-002.json'
  (New-SyntheticPage -PageOrdinal 1 -TargetOrdinal 1 -TargetPath 'Tooling/deployment/VIP_Post-Install Custom Action.vi' -Entrypoint 'manual-exploration' -FinalStatus 'succeeded' -GraphStatus $null -ReplayStatus 'ready' -SuppressionProfile 'unsuppressed' -PreviewImageCount 2 -ImageArtifactCount 1 -ComparisonArtifactCount 3) | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $pageOnePath -Encoding utf8
  (New-SyntheticPage -PageOrdinal 2 -TargetOrdinal 2 -TargetPath 'Tooling/deployment/VIP_Pre-Install Custom Action.vi' -Entrypoint 'curated-public-run' -FinalStatus 'failed' -GraphStatus 'incomplete' -ReplayStatus 'partial' -SuppressionProfile 'unsuppressed' -PreviewImageCount 0 -ImageArtifactCount 0 -ComparisonArtifactCount 1) | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $pageTwoPath -Encoding utf8

  $syntheticManifestPath = Join-Path $syntheticRoot 'downstream-processing-manifest.json'
  [ordered]@{
    schema = 'comparevi-history/downstream-processing-manifest@v1'
    generatedAtUtc = '2026-03-17T00:00:00Z'
    corpus = [ordered]@{
      repository = 'LabVIEW-Community-CI-CD/labview-icon-editor-demo'
      ref = 'develop'
      corpusIndexPath = 'corpus-index.json'
    }
    acceptedSchemas = [ordered]@{
      sharedEvidence = 'comparevi-history/shared-evidence@v1'
      evidenceGraph = 'comparevi-history/evidence-graph@v1'
      corpusPage = 'comparevi-history/corpus-page@v1'
    }
    processingModel = [ordered]@{
      unitKind = 'corpus-page'
      ordering = 'target-path-asc'
      continuationMode = 'page-ordinal'
      pageSize = 1
      pageCount = 2
      targetCount = 2
    }
    units = @(
      [ordered]@{
        unitId = 'page-001'
        pageOrdinal = 1
        pagePath = 'pages/corpus-page-001.json'
        targetCount = 1
        targetOrdinalStart = 1
        targetOrdinalEnd = 1
        continuationToken = 'page-001'
        status = 'ready'
      },
      [ordered]@{
        unitId = 'page-002'
        pageOrdinal = 2
        pagePath = 'pages/corpus-page-002.json'
        targetCount = 1
        targetOrdinalStart = 2
        targetOrdinalEnd = 2
        continuationToken = 'page-002'
        status = 'ready'
      }
    )
    completeness = [ordered]@{
      isComplete = $false
      reason = 'target-degradation-present'
    }
    pilotRecommendation = [ordered]@{
      name = 'manual-exploration-corpus-pilot@v1'
      selectionStrategy = 'explicit-evidence-list'
      minimumTargetCount = 2
      candidateTargetPaths = @(
        'Tooling/deployment/VIP_Post-Install Custom Action.vi',
        'Tooling/deployment/VIP_Pre-Install Custom Action.vi'
      )
      requiredSchemas = @(
        'comparevi-history/shared-evidence@v1',
        'comparevi-history/evidence-graph@v1'
      )
      continuationMode = 'page-ordinal'
      nextStep = 'Resume by page ordinal.'
    }
  } | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $syntheticManifestPath -Encoding utf8

  $syntheticOutputPath = Join-Path $tempRoot 'synthetic-summary.json'
  $syntheticGitHubOutputPath = Join-Path $tempRoot 'synthetic-github-output.txt'
  $syntheticJson = & $scriptPath -DownstreamProcessingManifestPath $syntheticManifestPath -StartPageOrdinal 1 -MaxPages 1 -OutputPath $syntheticOutputPath -GitHubOutputPath $syntheticGitHubOutputPath
  $syntheticSummary = $syntheticJson | ConvertFrom-Json -Depth 100

  if ($syntheticSummary.selection.processedPageCount -ne 1) { throw 'Synthetic processed page count mismatch.' }
  if ($syntheticSummary.selection.processedTargetCount -ne 1) { throw 'Synthetic processed target count mismatch.' }
  if (-not $syntheticSummary.selection.hasMorePages) { throw 'Synthetic selection should require continuation.' }
  if ($syntheticSummary.selection.nextPageOrdinal -ne 2) { throw 'Synthetic next page ordinal mismatch.' }
  if ($syntheticSummary.selection.nextContinuationToken -ne 'page-002') { throw 'Synthetic next continuation token mismatch.' }
  if ($syntheticSummary.completeness.isComplete) { throw 'Synthetic selection should be incomplete.' }
  if ($syntheticSummary.completeness.reason -ne 'continuation-required') { throw 'Synthetic completeness reason mismatch.' }
  if ($syntheticSummary.summary.totalPreviewImageCount -ne 2) { throw 'Synthetic preview image total mismatch.' }
  if ($syntheticSummary.summary.unsuppressedTargetCount -ne 1) { throw 'Synthetic unsuppressed target count mismatch.' }
  if ($syntheticSummary.summary.finalStatusCounts.succeeded -ne 1) { throw 'Synthetic final status count mismatch.' }
  if ($syntheticSummary.summary.graphStatusCounts.none -ne 1) { throw 'Synthetic graph status count mismatch.' }

  $syntheticGitHubOutputs = Get-Content -LiteralPath $syntheticGitHubOutputPath -Raw
  foreach ($requiredKey in @('processed-page-count=1', 'processed-target-count=1', 'next-page-ordinal=2', 'next-continuation-token=page-002', 'selection-complete=false', 'selection-reason=continuation-required')) {
    if ($syntheticGitHubOutputs -notmatch [regex]::Escape($requiredKey)) {
      throw "Expected synthetic GitHub output '$requiredKey'."
    }
  }
} finally {
  Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
