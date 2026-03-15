Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptPath = Join-Path $PSScriptRoot 'Resolve-CompareVIHistoryRequest.ps1'
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("comparevi-history-request-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

try {
  $repoRoot = Join-Path $tempRoot 'consumer'
  $githubDir = Join-Path $repoRoot '.github'
  New-Item -ItemType Directory -Path $githubDir -Force | Out-Null

  $targetSpec = @'
{
  "schema": "comparevi-history/consumer-targets@v1",
  "defaultTargetId": "settings-init",
  "targets": [
    {
      "id": "settings-init",
      "path": "resource/plugins/NIIconEditor/Miscellaneous/Settings Init.vi",
      "publicModes": [
        "attributes",
        "front-panel",
        "block-diagram"
      ],
      "history": {
        "startRef": "feature/head",
        "branchBudget": {
          "sourceBranchRef": "feature/head",
          "maxCommitCount": 32
        }
      },
      "reviewerSurface": {
        "variants": [
          "manual",
          "comment-gated"
        ]
      }
    }
  ]
}
'@
  $targetSpec | Set-Content -LiteralPath (Join-Path $githubDir 'comparevi-history-targets.json') -Encoding utf8

  $githubOutputPath = Join-Path $tempRoot 'request-output.txt'
  $requestJson = & $scriptPath `
    -RepositoryRoot $repoRoot `
    -TargetSpecPath '.github/comparevi-history-targets.json' `
    -ReviewerSurface manual `
    -ConsumerRepository 'ni/labview-icon-editor' `
    -ConsumerRef 'refs/pull/123/head' `
    -GitHubOutputPath $githubOutputPath

  $request = $requestJson | ConvertFrom-Json -Depth 20
  if ($request.schema -ne 'comparevi-history/request@v1') {
    throw 'Request schema mismatch.'
  }
  if ($request.target.id -ne 'settings-init') {
    throw 'Target id was not resolved from defaultTargetId.'
  }
  if ($request.target.path -ne 'resource/plugins/NIIconEditor/Miscellaneous/Settings Init.vi') {
    throw 'Target path mismatch.'
  }
  if (($request.target.requestedModes -join ',') -ne 'attributes,front-panel,block-diagram') {
    throw 'Public modes were not inherited from the target spec.'
  }
  if ($request.history.startRef -ne 'feature/head') {
    throw 'Target-spec startRef was not applied.'
  }
  if ($request.history.sourceBranchRef -ne 'feature/head') {
    throw 'Target-spec branch-budget sourceBranchRef was not applied.'
  }
  if ($request.history.maxBranchCommits -ne 32) {
    throw 'Target-spec branch-budget maxCommitCount was not applied.'
  }
  if ($request.reviewerSurface.kind -ne 'manual') {
    throw 'Reviewer surface kind mismatch.'
  }
  if (-not (Test-Path -LiteralPath $request.results.requestPath -PathType Leaf)) {
    throw 'Request receipt was not written.'
  }

  $githubOutputs = Get-Content -LiteralPath $githubOutputPath -Raw
  foreach ($requiredKey in @('target-id=settings-init', 'request-path=', 'public-run-path=', 'public-comment-path=', 'public-step-summary-path=')) {
    if ($githubOutputs -notmatch [regex]::Escape($requiredKey)) {
      throw "Expected GitHub output '$requiredKey'."
    }
  }

  $legacyRequest = & $scriptPath -RepositoryRoot $repoRoot -TargetPath 'legacy/path.vi' | ConvertFrom-Json -Depth 20
  if (($legacyRequest.target.requestedModes -join ',') -ne 'default') {
    throw 'Legacy path flow should preserve the default aggregate mode.'
  }

  $failed = $false
  try {
    & $scriptPath `
      -RepositoryRoot $repoRoot `
      -TargetSpecPath '.github/comparevi-history-targets.json' `
      -Mode 'default,attributes' | Out-Null
  } catch {
    $failed = $_.Exception.Message -match 'aggregate aliases'
  }

  if (-not $failed) {
    throw 'Expected target-spec public mode validation to reject aggregate aliases.'
  }
} finally {
  Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
