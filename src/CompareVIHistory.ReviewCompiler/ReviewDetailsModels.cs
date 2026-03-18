using System.Text.Json.Serialization;

namespace CompareVIHistory.ReviewCompiler;

internal sealed class ReviewSurface
{
    [JsonPropertyName("surfaceKind")]
    public string SurfaceKind { get; set; } = string.Empty;

    [JsonPropertyName("surfaceLabel")]
    public string SurfaceLabel { get; set; } = string.Empty;

    [JsonPropertyName("mode")]
    public string? Mode { get; set; }

    [JsonPropertyName("label")]
    public string? Label { get; set; }

    [JsonPropertyName("primaryReviewerRelativePath")]
    public string? PrimaryReviewerRelativePath { get; set; }

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
    public string? BaseImageSha256 { get; set; }

    [JsonPropertyName("headImageSha256")]
    public string? HeadImageSha256 { get; set; }

    [JsonPropertyName("sortKey")]
    public string? SortKey { get; set; }
}

internal sealed class ReviewChangeDetailsRecord
{
    [JsonPropertyName("targetId")]
    public string TargetId { get; set; } = string.Empty;

    [JsonPropertyName("targetPath")]
    public string TargetPath { get; set; } = string.Empty;

    [JsonPropertyName("comparison")]
    public ComparisonReceipt Comparison { get; set; } = new();

    [JsonPropertyName("sortKey")]
    public string SortKey { get; set; } = string.Empty;

    [JsonPropertyName("changeDetails")]
    public ReviewChangeDetails ChangeDetails { get; set; } = new();
}

internal sealed class ReviewChangeDetails
{
    [JsonPropertyName("label")]
    public string Label { get; set; } = string.Empty;

    [JsonPropertyName("sourceMode")]
    public string SourceMode { get; set; } = string.Empty;

    [JsonPropertyName("primaryReviewerRelativePath")]
    public string? PrimaryReviewerRelativePath { get; set; }

    [JsonPropertyName("debugReportHtmlRelativePath")]
    public string? DebugReportHtmlRelativePath { get; set; }

    [JsonPropertyName("includedCategories")]
    public string[] IncludedCategories { get; set; } = [];

    [JsonPropertyName("groupCount")]
    public int GroupCount { get; set; }

    [JsonPropertyName("omittedGroupCount")]
    public int OmittedGroupCount { get; set; }

    [JsonPropertyName("sectionCount")]
    public int SectionCount { get; set; }

    [JsonPropertyName("detailCount")]
    public int DetailCount { get; set; }

    [JsonPropertyName("groups")]
    public ReviewChangeDetailGroup[] Groups { get; set; } = [];
}

internal sealed class ReviewChangeDetailGroup
{
    [JsonPropertyName("heading")]
    public string Heading { get; set; } = string.Empty;

    [JsonPropertyName("sectionCount")]
    public int SectionCount { get; set; }

    [JsonPropertyName("detailCount")]
    public int DetailCount { get; set; }

    [JsonPropertyName("sampleDetails")]
    public string[] SampleDetails { get; set; } = [];

    [JsonPropertyName("omittedDetailCount")]
    public int OmittedDetailCount { get; set; }

    [JsonPropertyName("primaryReviewerRelativePath")]
    public string? PrimaryReviewerRelativePath { get; set; }

    [JsonPropertyName("primaryDebugReportHtmlRelativePath")]
    public string? PrimaryDebugReportHtmlRelativePath { get; set; }

    [JsonPropertyName("sectionLinks")]
    public DebugChangeDetailSectionLink[] SectionLinks { get; set; } = [];
}

internal sealed class DebugChangeDetailSectionLink
{
    [JsonPropertyName("sectionOrdinal")]
    public int SectionOrdinal { get; set; }

    [JsonPropertyName("label")]
    public string Label { get; set; } = string.Empty;

    [JsonPropertyName("reviewerRelativePath")]
    public string? ReviewerRelativePath { get; set; }

    [JsonPropertyName("debugReportHtmlRelativePath")]
    public string? DebugReportHtmlRelativePath { get; set; }
}

internal sealed class ReviewerSummary
{
    [JsonPropertyName("label")]
    public string Label { get; set; } = string.Empty;

    [JsonPropertyName("overallSeverity")]
    public string OverallSeverity { get; set; } = string.Empty;

    [JsonPropertyName("headline")]
    public string Headline { get; set; } = string.Empty;

    [JsonPropertyName("signalCount")]
    public int SignalCount { get; set; }

    [JsonPropertyName("omittedSignalCount")]
    public int OmittedSignalCount { get; set; }

    [JsonPropertyName("signals")]
    public ReviewerSignal[] Signals { get; set; } = [];
}

internal sealed class ReviewerSignal
{
    [JsonPropertyName("signalKey")]
    public string SignalKey { get; set; } = string.Empty;

    [JsonPropertyName("label")]
    public string Label { get; set; } = string.Empty;

    [JsonPropertyName("severity")]
    public string Severity { get; set; } = string.Empty;

    [JsonPropertyName("detailCount")]
    public int DetailCount { get; set; }

    [JsonPropertyName("sectionCount")]
    public int SectionCount { get; set; }

    [JsonPropertyName("summary")]
    public string Summary { get; set; } = string.Empty;

    [JsonPropertyName("primaryReviewerRelativePath")]
    public string? PrimaryReviewerRelativePath { get; set; }

    [JsonPropertyName("primaryDebugReportHtmlRelativePath")]
    public string? PrimaryDebugReportHtmlRelativePath { get; set; }

    [JsonPropertyName("sectionLinks")]
    public DebugChangeDetailSectionLink[] SectionLinks { get; set; } = [];
}
