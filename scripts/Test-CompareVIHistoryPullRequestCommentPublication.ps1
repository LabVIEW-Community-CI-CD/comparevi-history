Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptPath = Join-Path $PSScriptRoot 'Publish-CompareVIHistoryPullRequestComment.ps1'
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('comparevi-history-pr-publish-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

function New-PublicationArtifactZip {
  param(
    [Parameter(Mandatory = $true)]
    [string]$RootPath,
    [Parameter(Mandatory = $true)]
    [int]$PullRequestNumber,
    [Parameter(Mandatory = $true)]
    [string]$FinalStatus,
    [Parameter(Mandatory = $true)]
    [string]$CommentBody
  )

  $artifactRoot = Join-Path $RootPath 'artifact-src'
  $zipPath = Join-Path $RootPath 'artifact.zip'
  New-Item -ItemType Directory -Path $artifactRoot -Force | Out-Null

  @"
{
  "schema": "comparevi-history/pr-run@v2",
  "generatedAtUtc": "2026-03-17T00:00:00Z",
  "pullRequest": {
    "number": $PullRequestNumber,
    "htmlUrl": "https://github.com/example/repo/pull/$PullRequestNumber",
    "baseRepository": "LabVIEW-Community-CI-CD/labview-icon-editor-demo",
    "baseRef": "develop",
    "baseSha": "base-sha",
    "headRepository": "LabVIEW-Community-CI-CD/labview-icon-editor-demo",
    "headRef": "feature/history",
    "headSha": "head-sha",
    "isFork": false
  },
  "prPolicy": {
    "schema": "comparevi-history/pr-policy@v2",
    "path": "C:/repo/.github/comparevi-history-pr-policy.json",
    "applied": true,
    "discovery": {},
    "execution": {},
    "reviewerSurface": {},
    "trust": {}
  },
  "executionContext": {
    "selectionMode": "dynamic-paths",
    "forkBehavior": "hosted-auto",
    "fullSurface": "artifact-index"
  },
  "discovery": {
    "schema": "comparevi-history/changed-vi-discovery@v2",
    "path": "C:/results/changed-vi-discovery.json",
    "status": "ready",
    "reason": "selected-targets",
    "changedViCount": 1,
    "eligibleChangedViCount": 1,
    "excludedViCount": 0,
    "selectedTargetCount": 1,
    "overflowed": false,
    "overflowChangedViCount": 0
  },
  "outputs": {
    "resultsDir": "C:/results",
    "prRunPath": "C:/results/pr-run.json",
    "publicCommentPath": "C:/results/pr-comment.md",
    "publicStepSummaryPath": "C:/results/pr-step-summary.md",
    "targetRunsManifestPath": "C:/results/pr-target-runs-manifest.json",
    "indexMarkdownPath": "C:/results/index.md",
    "indexHtmlPath": "C:/results/index.html",
    "workflowRunUrl": "https://github.com/example/repo/actions/runs/321",
    "artifactName": "comparevi-history-pr-diagnostics-321"
  },
  "summary": {
    "finalStatus": "$FinalStatus",
    "finalReason": "completed",
    "changedViCount": 1,
    "eligibleChangedViCount": 1,
    "excludedViCount": 0,
    "selectedTargetCount": 1,
    "overflowed": false,
    "overflowChangedViCount": 0,
    "executedTargetCount": 1,
    "failedTargetCount": 0,
    "totalProcessed": 5,
    "totalDiffs": 2
  },
  "excludedViFiles": [],
  "targets": []
}
"@ | Set-Content -LiteralPath (Join-Path $artifactRoot 'pr-run.json') -Encoding utf8
  $CommentBody | Set-Content -LiteralPath (Join-Path $artifactRoot 'pr-comment.md') -Encoding utf8

  if (Test-Path -LiteralPath $zipPath) {
    Remove-Item -LiteralPath $zipPath -Force
  }
  Compress-Archive -Path (Join-Path $artifactRoot '*') -DestinationPath $zipPath -Force
  return $zipPath
}

try {
  $global:MockScenario = @{}
  $global:RecordedPosts = New-Object System.Collections.Generic.List[object]
  $global:RecordedPatches = New-Object System.Collections.Generic.List[object]

  function Invoke-RestMethod {
    param(
      [string]$Method,
      [string]$Uri,
      [hashtable]$Headers,
      [string]$Body,
      [string]$ContentType
    )

    $methodKey = if ([string]::IsNullOrWhiteSpace($Method)) { 'Get' } else { $Method }
    if ($Uri -like 'https://api.github.com/repos/*/actions/runs/*/artifacts?per_page=100') {
      return @{
        artifacts = @(
          @{
            name = $global:MockScenario.ArtifactName
            archive_download_url = 'https://example.test/artifact.zip'
          }
        )
      }
    }

    if ($Uri -like 'https://api.github.com/repos/*/issues/*/comments?per_page=100&page=1') {
      return @($global:MockScenario.ExistingComments)
    }

    if ($Uri -like 'https://api.github.com/repos/*/issues/*/comments?per_page=100&page=2') {
      return @()
    }

    if ($methodKey -eq 'Post' -and $Uri -like 'https://api.github.com/repos/*/issues/*/comments') {
      $payload = $Body | ConvertFrom-Json -Depth 10
      $global:RecordedPosts.Add($payload) | Out-Null
      return @{
        id = 991
        html_url = 'https://github.com/example/repo/pull/55#issuecomment-991'
      }
    }

    if ($methodKey -eq 'Patch' -and $Uri -like 'https://api.github.com/repos/*/issues/comments/*') {
      $payload = $Body | ConvertFrom-Json -Depth 10
      $global:RecordedPatches.Add($payload) | Out-Null
      return @{
        id = 771
        html_url = 'https://github.com/example/repo/pull/55#issuecomment-771'
      }
    }

    throw "Unexpected REST call: $methodKey $Uri"
  }

  function Invoke-WebRequest {
    param(
      [string]$Uri,
      [hashtable]$Headers,
      [string]$OutFile
    )

    Copy-Item -LiteralPath $global:MockScenario.ZipPath -Destination $OutFile -Force
  }

  $createRoot = Join-Path $tempRoot 'create'
  New-Item -ItemType Directory -Path $createRoot -Force | Out-Null
  $createComment = @'
<!-- comparevi-history:pull-request-diagnostics -->
## comparevi-history PR diagnostics

- Final status: `succeeded`
- Workflow run: [view run](https://github.com/example/repo/actions/runs/321)
'@
  $createZipPath = New-PublicationArtifactZip -RootPath $createRoot -PullRequestNumber 55 -FinalStatus 'succeeded' -CommentBody $createComment
  $global:MockScenario = @{
    ArtifactName = 'comparevi-history-pr-diagnostics-321'
    ExistingComments = @()
    ZipPath = $createZipPath
  }

  $createOutputPath = Join-Path $createRoot 'publish.out'
  $createReceiptJson = & $scriptPath `
    -Repository 'LabVIEW-Community-CI-CD/labview-icon-editor-demo' `
    -WorkflowRunId '321' `
    -GitHubToken 'token' `
    -ResultsDir (Join-Path $createRoot 'results') `
    -GitHubOutputPath $createOutputPath

  $createReceipt = $createReceiptJson | ConvertFrom-Json -Depth 64
  if ($createReceipt.schema -ne 'comparevi-history/pr-comment-publication@v1') {
    throw 'Publication receipt schema mismatch.'
  }
  if ($createReceipt.summary.status -ne 'succeeded' -or $createReceipt.summary.commentAction -ne 'created') {
    throw 'Expected the first publication path to create a sticky PR comment.'
  }
  if ($global:RecordedPosts.Count -ne 1) {
    throw 'Expected one PR comment creation request.'
  }
  if ($global:RecordedPosts[0].body -notmatch [regex]::Escape('<!-- comparevi-history:pull-request-diagnostics -->')) {
    throw 'Created PR comment body is missing the sticky marker.'
  }

  $createOutputText = Get-Content -LiteralPath $createOutputPath -Raw
  foreach ($requiredKey in @(
      'publication-receipt-path=',
      'publication-status=succeeded',
      'publication-reason=comment-created',
      'comment-id=991',
      'comment-url=https://github.com/example/repo/pull/55#issuecomment-991'
    )) {
    if ($createOutputText -notmatch [regex]::Escape($requiredKey)) {
      throw "Expected GitHub output '$requiredKey'."
    }
  }

  $updateRoot = Join-Path $tempRoot 'update'
  New-Item -ItemType Directory -Path $updateRoot -Force | Out-Null
  $updatedComment = @'
<!-- comparevi-history:pull-request-diagnostics -->
## comparevi-history PR diagnostics

- Final status: `blocked`
- Final reason: `max-changed-vi-count-exceeded`
'@
  $updateZipPath = New-PublicationArtifactZip -RootPath $updateRoot -PullRequestNumber 55 -FinalStatus 'blocked' -CommentBody $updatedComment
  $global:MockScenario = @{
    ArtifactName = 'comparevi-history-pr-diagnostics-654'
    ExistingComments = @(
      @{
        id = 771
        html_url = 'https://github.com/example/repo/pull/55#issuecomment-771'
        body = "<!-- comparevi-history:pull-request-diagnostics -->`nold body"
        updated_at = '2026-03-17T00:00:00Z'
      }
    )
    ZipPath = $updateZipPath
  }

  $updateReceiptJson = & $scriptPath `
    -Repository 'LabVIEW-Community-CI-CD/labview-icon-editor-demo' `
    -WorkflowRunId '654' `
    -ArtifactName 'comparevi-history-pr-diagnostics-654' `
    -GitHubToken 'token' `
    -ResultsDir (Join-Path $updateRoot 'results')

  $updateReceipt = $updateReceiptJson | ConvertFrom-Json -Depth 64
  if ($updateReceipt.summary.status -ne 'succeeded' -or $updateReceipt.summary.commentAction -ne 'updated') {
    throw 'Expected the second publication path to update the existing sticky PR comment.'
  }
  if ($global:RecordedPatches.Count -ne 1) {
    throw 'Expected one PR comment update request.'
  }
  if ($global:RecordedPatches[0].body -notmatch [regex]::Escape('Final status: `blocked`')) {
    throw 'Updated PR comment body mismatch.'
  }

  $failureRoot = Join-Path $tempRoot 'failure'
  New-Item -ItemType Directory -Path $failureRoot -Force | Out-Null
  $global:MockScenario = @{
    ArtifactName = 'comparevi-history-pr-diagnostics-999'
    ExistingComments = @()
    ZipPath = $createZipPath
  }

  $failureOutputPath = Join-Path $failureRoot 'publish.out'
  $failedAsExpected = $false
  try {
    & $scriptPath `
      -Repository 'LabVIEW-Community-CI-CD/labview-icon-editor-demo' `
      -WorkflowRunId '999' `
      -ArtifactName 'comparevi-history-pr-diagnostics-missing' `
      -GitHubToken 'token' `
      -ResultsDir (Join-Path $failureRoot 'results') `
      -GitHubOutputPath $failureOutputPath | Out-Null
  } catch {
    $failedAsExpected = $true
  }

  if (-not $failedAsExpected) {
    throw 'Publication should fail closed when the expected artifact is missing.'
  }
  $failureReceiptPath = Join-Path $failureRoot 'results' 'pr-comment-publication.json'
  if (-not (Test-Path -LiteralPath $failureReceiptPath -PathType Leaf)) {
    throw 'Publication failure should still write a receipt.'
  }
  $failureReceipt = Get-Content -LiteralPath $failureReceiptPath -Raw | ConvertFrom-Json -Depth 64
  if ($failureReceipt.summary.status -ne 'failed') {
    throw 'Failure receipt status mismatch.'
  }
  if ($failureReceipt.summary.reason -notmatch 'did not publish artifact') {
    throw 'Failure receipt reason mismatch.'
  }
} finally {
  Remove-Item function:Invoke-RestMethod -ErrorAction SilentlyContinue
  Remove-Item function:Invoke-WebRequest -ErrorAction SilentlyContinue
  Remove-Variable MockScenario, RecordedPosts, RecordedPatches -Scope Global -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
