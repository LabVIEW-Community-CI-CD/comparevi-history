[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string]$ImmutableTag,

  [string]$RepoRoot = (Split-Path -Parent $PSScriptRoot)
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($ImmutableTag -notmatch '^v[0-9]+\.[0-9]+\.[0-9]+$') {
  throw "ImmutableTag must match v<major>.<minor>.<patch>. Actual: '$ImmutableTag'."
}

$commentTemplatePath = Join-Path $RepoRoot 'docs/examples/comparevi-history-comment-gated.yml'
$safeTemplatesPath = Join-Path $RepoRoot 'docs/SAFE_PR_DIAGNOSTICS_TEMPLATES.md'

foreach ($path in @($commentTemplatePath, $safeTemplatesPath)) {
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
    throw "Template sync input not found: $path"
  }
}

$commentTemplate = Get-Content -LiteralPath $commentTemplatePath -Raw
$commentTemplate = [regex]::Replace(
  $commentTemplate,
  '(?m)(^\s*FACADE_REF:\s*)v[0-9]+\.[0-9]+\.[0-9]+\s*$',
  ("`$1{0}" -f $ImmutableTag)
)
$commentTemplate = [regex]::Replace(
  $commentTemplate,
  '(?m)(^\s*uses:\s+LabVIEW-Community-CI-CD/comparevi-history@)v[0-9]+\.[0-9]+\.[0-9]+\s*$',
  ("`$1{0}" -f $ImmutableTag)
)
$commentTemplate = [regex]::Replace(
  $commentTemplate,
  '(?m)(^\s*ACTION_REF:\s+LabVIEW-Community-CI-CD/comparevi-history@)v[0-9]+\.[0-9]+\.[0-9]+\s*$',
  ("`$1{0}" -f $ImmutableTag)
)
$commentTemplate | Set-Content -LiteralPath $commentTemplatePath -Encoding utf8

$safeTemplates = Get-Content -LiteralPath $safeTemplatesPath -Raw
$safeTemplates = [regex]::Replace(
  $safeTemplates,
  'LabVIEW-Community-CI-CD/comparevi-history@v[0-9]+\.[0-9]+\.[0-9]+',
  ('LabVIEW-Community-CI-CD/comparevi-history@{0}' -f $ImmutableTag)
)
$safeTemplates | Set-Content -LiteralPath $safeTemplatesPath -Encoding utf8

[ordered]@{
  immutableTag = $ImmutableTag
  commentTemplatePath = $commentTemplatePath
  safeTemplatesPath = $safeTemplatesPath
} | ConvertTo-Json -Depth 5
