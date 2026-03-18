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
  },
  "reviewerSurfaceContract": {
    "previewManifestRequired": true,
    "requiredPreviewPublicationStatus": "succeeded",
    "maxCommentPreviewCards": 4,
    "requiredSurfaceKinds": ["front-panel", "block-diagram"],
    "reviewerSummaryRequired": true,
    "changeDetailsRequired": true,
    "requiredMarkdownSections": [
      "## Workspace summary",
      "## Workspace navigation",
      "## Review workspace",
      "## Raw evidence inventory"
    ],
    "requiredHtmlMarkers": [
      "class=\"workspace-shell\"",
      "class=\"workspace-nav\"",
      "class=\"workspace-summary\"",
      "class=\"raw-evidence\""
    ],
    "surfaceReportLinksRequired": true,
    "signalReportLinksRequired": true,
    "changeDetailReportLinksRequired": true
  }
}
'@ | Set-Content -LiteralPath $policyPath -Encoding utf8

  return $policyPath
}

function New-PreviewPair {
  param(
    [Parameter(Mandatory = $true)]
    [string]$TargetPath,
    [Parameter(Mandatory = $true)]
    [string]$Mode,
    [Parameter(Mandatory = $true)]
    [int]$ComparisonIndex
  )

  return [ordered]@{
    targetId = 'dynamic-canary-001'
    targetPath = $TargetPath
    mode = $Mode
    comparison = [ordered]@{
      index = $ComparisonIndex
      baseRef = ('{0}-base-{1}' -f $Mode, $ComparisonIndex)
      headRef = ('{0}-head-{1}' -f $Mode, $ComparisonIndex)
      baseShortRef = ('base-{0:D2}' -f $ComparisonIndex)
      headShortRef = ('head-{0:D2}' -f $ComparisonIndex)
      baseSubject = ('Base subject {0}' -f $ComparisonIndex)
      headSubject = ('Head subject {0}' -f $ComparisonIndex)
    }
    reportHtmlRelativePath = ('targets/001/history/{0}/CanaryProbe.vi-{1:D3}-artifacts/compare-report.html' -f $Mode, $ComparisonIndex)
    baseImageRelativePath = ('targets/001/history/{0}/CanaryProbe.vi-{1:D3}-artifacts/compare-report_files/{2}_1.png' -f $Mode, $ComparisonIndex, $(if ($Mode -eq 'block-diagram') { 'bd' } else { 'fp' }))
    headImageRelativePath = ('targets/001/history/{0}/CanaryProbe.vi-{1:D3}-artifacts/compare-report_files/{2}_2.png' -f $Mode, $ComparisonIndex, $(if ($Mode -eq 'block-diagram') { 'bd' } else { 'fp' }))
  }
}

