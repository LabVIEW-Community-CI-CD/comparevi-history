Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptPath = Join-Path $PSScriptRoot 'Write-CompareVIHistoryRevisionCatalog.ps1'
$schemaPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'docs' 'schemas' 'comparevi-history-revision-catalog-v1.schema.json'
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("comparevi-history-revision-catalog-" + [guid]::NewGuid().ToString('N'))
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

  $legacyDir = Join-Path $repoRoot 'legacy'
  New-Item -ItemType Directory -Path $legacyDir -Force | Out-Null
  'v1' | Set-Content -LiteralPath (Join-Path $legacyDir 'Original.vi') -Encoding utf8
  Invoke-Git -RepositoryRoot $repoRoot -Arguments @('add', '.') | Out-Null
  Invoke-Git -RepositoryRoot $repoRoot -Arguments @('commit', '-m', 'Add original VI') | Out-Null

  $targetDir = Join-Path $repoRoot 'Tooling' 'deployment'
  New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
  Invoke-Git -RepositoryRoot $repoRoot -Arguments @('mv', 'legacy/Original.vi', 'Tooling/deployment/Target.vi') | Out-Null
  Invoke-Git -RepositoryRoot $repoRoot -Arguments @('commit', '-m', 'Rename VI into deployment folder') | Out-Null

  'v2' | Set-Content -LiteralPath (Join-Path $targetDir 'Target.vi') -Encoding utf8
  Invoke-Git -RepositoryRoot $repoRoot -Arguments @('add', 'Tooling/deployment/Target.vi') | Out-Null
  Invoke-Git -RepositoryRoot $repoRoot -Arguments @('commit', '-m', 'Modify deployment VI') | Out-Null

  $resultsDir = Join-Path $tempRoot 'results'
  $githubOutputPath = Join-Path $tempRoot 'github-output.txt'
  $summaryPath = Join-Path $tempRoot 'summary.md'
  $catalogJson = & $scriptPath `
    -RepositoryRoot $repoRoot `
    -TargetPath 'Tooling/deployment/Target.vi' `
    -SelectedRef 'HEAD' `
    -ConsumerRepository 'LabVIEW-Community-CI-CD/labview-icon-editor-demo' `
    -ConsumerRef 'develop' `
    -ResultsDir $resultsDir `
    -GitHubOutputPath $githubOutputPath `
    -StepSummaryPath $summaryPath

  $catalog = $catalogJson | ConvertFrom-Json -Depth 64
  if ($catalog.schema -ne 'comparevi-history/revision-catalog@v1') {
    throw 'Revision catalog schema mismatch.'
  }
  if (-not (Test-Path -LiteralPath $schemaPath -PathType Leaf)) {
    throw 'Revision catalog schema file is missing.'
  }
  if ($catalog.target.path -ne 'Tooling/deployment/Target.vi') {
    throw 'Normalized target path mismatch.'
  }
  if ($catalog.summary.revisionCount -ne 3) {
    throw 'Revision count mismatch.'
  }
  if ($catalog.summary.renameCount -ne 1) {
    throw 'Rename count mismatch.'
  }
  if ($catalog.discovery.historyMode -ne 'first-parent') {
    throw 'History mode mismatch.'
  }
  if ($catalog.revisions[0].path -ne 'legacy/Original.vi') {
    throw 'Oldest revision path mismatch.'
  }
  if ($catalog.revisions[1].previousPath -ne 'legacy/Original.vi') {
    throw 'Rename previousPath mismatch.'
  }
  if ($catalog.revisions[2].path -ne 'Tooling/deployment/Target.vi') {
    throw 'Newest revision path mismatch.'
  }
  if (-not (Test-Path -LiteralPath (Join-Path $resultsDir 'revision-catalog.json') -PathType Leaf)) {
    throw 'Revision catalog file was not written.'
  }

  $githubOutputs = Get-Content -LiteralPath $githubOutputPath -Raw
  foreach ($requiredKey in @(
      'revision-catalog-path=',
      'normalized-target-path=Tooling/deployment/Target.vi',
      'revision-count=3',
      'catalog-complete=true',
      'catalog-completeness-reason=selected-ref-lineage'
    )) {
    if ($githubOutputs -notmatch [regex]::Escape($requiredKey)) {
      throw "Expected GitHub output '$requiredKey'."
    }
  }

  $summary = Get-Content -LiteralPath $summaryPath -Raw
  if ($summary -notmatch 'comparevi-history manual VI exploration') {
    throw 'Step summary was not written.'
  }

  $failedTraversal = $false
  try {
    & $scriptPath -RepositoryRoot $repoRoot -TargetPath '../outside.vi' | Out-Null
  } catch {
    $failedTraversal = $_.Exception.Message -match 'traverse'
  }
  if (-not $failedTraversal) {
    throw 'Expected traversal validation failure.'
  }

  $failedNonVi = $false
  try {
    & $scriptPath -RepositoryRoot $repoRoot -TargetPath 'README.md' | Out-Null
  } catch {
    $failedNonVi = $_.Exception.Message -match '\.vi'
  }
  if (-not $failedNonVi) {
    throw 'Expected non-VI validation failure.'
  }

  $failedMissing = $false
  try {
    & $scriptPath -RepositoryRoot $repoRoot -TargetPath 'Tooling/deployment/Missing.vi' | Out-Null
  } catch {
    $failedMissing = $true
  }
  if (-not $failedMissing) {
    throw 'Expected missing-target validation failure.'
  }
} finally {
  Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
