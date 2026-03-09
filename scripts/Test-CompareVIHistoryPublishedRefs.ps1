Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptPath = Join-Path $PSScriptRoot 'Resolve-CompareVIHistoryPublishedRefs.ps1'
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("comparevi-history-published-refs-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

function Assert-Equal {
  param(
    [Parameter(Mandatory = $true)]
    [object]$Actual,
    [Parameter(Mandatory = $true)]
    [object]$Expected,
    [Parameter(Mandatory = $true)]
    [string]$Message
  )

  if ($Actual -ne $Expected) {
    throw "$Message Expected '$Expected', actual '$Actual'."
  }
}

try {
  $outputPath = Join-Path $tempRoot 'published-refs.json'
  $githubOutputPath = Join-Path $tempRoot 'github-output.txt'

  $json = & $scriptPath `
    -Repository 'LabVIEW-Community-CI-CD/comparevi-history' `
    -MajorTag 'v1' `
    -LatestImmutableTag 'v1.0.2' `
    -OutputPath $outputPath `
    -GitHubOutputPath $githubOutputPath

  $plan = $json | ConvertFrom-Json
  Assert-Equal -Actual $plan.latestImmutableTag -Expected 'v1.0.2' -Message 'Latest immutable tag mismatch.'
  Assert-Equal -Actual $plan.refs.Count -Expected 2 -Message 'Published ref count mismatch.'
  Assert-Equal -Actual $plan.refs[0].actionRef -Expected 'LabVIEW-Community-CI-CD/comparevi-history@v1' -Message 'Major action ref mismatch.'
  Assert-Equal -Actual $plan.refs[1].actionRef -Expected 'LabVIEW-Community-CI-CD/comparevi-history@v1.0.2' -Message 'Immutable action ref mismatch.'

  $writtenPlan = Get-Content -LiteralPath $outputPath -Raw | ConvertFrom-Json
  Assert-Equal -Actual $writtenPlan.refs[1].artifactSuffix -Expected 'v1-0-2' -Message 'Artifact suffix mismatch.'

  $githubOutput = Get-Content -LiteralPath $githubOutputPath
  if (-not ($githubOutput -contains 'latest-immutable-tag=v1.0.2')) {
    throw 'GitHub output did not include latest-immutable-tag.'
  }
  if (-not ($githubOutput | Where-Object { $_ -like 'published-refs-json=*' })) {
    throw 'GitHub output did not include published-refs-json.'
  }

  $failed = $false
  try {
    & $scriptPath -LatestImmutableTag 'develop' | Out-Null
  } catch {
    $failed = $_.Exception.Message -match 'immutable release tag'
  }

  if (-not $failed) {
    throw 'Expected invalid latest immutable tag validation to fail.'
  }
} finally {
  Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
