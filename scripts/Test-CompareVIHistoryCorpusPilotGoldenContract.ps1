Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$fixtureRoot = Join-Path $repoRoot 'tests' 'fixtures' 'corpus-pilot-v1'
$fixtureReadmePath = Join-Path $fixtureRoot 'README.md'
$corpusRoot = Join-Path $fixtureRoot 'corpus'
$corpusIndexPath = Join-Path $corpusRoot 'corpus-index.json'
$manifestPath = Join-Path $corpusRoot 'downstream-processing-manifest.json'
$pagePath = Join-Path $corpusRoot 'pages' 'corpus-page-001.json'

function Get-JsonReceipt {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path,
    [Parameter(Mandatory = $true)]
    [string]$ExpectedSchema
  )

  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    throw "Required fixture file is missing: $Path"
  }

  $json = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -Depth 100
  if ([string]$json.schema -ne $ExpectedSchema) {
    throw "Schema mismatch for '$Path'. Expected '$ExpectedSchema', actual '$($json.schema)'."
  }

  return $json
}

function Get-TargetProjection {
  param(
    [Parameter(Mandatory = $true)]
    $Page,
    [Parameter(Mandatory = $true)]
    $Target
  )

  return [ordered]@{
    pageOrdinal        = [int]$Page.page.pageOrdinal
    targetOrdinal      = [int]$Target.targetOrdinal
    targetKey          = [string]$Target.targetKey
    path               = [string]$Target.target.path
    selectedRef        = [string]$Target.target.selectedRef
    targetId           = $Target.target.targetId
    entrypoint         = [string]$Target.entrypoint
    sharedEvidencePath = [string]$Target.sources.sharedEvidencePath
    evidenceGraphPath  = $Target.sources.evidenceGraphPath
    finalStatus        = [string]$Target.completeness.finalStatus
    graphStatus        = $Target.completeness.graphStatus
    replayStatus       = [string]$Target.completeness.replayStatus
    suppressionProfile = [string]$Target.summary.suppressionProfile
    previewImageCount  = [int]$Target.summary.previewImageCount
    continuityStatus   = [string]$Target.completeness.continuityStatus
  }
}

function Get-ProjectionDigest {
  param(
    [Parameter(Mandatory = $true)]
    $Projection
  )

  $json = $Projection | ConvertTo-Json -Compress -Depth 20
  return [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData([System.Text.Encoding]::UTF8.GetBytes($json))).ToLowerInvariant()
}

if (-not (Test-Path -LiteralPath $fixtureReadmePath -PathType Leaf)) {
  throw 'Corpus pilot fixture README is missing.'
}

$fixtureReadme = Get-Content -LiteralPath $fixtureReadmePath -Raw
foreach ($requiredPattern in @(
    'canonical pilot contract baseline',
    '23206547436',
    'VIP_Post-Install Custom Action\.vi',
    'VIP_Pre-Install Custom Action\.vi',
    'page-ordinal',
    'markdown or HTML'
  )) {
  if ($fixtureReadme -notmatch $requiredPattern) {
    throw "Fixture README is missing required contract text: $requiredPattern"
  }
}

$manifestRaw = Get-Content -LiteralPath $manifestPath -Raw
$pageRaw = Get-Content -LiteralPath $pagePath -Raw
$indexRaw = Get-Content -LiteralPath $corpusIndexPath -Raw
foreach ($forbiddenReference in @('index.md', 'index.html', 'timeline.md', 'timeline.html')) {
  foreach ($content in @($manifestRaw, $pageRaw, $indexRaw)) {
    if ($content -match [regex]::Escape($forbiddenReference)) {
      throw "Golden corpus pilot fixture must not require '$forbiddenReference' for downstream processing."
    }
  }
}

$manifest = Get-JsonReceipt -Path $manifestPath -ExpectedSchema 'comparevi-history/downstream-processing-manifest@v1'
$page = Get-JsonReceipt -Path $pagePath -ExpectedSchema 'comparevi-history/corpus-page@v1'
$index = Get-JsonReceipt -Path $corpusIndexPath -ExpectedSchema 'comparevi-history/corpus-index@v1'

