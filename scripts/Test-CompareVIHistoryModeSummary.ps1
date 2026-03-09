Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptPath = Join-Path $PSScriptRoot 'Format-CompareVIHistoryModeSummary.ps1'
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("comparevi-history-mode-summary-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

try {
  $outputPath = Join-Path $tempRoot 'mode-summary.md'
  $githubOutputPath = Join-Path $tempRoot 'github-output.txt'
  $modeJson = @(
    [ordered]@{
      mode = 'attributes'
      processed = 2
      diffs = 1
      signalDiffs = 1
      noiseCollapsed = 0
      errors = 0
      status = 'ok'
    }
    [ordered]@{
      mode = 'attributes'
      processed = 2
      diffs = 0
      signalDiffs = 0
      noiseCollapsed = 0
      errors = 0
      status = 'ok'
    }
  ) | ConvertTo-Json -Depth 5 -Compress

  $summary = & $scriptPath `
    -RequestedModeList 'attributes,front-panel' `
    -ExecutedModeList 'front-panel,attributes' `
    -ModeManifestsJson $modeJson `
    -TotalProcessed '2' `
    -TotalDiffs '1' `
    -StopReason 'max-pairs' `
    -OutputPath $outputPath `
    -GitHubOutputPath $githubOutputPath

  if ($summary -notmatch 'Requested modes: `attributes, front-panel`') {
    throw 'Summary did not include normalized requested modes.'
  }
  if ($summary -notmatch '\| attributes \| 2 \| 1 \| 1 \| 0 \| 0 \| ok \|') {
    throw 'Summary did not include per-mode table row.'
  }
  if (-not (Test-Path -LiteralPath $outputPath -PathType Leaf)) {
    throw 'Mode summary output file was not written.'
  }

  $githubOutput = Get-Content -LiteralPath $githubOutputPath -Raw
  if ($githubOutput -notmatch 'mode-summary-markdown<<') {
    throw 'GitHub output did not include mode-summary-markdown.'
  }

  $legacyModeJson = [ordered]@{
    mode = 'block-diagram'
    processed = 1
    diffs = 1
    status = 'ok'
  } | ConvertTo-Json -Depth 4 -Compress

  $legacySummary = & $scriptPath `
    -RequestedModeList '' `
    -ExecutedModeList '' `
    -ModeManifestsJson $legacyModeJson `
    -TotalProcessed '1' `
    -TotalDiffs '1'

  if ($legacySummary -notmatch 'Requested modes: `block-diagram`') {
    throw 'Legacy summary did not derive requested modes from mode-manifests-json.'
  }
  if ($legacySummary -notmatch '\| block-diagram \| 1 \| 1 \| 0 \| 0 \| 0 \| ok \|') {
    throw 'Legacy summary did not fall back missing per-mode fields to zero.'
  }
} finally {
  Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
