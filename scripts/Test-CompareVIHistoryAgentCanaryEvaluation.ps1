Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptPath = Join-Path $PSScriptRoot 'Write-CompareVIHistoryAgentCanaryEvaluation.ps1'
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('comparevi-history-agent-canary-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

function New-CanaryPolicyFile {
  param(
    [Parameter(Mandatory = $true)]
    [string]$RootPath
  )

  $policyPath = Join-Path $RootPath 'comparevi-history-agent-canary.json'
  @'
{
  "schema": "comparevi-history/agent-canary-policy@v1",
  "prIdentification": {
    "branchPrefix": "agent-canary/",
    "requiredLabels": ["agent-canary"]
  },
  "targetContract": {
    "canonicalPath": "Tooling/comparevi-history-canary/CanaryProbe.vi",
    "expectedChangedViCount": 1,
    "expectedSelectedTargetCount": 1
  },
  "executionContract": {
    "expectedPublicModes": ["attributes", "front-panel", "block-diagram"],
    "expectedNoisePolicy": "include",
    "expectedFullSurface": "artifact-index"
  },
  "publicationContract": {
    "stickyCommentRequired": true,
    "requiredStatus": "succeeded"
  },
  "promotionContract": {
    "mergePolicy": "manual-only",
    "prMode": "draft"
  }
}
'@ | Set-Content -LiteralPath $policyPath -Encoding utf8

  return $policyPath
}

function New-PublicationArtifactZip {
  param(
    [Parameter(Mandatory = $true)]
    [string]$RootPath,
    [string]$HeadRef = 'agent-canary/comparevi-history-pr-diagnostics',
    [string]$TargetPath = 'Tooling/comparevi-history-canary/CanaryProbe.vi',
    [int]$ChangedViCount = 1,
    [int]$SelectedTargetCount = 1,
    [string]$ExecutionFinalStatus = 'succeeded',
    [string]$ExecutionFinalReason = 'completed',
    [string]$PublicationStatus = 'succeeded',
    [string]$PublicationReason = 'comment-created',
    [string]$CommentAction = 'created',
    [bool]$Draft = $true,
    [string[]]$Labels = @('agent-canary'),
    [bool]$IncludePublicationReceipt = $true,
    [bool]$IncludePrRun = $true,
    [bool]$IncludeDiscovery = $true,
    [bool]$IncludeIndex = $true,
    [string[]]$PublicModes = @('attributes', 'front-panel', 'block-diagram'),
    [string]$NoisePolicy = 'include',
    [string]$FullSurface = 'artifact-index'
  )

  $artifactRoot = Join-Path $RootPath 'artifact-src'
  $executionRoot = Join-Path $artifactRoot 'artifact'
  $zipPath = Join-Path $RootPath 'artifact.zip'
  New-Item -ItemType Directory -Path $executionRoot -Force | Out-Null

  $labelsJson = ($Labels | ForEach-Object { '"{0}"' -f $_ }) -join ', '
  $modesJson = ($PublicModes | ForEach-Object { '"{0}"' -f $_ }) -join ', '
  $draftLiteral = if ($Draft) { 'true' } else { 'false' }

  if ($IncludePublicationReceipt) {
    @"
{
  "schema": "comparevi-history/pr-comment-publication@v1",
  "generatedAtUtc": "2026-03-17T00:05:00Z",
  "repository": "LabVIEW-Community-CI-CD/labview-icon-editor-demo",
  "workflowRunId": "444",
  "artifactName": "comparevi-history-pr-diagnostics-publish-444",
  "artifactZipPath": "C:/results/publish/artifact.zip",
  "artifactRoot": "C:/results/publish/artifact",
  "prRunPath": "C:/results/publish/artifact/pr-run.json",
  "commentBodyPath": "C:/results/publish/artifact/pr-comment.md",
  "pullRequestNumber": 55,
  "workflowRunUrl": "https://github.com/example/repo/actions/runs/444",
  "summary": {
    "status": "$PublicationStatus",
    "reason": "$PublicationReason",
    "commentAction": "$CommentAction",
    "commentId": 991,
    "commentUrl": "https://github.com/example/repo/pull/55#issuecomment-991"
  }
}
"@ | Set-Content -LiteralPath (Join-Path $artifactRoot 'pr-comment-publication.json') -Encoding utf8
  }

  if ($IncludePrRun) {
    @"
{
  "schema": "comparevi-history/pr-run@v2",
  "generatedAtUtc": "2026-03-17T00:00:00Z",
  "pullRequest": {
    "number": 55,
    "htmlUrl": "https://github.com/example/repo/pull/55",
    "baseRepository": "LabVIEW-Community-CI-CD/labview-icon-editor-demo",
    "baseRef": "develop",
    "baseSha": "base-sha",
    "headRepository": "LabVIEW-Community-CI-CD/labview-icon-editor-demo",
    "headRef": "$HeadRef",
    "headSha": "head-sha",
    "isFork": false
  },
  "prPolicy": {
    "schema": "comparevi-history/pr-policy@v2",
    "path": "C:/repo/.github/comparevi-history-pr-policy.json",
    "applied": true,
    "discovery": {
      "selectionMode": "dynamic-paths",
      "includePaths": ["**/*.vi"],
      "excludePaths": [],
      "maxChangedViCount": 10,
      "overflowBehavior": "block"
    },
    "execution": {
      "publicModes": [$modesJson],
      "noisePolicy": "$NoisePolicy",
      "history": {
        "sourceBranchRefStrategy": "pull-request-base",
        "keepArtifactsOnNoDiff": true
      }
    },
    "reviewerSurface": {
      "emitCommentBody": true,
      "emitStepSummary": true,
      "fullSurface": "$FullSurface"
    },
    "trust": {
      "forkBehavior": "hosted-auto"
    }
  },
  "executionContext": {
    "selectionMode": "dynamic-paths",
    "forkBehavior": "hosted-auto",
    "fullSurface": "$FullSurface"
  },
  "discovery": {
    "schema": "comparevi-history/changed-vi-discovery@v2",
    "path": "C:/results/changed-vi-discovery.json",
    "status": "ready",
    "reason": "selected-targets",
    "changedViCount": $ChangedViCount,
    "eligibleChangedViCount": $ChangedViCount,
    "excludedViCount": 0,
    "selectedTargetCount": $SelectedTargetCount,
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
    "workflowRunUrl": "https://github.com/example/repo/actions/runs/333",
    "artifactName": "comparevi-history-pr-diagnostics-333"
  },
  "summary": {
    "finalStatus": "$ExecutionFinalStatus",
    "finalReason": "$ExecutionFinalReason",
    "changedViCount": $ChangedViCount,
    "eligibleChangedViCount": $ChangedViCount,
    "excludedViCount": 0,
    "selectedTargetCount": $SelectedTargetCount,
    "overflowed": false,
    "overflowChangedViCount": 0,
    "executedTargetCount": $SelectedTargetCount,
    "failedTargetCount": 0,
    "totalProcessed": 2,
    "totalDiffs": 1
  },
  "excludedViFiles": [],
  "targets": [
    {
      "targetId": "dynamic-canary-001",
      "targetSource": "dynamic-path",
      "targetPath": "$TargetPath",
      "requestedModes": [$modesJson],
      "requestedModeSource": "pr-policy",
      "sourceBranchRef": "develop",
      "keepArtifactsOnNoDiff": true,
      "currentPath": "$TargetPath",
      "previousPath": null,
      "changeStatus": "modified",
      "finalStatus": "$ExecutionFinalStatus",
      "finalReason": "$ExecutionFinalReason",
      "requestPath": "C:/results/targets/request.json",
      "publicRunPath": "C:/results/targets/public-run.json",
      "sharedEvidencePath": "C:/results/targets/shared-evidence.json",
      "historySummaryJsonPath": "C:/results/targets/history-summary.json",
      "historyReportMdPath": "C:/results/targets/history-report.md",
      "historyReportHtmlPath": "C:/results/targets/history-report.html",
      "modeSummaryJsonPath": "C:/results/targets/mode-summary.json",
      "modeSummaryPath": "C:/results/targets/mode-summary.md",
      "totalProcessed": 2,
      "totalDiffs": 1
    }
  ]
}
"@ | Set-Content -LiteralPath (Join-Path $executionRoot 'pr-run.json') -Encoding utf8
  }

  if ($IncludeDiscovery) {
    @"
{
  "schema": "comparevi-history/changed-vi-discovery@v2",
  "generatedAtUtc": "2026-03-17T00:00:00Z",
  "repository": "LabVIEW-Community-CI-CD/labview-icon-editor-demo",
  "eventName": "pull_request",
  "prPolicy": {
    "schema": "comparevi-history/pr-policy@v2",
    "path": "C:/repo/.github/comparevi-history-pr-policy.json",
    "applied": true,
    "discovery": {
      "selectionMode": "dynamic-paths",
      "includePaths": ["**/*.vi"],
      "excludePaths": [],
      "maxChangedViCount": 10,
      "overflowBehavior": "block"
    },
    "execution": {
      "publicModes": [$modesJson],
      "noisePolicy": "$NoisePolicy",
      "history": {
        "sourceBranchRefStrategy": "pull-request-base",
        "keepArtifactsOnNoDiff": true
      }
    },
    "reviewerSurface": {
      "emitCommentBody": true,
      "emitStepSummary": true,
      "fullSurface": "$FullSurface"
    },
    "trust": {
      "forkBehavior": "hosted-auto"
    }
  },
  "executionContext": {
    "selectionMode": "dynamic-paths",
    "forkBehavior": "hosted-auto",
    "fullSurface": "$FullSurface"
  },
  "pullRequest": {
    "number": 55,
    "htmlUrl": "https://github.com/example/repo/pull/55",
    "baseRepository": "LabVIEW-Community-CI-CD/labview-icon-editor-demo",
    "baseRef": "develop",
    "baseSha": "base-sha",
    "headRepository": "LabVIEW-Community-CI-CD/labview-icon-editor-demo",
    "headRef": "$HeadRef",
    "headSha": "head-sha",
    "isFork": false,
    "changedFileCount": $ChangedViCount
  },
  "changedViFiles": [
    {
      "status": "modified",
      "currentPath": "$TargetPath",
      "previousPath": null
    }
  ],
  "excludedViFiles": [],
  "selectedTargets": [
    {
      "targetId": "dynamic-canary-001",
      "targetSource": "dynamic-path",
      "targetPath": "$TargetPath",
      "requestedModes": [$modesJson],
      "requestedModeSource": "pr-policy",
      "history": {
        "branchBudget": {
          "sourceBranchRef": "develop",
          "maxCommitCount": null,
          "source": "pull-request-base"
        }
      },
      "keepArtifactsOnNoDiff": true,
      "currentPath": "$TargetPath",
      "previousPath": null,
      "changeStatus": "modified"
    }
  ],
  "summary": {
    "selectionMode": "dynamic-paths",
    "executionStatus": "ready",
    "executionReason": "selected-targets",
    "changedViCount": $ChangedViCount,
    "eligibleChangedViCount": $ChangedViCount,
    "excludedViCount": 0,
    "selectedTargetCount": $SelectedTargetCount,
    "overflowBehavior": "block",
    "overflowed": false,
    "overflowChangedViCount": 0
  }
}
"@ | Set-Content -LiteralPath (Join-Path $executionRoot 'changed-vi-discovery.json') -Encoding utf8
  }

  if ($IncludeIndex) {
    '# comparevi-history PR diagnostics index' | Set-Content -LiteralPath (Join-Path $executionRoot 'index.md') -Encoding utf8
    '<html><body>index</body></html>' | Set-Content -LiteralPath (Join-Path $executionRoot 'index.html') -Encoding utf8
  }

  if (Test-Path -LiteralPath $zipPath) {
    Remove-Item -LiteralPath $zipPath -Force
  }
  Compress-Archive -Path (Join-Path $artifactRoot '*') -DestinationPath $zipPath -Force

  return @{
    ZipPath = $zipPath
    Draft = $Draft
    Labels = @($Labels)
  }
}

try {
  $global:MockScenario = @{}

  function Invoke-RestMethod {
    param(
      [string]$Method,
      [string]$Uri,
      [hashtable]$Headers
    )

    $methodKey = if ([string]::IsNullOrWhiteSpace($Method)) { 'Get' } else { $Method }
    if ($methodKey -eq 'Get' -and $Uri -like 'https://api.github.com/repos/*/actions/runs/*/artifacts?per_page=100') {
      return @{
        artifacts = @(
          @{
            name = $global:MockScenario.ArtifactName
            archive_download_url = 'https://example.test/publication-artifact.zip'
          }
        )
      }
    }

    if ($methodKey -eq 'Get' -and $Uri -like 'https://api.github.com/repos/*/pulls/*') {
      return @{
        draft = $global:MockScenario.PullRequestDraft
        labels = @(
          $global:MockScenario.PullRequestLabels | ForEach-Object {
            @{
              name = $_
            }
          }
        )
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

  $policyRoot = Join-Path $tempRoot 'policy'
  New-Item -ItemType Directory -Path $policyRoot -Force | Out-Null
  $policyPath = New-CanaryPolicyFile -RootPath $policyRoot

  $successRoot = Join-Path $tempRoot 'success'
  New-Item -ItemType Directory -Path $successRoot -Force | Out-Null
  $successFixture = New-PublicationArtifactZip -RootPath $successRoot
  $global:MockScenario = @{
    ArtifactName = 'comparevi-history-pr-diagnostics-publish-444'
    ZipPath = $successFixture.ZipPath
    PullRequestDraft = $successFixture.Draft
    PullRequestLabels = $successFixture.Labels
  }

  $successOutputPath = Join-Path $successRoot 'evaluate.out'
  $successJson = & $scriptPath `
    -Repository 'LabVIEW-Community-CI-CD/labview-icon-editor-demo' `
    -WorkflowRunId '444' `
    -CanaryPolicyPath $policyPath `
    -GitHubToken 'token' `
    -ResultsDir (Join-Path $successRoot 'results') `
    -GitHubOutputPath $successOutputPath

  $successReceipt = $successJson | ConvertFrom-Json -Depth 64
  if ($successReceipt.schema -ne 'comparevi-history/agent-canary-evaluation@v1') {
    throw 'Agent canary evaluation schema mismatch.'
  }
  if (-not $successReceipt.summary.matchedPolicy) {
    throw 'Expected the success case to match the canary policy.'
  }
  if ($successReceipt.summary.status -ne 'succeeded' -or $successReceipt.summary.reason -ne 'canary-acceptance-satisfied') {
    throw 'Expected the success case to satisfy canary acceptance.'
  }
  if ($successReceipt.summary.changedViCount -ne 1 -or $successReceipt.summary.selectedTargetCount -ne 1) {
    throw 'Success case summary counts mismatch.'
  }
  if ($successReceipt.publication.status -ne 'succeeded' -or $successReceipt.execution.finalStatus -ne 'succeeded') {
    throw 'Success case status propagation mismatch.'
  }
  if (-not (Test-Path -LiteralPath $successReceipt.outputs.indexMarkdownPath -PathType Leaf) -or
    -not (Test-Path -LiteralPath $successReceipt.outputs.indexHtmlPath -PathType Leaf)) {
    throw 'Success case should preserve index surfaces.'
  }
  $successOutput = Get-Content -LiteralPath $successOutputPath -Raw
  foreach ($requiredKey in @(
      'evaluation-path=',
      'evaluation-status=succeeded',
      'evaluation-reason=canary-acceptance-satisfied',
      'matched-policy=true'
    )) {
    if ($successOutput -notmatch [regex]::Escape($requiredKey)) {
      throw "Expected GitHub output '$requiredKey'."
    }
  }

  $skipRoot = Join-Path $tempRoot 'skip'
  New-Item -ItemType Directory -Path $skipRoot -Force | Out-Null
  $skipFixture = New-PublicationArtifactZip -RootPath $skipRoot -HeadRef 'feature/not-a-canary' -Draft $false -Labels @('triage')
  $global:MockScenario = @{
    ArtifactName = 'comparevi-history-pr-diagnostics-publish-445'
    ZipPath = $skipFixture.ZipPath
    PullRequestDraft = $skipFixture.Draft
    PullRequestLabels = $skipFixture.Labels
  }

  $skipJson = & $scriptPath `
    -Repository 'LabVIEW-Community-CI-CD/labview-icon-editor-demo' `
    -WorkflowRunId '445' `
    -ArtifactName 'comparevi-history-pr-diagnostics-publish-445' `
    -CanaryPolicyPath $policyPath `
    -GitHubToken 'token' `
    -ResultsDir (Join-Path $skipRoot 'results')

  $skipReceipt = $skipJson | ConvertFrom-Json -Depth 64
  if ($skipReceipt.summary.status -ne 'skipped' -or $skipReceipt.summary.reason -ne 'non-canary-pr') {
    throw 'Expected a non-canary PR to skip cleanly.'
  }
  if ($skipReceipt.summary.matchedPolicy) {
    throw 'Non-canary PR should not match canary policy.'
  }
  if ($skipReceipt.summary.failureReasons -notcontains 'branch-prefix-mismatch' -or
    $skipReceipt.summary.failureReasons -notcontains 'missing-required-label:agent-canary' -or
    $skipReceipt.summary.failureReasons -notcontains 'pr-not-draft') {
    throw 'Non-canary skip reasons mismatch.'
  }

  $wrongPathRoot = Join-Path $tempRoot 'wrong-path'
  New-Item -ItemType Directory -Path $wrongPathRoot -Force | Out-Null
  $wrongPathFixture = New-PublicationArtifactZip -RootPath $wrongPathRoot -TargetPath 'Tooling/deployment/VIP_Post-Install Custom Action.vi'
  $global:MockScenario = @{
    ArtifactName = 'comparevi-history-pr-diagnostics-publish-446'
    ZipPath = $wrongPathFixture.ZipPath
    PullRequestDraft = $wrongPathFixture.Draft
    PullRequestLabels = $wrongPathFixture.Labels
  }

  $wrongPathFailed = $false
  try {
    & $scriptPath `
      -Repository 'LabVIEW-Community-CI-CD/labview-icon-editor-demo' `
      -WorkflowRunId '446' `
      -ArtifactName 'comparevi-history-pr-diagnostics-publish-446' `
      -CanaryPolicyPath $policyPath `
      -GitHubToken 'token' `
      -ResultsDir (Join-Path $wrongPathRoot 'results') | Out-Null
  } catch {
    $wrongPathFailed = $true
  }
  if (-not $wrongPathFailed) {
    throw 'Wrong target path should fail closed.'
  }
  $wrongPathReceipt = Get-Content -LiteralPath (Join-Path $wrongPathRoot 'results/agent-canary-evaluation.json') -Raw | ConvertFrom-Json -Depth 64
  if ($wrongPathReceipt.summary.status -ne 'failed' -or $wrongPathReceipt.summary.reason -ne 'wrong-target-path') {
    throw 'Wrong target path failure reason mismatch.'
  }

  $publishFailureRoot = Join-Path $tempRoot 'publish-failure'
  New-Item -ItemType Directory -Path $publishFailureRoot -Force | Out-Null
  $publishFailureFixture = New-PublicationArtifactZip -RootPath $publishFailureRoot -PublicationStatus 'failed' -PublicationReason 'comment-create-denied' -CommentAction 'none'
  $global:MockScenario = @{
    ArtifactName = 'comparevi-history-pr-diagnostics-publish-447'
    ZipPath = $publishFailureFixture.ZipPath
    PullRequestDraft = $publishFailureFixture.Draft
    PullRequestLabels = $publishFailureFixture.Labels
  }

  $publishFailedAsExpected = $false
  try {
    & $scriptPath `
      -Repository 'LabVIEW-Community-CI-CD/labview-icon-editor-demo' `
      -WorkflowRunId '447' `
      -ArtifactName 'comparevi-history-pr-diagnostics-publish-447' `
      -CanaryPolicyPath $policyPath `
      -GitHubToken 'token' `
      -ResultsDir (Join-Path $publishFailureRoot 'results') | Out-Null
  } catch {
    $publishFailedAsExpected = $true
  }
  if (-not $publishFailedAsExpected) {
    throw 'Publication failure should fail closed.'
  }
  $publishFailureReceipt = Get-Content -LiteralPath (Join-Path $publishFailureRoot 'results/agent-canary-evaluation.json') -Raw | ConvertFrom-Json -Depth 64
  if ($publishFailureReceipt.summary.reason -ne 'failed-publication') {
    throw 'Publication failure reason mismatch.'
  }

  $missingIndexRoot = Join-Path $tempRoot 'missing-index'
  New-Item -ItemType Directory -Path $missingIndexRoot -Force | Out-Null
  $missingIndexFixture = New-PublicationArtifactZip -RootPath $missingIndexRoot -IncludeIndex:$false
  $global:MockScenario = @{
    ArtifactName = 'comparevi-history-pr-diagnostics-publish-448'
    ZipPath = $missingIndexFixture.ZipPath
    PullRequestDraft = $missingIndexFixture.Draft
    PullRequestLabels = $missingIndexFixture.Labels
  }

  $missingIndexFailed = $false
  try {
    & $scriptPath `
      -Repository 'LabVIEW-Community-CI-CD/labview-icon-editor-demo' `
      -WorkflowRunId '448' `
      -ArtifactName 'comparevi-history-pr-diagnostics-publish-448' `
      -CanaryPolicyPath $policyPath `
      -GitHubToken 'token' `
      -ResultsDir (Join-Path $missingIndexRoot 'results') | Out-Null
  } catch {
    $missingIndexFailed = $true
  }
  if (-not $missingIndexFailed) {
    throw 'Missing index surfaces should fail closed.'
  }
  $missingIndexReceipt = Get-Content -LiteralPath (Join-Path $missingIndexRoot 'results/agent-canary-evaluation.json') -Raw | ConvertFrom-Json -Depth 64
  if ($missingIndexReceipt.summary.reason -ne 'missing-index-surface') {
    throw 'Missing index failure reason mismatch.'
  }

  $missingPublicationRoot = Join-Path $tempRoot 'missing-publication'
  New-Item -ItemType Directory -Path $missingPublicationRoot -Force | Out-Null
  $missingPublicationFixture = New-PublicationArtifactZip -RootPath $missingPublicationRoot -IncludePublicationReceipt:$false
  $global:MockScenario = @{
    ArtifactName = 'comparevi-history-pr-diagnostics-publish-449'
    ZipPath = $missingPublicationFixture.ZipPath
    PullRequestDraft = $missingPublicationFixture.Draft
    PullRequestLabels = $missingPublicationFixture.Labels
  }

  $missingPublicationFailed = $false
  try {
    & $scriptPath `
      -Repository 'LabVIEW-Community-CI-CD/labview-icon-editor-demo' `
      -WorkflowRunId '449' `
      -ArtifactName 'comparevi-history-pr-diagnostics-publish-449' `
      -CanaryPolicyPath $policyPath `
      -GitHubToken 'token' `
      -ResultsDir (Join-Path $missingPublicationRoot 'results') | Out-Null
  } catch {
    $missingPublicationFailed = $true
  }
  if (-not $missingPublicationFailed) {
    throw 'Missing publication receipt should fail closed.'
  }
  $missingPublicationReceipt = Get-Content -LiteralPath (Join-Path $missingPublicationRoot 'results/agent-canary-evaluation.json') -Raw | ConvertFrom-Json -Depth 64
  if ($missingPublicationReceipt.summary.reason -ne 'missing-pr-comment-publication') {
    throw 'Missing publication receipt reason mismatch.'
  }

  $missingPrRunRoot = Join-Path $tempRoot 'missing-pr-run'
  New-Item -ItemType Directory -Path $missingPrRunRoot -Force | Out-Null
  $missingPrRunFixture = New-PublicationArtifactZip -RootPath $missingPrRunRoot -IncludePrRun:$false
  $global:MockScenario = @{
    ArtifactName = 'comparevi-history-pr-diagnostics-publish-450'
    ZipPath = $missingPrRunFixture.ZipPath
    PullRequestDraft = $missingPrRunFixture.Draft
    PullRequestLabels = $missingPrRunFixture.Labels
  }

  $missingPrRunFailed = $false
  try {
    & $scriptPath `
      -Repository 'LabVIEW-Community-CI-CD/labview-icon-editor-demo' `
      -WorkflowRunId '450' `
      -ArtifactName 'comparevi-history-pr-diagnostics-publish-450' `
      -CanaryPolicyPath $policyPath `
      -GitHubToken 'token' `
      -ResultsDir (Join-Path $missingPrRunRoot 'results') | Out-Null
  } catch {
    $missingPrRunFailed = $true
  }
  if (-not $missingPrRunFailed) {
    throw 'Missing PR run receipt should fail closed.'
  }
  $missingPrRunReceipt = Get-Content -LiteralPath (Join-Path $missingPrRunRoot 'results/agent-canary-evaluation.json') -Raw | ConvertFrom-Json -Depth 64
  if ($missingPrRunReceipt.summary.reason -ne 'missing-pr-run') {
    throw 'Missing PR run reason mismatch.'
  }
} finally {
  Remove-Item function:Invoke-RestMethod -ErrorAction SilentlyContinue
  Remove-Item function:Invoke-WebRequest -ErrorAction SilentlyContinue
  Remove-Variable MockScenario -Scope Global -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