if ([string]$manifest.corpus.repository -ne 'LabVIEW-Community-CI-CD/labview-icon-editor-demo') { throw 'Fixture manifest repository mismatch.' }
if ([string]$manifest.corpus.ref -ne 'develop') { throw 'Fixture manifest ref mismatch.' }
if ([string]$manifest.processingModel.unitKind -ne 'corpus-page') { throw 'Fixture manifest unit kind mismatch.' }
if ([string]$manifest.processingModel.ordering -ne 'target-path-asc') { throw 'Fixture manifest ordering mismatch.' }
if ([string]$manifest.processingModel.continuationMode -ne 'page-ordinal') { throw 'Fixture manifest continuation mode mismatch.' }
if ([int]$manifest.processingModel.pageSize -ne 2) { throw 'Fixture manifest page size mismatch.' }
if ([int]$manifest.processingModel.pageCount -ne 1) { throw 'Fixture manifest page count mismatch.' }
if ([int]$manifest.processingModel.targetCount -ne 2) { throw 'Fixture manifest target count mismatch.' }
if ([bool]$manifest.completeness.isComplete -ne $true -or [string]$manifest.completeness.reason -ne 'all-targets-complete') { throw 'Fixture manifest completeness mismatch.' }

if ($manifest.units.Count -ne 1) { throw 'Fixture manifest must contain exactly one page unit.' }
$unit = $manifest.units[0]
if ([string]$unit.unitId -ne 'page-001') { throw 'Fixture manifest unit id mismatch.' }
if ([int]$unit.pageOrdinal -ne 1) { throw 'Fixture manifest page ordinal mismatch.' }
if ([string]$unit.pagePath -ne 'pages/corpus-page-001.json') { throw 'Fixture manifest page path mismatch.' }
if ([int]$unit.targetCount -ne 2 -or [int]$unit.targetOrdinalStart -ne 1 -or [int]$unit.targetOrdinalEnd -ne 2) { throw 'Fixture manifest target ordinal partition mismatch.' }
if ([string]$unit.continuationToken -ne 'page-001') { throw 'Fixture manifest continuation token mismatch.' }
if ([string]$unit.status -ne 'ready') { throw 'Fixture manifest unit status mismatch.' }

if ([string]$page.corpus.repository -ne [string]$manifest.corpus.repository -or [string]$page.corpus.ref -ne [string]$manifest.corpus.ref) {
  throw 'Fixture page repository/ref mismatch.'
}
if ([int]$page.page.pageOrdinal -ne 1) { throw 'Fixture page ordinal mismatch.' }
if ([int]$page.page.pageSize -ne 2) { throw 'Fixture page size mismatch.' }
if ([int]$page.page.targetCount -ne 2) { throw 'Fixture page target count mismatch.' }
if ([int]$page.page.targetOrdinalStart -ne 1 -or [int]$page.page.targetOrdinalEnd -ne 2) { throw 'Fixture page target partition mismatch.' }
if ([bool]$page.completeness.isComplete -ne $true -or [string]$page.completeness.reason -ne 'all-targets-complete') { throw 'Fixture page completeness mismatch.' }

