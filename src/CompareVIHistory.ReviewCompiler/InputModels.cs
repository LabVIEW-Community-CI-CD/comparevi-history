using System.Text.Json.Serialization;

namespace CompareVIHistory.ReviewCompiler;

internal sealed class TargetRunsManifest
{
    [JsonPropertyName("schema")]
    public string? Schema { get; set; }

    [JsonPropertyName("targets")]
    public TargetRun[]? Targets { get; set; }
}

internal sealed class TargetRun
{
    [JsonPropertyName("targetId")]
    public string? TargetId { get; set; }

    [JsonPropertyName("targetPath")]
    public string? TargetPath { get; set; }

    [JsonPropertyName("finalStatus")]
    public string? FinalStatus { get; set; }

    [JsonPropertyName("finalReason")]
    public string? FinalReason { get; set; }

    [JsonPropertyName("manifestPath")]
    public string? ManifestPath { get; set; }

    [JsonPropertyName("publicRunPath")]
    public string? PublicRunPath { get; set; }
}

internal sealed class HistorySuiteManifest
{
    [JsonPropertyName("modes")]
    public HistoryModeEntry[]? Modes { get; set; }
}

internal sealed class HistoryModeEntry
{
    [JsonPropertyName("name")]
    public string? Name { get; set; }

    [JsonPropertyName("manifestPath")]
    public string? ManifestPath { get; set; }
}

internal sealed class HistoryModeManifest
{
    [JsonPropertyName("comparisons")]
    public ComparisonManifest[]? Comparisons { get; set; }
}

internal sealed class ComparisonManifest
{
    [JsonPropertyName("index")]
    public int Index { get; set; }

    [JsonPropertyName("base")]
    public ComparisonRef? Base { get; set; }

    [JsonPropertyName("head")]
    public ComparisonRef? Head { get; set; }

    [JsonPropertyName("result")]
    public ComparisonResult? Result { get; set; }
}

internal sealed class ComparisonRef
{
    [JsonPropertyName("ref")]
    public string? Ref { get; set; }

    [JsonPropertyName("short")]
    public string? Short { get; set; }
}

internal sealed class ComparisonResult
{
    [JsonPropertyName("reportHtml")]
    public string? ReportHtml { get; set; }

    [JsonPropertyName("reportPath")]
    public string? ReportPath { get; set; }
}

internal sealed class PublicRunReceipt
{
    [JsonPropertyName("request")]
    public PublicRunRequest? Request { get; set; }
}

internal sealed class PublicRunRequest
{
    [JsonPropertyName("consumer")]
    public PublicRunConsumer? Consumer { get; set; }
}

internal sealed class PublicRunConsumer
{
    [JsonPropertyName("repositoryRoot")]
    public string? RepositoryRoot { get; set; }
}
