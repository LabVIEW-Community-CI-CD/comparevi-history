$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'CompareVIHistoryReviewBundleFixture.psm1') -Force

$scriptPath = Join-Path $PSScriptRoot 'Invoke-CompareVIHistoryReviewBundleCompiler.ps1'
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('comparevi-history-review-bundle-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

try {
  $fixture = New-CompareVIHistorySyntheticReviewBundleFixture -RootPath $tempRoot
  $resultsDir = [string]$fixture.resultsDir
  $targetRunsManifestPath = [string]$fixture.targetRunsManifestPath

  $outputPath = Join-Path $resultsDir 'review-bundle.json'
  $receiptJson = & $scriptPath -TargetRunsManifestPath $targetRunsManifestPath -ResultsDir $resultsDir -OutputPath $outputPath
  $receipt = $receiptJson | ConvertFrom-Json -Depth 64

  if ($receipt.schema -ne 'comparevi-history/review-bundle@v1') {
    throw 'Review bundle schema mismatch.'
  }
  if ($receipt.summary.targetCount -ne 1 -or
    $receipt.summary.rawPreviewPairCount -ne 4 -or
    $receipt.summary.reviewPairCount -ne 2 -or
    $receipt.summary.primaryReviewerDestinationPolicy -ne 'pair-level@v1') {
    throw 'Review bundle summary mismatch.'
  }
  if ($receipt.targets.Count -ne 1 -or
    $receipt.targets[0].rawPreviewPairCount -ne 4 -or
    $receipt.targets[0].reviewPairCount -ne 2) {
    throw 'Review bundle target summary mismatch.'
  }
  if ($receipt.rawPreviewPairs.Count -ne 4) {
    throw 'Expected four raw preview pairs in the review bundle.'
  }
  if ([string]$receipt.rawPreviewPairs[0].debugReportHtmlRelativePath -ne 'targets/001-demo/history/front-panel/Demo.vi-001-artifacts/compare-report.html') {
    throw 'Expected the first raw preview pair to preserve the raw report destination.'
  }
  if (($receipt.reviewPairs | Measure-Object).Count -ne 2) {
    throw 'Expected two compiled review pairs.'
  }
  if ([string]$receipt.reviewPairs[0].primaryReviewerDestination.kind -ne 'history-pair-review-page' -or
    $null -ne $receipt.reviewPairs[0].primaryReviewerDestination.relativePath) {
    throw 'Expected pair-level reviewer destinations from the compiled review bundle.'
  }
  $surfaceKinds = @($receipt.reviewPairs[0].surfaces | ForEach-Object { [string]$_.surfaceKind }) -join ','
  if ($surfaceKinds -ne 'front-panel,block-diagram') {
    throw "Expected front-panel and block-diagram surfaces on the first review pair. Actual: $surfaceKinds"
  }
  if ([string]$receipt.reviewPairs[0].debugDestinations.frontPanelReportHtmlRelativePath -ne 'targets/001-demo/history/front-panel/Demo.vi-001-artifacts/compare-report.html' -or
    [string]$receipt.reviewPairs[0].debugDestinations.blockDiagramReportHtmlRelativePath -ne 'targets/001-demo/history/block-diagram/Demo.vi-001-artifacts/compare-report.html' -or
    [string]$receipt.reviewPairs[0].debugDestinations.changeDetailsReportHtmlRelativePath -ne 'targets/001-demo/history/attributes/Demo.vi-001-artifacts/compare-report.reviewer-anchors.html') {
    throw 'Expected debug destinations to preserve the raw mode-scoped reports.'
  }
  if ([string]$receipt.reviewPairs[0].reviewerSummary.headline -ne 'Material logic-affecting movement and structure resizing' -or
    [string]$receipt.reviewPairs[1].reviewerSummary.headline -ne 'Material version or compatibility changes') {
    throw 'Reviewer summary compilation mismatch.'
  }
  if ([string]$receipt.reviewPairs[0].changeDetails.groups[0].heading -ne 'Block diagram moves' -or
    [string]$receipt.reviewPairs[0].changeDetails.groups[1].heading -ne 'Block diagram resizing' -or
    [string]$receipt.reviewPairs[1].changeDetails.groups[0].heading -ne 'VI version changes') {
    throw 'Change-details compilation mismatch.'
  }
  if ([string]$receipt.reviewPairs[0].changeDetails.groups[0].sectionLinks[0].debugReportHtmlRelativePath -ne 'targets/001-demo/history/attributes/Demo.vi-001-artifacts/compare-report.reviewer-anchors.html#comparevi-change-001-block-diagram-objects' -or
    [string]$receipt.reviewPairs[1].changeDetails.groups[0].primaryDebugReportHtmlRelativePath -ne 'targets/001-demo/history/attributes/Demo.vi-002-artifacts/compare-report.reviewer-anchors.html#comparevi-change-001-vi-attribute-miscellaneous') {
    throw 'Expected anchored attribute debug links in the compiled review bundle.'
  }
}
finally {
  if (Test-Path -LiteralPath $tempRoot) {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force
  }
}
