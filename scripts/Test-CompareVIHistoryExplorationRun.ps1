Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$catalogScriptPath = Join-Path $PSScriptRoot 'Write-CompareVIHistoryRevisionCatalog.ps1'
$chunkPlanScriptPath = Join-Path $PSScriptRoot 'Write-CompareVIHistoryChunkPlan.ps1'
$explorationRunScriptPath = Join-Path $PSScriptRoot 'Write-CompareVIHistoryExplorationRun.ps1'
$schemaPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'docs' 'schemas' 'comparevi-history-exploration-run-v1.schema.json'
$evidenceGraphSchemaPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'docs' 'schemas' 'comparevi-history-evidence-graph-v1.schema.json'
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("comparevi-history-exploration-run-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

function Invoke-Git {
  param(
    [Parameter(Mandatory = $true)]
    [string]$RepositoryRoot,
    [Parameter(Mandatory = $true)]
    [string[]]$Arguments
  )

  $output = & git -C $RepositoryRoot @Arguments 2>&1
  if ($LASTEXITCODE -ne 0) {
    throw ([string]::Join([Environment]::NewLine, @($output)))
  }

  return [string]::Join([Environment]::NewLine, @($output))
}

try {
  $repoRoot = Join-Path $tempRoot 'consumer'
  New-Item -ItemType Directory -Path $repoRoot -Force | Out-Null

  Invoke-Git -RepositoryRoot $repoRoot -Arguments @('init', '--initial-branch=main') | Out-Null
  Invoke-Git -RepositoryRoot $repoRoot -Arguments @('config', 'user.name', 'comparevi-history-test') | Out-Null
  Invoke-Git -RepositoryRoot $repoRoot -Arguments @('config', 'user.email', 'comparevi-history-test@example.com') | Out-Null

  $targetDir = Join-Path $repoRoot 'Tooling' 'deployment'
  New-Item -ItemType Directory -Path $targetDir -Force | Out-Null

  foreach ($ordinal in 1..4) {
    "v$ordinal" | Set-Content -LiteralPath (Join-Path $targetDir 'Target.vi') -Encoding utf8
    Invoke-Git -RepositoryRoot $repoRoot -Arguments @('add', 'Tooling/deployment/Target.vi') | Out-Null
    Invoke-Git -RepositoryRoot $repoRoot -Arguments @('commit', '-m', "Revision $ordinal") | Out-Null
  }

  $resultsDir = Join-Path $tempRoot 'results'
  & $catalogScriptPath `
    -RepositoryRoot $repoRoot `
    -TargetPath 'Tooling/deployment/Target.vi' `
    -SelectedRef 'HEAD' `
    -ConsumerRepository 'LabVIEW-Community-CI-CD/labview-icon-editor-demo' `
    -ConsumerRef 'develop' `
    -ResultsDir $resultsDir | Out-Null

  $chunkPlanJson = & $chunkPlanScriptPath `
    -RevisionCatalogPath (Join-Path $resultsDir 'revision-catalog.json') `
    -ChunkPairLimit 2 `
    -ResultsDir $resultsDir
  $chunkPlan = $chunkPlanJson | ConvertFrom-Json -Depth 64

  $githubOutputPath = Join-Path $tempRoot 'exploration-run-output.txt'
  $summaryPath = Join-Path $tempRoot 'exploration-run-summary.md'
  $explorationRunJson = & $explorationRunScriptPath `
    -RevisionCatalogPath (Join-Path $resultsDir 'revision-catalog.json') `
    -ChunkPlanPath (Join-Path $resultsDir 'chunk-plan.json') `
    -Modes 'attributes,front-panel,block-diagram' `
    -NoisePolicy 'collapse' `
    -GitHubOutputPath $githubOutputPath `
    -StepSummaryPath $summaryPath

  $explorationRun = $explorationRunJson | ConvertFrom-Json -Depth 64
  if ($explorationRun.schema -ne 'comparevi-history/exploration-run@v1') {
    throw 'Exploration run schema mismatch.'
  }
  if (-not (Test-Path -LiteralPath $schemaPath -PathType Leaf)) {
    throw 'Exploration run schema file is missing.'
  }
  if (-not (Test-Path -LiteralPath $evidenceGraphSchemaPath -PathType Leaf)) {
    throw 'Evidence graph schema file is missing.'
  }
  if ($explorationRun.discovery.revisionCount -ne 4) {
    throw 'Exploration run revision count mismatch.'
  }
  if ($explorationRun.planning.chunkCount -ne 2) {
    throw 'Exploration run chunk count mismatch.'
  }
  if ($explorationRun.summary.finalStatus -ne 'planned') {
    throw 'Exploration run final status mismatch.'
  }
  if ($explorationRun.summary.finalReason -ne 'chunk-plan-ready') {
    throw 'Exploration run final reason mismatch.'
  }
  if ($explorationRun.publication.bundleStatus -ne 'not-required') {
    throw 'Exploration run bundle status mismatch for the planning-only path.'
  }
  if ($explorationRun.replay.status -ne 'ready-for-chunk-execution') {
    throw 'Exploration run replay status mismatch.'
  }
  if ($explorationRun.surfaces.suppressionProfile -ne 'unknown') {
    throw 'Planned exploration run suppression profile mismatch.'
  }
  if (-not (Test-Path -LiteralPath $explorationRun.outputs.timelineMd -PathType Leaf)) {
    throw 'Timeline markdown was not written for the planned exploration run.'
  }
  if (-not (Test-Path -LiteralPath $explorationRun.outputs.timelineHtml -PathType Leaf)) {
    throw 'Timeline HTML was not written for the planned exploration run.'
  }
  if (-not (Test-Path -LiteralPath $explorationRun.outputs.indexMd -PathType Leaf)) {
    throw 'Index markdown was not written for the planned exploration run.'
  }
  if (-not (Test-Path -LiteralPath $explorationRun.outputs.indexHtml -PathType Leaf)) {
    throw 'Index HTML was not written for the planned exploration run.'
  }
  if (-not (Test-Path -LiteralPath (Join-Path $resultsDir 'exploration-run.json') -PathType Leaf)) {
    throw 'Exploration run file was not written.'
  }
  if ($explorationRun.evidence.schema -ne 'comparevi-history/evidence-graph@v1') {
    throw 'Exploration run evidence schema mismatch.'
  }
  if (-not (Test-Path -LiteralPath $explorationRun.evidence.graphPath -PathType Leaf)) {
    throw 'Evidence graph file was not written.'
  }
  if ($explorationRun.outputs.evidenceGraphPath -ne $explorationRun.evidence.graphPath) {
    throw 'Exploration run evidence graph output mismatch.'
  }

  $plannedEvidenceGraph = Get-Content -LiteralPath $explorationRun.evidence.graphPath -Raw | ConvertFrom-Json -Depth 64
  if ($plannedEvidenceGraph.schema -ne 'comparevi-history/evidence-graph@v1') {
    throw 'Planned evidence graph schema mismatch.'
  }
  if ($plannedEvidenceGraph.discovery.revisionCount -ne 4) {
    throw 'Planned evidence graph revision count mismatch.'
  }
  if ($plannedEvidenceGraph.continuity.segmentCount -ne 1 -or $plannedEvidenceGraph.continuity.breakCount -ne 0) {
    throw 'Planned evidence graph continuity summary mismatch.'
  }
  if ($plannedEvidenceGraph.execution.chunkCount -ne 2 -or $plannedEvidenceGraph.execution.status -ne 'planned') {
    throw 'Planned evidence graph execution summary mismatch.'
  }
  if ($plannedEvidenceGraph.surfaces.previewImages.Count -ne 0) {
    throw 'Planned evidence graph must not invent preview images.'
  }
  if ($plannedEvidenceGraph.surfaces.renderSurfaces.Count -lt 2 -or $plannedEvidenceGraph.surfaces.artifactSurfaces.Count -lt 3) {
    throw 'Planned evidence graph surface references are incomplete.'
  }
  if (($plannedEvidenceGraph.surfaces.artifactSurfaces | Where-Object { $_.kind -eq 'exploration-run-json' }).Count -ne 1) {
    throw 'Planned evidence graph must reference the exploration run artifact.'
  }
  if (($plannedEvidenceGraph.continuity.segments[0].revisions | Select-Object -First 1).ordinal -ne 1) {
    throw 'Planned evidence graph revisions must stay deterministically ordered.'
  }

  $githubOutputs = Get-Content -LiteralPath $githubOutputPath -Raw
  foreach ($requiredKey in @(
      'exploration-run-path=',
      'evidence-graph-path=',
      'exploration-status=planned',
      'exploration-reason=chunk-plan-ready',
      'index-md=',
      'index-html=',
      'timeline-md=',
      'timeline-html=',
      'bundle-path='
    )) {
    if ($githubOutputs -notmatch [regex]::Escape($requiredKey)) {
      throw "Expected GitHub output '$requiredKey'."
    }
  }

  $summary = Get-Content -LiteralPath $summaryPath -Raw
  if ($summary -notmatch 'comparevi-history exploration run') {
    throw 'Exploration run summary was not written.'
  }
  foreach ($requiredFragment in @(
      'Total chunk count: `2`',
      'Remaining planned chunk count: `2`',
      'Continuity status: `continuous`',
      'Continuity break count: `0`',
      'Segment count: `1`',
      'Replay status: `ready-for-chunk-execution` \(chunk-plan-present\)'
    )) {
    if ($summary -notmatch $requiredFragment) {
      throw "Planned exploration summary must include '$requiredFragment'."
    }
  }

  $firstReceiptPath = [string]$chunkPlan.chunks[0].outputs.receiptPath
  $secondReceiptPath = [string]$chunkPlan.chunks[1].outputs.receiptPath
  $firstHistoryDir = Join-Path ([string]$chunkPlan.chunks[0].outputs.chunkRoot) 'history'
  $secondHistoryDir = Join-Path ([string]$chunkPlan.chunks[1].outputs.chunkRoot) 'history'
  New-Item -ItemType Directory -Path $firstHistoryDir -Force | Out-Null
  New-Item -ItemType Directory -Path $secondHistoryDir -Force | Out-Null
  $firstPreviewDir = Join-Path $firstHistoryDir 'preview-images'
  New-Item -ItemType Directory -Path $firstPreviewDir -Force | Out-Null
  $firstPreviewPath = Join-Path $firstPreviewDir 'cli-image-00.png'
  [System.IO.File]::WriteAllBytes($firstPreviewPath, @(0xCA,0xFE,0xBA,0xBE))
  $firstReportMd = Join-Path $firstHistoryDir 'history-report.md'
  $firstReportHtml = Join-Path $firstHistoryDir 'history-report.html'
  $firstModeSummaryJson = Join-Path ([string]$chunkPlan.chunks[0].outputs.chunkRoot) 'mode-summary.json'
  '# chunk 1 report' | Set-Content -LiteralPath $firstReportMd -Encoding utf8
  '<html><body>chunk 1 report</body></html>' | Set-Content -LiteralPath $firstReportHtml -Encoding utf8
  @'
{
  "schema": "comparevi-history/mode-summary@v1",
  "suppressionProfile": "unsuppressed",
  "metadata": {
    "comparisonArtifactCount": 1,
    "captureCount": 1,
    "imageArtifactCount": 1,
    "imageMimeTypes": ["image/png"]
  }
}
'@ | Set-Content -LiteralPath $firstModeSummaryJson -Encoding utf8

  $firstReceipt = [ordered]@{
    schema = 'comparevi-history/chunk-receipt@v1'
    generatedAtUtc = [DateTime]::UtcNow.ToString('o')
    chunkId = [string]$chunkPlan.chunks[0].chunkId
    chunkOrdinal = [int]$chunkPlan.chunks[0].chunkOrdinal
    segmentOrdinal = [int]$chunkPlan.chunks[0].segmentOrdinal
    status = 'succeeded'
    pairCount = [int]$chunkPlan.chunks[0].pairCount
    pairOrdinalStart = [int]$chunkPlan.chunks[0].pairOrdinalStart
    pairOrdinalEnd = [int]$chunkPlan.chunks[0].pairOrdinalEnd
    revisionOrdinalStart = [int]$chunkPlan.chunks[0].revisionOrdinalStart
    revisionOrdinalEnd = [int]$chunkPlan.chunks[0].revisionOrdinalEnd
    execution = [ordered]@{
      startRef = [string]$chunkPlan.chunks[0].execution.startRef
      endRef = [string]$chunkPlan.chunks[0].execution.endRef
      maxPairs = [int]$chunkPlan.chunks[0].execution.maxPairs
    }
    outputs = [ordered]@{
      chunkRoot = [string]$chunkPlan.chunks[0].outputs.chunkRoot
      receiptPath = $firstReceiptPath
      manifestPath = [string]$chunkPlan.chunks[0].outputs.manifestPath
      historyResultsDir = $firstHistoryDir
      historyReportMd = $firstReportMd
      historyReportHtml = $firstReportHtml
      modeSummaryPath = $null
      modeSummaryJsonPath = $firstModeSummaryJson
    }
    summary = [ordered]@{
      requestedModes = @('attributes', 'front-panel', 'block-diagram')
      executedModes = @('attributes', 'front-panel', 'block-diagram')
      modeCount = 3
      totalProcessed = 2
      totalDiffs = 1
      stopReason = 'completed'
      finalStatus = 'succeeded'
      finalReason = 'completed'
    }
    surfaces = [ordered]@{
      suppressionProfile = 'unsuppressed'
      comparisonArtifactCount = 1
      captureCount = 1
      imageArtifactCount = 1
      imageMimeTypes = @('image/png')
      chunkCountWithMetadata = 1
      categoryCounts = [ordered]@{
        '<div class="dropdown-left">First VI: /compare/m0/Base.vi</div><div class="dropdown-right">Second VI: /compare/m0/Head.vi</div>' = 2
        'Block Diagram objects' = 1
      }
      previewImages = @(
        [ordered]@{
          mode = 'attributes'
          category = 'Block Diagram objects'
          comparisonPair = [ordered]@{
            firstPath = '/compare/m0/Base.vi'
            secondPath = '/compare/m0/Head.vi'
          }
          mimeType = 'image/png'
          byteLength = 4
          savedPath = $firstPreviewPath
          artifactRelativePath = 'preview-images/cli-image-00.png'
          sortKey = 'attributes|block diagram objects|preview-images/cli-image-00.png'
        }
      )
      bucketCounts = [ordered]@{ 'metadata-rich' = 1 }
    }
    failure = $null
  }
  $firstReceipt | ConvertTo-Json -Depth 64 | Set-Content -LiteralPath $firstReceiptPath -Encoding utf8

  $secondReceipt = [ordered]@{
    schema = 'comparevi-history/chunk-receipt@v1'
    generatedAtUtc = [DateTime]::UtcNow.ToString('o')
    chunkId = [string]$chunkPlan.chunks[1].chunkId
    chunkOrdinal = [int]$chunkPlan.chunks[1].chunkOrdinal
    segmentOrdinal = [int]$chunkPlan.chunks[1].segmentOrdinal
    status = 'failed'
    pairCount = [int]$chunkPlan.chunks[1].pairCount
    pairOrdinalStart = [int]$chunkPlan.chunks[1].pairOrdinalStart
    pairOrdinalEnd = [int]$chunkPlan.chunks[1].pairOrdinalEnd
    revisionOrdinalStart = [int]$chunkPlan.chunks[1].revisionOrdinalStart
    revisionOrdinalEnd = [int]$chunkPlan.chunks[1].revisionOrdinalEnd
    execution = [ordered]@{
      startRef = [string]$chunkPlan.chunks[1].execution.startRef
      endRef = [string]$chunkPlan.chunks[1].execution.endRef
      maxPairs = [int]$chunkPlan.chunks[1].execution.maxPairs
    }
    outputs = [ordered]@{
      chunkRoot = [string]$chunkPlan.chunks[1].outputs.chunkRoot
      receiptPath = $secondReceiptPath
      manifestPath = [string]$chunkPlan.chunks[1].outputs.manifestPath
      historyResultsDir = $secondHistoryDir
      historyReportMd = $null
      historyReportHtml = $null
      modeSummaryPath = $null
      modeSummaryJsonPath = $null
    }
    summary = [ordered]@{
      requestedModes = @('attributes', 'front-panel', 'block-diagram')
      executedModes = @()
      modeCount = 0
      totalProcessed = 0
      totalDiffs = 0
      stopReason = 'facade-step-failed'
      finalStatus = 'failed'
      finalReason = 'facade-step-failed'
    }
    surfaces = [ordered]@{
      suppressionProfile = 'unknown'
      comparisonArtifactCount = 0
      captureCount = 0
      imageArtifactCount = 0
      imageMimeTypes = @()
      chunkCountWithMetadata = 0
      categoryCounts = [ordered]@{}
      bucketCounts = [ordered]@{}
    }
    failure = [ordered]@{
      message = 'Forced compare failure.'
    }
  }
  $secondReceipt | ConvertTo-Json -Depth 64 | Set-Content -LiteralPath $secondReceiptPath -Encoding utf8

  $executedOutputPath = Join-Path $tempRoot 'exploration-run-executed-output.txt'
  $executedSummaryPath = Join-Path $tempRoot 'exploration-run-executed-summary.md'
  $executedRunJson = & $explorationRunScriptPath `
    -RevisionCatalogPath (Join-Path $resultsDir 'revision-catalog.json') `
    -ChunkPlanPath (Join-Path $resultsDir 'chunk-plan.json') `
    -Modes 'attributes,front-panel,block-diagram' `
    -NoisePolicy 'collapse' `
    -GitHubOutputPath $executedOutputPath `
    -StepSummaryPath $executedSummaryPath

  $executedRun = $executedRunJson | ConvertFrom-Json -Depth 64
  if ($executedRun.planning.status -ne 'partial') {
    throw 'Executed exploration run planning status mismatch.'
  }
  if ($executedRun.summary.finalStatus -ne 'partial') {
    throw 'Executed exploration run final status mismatch.'
  }
  if ($executedRun.summary.finalReason -ne 'one-or-more-chunks-failed') {
    throw 'Executed exploration run final reason mismatch.'
  }
  if ($executedRun.replay.status -ne 'degraded') {
    throw 'Executed exploration run replay status mismatch.'
  }
  if ($executedRun.surfaces.suppressionProfile -ne 'unsuppressed') {
    throw 'Executed exploration run suppression profile mismatch.'
  }
  if ($executedRun.surfaces.captureCount -ne 1 -or $executedRun.surfaces.imageArtifactCount -ne 1) {
    throw 'Executed exploration run metadata counts mismatch.'
  }
  if (($executedRun.surfaces.imageMimeTypes -join ',') -ne 'image/png') {
    throw 'Executed exploration run mime-type aggregation mismatch.'
  }
  if ($executedRun.surfaces.categoryCounts.PSObject.Properties.Name -match 'First VI') {
    throw 'Executed exploration run category counts must not retain raw comparison identity fragments.'
  }
  if ($executedRun.surfaces.categoryCounts.'Block Diagram objects' -ne 1) {
    throw 'Executed exploration run normalized category counts mismatch.'
  }
  if ($executedRun.surfaces.comparisonPairs.Count -ne 1) {
    throw 'Executed exploration run comparison pair count mismatch.'
  }
  if ($executedRun.surfaces.comparisonPairs[0].firstPath -ne '/compare/m0/Base.vi' -or $executedRun.surfaces.comparisonPairs[0].secondPath -ne '/compare/m0/Head.vi' -or $executedRun.surfaces.comparisonPairs[0].count -ne 2) {
    throw 'Executed exploration run comparison pair normalization mismatch.'
  }
  if ($executedRun.surfaces.previewImages.Count -ne 1) {
    throw 'Executed exploration run preview image count mismatch.'
  }
  if ($executedRun.surfaces.previewImages[0].chunkId -ne [string]$chunkPlan.chunks[0].chunkId) {
    throw 'Executed exploration run preview image chunkId mismatch.'
  }
  if ($executedRun.surfaces.previewImages[0].relativePath -ne 'chunk-receipts/chunk-001/history/preview-images/cli-image-00.png') {
    throw 'Executed exploration run preview image relative path mismatch.'
  }
  if ($executedRun.summary.previewImageCount -ne 1 -or $executedRun.summary.previewGalleryCount -ne 1 -or $executedRun.summary.previewGalleryOmittedCount -ne 0) {
    throw 'Executed exploration run preview gallery summary mismatch.'
  }
  if ($executedRun.summary.stepSummaryPreviewCount -ne 1 -or $executedRun.summary.stepSummaryPreviewOmittedCount -ne 0) {
    throw 'Executed exploration run step-summary preview summary mismatch.'
  }

  $executedEvidenceGraph = Get-Content -LiteralPath $executedRun.evidence.graphPath -Raw | ConvertFrom-Json -Depth 64
  if ($executedEvidenceGraph.execution.status -ne 'partial' -or $executedEvidenceGraph.execution.reason -ne 'one-or-more-chunks-failed') {
    throw 'Executed evidence graph execution status mismatch.'
  }
  if ($executedEvidenceGraph.execution.chunks.Count -ne 2) {
    throw 'Executed evidence graph chunk count mismatch.'
  }
  if (($executedEvidenceGraph.execution.chunks | Where-Object { $_.status -eq 'failed' }).Count -ne 1) {
    throw 'Executed evidence graph failed chunk count mismatch.'
  }
  if ($executedEvidenceGraph.execution.chunks[0].surfaces.suppressionProfile -ne 'unsuppressed') {
    throw 'Executed evidence graph chunk-level suppression profile mismatch.'
  }
  if ($executedEvidenceGraph.execution.chunks[0].surfaces.comparisonPairs.Count -ne 1 -or $executedEvidenceGraph.execution.chunks[0].surfaces.previewImages.Count -ne 1) {
    throw 'Executed evidence graph chunk-level surfaces must retain normalized comparison-pair and preview-image evidence.'
  }
  if ($executedEvidenceGraph.execution.chunks[0].surfaces.previewImages[0].relativePath -ne 'chunk-receipts/chunk-001/history/preview-images/cli-image-00.png') {
    throw 'Executed evidence graph chunk-level preview image path mismatch.'
  }
  if ($executedEvidenceGraph.surfaces.categoryCounts.PSObject.Properties.Name -match 'First VI') {
    throw 'Executed evidence graph category counts must not retain raw comparison identity fragments.'
  }
  if ($executedEvidenceGraph.surfaces.comparisonPairs.Count -ne 1 -or $executedEvidenceGraph.surfaces.previewImages.Count -ne 1) {
    throw 'Executed evidence graph normalized pair/image surfaces mismatch.'
  }
  if ($executedEvidenceGraph.surfaces.previewImages[0].relativePath -ne 'chunk-receipts/chunk-001/history/preview-images/cli-image-00.png') {
    throw 'Executed evidence graph preview image path mismatch.'
  }
  if ($executedEvidenceGraph.completeness.finalStatus -ne 'partial' -or $executedEvidenceGraph.completeness.replayStatus -ne 'degraded') {
    throw 'Executed evidence graph completeness mismatch.'
  }
  if (($executedEvidenceGraph.surfaces.renderSurfaces | Where-Object { $_.kind -eq 'history-report-html' }).Count -ne 1) {
    throw 'Executed evidence graph must surface the chunk HTML report.'
  }
  if (($executedEvidenceGraph.surfaces.artifactSurfaces | Where-Object { $_.kind -eq 'mode-summary-json' }).Count -ne 1) {
    throw 'Executed evidence graph must surface the chunk mode summary JSON.'
  }
  if (($executedEvidenceGraph.continuity.segments[0].chunkIds -join ',') -ne 'chunk-001,chunk-002') {
    throw 'Executed evidence graph must keep segment chunk ordering deterministic.'
  }

  $timelineMarkdown = Get-Content -LiteralPath $executedRun.outputs.timelineMd -Raw
  if ($timelineMarkdown -notmatch [regex]::Escape([string]$chunkPlan.chunks[0].chunkId)) {
    throw 'Timeline markdown must include the executed chunk id.'
  }
  if ($timelineMarkdown -notmatch 'Failure: `Forced compare failure\.?`') {
    throw 'Timeline markdown must include the failed chunk message.'
  }
  foreach ($requiredFragment in @(
      'Failed chunk count: `1`',
      'Suppression profile: `unsuppressed`',
      'Metadata surfaces: `captures=1, images=1, artifact-dirs=1, mime-types=image/png`',
      'Comparison pairs: `/compare/m0/Base\.vi -> /compare/m0/Head\.vi \(2\)`',
      'Remaining planned chunk count: `0`',
      'Replay status: `degraded` \(partial-chunk-execution\)'
    )) {
    if ($timelineMarkdown -notmatch $requiredFragment) {
      throw "Executed timeline markdown must include '$requiredFragment'."
    }
  }
  $indexMarkdown = Get-Content -LiteralPath $executedRun.outputs.indexMd -Raw
  if ($indexMarkdown -notmatch 'comparevi-history manual exploration index') {
    throw 'Index markdown must include the index heading.'
  }
  foreach ($requiredFragment in @(
      '## Primary review surfaces',
      '## Review navigation',
      '### Mode navigation',
      '### Comparison pair navigation'
    )) {
    if ($indexMarkdown -notmatch [regex]::Escape($requiredFragment)) {
      throw "Index markdown must include '$requiredFragment'."
    }
  }
  if ($indexMarkdown -notmatch [regex]::Escape('chunk-receipts/chunk-001/history/history-report.html')) {
    throw 'Index markdown must surface chunk history report navigation.'
  }
  foreach ($requiredFragment in @(
      'Failed chunk count: `1`',
      'Suppression profile: `unsuppressed`',
      'Metadata surfaces: `captures=1, images=1, artifact-dirs=1, mime-types=image/png`',
      'Preview images: `1`',
      'Preview gallery: `1` shown, `0` omitted, cap `12`',
      'Comparison pairs: `/compare/m0/Base\.vi -> /compare/m0/Head\.vi \(2\)`',
      'Replay status: `degraded` \(partial-chunk-execution\)',
      'Bundle status: `not-required`'
    )) {
    if ($indexMarkdown -notmatch $requiredFragment) {
      throw "Executed index markdown must include '$requiredFragment'."
    }
  }
  if ($indexMarkdown -notmatch [regex]::Escape('![attributes | Block Diagram objects](chunk-receipts/chunk-001/history/preview-images/cli-image-00.png)')) {
    throw 'Executed index markdown must embed the preview image gallery entry.'
  }
  $executedSummary = Get-Content -LiteralPath $executedSummaryPath -Raw
  foreach ($requiredFragment in @(
      'Total chunk count: `2`',
      'Failed chunk count: `1`',
      'Remaining planned chunk count: `0`',
      'Continuity break count: `0`',
      'Preview images: `1`',
      'Step summary previews: `1` shown, `0` omitted, cap `2`, byte-budget `196608`',
      'Comparison pairs: `/compare/m0/Base\.vi -> /compare/m0/Head\.vi \(2\)`',
      'Replay status: `degraded` \(partial-chunk-execution\)'
    )) {
    if ($executedSummary -notmatch $requiredFragment) {
      throw "Executed step summary must include '$requiredFragment'."
    }
  }
  if ($executedSummary -notmatch 'data:image/png;base64,') {
    throw 'Executed step summary must embed a preview image data URI.'
  }

  $secondReceipt.status = 'succeeded'
  $secondReceipt.summary.executedModes = @('attributes', 'front-panel', 'block-diagram')
  $secondReceipt.summary.modeCount = 3
  $secondReceipt.summary.totalProcessed = [int]$chunkPlan.chunks[1].pairCount
  $secondReceipt.summary.totalDiffs = 1
  $secondReceipt.summary.stopReason = 'completed'
  $secondReceipt.summary.finalStatus = 'succeeded'
  $secondReceipt.summary.finalReason = 'completed'
  $secondReceipt.failure = $null
  $secondReceipt | ConvertTo-Json -Depth 64 | Set-Content -LiteralPath $secondReceiptPath -Encoding utf8

  $bundleDir = Join-Path $tempRoot 'bundle'
  New-Item -ItemType Directory -Path $bundleDir -Force | Out-Null
  $bundlePath = Join-Path $bundleDir 'manual-vi-exploration-bundle.zip'
  [System.IO.File]::WriteAllBytes($bundlePath, @(0x50,0x4B,0x03,0x04))

  $bundleOutputPath = Join-Path $tempRoot 'exploration-run-bundle-output.txt'
  $bundleSummaryPath = Join-Path $tempRoot 'exploration-run-bundle-summary.md'
  $bundledRunJson = & $explorationRunScriptPath `
    -RevisionCatalogPath (Join-Path $resultsDir 'revision-catalog.json') `
    -ChunkPlanPath (Join-Path $resultsDir 'chunk-plan.json') `
    -Modes 'attributes,front-panel,block-diagram' `
    -NoisePolicy 'collapse' `
    -BundlePath $bundlePath `
    -BundleStatus 'succeeded' `
    -BundleReason 'bundle-created' `
    -GitHubOutputPath $bundleOutputPath `
    -StepSummaryPath $bundleSummaryPath
  $bundledRun = $bundledRunJson | ConvertFrom-Json -Depth 64
  if ($bundledRun.outputs.bundlePath -ne $bundlePath) {
    throw 'Bundled exploration run must record bundlePath.'
  }
  if ($bundledRun.publication.bundleStatus -ne 'succeeded') {
    throw 'Bundled exploration run publication status mismatch.'
  }
  $bundledEvidenceGraph = Get-Content -LiteralPath $bundledRun.evidence.graphPath -Raw | ConvertFrom-Json -Depth 64
  if ($bundledEvidenceGraph.completeness.bundleStatus -ne 'succeeded') {
    throw 'Bundled evidence graph bundle status mismatch.'
  }
  if (($bundledEvidenceGraph.surfaces.artifactSurfaces | Where-Object { $_.kind -eq 'bundle-zip' }).Count -ne 1) {
    throw 'Bundled evidence graph must surface the published bundle.'
  }
  $bundledIndexMarkdown = Get-Content -LiteralPath $bundledRun.outputs.indexMd -Raw
  if ($bundledIndexMarkdown -notmatch [regex]::Escape('manual-vi-exploration-bundle.zip')) {
    throw 'Bundled exploration index must link the published bundle.'
  }

  $bundleFailureOutputPath = Join-Path $tempRoot 'exploration-run-bundle-failure-output.txt'
  $bundleFailureSummaryPath = Join-Path $tempRoot 'exploration-run-bundle-failure-summary.md'
  $bundleFailureRunJson = & $explorationRunScriptPath `
    -RevisionCatalogPath (Join-Path $resultsDir 'revision-catalog.json') `
    -ChunkPlanPath (Join-Path $resultsDir 'chunk-plan.json') `
    -Modes 'attributes,front-panel,block-diagram' `
    -NoisePolicy 'collapse' `
    -BundleStatus 'failed' `
    -BundleReason 'bundle-packaging-failed' `
    -GitHubOutputPath $bundleFailureOutputPath `
    -StepSummaryPath $bundleFailureSummaryPath
  $bundleFailureRun = $bundleFailureRunJson | ConvertFrom-Json -Depth 64
  if ($bundleFailureRun.summary.finalStatus -ne 'partial') {
    throw 'Bundle failure must degrade the final exploration run status.'
  }
  if ($bundleFailureRun.summary.finalReason -ne 'bundle-packaging-failed') {
    throw 'Bundle failure final reason mismatch.'
  }
  if ($bundleFailureRun.publication.bundleStatus -ne 'failed') {
    throw 'Bundle failure publication status mismatch.'
  }
  $bundleFailureEvidenceGraph = Get-Content -LiteralPath $bundleFailureRun.evidence.graphPath -Raw | ConvertFrom-Json -Depth 64
  if ($bundleFailureEvidenceGraph.completeness.bundleStatus -ne 'failed' -or $bundleFailureEvidenceGraph.completeness.bundleReason -ne 'bundle-packaging-failed') {
    throw 'Bundle failure evidence graph publication state mismatch.'
  }
  if ($bundleFailureEvidenceGraph.completeness.finalStatus -ne 'partial') {
    throw 'Bundle failure evidence graph must preserve degraded final status.'
  }
} finally {
  Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
