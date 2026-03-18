using System.Text.Json.Serialization;

namespace CompareVIHistory.ReviewCompiler;

internal sealed class ReviewBundle
{
    [JsonPropertyName("schema")]
    public string Schema { get; set; } = string.Empty;

    [JsonPropertyName("generatedAtUtc")]
    public DateTime GeneratedAtUtc { get; set; }

    [JsonPropertyName("targetRunsManifestPath")]
    public string TargetRunsManifestPath { get; set; } = string.Empty;

    [JsonPropertyName("resultsDir")]
    public string ResultsDir { get; set; } = string.Empty;

    [JsonPropertyName("summary")]
    public ReviewBundleSummary Summary { get; set; } = new();

    [JsonPropertyName("targets")]
    public ReviewBundleTarget[] Targets { get; set; } = [];

    [JsonPropertyName("rawPreviewPairs")]
    public RawPreviewPair[] RawPreviewPairs { get; set; } = [];

    [JsonPropertyName("reviewPairs")]
    public ReviewPair[] ReviewPairs { get; set; } = [];
}

internal sealed class ReviewBundleSummary
{
    [JsonPropertyName("targetCount")]
    public int TargetCount { get; set; }

    [JsonPropertyName("rawPreviewPairCount")]
    public int RawPreviewPairCount { get; set; }

    [JsonPropertyName("reviewPairCount")]
    public int ReviewPairCount { get; set; }

    [JsonPropertyName("primaryReviewerDestinationPolicy")]
    public string PrimaryReviewerDestinationPolicy { get; set; } = string.Empty;
}

internal sealed class ReviewBundleTarget
{
    [JsonPropertyName("targetId")]
    public string TargetId { get; set; } = string.Empty;

    [JsonPropertyName("targetPath")]
    public string TargetPath { get; set; } = string.Empty;

    [JsonPropertyName("finalStatus")]
    public string? FinalStatus { get; set; }

    [JsonPropertyName("finalReason")]
    public string? FinalReason { get; set; }

    [JsonPropertyName("rawPreviewPairCount")]
    public int RawPreviewPairCount { get; set; }

    [JsonPropertyName("rawPreviewPairs")]
    public RawPreviewPair[] RawPreviewPairs { get; set; } = [];

    [JsonPropertyName("reviewPairCount")]
    public int ReviewPairCount { get; set; }
}

internal sealed class RawPreviewPair
{
    [JsonPropertyName("targetId")]
    public string TargetId { get; set; } = string.Empty;

    [JsonPropertyName("targetPath")]
    public string TargetPath { get; set; } = string.Empty;

    [JsonPropertyName("mode")]
    public string Mode { get; set; } = string.Empty;

    [JsonPropertyName("comparison")]
    public ComparisonReceipt Comparison { get; set; } = new();

    [JsonPropertyName("sectionKind")]
    public string SectionKind { get; set; } = string.Empty;

    [JsonPropertyName("sectionOrdinal")]
    public int SectionOrdinal { get; set; }

    [JsonPropertyName("label")]
    public string Label { get; set; } = string.Empty;

    [JsonPropertyName("debugReportHtmlRelativePath")]
    public string? DebugReportHtmlRelativePath { get; set; }

    [JsonPropertyName("baseImageRelativePath")]
    public string BaseImageRelativePath { get; set; } = string.Empty;

    [JsonPropertyName("headImageRelativePath")]
    public string HeadImageRelativePath { get; set; } = string.Empty;

    [JsonPropertyName("baseByteLength")]
    public long BaseByteLength { get; set; }

    [JsonPropertyName("headByteLength")]
    public long HeadByteLength { get; set; }

    [JsonPropertyName("baseImageSha256")]
    public string BaseImageSha256 { get; set; } = string.Empty;

    [JsonPropertyName("headImageSha256")]
    public string HeadImageSha256 { get; set; } = string.Empty;

    [JsonPropertyName("sortKey")]
    public string SortKey { get; set; } = string.Empty;
}

internal sealed class ComparisonReceipt
{
    [JsonPropertyName("index")]
    public int Index { get; set; }

    [JsonPropertyName("baseRef")]
    public string? BaseRef { get; set; }

    [JsonPropertyName("headRef")]
    public string? HeadRef { get; set; }

    [JsonPropertyName("baseShortRef")]
    public string? BaseShortRef { get; set; }

    [JsonPropertyName("headShortRef")]
    public string? HeadShortRef { get; set; }

    [JsonPropertyName("baseSubject")]
    public string? BaseSubject { get; set; }

    [JsonPropertyName("headSubject")]
    public string? HeadSubject { get; set; }
}

internal sealed class ReviewPair
{
    [JsonPropertyName("reviewPairKey")]
    public string ReviewPairKey { get; set; } = string.Empty;

    [JsonPropertyName("targetId")]
    public string TargetId { get; set; } = string.Empty;

    [JsonPropertyName("targetPath")]
    public string TargetPath { get; set; } = string.Empty;

    [JsonPropertyName("comparison")]
    public ComparisonReceipt Comparison { get; set; } = new();

    [JsonPropertyName("sortKey")]
    public string SortKey { get; set; } = string.Empty;

    [JsonPropertyName("primaryReviewerDestination")]
    public ReviewerDestination PrimaryReviewerDestination { get; set; } = new();

    [JsonPropertyName("debugDestinations")]
    public DebugDestinations DebugDestinations { get; set; } = new();

    [JsonPropertyName("surfaces")]
    public ReviewSurface[] Surfaces { get; set; } = [];

    [JsonPropertyName("reviewerSummary")]
    public ReviewerSummary? ReviewerSummary { get; set; }

    [JsonPropertyName("changeDetails")]
    public ReviewChangeDetails? ChangeDetails { get; set; }
}

internal sealed class ReviewerDestination
{
    [JsonPropertyName("kind")]
    public string Kind { get; set; } = string.Empty;

    [JsonPropertyName("relativePath")]
    public string? RelativePath { get; set; }
}

internal sealed class DebugDestinations
{
    [JsonPropertyName("frontPanelReportHtmlRelativePath")]
    public string? FrontPanelReportHtmlRelativePath { get; set; }

    [JsonPropertyName("blockDiagramReportHtmlRelativePath")]
    public string? BlockDiagramReportHtmlRelativePath { get; set; }

    [JsonPropertyName("changeDetailsReportHtmlRelativePath")]
    public string? ChangeDetailsReportHtmlRelativePath { get; set; }
}
