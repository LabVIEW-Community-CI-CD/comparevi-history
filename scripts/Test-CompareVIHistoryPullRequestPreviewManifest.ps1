Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptPath = Join-Path $PSScriptRoot 'Write-CompareVIHistoryPullRequestPreviewManifest.ps1'
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('comparevi-history-pr-preview-manifest-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

function New-PreviewReportFixture {
  param(
    [Parameter(Mandatory = $true)]
    [string]$ModeRoot,
    [Parameter(Mandatory = $true)]
    [int]$ComparisonIndex,
    [Parameter(Mandatory = $true)]
    [string]$BaseRef,
    [Parameter(Mandatory = $true)]
    [string]$HeadRef
  )

  $artifactDir = Join-Path $ModeRoot ('Demo.vi-{0:D3}-artifacts' -f $ComparisonIndex)
  $reportFilesDir = Join-Path $artifactDir 'compare-report_files'
  New-Item -ItemType Directory -Path $reportFilesDir -Force | Out-Null
  foreach ($imageName in @('fp_1.png', 'fp_2.png')) {
    [System.IO.File]::WriteAllBytes((Join-Path $reportFilesDir $imageName), @(0xCA, 0xFE, 0xBA, 0xBE))
  }

  $reportHtmlPath = Join-Path $artifactDir 'compare-report.html'
  @'
<!DOCTYPE html>
<html>
<body>
<div class="compared-VIs">
<details><summary class="difference-heading"><div class="dropdown-left">First VI: /compare/base/Base.vi</div><div class="dropdown-right">Second VI: /compare/head/Head.vi</div></summary>
<table class="difference"><tr class="compared-vi-image-captions"><td class="compared-vi-image-caption">Front Panel Overview</td></tr>
<tr class="compared-images"><td class="diff-image"><img class="difference-image" src="compare-report_files/fp_1.png"/></td><td class="difference-divider"></td><td class="diff-image"><img class="difference-image" src="compare-report_files/fp_2.png"/></td></tr></table></details>
</div>
</body>
</html>
'@ | Set-Content -LiteralPath $reportHtmlPath -Encoding utf8

  return [ordered]@{
    index = $ComparisonIndex
    base = [ordered]@{ ref = $BaseRef }
    head = [ordered]@{ ref = $HeadRef }
    result = [ordered]@{
      reportHtml = $reportHtmlPath
    }
  }
}

try {
  $resultsDir = Join-Path $tempRoot 'results'
  $targetRoot = Join-Path $resultsDir 'targets/001-demo/history'
  New-Item -ItemType Directory -Path $targetRoot -Force | Out-Null

  $modeManifests = New-Object System.Collections.Generic.List[object]
  foreach ($modeName in @('front-panel', 'block-diagram', 'attributes')) {
    $modeRoot = Join-Path $targetRoot $modeName
    New-Item -ItemType Directory -Path $modeRoot -Force | Out-Null

    $comparisons = @(
      (New-PreviewReportFixture -ModeRoot $modeRoot -ComparisonIndex 1 -BaseRef ('{0}-base-1' -f $modeName) -HeadRef ('{0}-head-1' -f $modeName)),
      (New-PreviewReportFixture -ModeRoot $modeRoot -ComparisonIndex 2 -BaseRef ('{0}-base-2' -f $modeName) -HeadRef ('{0}-head-2' -f $modeName))
    )

    $modeManifestPath = Join-Path $modeRoot 'manifest.json'
    ([ordered]@{
        schema = 'vi-compare/history@v1'
        generatedAt = '2026-03-18T00:00:00Z'
        mode = $modeName
        comparisons = $comparisons
      } | ConvertTo-Json -Depth 64) | Set-Content -LiteralPath $modeManifestPath -Encoding utf8

    $modeManifests.Add([ordered]@{
        name = $modeName
        manifestPath = $modeManifestPath
      }) | Out-Null
  }

  $suiteManifestPath = Join-Path $targetRoot 'manifest.json'
  ([ordered]@{
      schema = 'vi-compare/history-suite@v1'
      generatedAt = '2026-03-18T00:00:00Z'
      modes = @($modeManifests | ForEach-Object { $_ })
    } | ConvertTo-Json -Depth 64) | Set-Content -LiteralPath $suiteManifestPath -Encoding utf8

  $targetRunsManifestPath = Join-Path $resultsDir 'pr-target-runs-manifest.json'
  ([ordered]@{
      schema = 'comparevi-history/pr-target-runs-manifest@v2'
      generatedAtUtc = '2026-03-18T00:00:00Z'
      summary = [ordered]@{
        selectedTargetCount = 1
        executedTargetCount = 1
        failedTargetCount = 0
        skippedTargetCount = 0
        executionStatus = 'succeeded'
        executionReason = 'completed'
      }
      targets = @(
        [ordered]@{
          targetId = 'dynamic-demo-target'
          targetSource = 'dynamic-path'
          targetPath = 'Tooling/demo/Demo.vi'
          requestedModes = @('attributes', 'front-panel', 'block-diagram')
          keepArtifactsOnNoDiff = $true
          finalStatus = 'succeeded'
          finalReason = 'completed'
          manifestPath = $suiteManifestPath
        }
      )
    } | ConvertTo-Json -Depth 64) | Set-Content -LiteralPath $targetRunsManifestPath -Encoding utf8

  $outputPath = Join-Path $tempRoot 'preview-manifest.out'
  $receiptJson = & $scriptPath `
    -TargetRunsManifestPath $targetRunsManifestPath `
    -ResultsDir $resultsDir `
    -CommentPreviewPairCap 4 `
    -IndexPreviewPairCap 12 `
    -GitHubOutputPath $outputPath

  $receipt = $receiptJson | ConvertFrom-Json -Depth 64
  if ($receipt.schema -ne 'comparevi-history/pr-preview-manifest@v1') {
    throw 'Preview manifest schema mismatch.'
  }
  if ($receipt.summary.previewPairCount -ne 6) {
    throw 'Expected six preview pairs from the PR31-shaped fixture.'
  }
  if ($receipt.summary.commentSelectionPolicy -ne 'mode-balanced@v1' -or $receipt.summary.indexSelectionPolicy -ne 'mode-balanced@v1') {
    throw 'Expected explicit mode-balanced selection policies in the preview manifest summary.'
  }
  if ($receipt.summary.commentPreviewPairCount -ne 4 -or $receipt.summary.commentPreviewPairOmittedCount -ne 2) {
    throw 'Comment preview pair selection mismatch.'
  }
  if ($receipt.summary.indexPreviewPairCount -ne 6 -or $receipt.summary.indexPreviewPairOmittedCount -ne 0) {
    throw 'Index preview pair selection mismatch.'
  }
  if ($receipt.targets.Count -ne 1 -or $receipt.targets[0].previewPairCount -ne 6) {
    throw 'Target preview pair count mismatch.'
  }

  $commentOrder = @(
    $receipt.commentPreviewPairs |
      ForEach-Object { '{0}:{1}' -f [string]$_.mode, [int]$_.comparison.index }
  ) -join ','
  if ($commentOrder -ne 'front-panel:1,block-diagram:1,attributes:1,front-panel:2') {
    throw "Comment preview pair order mismatch: $commentOrder"
  }

  $indexOrder = @(
    $receipt.indexPreviewPairs |
      ForEach-Object { '{0}:{1}' -f [string]$_.mode, [int]$_.comparison.index }
  ) -join ','
  if ($indexOrder -ne 'front-panel:1,block-diagram:1,attributes:1,front-panel:2,block-diagram:2,attributes:2') {
    throw "Index preview pair order mismatch: $indexOrder"
  }

  if ($receipt.commentPreviewPairs[0].baseImageRelativePath -ne 'targets/001-demo/history/front-panel/Demo.vi-001-artifacts/compare-report_files/fp_1.png') {
    throw 'Expected normalized relative path for the first comment preview base image.'
  }
  if ($receipt.commentPreviewPairs[1].baseImageRelativePath -ne 'targets/001-demo/history/block-diagram/Demo.vi-001-artifacts/compare-report_files/fp_1.png') {
    throw 'Expected mode-specific preview identity to survive repeated image filenames.'
  }

  $outputText = Get-Content -LiteralPath $outputPath -Raw
  foreach ($requiredKey in @(
      'preview-manifest-path=',
      'preview-pair-count=6',
      'comment-preview-pair-count=4',
      'comment-preview-pair-omitted-count=2',
      'index-preview-pair-count=6',
      'index-preview-pair-omitted-count=0'
    )) {
    if ($outputText -notmatch [regex]::Escape($requiredKey)) {
      throw "Expected GitHub output '$requiredKey'."
    }
  }
} finally {
  Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
