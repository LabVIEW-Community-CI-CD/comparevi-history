Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptPath = Join-Path $PSScriptRoot 'Write-CompareVIHistoryPullRequestPreviewManifest.ps1'
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('comparevi-history-pr-preview-manifest-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

try {
  $resultsDir = Join-Path $tempRoot 'results'
  $targetRoot = Join-Path $resultsDir 'targets/001-demo/history'
  $modeRoot = Join-Path $targetRoot 'front-panel'
  $artifactDir = Join-Path $modeRoot 'Demo.vi-001-artifacts'
  $reportFilesDir = Join-Path $artifactDir 'compare-report_files'
  New-Item -ItemType Directory -Path $reportFilesDir -Force | Out-Null

  foreach ($imageName in @('fp_1.png', 'fp_2.png', '0_0_11_11_1.png', '0_0_11_11_2.png', '1_0_11_11_1.png', '1_0_11_11_2.png')) {
    [System.IO.File]::WriteAllBytes((Join-Path $reportFilesDir $imageName), @(0xCA, 0xFE, 0xBA, 0xBE))
  }

  $reportHtmlPath = Join-Path $artifactDir 'compare-report.html'
  @'
<!DOCTYPE html>
<html>
<body>
<div class="compared-VIs">
<details><summary class="difference-heading"><div class="dropdown-left">First VI: /compare/m0/Base.vi</div><div class="dropdown-right">Second VI: /compare/m0/Head.vi</div></summary>
<table class="difference"><tr class="compared-vi-image-captions"><td class="compared-vi-image-caption">Front Panel Overview</td></tr>
<tr class="compared-images"><td class="diff-image"><img class="difference-image" src="compare-report_files/fp_1.png"/></td><td class="difference-divider"></td><td class="diff-image"><img class="difference-image" src="compare-report_files/fp_2.png"/></td></tr></table></details>
</div>
<div class="included-attributes"></div>
<details class="cosmetic" closed>
<summary class="difference-cosmetic-heading">1. Front Panel - Variant</summary>
<table class="difference"><tr class="compared-vi-image-captions"><td class="compared-vi-image-caption">/compare/m0/Base.vi</td><td class="difference-divider"></td><td class="compared-vi-image-caption">/compare/m0/Head.vi</td></tr><tr class="compared-images"><td class="diff-image"><img class="difference-image" src="compare-report_files/0_0_11_11_1.png" alt="compare-report_files/0_0_11_11_1.png"></td><td class="difference-divider"></td><td class="diff-image"><img class="difference-image" src="compare-report_files/0_0_11_11_2.png" alt="compare-report_files/0_0_11_11_2.png"></td></tr></table>
</details>
<details class="cosmetic" closed>
<summary class="difference-cosmetic-heading">2. Front Panel - Pane</summary>
<table class="difference"><tr class="compared-vi-image-captions"><td class="compared-vi-image-caption">/compare/m0/Base.vi</td><td class="difference-divider"></td><td class="compared-vi-image-caption">/compare/m0/Head.vi</td></tr><tr class="compared-images"><td class="diff-image"><img class="difference-image" src="compare-report_files/1_0_11_11_1.png" alt="compare-report_files/1_0_11_11_1.png"></td><td class="difference-divider"></td><td class="diff-image"><img class="difference-image" src="compare-report_files/1_0_11_11_2.png" alt="compare-report_files/1_0_11_11_2.png"></td></tr></table>
</details>
</body>
</html>
'@ | Set-Content -LiteralPath $reportHtmlPath -Encoding utf8

  $modeManifestPath = Join-Path $modeRoot 'manifest.json'
  @"
{
  "schema": "vi-compare/history@v1",
  "generatedAt": "2026-03-18T00:00:00Z",
  "mode": "front-panel",
  "comparisons": [
    {
      "index": 1,
      "base": { "ref": "base-sha" },
      "head": { "ref": "head-sha" },
      "result": {
        "reportHtml": "$($reportHtmlPath.Replace('\', '\\'))"
      }
    }
  ]
}
"@ | Set-Content -LiteralPath $modeManifestPath -Encoding utf8

  $suiteManifestPath = Join-Path $targetRoot 'manifest.json'
  @"
{
  "schema": "vi-compare/history-suite@v1",
  "generatedAt": "2026-03-18T00:00:00Z",
  "modes": [
    {
      "name": "front-panel",
      "manifestPath": "$($modeManifestPath.Replace('\', '\\'))"
    }
  ]
}
"@ | Set-Content -LiteralPath $suiteManifestPath -Encoding utf8

  $targetRunsManifestPath = Join-Path $resultsDir 'pr-target-runs-manifest.json'
  @"
{
  "schema": "comparevi-history/pr-target-runs-manifest@v2",
  "generatedAtUtc": "2026-03-18T00:00:00Z",
  "summary": {
    "selectedTargetCount": 1,
    "executedTargetCount": 1,
    "failedTargetCount": 0,
    "skippedTargetCount": 0,
    "executionStatus": "succeeded",
    "executionReason": "completed"
  },
  "targets": [
    {
      "targetId": "dynamic-demo-target",
      "targetSource": "dynamic-path",
      "targetPath": "Tooling/demo/Demo.vi",
      "requestedModes": ["front-panel"],
      "keepArtifactsOnNoDiff": true,
      "finalStatus": "succeeded",
      "finalReason": "completed",
      "manifestPath": "$($suiteManifestPath.Replace('\', '\\'))"
    }
  ]
}
"@ | Set-Content -LiteralPath $targetRunsManifestPath -Encoding utf8

  $outputPath = Join-Path $tempRoot 'preview-manifest.out'
  $receiptJson = & $scriptPath `
    -TargetRunsManifestPath $targetRunsManifestPath `
    -ResultsDir $resultsDir `
    -CommentPreviewPairCap 2 `
    -IndexPreviewPairCap 3 `
    -GitHubOutputPath $outputPath

  $receipt = $receiptJson | ConvertFrom-Json -Depth 64
  if ($receipt.schema -ne 'comparevi-history/pr-preview-manifest@v1') {
    throw 'Preview manifest schema mismatch.'
  }
  if ($receipt.summary.previewPairCount -ne 3) {
    throw 'Expected three preview pairs from the report HTML.'
  }
  if ($receipt.summary.commentPreviewPairCount -ne 2 -or $receipt.summary.commentPreviewPairOmittedCount -ne 1) {
    throw 'Comment preview pair selection mismatch.'
  }
  if ($receipt.summary.indexPreviewPairCount -ne 3 -or $receipt.summary.indexPreviewPairOmittedCount -ne 0) {
    throw 'Index preview pair selection mismatch.'
  }
  if ($receipt.targets.Count -ne 1 -or $receipt.targets[0].previewPairCount -ne 3) {
    throw 'Target preview pair count mismatch.'
  }
  if ($receipt.commentPreviewPairs[0].label -ne 'Front Panel Overview') {
    throw 'Expected overview preview to sort first for the PR comment.'
  }
  if ($receipt.commentPreviewPairs[0].baseImageRelativePath -ne 'targets/001-demo/history/front-panel/Demo.vi-001-artifacts/compare-report_files/fp_1.png') {
    throw 'Expected normalized relative path for the base preview image.'
  }
  if ($receipt.previewPairs[1].label -ne '1. Front Panel - Variant') {
    throw 'Expected detail preview label normalization.'
  }

  $outputText = Get-Content -LiteralPath $outputPath -Raw
  foreach ($requiredKey in @(
      'preview-manifest-path=',
      'preview-pair-count=3',
      'comment-preview-pair-count=2',
      'comment-preview-pair-omitted-count=1',
      'index-preview-pair-count=3'
    )) {
    if ($outputText -notmatch [regex]::Escape($requiredKey)) {
      throw "Expected GitHub output '$requiredKey'."
    }
  }
} finally {
  Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
