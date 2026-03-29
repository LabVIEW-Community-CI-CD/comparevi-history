Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptPath = Join-Path $PSScriptRoot 'Write-CompareVIHistorySharedEvidence.ps1'
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("comparevi-history-shared-evidence-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

try {
  $resultsRoot = Join-Path $tempRoot 'results'
  $publicRoot = Join-Path $resultsRoot 'public'
  $previewDir = Join-Path $resultsRoot 'preview-images'
  New-Item -ItemType Directory -Path $publicRoot -Force | Out-Null
  New-Item -ItemType Directory -Path $previewDir -Force | Out-Null

  $manifestPath = Join-Path $resultsRoot 'manifest.json'
  $historySummaryPath = Join-Path $resultsRoot 'history-summary.json'
  $historyReportMd = Join-Path $resultsRoot 'history-report.md'
  $historyReportHtml = Join-Path $resultsRoot 'history-report.html'
  $requestPath = Join-Path $publicRoot 'request.json'
  $publicRunPath = Join-Path $publicRoot 'public-run.json'
  $publicCommentPath = Join-Path $publicRoot 'comment.md'
  $publicStepSummaryPath = Join-Path $publicRoot 'step-summary.md'
  $modeSummaryPath = Join-Path $publicRoot 'mode-summary.md'
  $modeSummaryJsonPath = Join-Path $publicRoot 'mode-summary.json'
  $sharedEvidencePath = Join-Path $publicRoot 'shared-evidence.json'
  $previewPath = Join-Path $previewDir 'cli-image-00.png'

  '{}' | Set-Content -LiteralPath $manifestPath -Encoding utf8
  '{}' | Set-Content -LiteralPath $historySummaryPath -Encoding utf8
  '# report' | Set-Content -LiteralPath $historyReportMd -Encoding utf8
  '<html></html>' | Set-Content -LiteralPath $historyReportHtml -Encoding utf8
  'comment' | Set-Content -LiteralPath $publicCommentPath -Encoding utf8
  'summary' | Set-Content -LiteralPath $publicStepSummaryPath -Encoding utf8
  'mode summary' | Set-Content -LiteralPath $modeSummaryPath -Encoding utf8
  [System.IO.File]::WriteAllBytes($previewPath, @(0x50, 0x4B, 0x03, 0x04))

  @'
{
  "schema": "comparevi-history/public-run@v1",
  "requestPath": "__REQUEST_PATH__",
  "request": {
    "consumer": {
      "repository": "LabVIEW-Community-CI-CD/labview-icon-editor-demo",
      "ref": "develop"
    },
    "target": {
      "id": "vip-post-install-custom-action",
      "path": "Tooling/deployment/VIP_Post-Install Custom Action.vi"
    },
    "history": {
      "startRef": "HEAD",
      "noisePolicy": "collapse",
      "includeMergeParents": false
    }
  },
  "outputs": {
    "resultsDir": "__RESULTS_ROOT__",
    "manifestPath": "__MANIFEST_PATH__",
    "historySummaryJson": "__HISTORY_SUMMARY_PATH__",
    "historyReportMd": "__HISTORY_REPORT_MD__",
    "historyReportHtml": "__HISTORY_REPORT_HTML__",
    "publicCommentPath": "__PUBLIC_COMMENT_PATH__",
    "publicStepSummaryPath": "__PUBLIC_STEP_SUMMARY_PATH__"
  },
  "summary": {
    "modeCount": 3,
    "requestedModes": ["attributes", "front-panel", "block-diagram"],
    "executedModes": ["attributes", "front-panel", "block-diagram"],
    "totalProcessed": 5,
    "totalDiffs": 2,
    "stopReason": "completed",
    "finalStatus": "succeeded",
    "finalReason": "completed"
  },
  "replay": {
    "status": "ready",
    "reason": "history-summary-present"
  }
}
'@.Replace('__REQUEST_PATH__', ($requestPath -replace '\\', '/')).
    Replace('__RESULTS_ROOT__', ($resultsRoot -replace '\\', '/')).
    Replace('__MANIFEST_PATH__', ($manifestPath -replace '\\', '/')).
    Replace('__HISTORY_SUMMARY_PATH__', ($historySummaryPath -replace '\\', '/')).
    Replace('__HISTORY_REPORT_MD__', ($historyReportMd -replace '\\', '/')).
    Replace('__HISTORY_REPORT_HTML__', ($historyReportHtml -replace '\\', '/')).
    Replace('__PUBLIC_COMMENT_PATH__', ($publicCommentPath -replace '\\', '/')).
    Replace('__PUBLIC_STEP_SUMMARY_PATH__', ($publicStepSummaryPath -replace '\\', '/')) |
    Set-Content -LiteralPath $publicRunPath -Encoding utf8

  @'
{
  "schema": "comparevi-history/mode-summary@v1",
  "requestedModes": ["attributes", "front-panel", "block-diagram"],
  "executedModes": ["attributes", "front-panel", "block-diagram"],
  "totalProcessed": 5,
  "totalDiffs": 2,
  "stopReason": "completed",
  "suppressionProfile": "unsuppressed",
  "categoryCounts": {
    "Block Diagram objects": 1
  },
  "comparisonPairs": [
    {
      "firstPath": "/compare/base.vi",
      "secondPath": "/compare/head.vi",
      "count": 2
    }
  ],
  "bucketCounts": {
    "metadata-rich": 1
  },
  "previewImages": [
    {
      "mode": "attributes",
      "category": "Block Diagram objects",
      "comparisonPair": {
        "firstPath": "/compare/base.vi",
        "secondPath": "/compare/head.vi"
      },
      "mimeType": "image/png",
      "byteLength": 4,
      "savedPath": "__PREVIEW_PATH__",
      "artifactRelativePath": "preview-images/cli-image-00.png",
      "sortKey": "attributes|block-diagram|preview-images/cli-image-00.png"
    }
  ],
  "metadata": {
    "comparisonArtifactCount": 1,
    "captureCount": 1,
    "imageArtifactCount": 1,
    "imageMimeTypes": ["image/png"]
  }
}
'@.Replace('__PREVIEW_PATH__', ($previewPath -replace '\\', '/')) |
    Set-Content -LiteralPath $modeSummaryJsonPath -Encoding utf8

  $publicOutputPath = Join-Path $tempRoot 'public-output.txt'
  $publicRunJson = & $scriptPath `
    -PublicRunPath $publicRunPath `
    -ModeSummaryJsonPath $modeSummaryJsonPath `
    -ModeSummaryPath $modeSummaryPath `
    -OutputPath $sharedEvidencePath `
    -GitHubOutputPath $publicOutputPath

  $publicSharedEvidence = $publicRunJson | ConvertFrom-Json -Depth 64
  if ($publicSharedEvidence.schema -ne 'comparevi-history/shared-evidence@v1') {
    throw 'Shared evidence public-run schema mismatch.'
  }
  if ($publicSharedEvidence.source.schema -ne 'comparevi-history/public-run@v1') {
    throw 'Shared evidence public-run source schema mismatch.'
  }
  if ($publicSharedEvidence.surfaces.previewImages.Count -ne 1) {
    throw 'Shared evidence public-run preview image count mismatch.'
  }
  if ($publicSharedEvidence.surfaces.previewImages[0].scope -ne 'run' -or $null -ne $publicSharedEvidence.surfaces.previewImages[0].chunkId) {
    throw 'Shared evidence public-run preview image normalization mismatch.'
  }
  if ($publicSharedEvidence.surfaces.renderSurfaces.Count -lt 4 -or $publicSharedEvidence.surfaces.artifactSurfaces.Count -lt 5) {
    throw 'Shared evidence public-run surface references are incomplete.'
  }
  if (($publicSharedEvidence.surfaces.artifactSurfaces | Where-Object { $_.kind -eq 'shared-evidence-json' }).Count -ne 1) {
    throw 'Shared evidence public-run must reference shared-evidence.json.'
  }
  if ((Get-Content -LiteralPath $publicOutputPath -Raw) -notmatch 'shared-evidence-path=') {
    throw 'Shared evidence writer did not emit shared-evidence-path for public-run mode.'
  }

  $graphPath = Join-Path $resultsRoot 'evidence-graph.json'
  @'
{
  "schema": "comparevi-history/evidence-graph@v1",
  "generatedAtUtc": "2026-03-17T00:00:00Z",
  "consumer": {
    "repository": "LabVIEW-Community-CI-CD/labview-icon-editor-demo",
    "ref": "develop"
  },
  "target": {
    "path": "Tooling/deployment/VIP_Post-Install Custom Action.vi",
    "selectedRef": "HEAD",
    "extension": ".vi"
  },
  "configuration": {
    "requestedModes": ["attributes", "front-panel", "block-diagram"],
    "noisePolicy": "include",
    "includeMergeParents": false
  },
  "discovery": {
    "revisionCatalogPath": "__REVISION_CATALOG__",
    "revisionCount": 4,
    "historyMode": "selected-ref-lineage",
    "followRenames": true,
    "catalogComplete": true,
    "catalogCompletenessReason": "complete"
  },
  "continuity": {
    "status": "continuous",
    "breakCount": 0,
    "segmentCount": 1,
    "segments": [],
    "breaks": []
  },
  "execution": {
    "chunkPlanPath": "__CHUNK_PLAN__",
    "chunkReceiptsRoot": "__CHUNK_ROOT__",
    "chunkPairLimit": 2,
    "pairCount": 2,
    "chunkCount": 1,
    "plannedChunkCount": 1,
    "completedChunkCount": 1,
    "failedChunkCount": 0,
    "skippedChunkCount": 0,
    "status": "complete",
    "reason": "all-chunks-succeeded",
    "chunks": [
      {
        "chunkId": "chunk-001",
        "chunkOrdinal": 1,
        "segmentOrdinal": 1,
        "status": "succeeded",
        "pairCount": 2,
        "pairOrdinalStart": 1,
        "pairOrdinalEnd": 2,
        "revisionOrdinalStart": 1,
        "revisionOrdinalEnd": 3,
        "execution": {
          "startRef": "HEAD~1",
          "endRef": "HEAD",
          "maxPairs": 2,
          "toolingSource": "bundle",
          "compareviRepository": "LabVIEW-Community-CI-CD/compare-vi-cli-action",
          "compareviRef": "v0.6.6",
          "invokeScriptPath": null
        },
        "outputs": {
          "chunkRoot": "__CHUNK_ROOT__",
          "receiptPath": "__CHUNK_ROOT__/receipt.json",
          "manifestPath": "__CHUNK_ROOT__/manifest.json",
          "runOutputPath": "__CHUNK_ROOT__/run-output.txt",
          "historyResultsDir": "__RESULTS_ROOT__",
          "historyManifestPath": "__MANIFEST_PATH__",
          "historySummaryJson": "__HISTORY_SUMMARY_PATH__",
          "historyReportMd": "__HISTORY_REPORT_MD__",
          "historyReportHtml": "__HISTORY_REPORT_HTML__",
          "modeSummaryPath": "__MODE_SUMMARY_PATH__",
          "modeSummaryJsonPath": "__MODE_SUMMARY_JSON_PATH__"
        },
        "summary": {
          "requestedModes": ["attributes", "front-panel", "block-diagram"],
          "executedModes": ["attributes", "front-panel", "block-diagram"],
          "modeCount": 3,
          "totalProcessed": 5,
          "totalDiffs": 2,
          "stopReason": "completed",
          "finalStatus": "succeeded",
          "finalReason": "completed"
        },
        "surfaces": {
          "suppressionProfile": "unsuppressed",
          "comparisonArtifactCount": 1,
          "captureCount": 1,
          "imageArtifactCount": 1,
          "imageMimeTypes": ["image/png"],
          "categoryCounts": {
            "Block Diagram objects": 1
          },
          "comparisonPairs": [
            {
              "firstPath": "/compare/base.vi",
              "secondPath": "/compare/head.vi",
              "count": 2
            }
          ],
          "bucketCounts": {
            "metadata-rich": 1
          },
          "previewImages": [
            {
              "chunkId": "chunk-001",
              "mode": "attributes",
              "category": "Block Diagram objects",
              "comparisonPair": {
                "firstPath": "/compare/base.vi",
                "secondPath": "/compare/head.vi"
              },
              "mimeType": "image/png",
              "byteLength": 4,
              "relativePath": "preview-images/cli-image-00.png",
              "sortKey": "attributes|block-diagram|preview-images/cli-image-00.png"
            }
          ]
        },
        "failure": null,
        "replay": {
          "status": "ready",
          "reason": "history-summary-present"
        }
      }
    ]
  },
  "surfaces": {
    "suppressionProfile": "unsuppressed",
    "comparisonArtifactCount": 1,
    "captureCount": 1,
    "imageArtifactCount": 1,
    "imageMimeTypes": ["image/png"],
    "chunkCountWithMetadata": 1,
    "categoryCounts": {
      "Block Diagram objects": 1
    },
    "comparisonPairs": [
      {
        "firstPath": "/compare/base.vi",
        "secondPath": "/compare/head.vi",
        "count": 2
      }
    ],
    "bucketCounts": {
      "metadata-rich": 1
    },
    "previewImages": [
      {
        "chunkId": "chunk-001",
        "mode": "attributes",
        "category": "Block Diagram objects",
        "comparisonPair": {
          "firstPath": "/compare/base.vi",
          "secondPath": "/compare/head.vi"
        },
        "mimeType": "image/png",
        "byteLength": 4,
        "relativePath": "preview-images/cli-image-00.png",
        "sortKey": "attributes|block-diagram|preview-images/cli-image-00.png"
      }
    ],
    "renderSurfaces": [
      {
        "scope": "run",
        "kind": "index-html",
        "chunkId": null,
        "relativePath": "index.html",
        "pathType": "file",
        "contentType": "text/html"
      }
    ],
    "artifactSurfaces": [
      {
        "scope": "run",
        "kind": "evidence-graph-json",
        "chunkId": null,
        "relativePath": "evidence-graph.json",
        "pathType": "file",
        "contentType": "application/json"
      }
    ]
  },
  "completeness": {
    "catalogComplete": true,
    "catalogCompletenessReason": "complete",
    "finalStatus": "succeeded",
    "finalReason": "all-chunks-succeeded",
    "replayStatus": "ready",
    "replayReason": "all-chunks-executed",
    "bundleStatus": "not-required",
    "bundleReason": "bundle-not-requested",
    "previewImageCount": 1,
    "previewGalleryCap": 12,
    "previewGalleryCount": 1,
    "previewGalleryOmittedCount": 0,
    "stepSummaryPreviewCap": 2,
    "stepSummaryPreviewCount": 1,
    "stepSummaryPreviewOmittedCount": 0,
    "stepSummaryPreviewByteBudget": 196608
  }
}
'@.Replace('__REVISION_CATALOG__', ((Join-Path $resultsRoot 'revision-catalog.json') -replace '\\', '/')).
    Replace('__CHUNK_PLAN__', ((Join-Path $resultsRoot 'chunk-plan.json') -replace '\\', '/')).
    Replace('__CHUNK_ROOT__', ((Join-Path $resultsRoot 'chunk-receipts/chunk-001') -replace '\\', '/')).
    Replace('__RESULTS_ROOT__', ($resultsRoot -replace '\\', '/')).
    Replace('__MANIFEST_PATH__', ($manifestPath -replace '\\', '/')).
    Replace('__HISTORY_SUMMARY_PATH__', ($historySummaryPath -replace '\\', '/')).
    Replace('__HISTORY_REPORT_MD__', ($historyReportMd -replace '\\', '/')).
    Replace('__HISTORY_REPORT_HTML__', ($historyReportHtml -replace '\\', '/')).
    Replace('__MODE_SUMMARY_PATH__', ($modeSummaryPath -replace '\\', '/')).
    Replace('__MODE_SUMMARY_JSON_PATH__', ($modeSummaryJsonPath -replace '\\', '/')) |
    Set-Content -LiteralPath $graphPath -Encoding utf8

  $graphOutputPath = Join-Path $tempRoot 'graph-output.txt'
  $graphSharedEvidencePath = Join-Path $resultsRoot 'shared-evidence-from-graph.json'
  $graphJson = & $scriptPath `
    -EvidenceGraphPath $graphPath `
    -OutputPath $graphSharedEvidencePath `
    -GitHubOutputPath $graphOutputPath

  $graphSharedEvidence = $graphJson | ConvertFrom-Json -Depth 64
  if ($graphSharedEvidence.source.schema -ne 'comparevi-history/evidence-graph@v1') {
    throw 'Shared evidence graph source schema mismatch.'
  }
  if ($graphSharedEvidence.surfaces.previewImages.Count -ne 1 -or $graphSharedEvidence.surfaces.previewImages[0].scope -ne 'chunk') {
    throw 'Shared evidence graph preview image normalization mismatch.'
  }
  if ($graphSharedEvidence.summary.totalProcessed -ne 5 -or $graphSharedEvidence.summary.totalDiffs -ne 2) {
    throw 'Shared evidence graph summary aggregation mismatch.'
  }
  if ((Get-Content -LiteralPath $graphOutputPath -Raw) -notmatch 'shared-evidence-path=') {
    throw 'Shared evidence writer did not emit shared-evidence-path for graph mode.'
  }
} finally {
  Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
