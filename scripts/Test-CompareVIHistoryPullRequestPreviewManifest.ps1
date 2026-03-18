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
    [string]$ModeName,
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
  [System.IO.File]::WriteAllBytes((Join-Path $reportFilesDir 'fp_1.png'), @(0xCA, 0xFE, 0xBA, 0xBE))
  [System.IO.File]::WriteAllBytes((Join-Path $reportFilesDir 'fp_2.png'), @(0xBE, 0xBA, 0xFE, 0xCA))
  [System.IO.File]::WriteAllBytes((Join-Path $reportFilesDir 'bd_1.png'), @(0x0B, 0xD1, 0xA6, 0x01))
  [System.IO.File]::WriteAllBytes((Join-Path $reportFilesDir 'bd_2.png'), @(0x10, 0x0C, 0xD1, 0xA6))

  $reportHtmlPath = Join-Path $artifactDir 'compare-report.html'
  $reportHtml = if ($ModeName -eq 'attributes') {
@"
<!DOCTYPE html>
<html>
<body>
<div class="compared-VIs">
<details><summary class="difference-heading"><div class="dropdown-left">First VI: /compare/base/Base.vi</div><div class="dropdown-right">Second VI: /compare/head/Head.vi</div></summary>
<table class="difference"><tr class="compared-vi-image-captions"><td class="compared-vi-image-caption">Front Panel Overview</td></tr>
<tr class="compared-images"><td class="diff-image"><img class="difference-image" src="compare-report_files/fp_1.png"/></td><td class="difference-divider"></td><td class="diff-image"><img class="difference-image" src="compare-report_files/fp_2.png"/></td></tr>
<tr class="compared-vi-image-captions"><td class="compared-vi-image-caption">Block Diagram Overview</td></tr>
<tr class="compared-images"><td class="diff-image"><img class="difference-image" src="compare-report_files/bd_1.png"/></td><td class="difference-divider"></td><td class="diff-image"><img class="difference-image" src="compare-report_files/bd_2.png"/></td></tr></table></details>
</div>
<div class="included-attributes">
<ul class="inclusion-list">
<li class="checked">Block Diagram Functional</li>
<li class="checked">VI Attribute</li>
</ul>
</div>
<h2 class="section-header">Detailed Information</h2>
$(if ($ComparisonIndex -eq 1) {
@'
<details open>
<summary class="difference-heading">1. Block Diagram objects</summary>
<ol class="detailed-description-list" type="A">
<li class="diff-detail">Property Node - moved : changed from "(-35,102)" to "(-55,77)"</li>
<li class="diff-detail">Tunnel - moved : changed from "(141,124)" to "(141,124)"</li>
<li class="diff-detail">Case Selector - moved : changed from "(141,143)" to "(141,143)"</li>
</ol>
</details>
<details open>
<summary class="difference-heading">2. Block Diagram objects</summary>
<ol class="detailed-description-list" type="A">
<li class="diff-detail">Case Structure - resized : changed from "702*298" to "702*370"</li>
<li class="diff-detail"> - resized : changed from "690*23" to "690*25"</li>
</ol>
</details>
'@
} else {
@'
<details open>
<summary class="difference-heading">1. VI Attribute - Miscellaneous</summary>
<ol class="detailed-description-list" type="A">
<li class="diff-detail">VI Version : changed from "21.0" to "20.0"</li>
</ol>
</details>
'@
})
</body>
</html>
"@
  } else {
@'
<!DOCTYPE html>
<html>
<body>
<div class="compared-VIs">
<details><summary class="difference-heading"><div class="dropdown-left">First VI: /compare/base/Base.vi</div><div class="dropdown-right">Second VI: /compare/head/Head.vi</div></summary>
<table class="difference"><tr class="compared-vi-image-captions"><td class="compared-vi-image-caption">Front Panel Overview</td></tr>
<tr class="compared-images"><td class="diff-image"><img class="difference-image" src="compare-report_files/fp_1.png"/></td><td class="difference-divider"></td><td class="diff-image"><img class="difference-image" src="compare-report_files/fp_2.png"/></td></tr>
<tr class="compared-vi-image-captions"><td class="compared-vi-image-caption">Block Diagram Overview</td></tr>
<tr class="compared-images"><td class="diff-image"><img class="difference-image" src="compare-report_files/bd_1.png"/></td><td class="difference-divider"></td><td class="diff-image"><img class="difference-image" src="compare-report_files/bd_2.png"/></td></tr></table></details>
</div>
</body>
</html>
'@
  }
  $reportHtml | Set-Content -LiteralPath $reportHtmlPath -Encoding utf8

  return [ordered]@{
    index = $ComparisonIndex
    base = [ordered]@{
      ref = $BaseRef
      short = ('base-{0:D2}' -f $ComparisonIndex)
    }
    head = [ordered]@{
      ref = $HeadRef
      short = ('head-{0:D2}' -f $ComparisonIndex)
    }
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
      (New-PreviewReportFixture -ModeRoot $modeRoot -ModeName $modeName -ComparisonIndex 1 -BaseRef ('{0}-base-1' -f $modeName) -HeadRef ('{0}-head-1' -f $modeName)),
      (New-PreviewReportFixture -ModeRoot $modeRoot -ModeName $modeName -ComparisonIndex 2 -BaseRef ('{0}-base-2' -f $modeName) -HeadRef ('{0}-head-2' -f $modeName))
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
  if ($receipt.summary.previewPairCount -ne 4) {
    throw 'Expected four raw preview pairs from the PR31-shaped fixture.'
  }
  if ($receipt.summary.rawPreviewPairCount -ne 4 -or $receipt.summary.reviewerPreviewPairCount -ne 2) {
    throw 'Expected explicit raw and reviewer preview pair counts in the preview manifest summary.'
  }
  if ($receipt.summary.reviewerPreviewCardCount -ne 2 -or
    $receipt.summary.reviewerPreviewSurfaceCount -ne 4) {
    throw 'Expected reviewer preview card and surface counts in the preview manifest summary.'
  }
  if ($receipt.summary.commentSelectionPolicy -ne 'reviewer-canonical@v1' -or $receipt.summary.indexSelectionPolicy -ne 'reviewer-canonical@v1') {
    throw 'Expected explicit reviewer-canonical selection policies in the preview manifest summary.'
  }
  if ($receipt.summary.commentPreviewPairCount -ne 2 -or $receipt.summary.commentPreviewPairOmittedCount -ne 0) {
    throw 'Comment preview pair selection mismatch.'
  }
  if ($receipt.summary.commentPreviewCardCount -ne 2 -or
    $receipt.summary.commentPreviewSurfaceCount -ne 4 -or
    $receipt.summary.commentCardSelectionPolicy -ne 'reviewer-multisurface@v1') {
    throw 'Comment preview card summary mismatch.'
  }
  if ($receipt.summary.indexPreviewPairCount -ne 2 -or $receipt.summary.indexPreviewPairOmittedCount -ne 0) {
    throw 'Index preview pair selection mismatch.'
  }
  if ($receipt.summary.indexPreviewCardCount -ne 2 -or
    $receipt.summary.indexPreviewSurfaceCount -ne 4 -or
    $receipt.summary.indexCardSelectionPolicy -ne 'reviewer-multisurface@v1') {
    throw 'Index preview card summary mismatch.'
  }
  if ($receipt.targets.Count -ne 1 -or $receipt.targets[0].previewPairCount -ne 4) {
    throw 'Target preview pair count mismatch.'
  }

  $commentOrder = @(
    $receipt.commentPreviewPairs |
      ForEach-Object { '{0}:{1}' -f [string]$_.mode, [int]$_.comparison.index }
  ) -join ','
  if ($commentOrder -ne 'front-panel:1,front-panel:2') {
    throw "Comment preview pair order mismatch: $commentOrder"
  }

  $indexOrder = @(
    $receipt.indexPreviewPairs |
      ForEach-Object { '{0}:{1}' -f [string]$_.mode, [int]$_.comparison.index }
  ) -join ','
  if ($indexOrder -ne 'front-panel:1,front-panel:2') {
    throw "Index preview pair order mismatch: $indexOrder"
  }

  if ($receipt.commentPreviewPairs[0].baseImageRelativePath -ne 'targets/001-demo/history/front-panel/Demo.vi-001-artifacts/compare-report_files/fp_1.png') {
    throw 'Expected normalized relative path for the first comment preview base image.'
  }
  if ($receipt.commentPreviewPairs[1].baseImageRelativePath -ne 'targets/001-demo/history/front-panel/Demo.vi-002-artifacts/compare-report_files/fp_1.png') {
    throw 'Expected reviewer selection to collapse mode-duplicated preview pairs while preserving comparison order.'
  }
  if ([string]$receipt.commentPreviewPairs[0].comparison.baseShortRef -ne 'base-01' -or
    [string]$receipt.commentPreviewPairs[0].comparison.headShortRef -ne 'head-01') {
    throw 'Expected preview manifest pairs to preserve comparison short refs for reviewer rendering.'
  }
  if ($null -ne $receipt.commentPreviewPairs[0].comparison.baseSubject -or
    $null -ne $receipt.commentPreviewPairs[0].comparison.headSubject) {
    throw 'Preview manifest fixture without a repository root should not invent commit subjects.'
  }
  if ($receipt.commentPreviewCards.Count -ne 2 -or $receipt.indexPreviewCards.Count -ne 2) {
    throw 'Expected reviewer preview cards for both comment and index surfaces.'
  }
  $commentCardSurfaceSummary = @(
    $receipt.commentPreviewCards[0].surfaces |
      ForEach-Object { [string]$_.surfaceKind }
  ) -join ','
  if ($commentCardSurfaceSummary -ne 'front-panel,block-diagram') {
    throw "Expected the first reviewer card to surface both front-panel and block-diagram images. Actual: $commentCardSurfaceSummary"
  }
  if ($receipt.commentPreviewCards[0].surfaces[0].surfaceLabel -ne 'Front panel' -or
    $receipt.commentPreviewCards[0].surfaces[1].surfaceLabel -ne 'Block diagram') {
    throw 'Reviewer cards should use reviewer-facing surface labels.'
  }
  if ($receipt.commentPreviewCards[0].surfaces[0].baseImageRelativePath -ne 'targets/001-demo/history/front-panel/Demo.vi-001-artifacts/compare-report_files/fp_1.png' -or
    $receipt.commentPreviewCards[0].surfaces[1].baseImageRelativePath -ne 'targets/001-demo/history/block-diagram/Demo.vi-001-artifacts/compare-report_files/bd_1.png') {
    throw 'Reviewer cards should preserve both front-panel and block-diagram image paths for the same history pair.'
  }
  if ([string]$receipt.commentPreviewCards[0].changeDetails.label -ne 'Change details' -or
    [string]$receipt.commentPreviewCards[0].changeDetails.sourceMode -ne 'attributes') {
    throw 'Reviewer cards should attach bounded change-detail summaries from the attributes compare report.'
  }
  if ((@($receipt.commentPreviewCards[0].changeDetails.includedCategories) -join ',') -ne 'Block Diagram Functional,VI Attribute') {
    throw 'Reviewer cards should preserve included categories from the attributes compare report.'
  }
  if ([string]$receipt.commentPreviewCards[0].changeDetails.groups[0].heading -ne 'Block diagram moves' -or
    [int]$receipt.commentPreviewCards[0].changeDetails.groups[0].detailCount -ne 3 -or
    [int]$receipt.commentPreviewCards[0].changeDetails.groups[0].sectionCount -ne 1 -or
    [int]$receipt.commentPreviewCards[0].changeDetails.groups[0].omittedDetailCount -ne 0) {
    throw 'Reviewer cards should split coarse block diagram sections into semantic move groups.'
  }
  if ($receipt.commentPreviewCards[0].changeDetails.groups[0].sampleDetails.Count -ne 3 -or
    $receipt.commentPreviewCards[0].changeDetails.groups[0].sampleDetails[0] -notmatch 'Property Node - moved') {
    throw 'Reviewer cards should preserve the first bounded change-detail samples.'
  }
  if ([string]$receipt.commentPreviewCards[0].changeDetails.groups[1].heading -ne 'Block diagram resizing' -or
    [int]$receipt.commentPreviewCards[0].changeDetails.groups[1].detailCount -ne 2 -or
    [string]$receipt.commentPreviewCards[0].changeDetails.groups[1].primaryReportHtmlRelativePath -ne 'targets/001-demo/history/attributes/Demo.vi-001-artifacts/compare-report.html#comparevi-change-002-block-diagram-objects') {
    throw 'Reviewer cards should surface semantic resize groups with exact section anchors.'
  }
  if ($receipt.commentPreviewCards[0].changeDetails.groups[0].sectionLinks.Count -ne 1 -or
    [string]$receipt.commentPreviewCards[0].changeDetails.groups[0].sectionLinks[0].reportHtmlRelativePath -ne 'targets/001-demo/history/attributes/Demo.vi-001-artifacts/compare-report.html#comparevi-change-001-block-diagram-objects' -or
    [string]$receipt.commentPreviewCards[0].changeDetails.groups[0].sectionLinks[0].label -ne 'section 1') {
    throw 'Reviewer cards should expose exact section links for semantic groups.'
  }
  if ([string]$receipt.commentPreviewCards[1].changeDetails.groups[0].heading -ne 'VI version changes' -or
    [string]$receipt.commentPreviewCards[1].changeDetails.groups[0].primaryReportHtmlRelativePath -ne 'targets/001-demo/history/attributes/Demo.vi-002-artifacts/compare-report.html#comparevi-change-001-vi-attribute-miscellaneous' -or
    $receipt.commentPreviewCards[1].changeDetails.groups[0].sampleDetails[0] -notmatch 'VI Version : changed from "21\.0" to "20\.0"') {
    throw 'Reviewer cards should preserve distinct VI attribute change summaries for later history pairs.'
  }

  $anchoredReportHtml = Get-Content -LiteralPath (Join-Path $targetRoot 'attributes/Demo.vi-001-artifacts/compare-report.html') -Raw
  if ($anchoredReportHtml -notmatch [regex]::Escape('id="comparevi-change-001-block-diagram-objects"') -or
    $anchoredReportHtml -notmatch [regex]::Escape('id="comparevi-change-002-block-diagram-objects"')) {
    throw 'Attributes compare reports should be stamped with deterministic section anchors for reviewer deep links.'
  }

  $outputText = Get-Content -LiteralPath $outputPath -Raw
  foreach ($requiredKey in @(
      'preview-manifest-path=',
      'preview-pair-count=2',
      'raw-preview-pair-count=4',
      'reviewer-preview-pair-count=2',
      'comment-preview-pair-count=2',
      'comment-preview-pair-omitted-count=0',
      'index-preview-pair-count=2',
      'index-preview-pair-omitted-count=0',
      'reviewer-preview-card-count=2',
      'reviewer-preview-surface-count=4',
      'comment-preview-card-count=2',
      'comment-preview-surface-count=4',
      'index-preview-card-count=2',
      'index-preview-surface-count=4'
    )) {
    if ($outputText -notmatch [regex]::Escape($requiredKey)) {
      throw "Expected GitHub output '$requiredKey'."
    }
  }
} finally {
  Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
