Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$catalogScriptPath = Join-Path $PSScriptRoot 'Write-CompareVIHistoryRevisionCatalog.ps1'
$chunkPlanScriptPath = Join-Path $PSScriptRoot 'Write-CompareVIHistoryChunkPlan.ps1'
$explorationRunScriptPath = Join-Path $PSScriptRoot 'Write-CompareVIHistoryExplorationRun.ps1'
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("comparevi-history-exploration-index-" + [guid]::NewGuid().ToString('N'))
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

  'v1' | Set-Content -LiteralPath (Join-Path $targetDir 'Target.vi') -Encoding utf8
  Invoke-Git -RepositoryRoot $repoRoot -Arguments @('add', 'Tooling/deployment/Target.vi') | Out-Null
  Invoke-Git -RepositoryRoot $repoRoot -Arguments @('commit', '-m', 'Revision 1') | Out-Null

  'v2' | Set-Content -LiteralPath (Join-Path $targetDir 'Target.vi') -Encoding utf8
  Invoke-Git -RepositoryRoot $repoRoot -Arguments @('add', 'Tooling/deployment/Target.vi') | Out-Null
  Invoke-Git -RepositoryRoot $repoRoot -Arguments @('commit', '-m', 'Revision 2') | Out-Null

  Remove-Item -LiteralPath (Join-Path $targetDir 'Target.vi') -Force
  Invoke-Git -RepositoryRoot $repoRoot -Arguments @('add', 'Tooling/deployment/Target.vi') | Out-Null
  Invoke-Git -RepositoryRoot $repoRoot -Arguments @('commit', '-m', 'Revision 3 delete') | Out-Null

  'v4' | Set-Content -LiteralPath (Join-Path $targetDir 'Target.vi') -Encoding utf8
  Invoke-Git -RepositoryRoot $repoRoot -Arguments @('add', 'Tooling/deployment/Target.vi') | Out-Null
  Invoke-Git -RepositoryRoot $repoRoot -Arguments @('commit', '-m', 'Revision 4 reintroduce') | Out-Null

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
  $chunk = $chunkPlan.chunks[0]

  $chunkRoot = [string]$chunk.outputs.chunkRoot
  $historyDir = Join-Path $chunkRoot 'history'
  New-Item -ItemType Directory -Path $historyDir -Force | Out-Null
  $previewDir = Join-Path $historyDir 'preview-images'
  New-Item -ItemType Directory -Path $previewDir -Force | Out-Null
  $previewPath = Join-Path $previewDir 'cli-image-00.png'
  [System.IO.File]::WriteAllBytes($previewPath, @(0xCA,0xFE,0xBA,0xBE))
  '# history report' | Set-Content -LiteralPath (Join-Path $historyDir 'history-report.md') -Encoding utf8
  '<html><body>history report</body></html>' | Set-Content -LiteralPath (Join-Path $historyDir 'history-report.html') -Encoding utf8
  '# mode summary' | Set-Content -LiteralPath (Join-Path $chunkRoot 'mode-summary.md') -Encoding utf8

  $receiptPath = [string]$chunk.outputs.receiptPath
  $receipt = Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json -Depth 64
  $receipt.status = 'succeeded'
  $receipt | Add-Member -NotePropertyName summary -NotePropertyValue ([ordered]@{
      requestedModes = @('attributes', 'front-panel', 'block-diagram')
      executedModes = @('attributes', 'front-panel', 'block-diagram')
      modeCount = 3
      totalProcessed = [int]$chunk.pairCount
      totalDiffs = 1
      stopReason = 'completed'
      finalStatus = 'succeeded'
      finalReason = 'completed'
    }) -Force
  $receipt | Add-Member -NotePropertyName surfaces -NotePropertyValue ([ordered]@{
      suppressionProfile = 'unsuppressed'
      comparisonArtifactCount = 1
      captureCount = 1
      imageArtifactCount = 1
      imageMimeTypes = @('image/png')
      chunkCountWithMetadata = 1
      categoryCounts = [ordered]@{ attributes = 1 }
      previewImages = @(
        [ordered]@{
          mode = 'attributes'
          category = 'attributes'
          comparisonPair = $null
          mimeType = 'image/png'
          byteLength = 4
          savedPath = $previewPath
          artifactRelativePath = 'preview-images/cli-image-00.png'
          sortKey = 'attributes|attributes|preview-images/cli-image-00.png'
        }
      )
      bucketCounts = [ordered]@{ 'metadata-rich' = 1 }
    }) -Force
  $receipt.outputs | Add-Member -NotePropertyName historyResultsDir -NotePropertyValue $historyDir -Force
  $receipt.outputs | Add-Member -NotePropertyName historyReportMd -NotePropertyValue (Join-Path $historyDir 'history-report.md') -Force
  $receipt.outputs | Add-Member -NotePropertyName historyReportHtml -NotePropertyValue (Join-Path $historyDir 'history-report.html') -Force
  $receipt.outputs | Add-Member -NotePropertyName modeSummaryPath -NotePropertyValue (Join-Path $chunkRoot 'mode-summary.md') -Force
  '{}' | Set-Content -LiteralPath (Join-Path $chunkRoot 'mode-summary.json') -Encoding utf8
  $receipt.outputs | Add-Member -NotePropertyName modeSummaryJsonPath -NotePropertyValue (Join-Path $chunkRoot 'mode-summary.json') -Force
  $receipt | ConvertTo-Json -Depth 64 | Set-Content -LiteralPath $receiptPath -Encoding utf8

  $explorationRunJson = & $explorationRunScriptPath `
    -RevisionCatalogPath (Join-Path $resultsDir 'revision-catalog.json') `
    -ChunkPlanPath (Join-Path $resultsDir 'chunk-plan.json') `
    -Modes 'attributes,front-panel,block-diagram' `
    -NoisePolicy 'collapse'
  $explorationRun = $explorationRunJson | ConvertFrom-Json -Depth 64

  $indexMd = [string]$explorationRun.outputs.indexMd
  $indexHtml = [string]$explorationRun.outputs.indexHtml
  if (-not (Test-Path -LiteralPath $indexMd -PathType Leaf)) {
    throw 'Index markdown was not written.'
  }
  if (-not (Test-Path -LiteralPath $indexHtml -PathType Leaf)) {
    throw 'Index HTML was not written.'
  }

  $indexMarkdown = Get-Content -LiteralPath $indexMd -Raw
  if ($indexMarkdown -notmatch 'comparevi-history manual exploration index') {
    throw 'Index markdown heading mismatch.'
  }
  if ($indexMarkdown -notmatch [regex]::Escape('[timeline.md](timeline.md)')) {
    throw 'Index markdown must link the timeline markdown surface.'
  }
  if ($indexMarkdown -notmatch [regex]::Escape('chunk-receipts/chunk-001/chunk-receipt.json')) {
    throw 'Index markdown must link the chunk receipt.'
  }
  if ($indexMarkdown -notmatch [regex]::Escape('chunk-receipts/chunk-001/history/history-report.html')) {
    throw 'Index markdown must link the chunk HTML report.'
  }
  if ($indexMarkdown -notmatch [regex]::Escape('![attributes | attributes](chunk-receipts/chunk-001/history/preview-images/cli-image-00.png)')) {
    throw 'Index markdown must embed the preview image gallery entry.'
  }
  foreach ($requiredFragment in @(
      'Continuity status: `break-detected`',
      'Continuity break count: `1`',
      'Segment count: `2`',
      'Suppression profile: `unsuppressed`',
      'Metadata surfaces: `captures=1, images=1, artifact-dirs=1, mime-types=image/png`',
      'Preview images: `1`',
      'Preview gallery: `1` shown, `0` omitted, cap `12`',
      'Segment `1`: revisions `1` -> `3`, pairs `2`, start `selected-ref-lineage-start`; break after revision `3` \(delete-observed\)',
      'Segment `2`: revisions `4` -> `4`, pairs `0`, start `reintroduced-after-delete`'
    )) {
    if ($indexMarkdown -notmatch $requiredFragment) {
      throw "Index markdown must include '$requiredFragment'."
    }
  }

  $indexHtmlContent = Get-Content -LiteralPath $indexHtml -Raw
  if ($indexHtmlContent -notmatch 'comparevi-history manual exploration index') {
    throw 'Index HTML heading mismatch.'
  }
  if ($indexHtmlContent -notmatch [regex]::Escape('href="timeline.html"')) {
    throw 'Index HTML must link the timeline HTML surface.'
  }
  if ($indexHtmlContent -notmatch [regex]::Escape('history-report.html')) {
    throw 'Index HTML must link the chunk HTML report.'
  }
  if ($indexHtmlContent -notmatch [regex]::Escape('src="chunk-receipts/chunk-001/history/preview-images/cli-image-00.png"')) {
    throw 'Index HTML must embed the preview image gallery entry.'
  }
  foreach ($requiredFragment in @(
      'Continuity status</strong><span>break-detected</span>',
      'Continuity break count</strong><span>1</span>',
      'Suppression profile</strong><span>unsuppressed</span>',
      'Metadata surfaces</strong><span>captures=1, images=1, artifact-dirs=1</span>',
      'Preview images</strong><span>1</span>',
      'Remaining planned chunks</strong><span>0</span>',
      'reintroduced-after-delete',
      'delete-observed'
    )) {
    if ($indexHtmlContent -notmatch $requiredFragment) {
      throw "Index HTML must include '$requiredFragment'."
    }
  }
} finally {
  Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