function New-PreviewCard {
  param(
    [Parameter(Mandatory = $true)]
    [string]$TargetPath,
    [Parameter(Mandatory = $true)]
    [object[]]$PreviewPairs,
    [Parameter(Mandatory = $true)]
    [int]$ComparisonIndex,
    [switch]$Published
  )

  $matchingPairs = @(
    $PreviewPairs |
      Where-Object { [int]$_.comparison.index -eq $ComparisonIndex } |
      Sort-Object {
        switch ([string]$_.mode) {
          'front-panel' { 0 }
          'block-diagram' { 1 }
          default { 99 }
        }
      }
  )

  $prefix = $(if ($Published.IsPresent) {
      'https://github.com/LabVIEW-Community-CI-CD/labview-icon-editor-demo/blob/comparevi-history-pr-previews/.comparevi-history/pr-diagnostics/previews/pull-request-00055/workflow-run-444'
    } else {
      $null
    })

  $surfaces = @(
    $matchingPairs |
      ForEach-Object {
        [ordered]@{
          surfaceKind = [string]$_.mode
          surfaceLabel = $(if ([string]$_.mode -eq 'front-panel') { 'Front panel' } else { 'Block diagram' })
          reportHtmlRelativePath = [string]$_.reportHtmlRelativePath
          reportUrl = $(if ($Published.IsPresent) { '{0}/{1:D3}-history-pair-{2:D2}/{3:D2}-{4}/evidence.md' -f $prefix, $ComparisonIndex, $ComparisonIndex, $(if ([string]$_.mode -eq 'front-panel') { 1 } else { 2 }), [string]$_.mode } else { $null })
          baseImageRelativePath = [string]$_.baseImageRelativePath
          headImageRelativePath = [string]$_.headImageRelativePath
        }
      }
  )

  return [ordered]@{
    targetId = 'dynamic-canary-001'
    targetPath = $TargetPath
    comparison = $matchingPairs[0].comparison
    reviewerSummary = [ordered]@{
      label = 'Reviewer summary'
      overallSeverity = 'medium'
      headline = $(if ($ComparisonIndex -eq 1) { 'Material logic-affecting movement and structure resizing' } else { 'Material version or compatibility changes' })
      signalCount = $(if ($ComparisonIndex -eq 1) { 2 } else { 1 })
      omittedSignalCount = 0
      signals = @(
        [ordered]@{
          signalKey = $(if ($ComparisonIndex -eq 1) { 'logic-affecting-movement' } else { 'version-or-compatibility-changes' })
          label = $(if ($ComparisonIndex -eq 1) { 'Logic-affecting movement' } else { 'Version or compatibility changes' })
          severity = 'medium'
          detailCount = $(if ($ComparisonIndex -eq 1) { 3 } else { 1 })
          sectionCount = 1
          summary = $(if ($ComparisonIndex -eq 1) { 'Block diagram objects moved across 1 exact sections.' } else { 'Version or compatibility changes detected across 1 exact sections.' })
          primaryReportHtmlRelativePath = ('targets/001/history/attributes/CanaryProbe.vi-{0:D3}-artifacts/compare-report.html#comparevi-change-001-{1}' -f $ComparisonIndex, $(if ($ComparisonIndex -eq 1) { 'block-diagram-objects' } else { 'vi-attribute-miscellaneous' }))
          primaryReportUrl = $(if ($Published.IsPresent) { '{0}/{1:D3}-history-pair-{1:D2}/change-details.md#comparevi-change-001-{2}' -f $prefix, $ComparisonIndex, $(if ($ComparisonIndex -eq 1) { 'block-diagram-objects' } else { 'vi-attribute-miscellaneous' }) } else { $null })
          sectionLinks = @(
            [ordered]@{
              sectionOrdinal = 1
              label = 'section 1'
              reportHtmlRelativePath = ('targets/001/history/attributes/CanaryProbe.vi-{0:D3}-artifacts/compare-report.html#comparevi-change-001-{1}' -f $ComparisonIndex, $(if ($ComparisonIndex -eq 1) { 'block-diagram-objects' } else { 'vi-attribute-miscellaneous' }))
              reportUrl = $(if ($Published.IsPresent) { '{0}/{1:D3}-history-pair-{1:D2}/change-details.md#comparevi-change-001-{2}' -f $prefix, $ComparisonIndex, $(if ($ComparisonIndex -eq 1) { 'block-diagram-objects' } else { 'vi-attribute-miscellaneous' }) } else { $null })
            }
          )
        }
        $(if ($ComparisonIndex -eq 1) {
            ,
            [ordered]@{
              signalKey = 'structure-resizing'
              label = 'Structure resizing'
              severity = 'low'
              detailCount = 2
              sectionCount = 1
              summary = 'Structure resizing detected across 1 exact sections.'
              primaryReportHtmlRelativePath = 'targets/001/history/attributes/CanaryProbe.vi-001-artifacts/compare-report.html#comparevi-change-002-block-diagram-objects'
              primaryReportUrl = $(if ($Published.IsPresent) { "$prefix/001-history-pair-01/change-details.md#comparevi-change-002-block-diagram-objects" } else { $null })
              sectionLinks = @(
                [ordered]@{
                  sectionOrdinal = 2
                  label = 'section 2'
                  reportHtmlRelativePath = 'targets/001/history/attributes/CanaryProbe.vi-001-artifacts/compare-report.html#comparevi-change-002-block-diagram-objects'
                  reportUrl = $(if ($Published.IsPresent) { "$prefix/001-history-pair-01/change-details.md#comparevi-change-002-block-diagram-objects" } else { $null })
                }
              )
            }
          })
      )
    }
    changeDetails = [ordered]@{
      label = 'Change details'
      sourceMode = 'attributes'
      reportHtmlRelativePath = ('targets/001/history/attributes/CanaryProbe.vi-{0:D3}-artifacts/compare-report.html' -f $ComparisonIndex)
      reportUrl = $(if ($Published.IsPresent) { '{0}/{1:D3}-history-pair-{1:D2}/change-details.md' -f $prefix, $ComparisonIndex } else { $null })
      includedCategories = $(if ($ComparisonIndex -eq 1) { @('Block Diagram Functional', 'VI Attribute') } else { @('VI Attribute') })
      groupCount = $(if ($ComparisonIndex -eq 1) { 2 } else { 1 })
      omittedGroupCount = 0
      sectionCount = $(if ($ComparisonIndex -eq 1) { 2 } else { 1 })
      detailCount = $(if ($ComparisonIndex -eq 1) { 5 } else { 1 })
      groups = @(
        [ordered]@{
          heading = $(if ($ComparisonIndex -eq 1) { 'Block diagram moves' } else { 'VI version changes' })
          sectionCount = 1
          detailCount = $(if ($ComparisonIndex -eq 1) { 3 } else { 1 })
          sampleDetails = @('sample')
          omittedDetailCount = 0
          primaryReportHtmlRelativePath = ('targets/001/history/attributes/CanaryProbe.vi-{0:D3}-artifacts/compare-report.html#comparevi-change-001-{1}' -f $ComparisonIndex, $(if ($ComparisonIndex -eq 1) { 'block-diagram-objects' } else { 'vi-attribute-miscellaneous' }))
          primaryReportUrl = $(if ($Published.IsPresent) { '{0}/{1:D3}-history-pair-{1:D2}/change-details.md#comparevi-change-001-{2}' -f $prefix, $ComparisonIndex, $(if ($ComparisonIndex -eq 1) { 'block-diagram-objects' } else { 'vi-attribute-miscellaneous' }) } else { $null })
          sectionLinks = @(
            [ordered]@{
              sectionOrdinal = 1
              label = 'section 1'
              reportHtmlRelativePath = ('targets/001/history/attributes/CanaryProbe.vi-{0:D3}-artifacts/compare-report.html#comparevi-change-001-{1}' -f $ComparisonIndex, $(if ($ComparisonIndex -eq 1) { 'block-diagram-objects' } else { 'vi-attribute-miscellaneous' }))
              reportUrl = $(if ($Published.IsPresent) { '{0}/{1:D3}-history-pair-{1:D2}/change-details.md#comparevi-change-001-{2}' -f $prefix, $ComparisonIndex, $(if ($ComparisonIndex -eq 1) { 'block-diagram-objects' } else { 'vi-attribute-miscellaneous' }) } else { $null })
            }
          )
        }
        $(if ($ComparisonIndex -eq 1) {
            ,
            [ordered]@{
              heading = 'Block diagram resizing'
              sectionCount = 1
              detailCount = 2
              sampleDetails = @('sample')
              omittedDetailCount = 0
              primaryReportHtmlRelativePath = 'targets/001/history/attributes/CanaryProbe.vi-001-artifacts/compare-report.html#comparevi-change-002-block-diagram-objects'
              primaryReportUrl = $(if ($Published.IsPresent) { "$prefix/001-history-pair-01/change-details.md#comparevi-change-002-block-diagram-objects" } else { $null })
              sectionLinks = @(
                [ordered]@{
                  sectionOrdinal = 2
                  label = 'section 2'
                  reportHtmlRelativePath = 'targets/001/history/attributes/CanaryProbe.vi-001-artifacts/compare-report.html#comparevi-change-002-block-diagram-objects'
                  reportUrl = $(if ($Published.IsPresent) { "$prefix/001-history-pair-01/change-details.md#comparevi-change-002-block-diagram-objects" } else { $null })
                }
              )
            }
          })
      )
    }
    surfaces = $surfaces
  }
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
    [bool]$IncludePreviewManifest = $true,
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
  $previewPairs = @(
    (New-PreviewPair -TargetPath $TargetPath -Mode 'front-panel' -ComparisonIndex 1),
    (New-PreviewPair -TargetPath $TargetPath -Mode 'block-diagram' -ComparisonIndex 1),
    (New-PreviewPair -TargetPath $TargetPath -Mode 'front-panel' -ComparisonIndex 2),
    (New-PreviewPair -TargetPath $TargetPath -Mode 'block-diagram' -ComparisonIndex 2)
  )
  $indexPreviewCards = @(
    (New-PreviewCard -TargetPath $TargetPath -PreviewPairs $previewPairs -ComparisonIndex 1),
    (New-PreviewCard -TargetPath $TargetPath -PreviewPairs $previewPairs -ComparisonIndex 2)
  )
  $commentPreviewCards = @(
    (New-PreviewCard -TargetPath $TargetPath -PreviewPairs $previewPairs -ComparisonIndex 1 -Published),
    (New-PreviewCard -TargetPath $TargetPath -PreviewPairs $previewPairs -ComparisonIndex 2 -Published)
  )
  $commentPreviewCardsJson = $commentPreviewCards | ConvertTo-Json -Depth 64
  $indexPreviewCardsJson = $indexPreviewCards | ConvertTo-Json -Depth 64

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
  },
  "previewPublication": {
    "status": "$(if ($IncludePreviewManifest) { 'succeeded' } else { 'not-required' })",
    "reason": "$(if ($IncludePreviewManifest) { 'preview-images-published' } else { 'preview-manifest-missing' })",
    "branch": "comparevi-history-pr-previews",
    "root": ".comparevi-history/pr-diagnostics/previews/pull-request-00055/workflow-run-444",
    "manifestPath": "$(if ($IncludePreviewManifest) { '.comparevi-history/pr-diagnostics/previews/pull-request-00055/workflow-run-444/preview-manifest.json' } else { '' })",
    "manifestUrl": "$(if ($IncludePreviewManifest) { 'https://github.com/LabVIEW-Community-CI-CD/labview-icon-editor-demo/blob/comparevi-history-pr-previews/.comparevi-history/pr-diagnostics/previews/pull-request-00055/workflow-run-444/preview-manifest.json' } else { '' })",
    "previewPairCount": $(if ($IncludePreviewManifest) { 2 } else { 0 }),
    "publishedSurfaceCount": $(if ($IncludePreviewManifest) { 4 } else { 0 }),
    "publishedImageCount": $(if ($IncludePreviewManifest) { 8 } else { 0 }),
    "commentPreviewCards": $commentPreviewCardsJson,
    "commentPreviewPairs": []
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
    "previewManifestPath": $(if ($IncludePreviewManifest) { '"C:/results/pr-preview-manifest.json"' } else { 'null' }),
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
    "totalDiffs": 1,
    "commentPreviewPairCount": $(if ($IncludePreviewManifest) { 2 } else { 0 }),
    "indexPreviewCardCount": $(if ($IncludePreviewManifest) { 2 } else { 0 })
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

  @'
<!-- comparevi-history:pull-request-diagnostics -->
## comparevi-history pull request diagnostics

- Reviewer preview gallery: `2` history pairs shown, `0` omitted, cap `4`
- Raw preview surfaces collapsed for review: `4` raw -> `2` reviewer-canonical
'@ | Set-Content -LiteralPath (Join-Path $executionRoot 'pr-comment.md') -Encoding utf8

  if ($IncludePreviewManifest) {
    foreach ($previewPair in $previewPairs) {
      foreach ($relativePath in @([string]$previewPair.baseImageRelativePath, [string]$previewPair.headImageRelativePath)) {
        $fullPath = Join-Path $executionRoot ($relativePath -replace '/', [System.IO.Path]::DirectorySeparatorChar)
        New-Item -ItemType Directory -Path (Split-Path -Parent $fullPath) -Force | Out-Null
        [System.IO.File]::WriteAllBytes($fullPath, @(0xCA, 0xFE, 0xBA, 0xBE))
      }
    }

    ([ordered]@{
        schema = 'comparevi-history/pr-preview-manifest@v1'
        generatedAtUtc = '2026-03-17T00:00:00Z'
        targetRunsManifestPath = 'C:/results/pr-target-runs-manifest.json'
        resultsDir = 'C:/results'
        summary = [ordered]@{
          targetCount = 1
          previewPairCount = 4
          rawPreviewPairCount = 4
          reviewerPreviewPairCount = 2
          reviewerPreviewCardCount = 2
          reviewerPreviewSurfaceCount = 4
          commentPreviewPairCap = 4
          commentPreviewPairCount = 2
          commentPreviewPairOmittedCount = 0
          commentPreviewCardCount = 2
          commentPreviewSurfaceCount = 4
          commentCardSelectionPolicy = 'reviewer-multisurface@v1'
          indexPreviewPairCap = 12
          indexPreviewPairCount = 2
          indexPreviewPairOmittedCount = 0
          indexPreviewCardCount = 2
          indexPreviewSurfaceCount = 4
          indexCardSelectionPolicy = 'reviewer-multisurface@v1'
        }
        indexPreviewCards = $indexPreviewCards
      } | ConvertTo-Json -Depth 64) | Set-Content -LiteralPath (Join-Path $executionRoot 'pr-preview-manifest.json') -Encoding utf8
  }

  if ($IncludeIndex) {
    @"
# comparevi-history PR diagnostics workspace

## Workspace summary

- History pairs in workspace: `2`
- Targets in workspace: `1`
- Severity mix: `0` high / `2` medium / `0` low

## Workspace navigation

- [History pair 1](#history-pair-01-tooling-comparevi-history-canary-canaryprobe-vi) `medium` - Material logic-affecting movement and structure resizing
- [History pair 2](#history-pair-02-tooling-comparevi-history-canary-canaryprobe-vi) `medium` - Material version or compatibility changes

## Review workspace

<a id="history-pair-01-tooling-comparevi-history-canary-canaryprobe-vi"></a>

Quick links: [card](#history-pair-01-tooling-comparevi-history-canary-canaryprobe-vi)

<a id="history-pair-02-tooling-comparevi-history-canary-canaryprobe-vi"></a>

Quick links: [card](#history-pair-02-tooling-comparevi-history-canary-canaryprobe-vi)

## Raw evidence inventory
"@ | Set-Content -LiteralPath (Join-Path $executionRoot 'index.md') -Encoding utf8
    @'
<html>
<head><title>comparevi-history PR diagnostics workspace</title></head>
<body>
  <div class="workspace-shell">
    <aside class="workspace-nav">
      <a class="workspace-nav-link" href="#history-pair-01-tooling-comparevi-history-canary-canaryprobe-vi">History pair 1</a>
      <a class="workspace-nav-link" href="#history-pair-02-tooling-comparevi-history-canary-canaryprobe-vi">History pair 2</a>
    </aside>
    <main class="workspace-main">
      <section class="workspace-summary"></section>
      <section class="preview-gallery">
        <article class="preview-card" id="history-pair-01-tooling-comparevi-history-canary-canaryprobe-vi"></article>
        <article class="preview-card" id="history-pair-02-tooling-comparevi-history-canary-canaryprobe-vi"></article>
      </section>
      <section class="raw-evidence"></section>
    </main>
  </div>
</body>
</html>
'@ | Set-Content -LiteralPath (Join-Path $executionRoot 'index.html') -Encoding utf8
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
      $artifactNames = @()
      if ($global:MockScenario -is [System.Collections.IDictionary] -and $global:MockScenario.Contains('ArtifactNames')) {
        $artifactNames = @($global:MockScenario.ArtifactNames)
      } elseif ($global:MockScenario -is [System.Collections.IDictionary] -and $global:MockScenario.Contains('ArtifactName') -and -not [string]::IsNullOrWhiteSpace($global:MockScenario.ArtifactName)) {
        $artifactNames = @($global:MockScenario.ArtifactName)
      }

      return @{
        artifacts = @(
          $artifactNames | ForEach-Object {
            @{
              name = $_
              archive_download_url = 'https://example.test/publication-artifact.zip'
            }
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
  if ([string]$successReceipt.summary.previewPublicationStatus -ne 'succeeded' -or
    [int]$successReceipt.summary.commentPreviewCardCount -ne 2 -or
    [int]$successReceipt.summary.indexPreviewCardCount -ne 2) {
    throw 'Success case reviewer-surface summary mismatch.'
  }
  if ($successReceipt.checks.reviewerSurfaceContract.matched -ne $true) {
    throw 'Success case should satisfy reviewer-surface canary checks.'
  }
  if ([string]$successReceipt.reviewerSurface.previewManifestPath -notmatch 'pr-preview-manifest\.json$' -or
    [string]$successReceipt.outputs.commentBodyPath -notmatch 'pr-comment\.md$') {
    throw 'Success case should preserve reviewer-surface artifact paths.'
  }
  if ($successReceipt.artifactName -ne 'comparevi-history-pr-diagnostics-publish-444') {
    throw 'Success case should preserve the resolved artifact name.'
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

  $fallbackRoot = Join-Path $tempRoot 'fallback'
  New-Item -ItemType Directory -Path $fallbackRoot -Force | Out-Null
  $fallbackFixture = New-PublicationArtifactZip -RootPath $fallbackRoot -HeadRef 'feature/not-a-canary' -Draft $false -Labels @('triage')
  $global:MockScenario = @{
    ArtifactNames = @('comparevi-history-pr-diagnostics-publish-333')
    ZipPath = $fallbackFixture.ZipPath
    PullRequestDraft = $fallbackFixture.Draft
    PullRequestLabels = $fallbackFixture.Labels
  }

  $fallbackJson = & $scriptPath `
    -Repository 'LabVIEW-Community-CI-CD/labview-icon-editor-demo' `
    -WorkflowRunId '4451' `
    -ArtifactName 'comparevi-history-pr-diagnostics-publish-4451' `
    -CanaryPolicyPath $policyPath `
    -GitHubToken 'token' `
    -ResultsDir (Join-Path $fallbackRoot 'results')

  $fallbackReceipt = $fallbackJson | ConvertFrom-Json -Depth 64
  if ($fallbackReceipt.artifactName -ne 'comparevi-history-pr-diagnostics-publish-333') {
    throw 'Fallback resolution should use the actual publisher artifact name.'
  }
  if ($fallbackReceipt.summary.status -ne 'skipped' -or $fallbackReceipt.summary.reason -ne 'non-canary-pr') {
    throw 'Fallback resolution should still skip non-canary PRs cleanly.'
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

  $missingPreviewManifestRoot = Join-Path $tempRoot 'missing-preview-manifest'
  New-Item -ItemType Directory -Path $missingPreviewManifestRoot -Force | Out-Null
  $missingPreviewManifestFixture = New-PublicationArtifactZip -RootPath $missingPreviewManifestRoot -IncludePreviewManifest:$false
  $global:MockScenario = @{
    ArtifactName = 'comparevi-history-pr-diagnostics-publish-4481'
    ZipPath = $missingPreviewManifestFixture.ZipPath
    PullRequestDraft = $missingPreviewManifestFixture.Draft
    PullRequestLabels = $missingPreviewManifestFixture.Labels
  }

  $missingPreviewManifestFailed = $false
  try {
    & $scriptPath `
      -Repository 'LabVIEW-Community-CI-CD/labview-icon-editor-demo' `
      -WorkflowRunId '4481' `
      -ArtifactName 'comparevi-history-pr-diagnostics-publish-4481' `
      -CanaryPolicyPath $policyPath `
      -GitHubToken 'token' `
      -ResultsDir (Join-Path $missingPreviewManifestRoot 'results') | Out-Null
  } catch {
    $missingPreviewManifestFailed = $true
  }
  if (-not $missingPreviewManifestFailed) {
    throw 'Missing preview manifest should fail closed.'
  }
  $missingPreviewManifestReceipt = Get-Content -LiteralPath (Join-Path $missingPreviewManifestRoot 'results/agent-canary-evaluation.json') -Raw | ConvertFrom-Json -Depth 64
  if ($missingPreviewManifestReceipt.summary.reason -ne 'missing-preview-manifest') {
    throw 'Missing preview manifest reason mismatch.'
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
