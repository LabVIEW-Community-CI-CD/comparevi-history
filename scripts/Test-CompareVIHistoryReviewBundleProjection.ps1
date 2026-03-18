$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'CompareVIHistoryReviewBundleProjection.psm1') -Force

$reviewBundle = [ordered]@{
  schema = 'comparevi-history/review-bundle@v1'
  reviewPairs = @(
    [ordered]@{
      targetId = 'target-a'
      targetPath = 'Tooling/demo/A.vi'
      comparison = [ordered]@{
        index = 1
        baseRef = 'base-1'
        headRef = 'head-1'
      }
      sortKey = 'Tooling/demo/A.vi|0001'
      surfaces = @(
        [ordered]@{
          surfaceKind = 'front-panel'
          surfaceLabel = 'Front panel'
          primaryReviewerRelativePath = 'history-pairs/001/index.html#front-panel'
          debugReportHtmlRelativePath = 'targets/a/front-panel.html'
          baseImageRelativePath = 'targets/a/fp-base.png'
          headImageRelativePath = 'targets/a/fp-head.png'
          baseByteLength = 4
          headByteLength = 4
          baseImageSha256 = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
          headImageSha256 = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
          sortKey = 'a|front-panel'
        }
      )
      reviewerSummary = [ordered]@{
        label = 'Reviewer summary'
        overallSeverity = 'medium'
        headline = 'Bundle headline 1'
        signalCount = 1
        omittedSignalCount = 0
        signals = @(
          [ordered]@{
            signalKey = 'signal-1'
            label = 'Signal 1'
            severity = 'medium'
            detailCount = 1
            sectionCount = 1
            summary = 'Signal 1 summary'
            primaryReviewerRelativePath = 'history-pairs/001/index.html#signal-1'
            primaryDebugReportHtmlRelativePath = 'targets/a/debug-signal-1.html'
            sectionLinks = @()
          }
        )
      }
      changeDetails = [ordered]@{
        label = 'Change details'
        sourceMode = 'attributes'
        primaryReviewerRelativePath = 'history-pairs/001/index.html#change-details'
        debugReportHtmlRelativePath = 'targets/a/change-details.html'
        includedCategories = @('VI Attribute')
        groupCount = 1
        omittedGroupCount = 0
        sectionCount = 1
        detailCount = 1
        groups = @()
      }
    },
    [ordered]@{
      targetId = 'target-a'
      targetPath = 'Tooling/demo/A.vi'
      comparison = [ordered]@{
        index = 2
        baseRef = 'base-2'
        headRef = 'head-2'
      }
      sortKey = 'Tooling/demo/A.vi|0002'
      surfaces = @(
        [ordered]@{
          surfaceKind = 'front-panel'
          surfaceLabel = 'Front panel'
          primaryReviewerRelativePath = 'history-pairs/002/index.html#front-panel'
          debugReportHtmlRelativePath = 'targets/a/front-panel-2.html'
          baseImageRelativePath = 'targets/a/fp2-base.png'
          headImageRelativePath = 'targets/a/fp2-head.png'
          baseByteLength = 4
          headByteLength = 4
          baseImageSha256 = 'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc'
          headImageSha256 = 'dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd'
          sortKey = 'b|front-panel'
        }
      )
      reviewerSummary = [ordered]@{
        label = 'Reviewer summary'
        overallSeverity = 'low'
        headline = 'Bundle headline 2'
        signalCount = 1
        omittedSignalCount = 0
        signals = @()
      }
      changeDetails = $null
    }
  )
}

$allCards = @(Get-CompareVIHistoryReviewBundleCards -ReviewBundle $reviewBundle)
if ($allCards.Count -ne 2 -or
  [string]$allCards[0].reviewerSummary.headline -ne 'Bundle headline 1' -or
  [string]$allCards[1].reviewerSummary.headline -ne 'Bundle headline 2') {
  throw 'Expected review-bundle projection to return ordered review cards from the compiled bundle.'
}

$selectedPairs = @(
  [ordered]@{
    targetId = 'target-a'
    comparison = [ordered]@{
      index = 2
    }
  }
)
$selectedCards = @(Get-CompareVIHistoryReviewBundleCards -ReviewBundle $reviewBundle -SelectedPreviewPairs $selectedPairs -UseSelectedPreviewPairs)
if ($selectedCards.Count -ne 1 -or
  [int]$selectedCards[0].comparison.index -ne 2 -or
  [string]$selectedCards[0].surfaces[0].reportHtmlRelativePath -ne 'history-pairs/002/index.html#front-panel') {
  throw 'Expected selection-driven projection to resolve review cards from review-bundle identities.'
}

$missingThrew = $false
try {
  [void](Get-CompareVIHistoryReviewBundleCards -ReviewBundle $reviewBundle -SelectedPreviewPairs @(
        [ordered]@{
          targetId = 'missing-target'
          comparison = [ordered]@{ index = 9 }
        }
      ) -UseSelectedPreviewPairs)
} catch {
  if ([string]$_.Exception.Message -match 'missing review pairs') {
    $missingThrew = $true
  } else {
    throw
  }
}

if (-not $missingThrew) {
  throw 'Expected missing selected review pairs to fail closed.'
}