if ([string]$index.corpus.repository -ne [string]$manifest.corpus.repository -or [string]$index.corpus.ref -ne [string]$manifest.corpus.ref) {
  throw 'Fixture corpus index repository/ref mismatch.'
}
if ([int]$index.corpus.pageSize -ne 2) { throw 'Fixture corpus index page size mismatch.' }
if ([int]$index.corpus.targetCount -ne 2) { throw 'Fixture corpus index target count mismatch.' }
if ([int]$index.corpus.sharedEvidenceCount -ne 2 -or [int]$index.corpus.evidenceGraphCount -ne 2) { throw 'Fixture corpus index evidence count mismatch.' }
if ([bool]$index.completeness.isComplete -ne $true -or [string]$index.completeness.reason -ne 'all-targets-complete') { throw 'Fixture corpus index completeness mismatch.' }
if ([string]$index.paging.continuationMode -ne 'page-ordinal') { throw 'Fixture corpus index continuation mode mismatch.' }
if ([bool]$index.paging.continuationRequired -ne $false) { throw 'Fixture corpus index continuationRequired mismatch.' }
if ($index.paging.pages.Count -ne 1) { throw 'Fixture corpus index must contain exactly one page digest.' }
$indexPage = $index.paging.pages[0]
if ([int]$indexPage.pageOrdinal -ne 1 -or [string]$indexPage.relativePath -ne 'pages/corpus-page-001.json' -or [string]$indexPage.continuationToken -ne 'page-001') {
  throw 'Fixture corpus index page digest mismatch.'
}

$expectedPaths = @(
  'Tooling/deployment/VIP_Post-Install Custom Action.vi',
  'Tooling/deployment/VIP_Pre-Install Custom Action.vi'
)
$pagePaths = @($page.targets | ForEach-Object { [string]$_.target.path })
$digestPaths = @($index.targetDigests | ForEach-Object { [string]$_.path })
if (($pagePaths -join '|') -ne ($expectedPaths -join '|')) { throw 'Fixture page target ordering drifted.' }
if (($digestPaths -join '|') -ne ($expectedPaths -join '|')) { throw 'Fixture corpus index target ordering drifted.' }

$expectedProjectionDigests = @{
  'Tooling/deployment/VIP_Post-Install Custom Action.vi' = '7de4c8c3987d475f841cad03495c0441256db8e0137220dca2640c92c9f8849f'
  'Tooling/deployment/VIP_Pre-Install Custom Action.vi' = '8dfca8b836e55b84556e6504c658ff4acf98a0503fcdcebd35f84801f2c76e00'
}

for ($i = 0; $i -lt $page.targets.Count; $i++) {
  $pageTarget = $page.targets[$i]
  $digestTarget = $index.targetDigests[$i]
  $path = [string]$pageTarget.target.path
  if (-not $expectedProjectionDigests.ContainsKey($path)) {
    throw "Unexpected fixture target path '$path'."
  }

  if ([int]$pageTarget.targetOrdinal -ne ($i + 1)) { throw "Fixture target ordinal drifted for '$path'." }
  if ([int]$digestTarget.targetOrdinal -ne ($i + 1)) { throw "Fixture digest ordinal drifted for '$path'." }
  if ([int]$digestTarget.pageOrdinal -ne 1) { throw "Fixture digest page ordinal drifted for '$path'." }
  if ([string]$digestTarget.entrypoint -ne 'manual-exploration') { throw "Fixture digest entrypoint drifted for '$path'." }
  if ([string]$digestTarget.finalStatus -ne 'succeeded') { throw "Fixture digest finalStatus drifted for '$path'." }
  if ($null -ne $digestTarget.graphStatus) { throw "Fixture digest graphStatus drifted for '$path'." }
  if ([int]$digestTarget.previewImageCount -ne 0) { throw "Fixture digest previewImageCount drifted for '$path'." }
  if ([string]$digestTarget.sharedEvidencePath -ne ('../' + ([string]$pageTarget.sources.sharedEvidencePath).TrimStart('.','/'))) {
    throw "Fixture shared evidence path drifted for '$path'."
  }
  if ([string]$digestTarget.evidenceGraphPath -ne ('../' + ([string]$pageTarget.sources.evidenceGraphPath).TrimStart('.','/'))) {
    throw "Fixture evidence graph path drifted for '$path'."
  }

  $projection = Get-TargetProjection -Page $page -Target $pageTarget
  $projectionDigest = Get-ProjectionDigest -Projection $projection
  if ($projectionDigest -ne $expectedProjectionDigests[$path]) {
    throw "Fixture projection digest drifted for '$path'."
  }
}
