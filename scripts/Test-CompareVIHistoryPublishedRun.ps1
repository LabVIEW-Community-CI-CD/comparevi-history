Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptPath = Join-Path $PSScriptRoot 'Assert-CompareVIHistoryPublishedRun.ps1'
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("comparevi-history-published-run-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

try {
  $resultsRoot = Join-Path $tempRoot 'history'
  $defaultResults = Join-Path $resultsRoot 'default'
  $attributesResults = Join-Path $resultsRoot 'attributes'
  New-Item -ItemType Directory -Path $defaultResults -Force | Out-Null
  New-Item -ItemType Directory -Path $attributesResults -Force | Out-Null

  $manifestPath = Join-Path $resultsRoot 'manifest.json'
  $historySummaryJson = Join-Path $resultsRoot 'history-summary.json'
  $historyReportMd = Join-Path $resultsRoot 'history-report.md'
  $historyReportHtml = Join-Path $resultsRoot 'history-report.html'
  $defaultManifestPath = Join-Path $defaultResults 'manifest.json'
  $attributesManifestPath = Join-Path $attributesResults 'manifest.json'
  $evidencePath = Join-Path $resultsRoot 'published-evidence.json'
  $stepSummaryPath = Join-Path $resultsRoot 'summary.md'
  $requestPath = Join-Path $resultsRoot 'request.json'
  $publicRunPath = Join-Path $resultsRoot 'public-run.json'
  $publicCommentPath = Join-Path $resultsRoot 'comment.md'
  $publicStepSummaryPath = Join-Path $resultsRoot 'public-step-summary.md'

  New-Item -ItemType Directory -Path $resultsRoot -Force | Out-Null
  '{}' | Set-Content -LiteralPath $manifestPath -Encoding utf8
  '{}' | Set-Content -LiteralPath $historySummaryJson -Encoding utf8
  '# report' | Set-Content -LiteralPath $historyReportMd -Encoding utf8
  '<html></html>' | Set-Content -LiteralPath $historyReportHtml -Encoding utf8
  '{}' | Set-Content -LiteralPath $defaultManifestPath -Encoding utf8
  '{}' | Set-Content -LiteralPath $attributesManifestPath -Encoding utf8
  '{"schema":"comparevi-history/request@v1"}' | Set-Content -LiteralPath $requestPath -Encoding utf8
  @'
{
  "schema": "comparevi-history/public-run@v1",
  "backend": {
    "historyFacadeSchema": "comparevi-tools/history-facade@v1"
  },
  "summary": {
    "finalStatus": "succeeded",
    "finalReason": "completed"
  }
}
'@ | Set-Content -LiteralPath $publicRunPath -Encoding utf8
  'comment' | Set-Content -LiteralPath $publicCommentPath -Encoding utf8
  'summary' | Set-Content -LiteralPath $publicStepSummaryPath -Encoding utf8
  'artifact' | Set-Content -LiteralPath (Join-Path $defaultResults 'result.txt') -Encoding utf8
  'artifact' | Set-Content -LiteralPath (Join-Path $attributesResults 'result.txt') -Encoding utf8

  $modeJson = @(
    [ordered]@{
      mode = 'default'
      slug = 'default'
      manifest = $defaultManifestPath
      resultsDir = $defaultResults
      processed = 1
      diffs = 1
      signalDiffs = 0
      noiseCollapsed = 0
      errors = 0
      status = 'ok'
      stopReason = 'max-pairs'
    }
    [ordered]@{
      mode = 'attributes'
      slug = 'attributes'
      manifest = $attributesManifestPath
      resultsDir = $attributesResults
      processed = 1
      diffs = 0
      signalDiffs = 0
      noiseCollapsed = 0
      errors = 0
      status = 'ok'
      stopReason = 'max-pairs'
    }
  ) | ConvertTo-Json -Depth 6 -Compress

  $evidenceJson = & $scriptPath `
    -ActionRef 'LabVIEW-Community-CI-CD/comparevi-history@v1' `
    -ConsumerRepository 'ni/labview-icon-editor' `
    -ConsumerRef 'develop' `
    -TargetPath 'Tooling/deployment/VIP_Post-Install Custom Action.vi' `
    -ExpectedModeList 'default,attributes' `
    -ManifestPath $manifestPath `
    -ResultsDir $resultsRoot `
    -ModeCount '2' `
    -ModeList 'attributes, default' `
    -RequestedModeList 'default,attributes' `
    -ExecutedModeList 'attributes,default' `
    -ModeManifestsJson $modeJson `
    -HistorySummaryJson $historySummaryJson `
    -HistoryReportMd $historyReportMd `
    -HistoryReportHtml $historyReportHtml `
    -TotalProcessed '1' `
    -TotalDiffs '1' `
    -StopReason 'max-pairs' `
    -RequestPath $requestPath `
    -PublicRunPath $publicRunPath `
    -PublicCommentPath $publicCommentPath `
    -PublicStepSummaryPath $publicStepSummaryPath `
    -FinalStatus 'succeeded' `
    -FinalReason 'completed' `
    -ArtifactName 'published-consumer-test' `
    -EvidencePath $evidencePath `
    -StepSummaryPath $stepSummaryPath

  $evidence = $evidenceJson | ConvertFrom-Json
  if ($evidence.consumerRepository -ne 'ni/labview-icon-editor') {
    throw 'Evidence consumer repository mismatch.'
  }
  if ($evidence.modes.Count -ne 2) {
    throw 'Evidence mode count mismatch.'
  }
  if (-not (Test-Path -LiteralPath $evidencePath -PathType Leaf)) {
    throw 'Evidence file was not written.'
  }
  if (-not (Test-Path -LiteralPath $stepSummaryPath -PathType Leaf)) {
    throw 'Step summary file was not written.'
  }

  $failed = $false
  try {
    & $scriptPath `
      -ActionRef 'LabVIEW-Community-CI-CD/comparevi-history@v1' `
      -ConsumerRepository 'ni/labview-icon-editor' `
      -ConsumerRef 'develop' `
      -TargetPath 'Tooling/deployment/VIP_Post-Install Custom Action.vi' `
      -ExpectedModeList 'default,attributes,front-panel' `
      -ManifestPath $manifestPath `
      -ResultsDir $resultsRoot `
      -ModeCount '2' `
      -ModeList 'attributes, default' `
      -ModeManifestsJson $modeJson `
      -HistorySummaryJson $historySummaryJson `
      -HistoryReportMd $historyReportMd `
      -HistoryReportHtml $historyReportHtml `
      -TotalProcessed '1' | Out-Null
  } catch {
    $failed = $_.Exception.Message -match 'ModeCount mismatch'
  }

  if (-not $failed) {
    throw 'Expected invalid mode count assertion to fail.'
  }
} finally {
  Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
