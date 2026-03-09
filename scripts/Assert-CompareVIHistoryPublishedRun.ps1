param(
  [Parameter(Mandatory = $true)]
  [string]$ActionRef,
  [Parameter(Mandatory = $true)]
  [string]$ConsumerRepository,
  [Parameter(Mandatory = $true)]
  [string]$ConsumerRef,
  [Parameter(Mandatory = $true)]
  [string]$TargetPath,
  [Parameter(Mandatory = $true)]
  [string]$ExpectedModeList,
  [Parameter(Mandatory = $true)]
  [string]$ManifestPath,
  [Parameter(Mandatory = $true)]
  [string]$ResultsDir,
  [Parameter(Mandatory = $true)]
  [string]$ModeCount,
  [Parameter(Mandatory = $true)]
  [string]$ModeList,
  [Parameter(Mandatory = $true)]
  [string]$ModeManifestsJson,
  [Parameter(Mandatory = $true)]
  [string]$HistoryReportMd,
  [Parameter(Mandatory = $true)]
  [string]$HistoryReportHtml,
  [Parameter(Mandatory = $true)]
  [string]$TotalProcessed,
  [string]$TotalDiffs,
  [string]$StopReason,
  [string]$RequestedModeList,
  [string]$ExecutedModeList,
  [string]$ArtifactName,
  [string]$EvidencePath,
  [string]$StepSummaryPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function ConvertTo-NormalizedModeList {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Value
  )

  return @(
    $Value -split '[,;]'
    | ForEach-Object { $_.Trim() }
    | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    | Sort-Object -Unique
  )
}

function Assert-ExistingPath {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path,
    [Parameter(Mandatory = $true)]
    [string]$PathType,
    [Parameter(Mandatory = $true)]
    [string]$Label
  )

  if ([string]::IsNullOrWhiteSpace($Path)) {
    throw "$Label was empty."
  }

  if (-not (Test-Path -LiteralPath $Path -PathType $PathType)) {
    throw "$Label not found: $Path"
  }
}

function Get-EntryValue {
  param(
    [Parameter(Mandatory = $true)]
    [object]$Entry,
    [Parameter(Mandatory = $true)]
    [string]$Name,
    $DefaultValue = $null
  )

  $property = $Entry.PSObject.Properties[$Name]
  if ($null -eq $property) {
    return $DefaultValue
  }

  return $property.Value
}

$expectedModes = ConvertTo-NormalizedModeList -Value $ExpectedModeList
if ($expectedModes.Count -eq 0) {
  throw 'ExpectedModeList must resolve to at least one mode.'
}

$reportedModes = ConvertTo-NormalizedModeList -Value $ModeList
$requestedModes = if ([string]::IsNullOrWhiteSpace($RequestedModeList)) {
  $expectedModes
} else {
  ConvertTo-NormalizedModeList -Value $RequestedModeList
}
$executedModes = if ([string]::IsNullOrWhiteSpace($ExecutedModeList)) {
  $reportedModes
} else {
  ConvertTo-NormalizedModeList -Value $ExecutedModeList
}

if ([int]$ModeCount -ne $expectedModes.Count) {
  throw "ModeCount mismatch. Expected $($expectedModes.Count), actual $ModeCount."
}

if (@(Compare-Object -ReferenceObject $expectedModes -DifferenceObject $reportedModes).Count -gt 0) {
  throw "ModeList mismatch. Expected '$($expectedModes -join ', ')', actual '$($reportedModes -join ', ')'."
}

if (@(Compare-Object -ReferenceObject $expectedModes -DifferenceObject $executedModes).Count -gt 0) {
  throw "Executed modes mismatch. Expected '$($expectedModes -join ', ')', actual '$($executedModes -join ', ')'."
}

Assert-ExistingPath -Path $ManifestPath -PathType Leaf -Label 'Manifest'
Assert-ExistingPath -Path $ResultsDir -PathType Container -Label 'Results directory'
Assert-ExistingPath -Path $HistoryReportMd -PathType Leaf -Label 'Markdown report'
Assert-ExistingPath -Path $HistoryReportHtml -PathType Leaf -Label 'HTML report'

if ([string]::IsNullOrWhiteSpace($TotalProcessed) -or [int]$TotalProcessed -lt 1) {
  throw "Expected TotalProcessed >= 1. Actual: $TotalProcessed"
}

$modeEntries = @($ModeManifestsJson | ConvertFrom-Json)
if ($modeEntries.Count -ne $expectedModes.Count) {
  throw "ModeManifestsJson count mismatch. Expected $($expectedModes.Count), actual $($modeEntries.Count)."
}

$modeSummaryPath = $null
if (-not [string]::IsNullOrWhiteSpace($EvidencePath)) {
  $modeSummaryPath = Join-Path (Split-Path -Parent $EvidencePath) 'mode-summary.md'
}

