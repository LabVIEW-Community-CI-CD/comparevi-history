Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

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

function New-CompareVIHistorySyntheticReviewBundleFixture {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)]
    [string]$RootPath
  )

  $resultsDir = Join-Path $RootPath 'results'
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
      targets = @(
        [ordered]@{
          targetId = 'dynamic-demo-target'
          targetPath = 'Tooling/demo/Demo.vi'
          finalStatus = 'succeeded'
          finalReason = 'completed'
          manifestPath = $suiteManifestPath
        }
      )
    } | ConvertTo-Json -Depth 64) | Set-Content -LiteralPath $targetRunsManifestPath -Encoding utf8

  return [ordered]@{
    resultsDir = $resultsDir
    targetRoot = $targetRoot
    suiteManifestPath = $suiteManifestPath
    targetRunsManifestPath = $targetRunsManifestPath
  }
}

Export-ModuleMember -Function New-CompareVIHistorySyntheticReviewBundleFixture
