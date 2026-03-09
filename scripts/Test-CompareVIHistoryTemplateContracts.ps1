Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$manualTemplatePath = Join-Path $repoRoot 'docs/examples/comparevi-history-workflow-dispatch.yml'
$commentTemplatePath = Join-Path $repoRoot 'docs/examples/comparevi-history-comment-gated.yml'
$safeTemplatesPath = Join-Path $repoRoot 'docs/SAFE_PR_DIAGNOSTICS_TEMPLATES.md'
$releaseWorkflowPath = Join-Path $repoRoot '.github/workflows/release.yml'
$readmePath = Join-Path $repoRoot 'README.md'

function Assert-Match {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Content,
    [Parameter(Mandatory = $true)]
    [string]$Pattern,
    [Parameter(Mandatory = $true)]
    [string]$Message
  )

  if ($Content -notmatch $Pattern) {
    throw $Message
  }
}

function Assert-Equal {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Actual,
    [Parameter(Mandatory = $true)]
    [string]$Expected,
    [Parameter(Mandatory = $true)]
    [string]$Message
  )

  if ($Actual -ne $Expected) {
    throw "$Message Expected '$Expected', actual '$Actual'."
  }
}

$manualTemplate = Get-Content -LiteralPath $manualTemplatePath -Raw
$commentTemplate = Get-Content -LiteralPath $commentTemplatePath -Raw
$safeTemplates = Get-Content -LiteralPath $safeTemplatesPath -Raw
$releaseWorkflow = Get-Content -LiteralPath $releaseWorkflowPath -Raw
$readme = Get-Content -LiteralPath $readmePath -Raw

Assert-Match -Content $manualTemplate -Pattern '(?m)^\s*runs-on:\s+ubuntu-latest\s*$' -Message 'Manual template must use ubuntu-latest.'
Assert-Match -Content $manualTemplate -Pattern '(?m)^\s*COMPAREVI_NI_LINUX_IMAGE:\s+nationalinstruments/labview:2026q1-linux\s*$' -Message 'Manual template must pin the NI Linux image.'
Assert-Match -Content $manualTemplate -Pattern 'docker pull "\$COMPAREVI_NI_LINUX_IMAGE"' -Message 'Manual template must pre-pull the NI Linux image.'
Assert-Match -Content $manualTemplate -Pattern 'invoke_script_path:\s+Tooling/Invoke-CompareVIHistoryHostedNILinux\.ps1' -Message 'Manual template must use the hosted NI Linux invoke adapter.'
Assert-Match -Content $manualTemplate -Pattern 'Container image' -Message 'Manual template summary must surface the container image.'

Assert-Match -Content $commentTemplate -Pattern '(?m)^\s*runs-on:\s+ubuntu-latest\s*$' -Message 'Comment-gated template must use ubuntu-latest.'
Assert-Match -Content $commentTemplate -Pattern '(?m)^\s*pull-requests:\s+write\s*$' -Message 'Comment-gated template must request pull-requests: write.'
Assert-Match -Content $commentTemplate -Pattern '(?m)^\s*COMPAREVI_NI_LINUX_IMAGE:\s+nationalinstruments/labview:2026q1-linux\s*$' -Message 'Comment-gated template must pin the NI Linux image.'
Assert-Match -Content $commentTemplate -Pattern 'docker pull "\$COMPAREVI_NI_LINUX_IMAGE"' -Message 'Comment-gated template must pre-pull the NI Linux image.'
Assert-Match -Content $commentTemplate -Pattern 'invoke_script_path:\s+Tooling/Invoke-CompareVIHistoryHostedNILinux\.ps1' -Message 'Comment-gated template must use the hosted NI Linux invoke adapter.'
Assert-Match -Content $commentTemplate -Pattern 'Resource not accessible by integration' -Message 'Comment-gated template must recognize permission-denied PR comment failures.'
Assert-Match -Content $commentTemplate -Pattern 'PR comment publication was denied by the repository token' -Message 'Comment-gated template must warn on denied PR comment publication.'
Assert-Match -Content $commentTemplate -Pattern 'PR comment publication: `skipped`' -Message 'Comment-gated template must record skipped PR comment publication in the step summary.'
Assert-Match -Content $releaseWorkflow -Pattern 'scripts/Sync-CompareVIHistoryPublishedTemplates\.ps1' -Message 'Release workflow must include the published template sync script.'
Assert-Match -Content $releaseWorkflow -Pattern 'Published comment-gated template now points at' -Message 'Release notes must mention the published comment-gated template pin.'
Assert-Match -Content $readme -Pattern 'hosted NI Linux container path wired by a repo-local adapter' -Message 'README must document the hosted NI Linux adapter path.'
Assert-Match -Content $readme -Pattern 'nationalinstruments/labview:2026q1-linux' -Message 'README must mention the published hosted NI Linux image path.'

$facadeRefMatch = [regex]::Match($commentTemplate, '(?m)^\s*FACADE_REF:\s*(v[0-9]+\.[0-9]+\.[0-9]+)\s*$')
$usesRefMatch = [regex]::Match($commentTemplate, '(?m)^\s*uses:\s+LabVIEW-Community-CI-CD/comparevi-history@(v[0-9]+\.[0-9]+\.[0-9]+)\s*$')
$actionRefMatch = [regex]::Match($commentTemplate, '(?m)^\s*ACTION_REF:\s+LabVIEW-Community-CI-CD/comparevi-history@(v[0-9]+\.[0-9]+\.[0-9]+)\s*$')
$docsRefMatch = [regex]::Match($safeTemplates, 'LabVIEW-Community-CI-CD/comparevi-history@(v[0-9]+\.[0-9]+\.[0-9]+)')

foreach ($match in @($facadeRefMatch, $usesRefMatch, $actionRefMatch, $docsRefMatch)) {
  if (-not $match.Success) {
    throw 'Failed to resolve the published immutable tag across the comment-gated template contract.'
  }
}

$immutableTag = $facadeRefMatch.Groups[1].Value
Assert-Equal -Actual $usesRefMatch.Groups[1].Value -Expected $immutableTag -Message 'Comment-gated template uses: pin mismatch.'
Assert-Equal -Actual $actionRefMatch.Groups[1].Value -Expected $immutableTag -Message 'Comment-gated template ACTION_REF mismatch.'
Assert-Equal -Actual $docsRefMatch.Groups[1].Value -Expected $immutableTag -Message 'Safe template docs immutable tag mismatch.'