$modeSummary = & (Join-Path $PSScriptRoot 'Format-CompareVIHistoryModeSummary.ps1') `
  -RequestedModeList ($requestedModes -join ', ') `
  -ExecutedModeList ($executedModes -join ', ') `
  -ModeManifestsJson $ModeManifestsJson `
  -TotalProcessed $TotalProcessed `
  -TotalDiffs $TotalDiffs `
  -StopReason $StopReason `
  -OutputPath $modeSummaryPath

$artifactFiles = @(Get-ChildItem -LiteralPath $ResultsDir -Recurse -File)
if ($artifactFiles.Count -lt 1) {
  throw "Results directory '$ResultsDir' did not contain any files to upload."
}

foreach ($entry in $modeEntries) {
  $modeName = [string](Get-EntryValue -Entry $entry -Name 'mode' -DefaultValue '')
  if ([string]::IsNullOrWhiteSpace($modeName)) {
    throw 'Mode manifest entry contained an empty mode value.'
  }

  Assert-ExistingPath -Path ([string](Get-EntryValue -Entry $entry -Name 'manifest' -DefaultValue '')) -PathType Leaf -Label "Mode manifest for $modeName"
  Assert-ExistingPath -Path ([string](Get-EntryValue -Entry $entry -Name 'resultsDir' -DefaultValue '')) -PathType Container -Label "Mode results directory for $modeName"
}

$evidence = [ordered]@{
  schema            = 'comparevi-history/published-consumer-evidence@v1'
  generatedAtUtc    = [DateTime]::UtcNow.ToString('o')
  actionRef         = $ActionRef
  consumerRepository= $ConsumerRepository
  consumerRef       = $ConsumerRef
  targetPath        = $TargetPath
  expectedModes     = $expectedModes
  requestedModes    = $requestedModes
  executedModes     = $executedModes
  modeCount         = [int]$ModeCount
  totalProcessed    = [int]$TotalProcessed
  totalDiffs        = if ([string]::IsNullOrWhiteSpace($TotalDiffs)) { $null } else { [int]$TotalDiffs }
  stopReason        = $StopReason
  manifestPath      = $ManifestPath
  resultsDir        = $ResultsDir
  historyReportMd   = $HistoryReportMd
  historyReportHtml = $HistoryReportHtml
  artifactName      = $ArtifactName
  artifactFileCount = $artifactFiles.Count
  modeSummaryMarkdown = $modeSummary
  modes             = @(
    foreach ($entry in $modeEntries) {
      [ordered]@{
        mode           = [string](Get-EntryValue -Entry $entry -Name 'mode' -DefaultValue '')
        slug           = [string](Get-EntryValue -Entry $entry -Name 'slug' -DefaultValue '')
        manifest       = [string](Get-EntryValue -Entry $entry -Name 'manifest' -DefaultValue '')
        resultsDir     = [string](Get-EntryValue -Entry $entry -Name 'resultsDir' -DefaultValue '')
        processed      = Get-EntryValue -Entry $entry -Name 'processed' -DefaultValue 0
        diffs          = Get-EntryValue -Entry $entry -Name 'diffs' -DefaultValue 0
        signalDiffs    = Get-EntryValue -Entry $entry -Name 'signalDiffs' -DefaultValue 0
        noiseCollapsed = Get-EntryValue -Entry $entry -Name 'noiseCollapsed' -DefaultValue 0
        errors         = Get-EntryValue -Entry $entry -Name 'errors' -DefaultValue 0
        status         = [string](Get-EntryValue -Entry $entry -Name 'status' -DefaultValue 'unknown')
        stopReason     = [string](Get-EntryValue -Entry $entry -Name 'stopReason' -DefaultValue '')
      }
    }
  )
}

if (-not [string]::IsNullOrWhiteSpace($EvidencePath)) {
  $evidenceDirectory = Split-Path -Parent $EvidencePath
  if (-not [string]::IsNullOrWhiteSpace($evidenceDirectory)) {
    New-Item -ItemType Directory -Path $evidenceDirectory -Force | Out-Null
  }
  $evidence | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $EvidencePath -Encoding utf8
}

if (-not [string]::IsNullOrWhiteSpace($StepSummaryPath)) {
  @(
    '## comparevi-history published consumer validation'
    ''
    ('- Action ref: `{0}`' -f $ActionRef)
    ('- Consumer repo: `{0}@{1}`' -f $ConsumerRepository, $ConsumerRef)
    ('- Target path: `{0}`' -f $TargetPath)
    ('- Artifact name: `{0}`' -f $(if ([string]::IsNullOrWhiteSpace($ArtifactName)) { 'n/a' } else { $ArtifactName }))
    ''
    '### Reviewer summary'
    ''
    $modeSummary
  ) | Out-File -FilePath $StepSummaryPath -Encoding utf8 -Append
}

$evidence | ConvertTo-Json -Depth 10
