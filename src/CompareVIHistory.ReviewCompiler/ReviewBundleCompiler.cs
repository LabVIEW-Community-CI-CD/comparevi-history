using System.Globalization;

namespace CompareVIHistory.ReviewCompiler;

internal static class ReviewBundleCompiler
{
    private static readonly IReadOnlyDictionary<string, int> ModeOrder = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase)
    {
        ["front-panel"] = 0,
        ["block-diagram"] = 1,
        ["attributes"] = 2
    };

    private static readonly IReadOnlyDictionary<string, int> SectionKindOrder = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase)
    {
        ["overview"] = 0,
        ["detail"] = 1
    };

    public static ReviewBundle Build(CompilerOptions options)
    {
        if (!File.Exists(options.TargetRunsManifestPath))
        {
            throw new InvalidOperationException($"Target-runs manifest not found: {options.TargetRunsManifestPath}");
        }

        if (!Directory.Exists(options.ResultsDir))
        {
            throw new InvalidOperationException($"Results directory not found: {options.ResultsDir}");
        }

        var targetRunsManifest = PathHelpers.ReadJsonFile<TargetRunsManifest>(options.TargetRunsManifestPath);
        if (!string.Equals(targetRunsManifest.Schema, "comparevi-history/pr-target-runs-manifest@v2", StringComparison.Ordinal))
        {
            throw new InvalidOperationException($"Unsupported target-runs manifest schema in '{options.TargetRunsManifestPath}': {targetRunsManifest.Schema}");
        }

        var basePath = Environment.CurrentDirectory;
        var allRawPreviewPairs = new List<RawPreviewPair>();
        var allChangeDetails = new List<ReviewChangeDetailsRecord>();
        var targetContexts = new List<TargetContext>();

        foreach (var target in targetRunsManifest.Targets ?? [])
        {
            var targetId = ReviewCompilerText.CleanString(target.TargetId) ?? string.Empty;
            var targetPath = ReviewCompilerText.CleanString(target.TargetPath) ?? string.Empty;
            var targetRepositoryRoot = ResolveTargetRepositoryRoot(target, basePath);
            var suiteManifestPath = PathHelpers.ResolveExistingFilePath(ReviewCompilerText.CleanString(target.ManifestPath), basePath);
            var targetRawPreviewPairs = new List<RawPreviewPair>();

            if (!string.IsNullOrWhiteSpace(suiteManifestPath))
            {
                var suiteManifest = PathHelpers.ReadJsonFile<HistorySuiteManifest>(suiteManifestPath!);
                foreach (var modeEntry in suiteManifest.Modes ?? [])
                {
                    var modeName = ReviewCompilerText.CleanString(modeEntry.Name);
                    if (string.IsNullOrWhiteSpace(modeName))
                    {
                        continue;
                    }

                    var modeManifestPath = PathHelpers.ResolveExistingFilePath(ReviewCompilerText.CleanString(modeEntry.ManifestPath), basePath);
                    if (string.IsNullOrWhiteSpace(modeManifestPath))
                    {
                        continue;
                    }

                    var modeManifest = PathHelpers.ReadJsonFile<HistoryModeManifest>(modeManifestPath!);
                    foreach (var comparison in modeManifest.Comparisons ?? [])
                    {
                        var reportHtmlPath = PathHelpers.ResolveExistingFilePath(ReviewCompilerText.CleanString(comparison.Result?.ReportHtml), basePath)
                            ?? PathHelpers.ResolveExistingFilePath(ReviewCompilerText.CleanString(comparison.Result?.ReportPath), basePath);
                        if (string.IsNullOrWhiteSpace(reportHtmlPath))
                        {
                            continue;
                        }

                        if (string.Equals(modeName, "attributes", StringComparison.OrdinalIgnoreCase))
                        {
                            var changeDetails = HtmlReviewParser.GetReviewerChangeDetailsFromReport(
                                reportHtmlPath!,
                                options.ResultsDir,
                                targetId,
                                targetPath,
                                comparison,
                                targetRepositoryRoot);
                            if (changeDetails is not null)
                            {
                                allChangeDetails.Add(changeDetails);
                            }
                        }

                        foreach (var rawPreviewPair in HtmlReviewParser.GetReportPreviewPairs(
                                     reportHtmlPath!,
                                     options.ResultsDir,
                                     targetId,
                                     targetPath,
                                     modeName!,
                                     comparison,
                                     targetRepositoryRoot,
                                     GetModeSortOrder(modeName),
                                     GetSectionKindSortOrder))
                        {
                            targetRawPreviewPairs.Add(rawPreviewPair);
                            allRawPreviewPairs.Add(rawPreviewPair);
                        }
                    }
                }
            }

            targetContexts.Add(new TargetContext(target, targetRawPreviewPairs));
        }

        var orderedRawPreviewPairs = allRawPreviewPairs.OrderBy(static pair => pair.SortKey, StringComparer.Ordinal).ToArray();
        var reviewPairs = BuildReviewPairs(orderedRawPreviewPairs, allChangeDetails);
        var reviewPairsByTargetId = reviewPairs
            .GroupBy(static pair => pair.TargetId, StringComparer.OrdinalIgnoreCase)
            .ToDictionary(static group => group.Key, static group => group.ToArray(), StringComparer.OrdinalIgnoreCase);

        var targets = targetContexts.Select(context =>
        {
            reviewPairsByTargetId.TryGetValue(ReviewCompilerText.CleanString(context.Target.TargetId) ?? string.Empty, out var targetReviewPairs);
            targetReviewPairs ??= [];
            return new ReviewBundleTarget
            {
                TargetId = ReviewCompilerText.CleanString(context.Target.TargetId) ?? string.Empty,
                TargetPath = ReviewCompilerText.CleanString(context.Target.TargetPath) ?? string.Empty,
                FinalStatus = ReviewCompilerText.CleanString(context.Target.FinalStatus),
                FinalReason = ReviewCompilerText.CleanString(context.Target.FinalReason),
                RawPreviewPairCount = context.RawPreviewPairs.Count,
                RawPreviewPairs = context.RawPreviewPairs.OrderBy(static pair => pair.SortKey, StringComparer.Ordinal).ToArray(),
                ReviewPairCount = targetReviewPairs.Length
            };
        }).ToArray();

        return new ReviewBundle
        {
            Schema = "comparevi-history/review-bundle@v1",
            GeneratedAtUtc = DateTime.UtcNow,
            TargetRunsManifestPath = options.TargetRunsManifestPath,
            ResultsDir = options.ResultsDir,
            Summary = new ReviewBundleSummary
            {
                TargetCount = targets.Length,
                RawPreviewPairCount = orderedRawPreviewPairs.Length,
                ReviewPairCount = reviewPairs.Length,
                PrimaryReviewerDestinationPolicy = "pair-level@v1"
            },
            Targets = targets,
            RawPreviewPairs = orderedRawPreviewPairs,
            ReviewPairs = reviewPairs
        };
    }

    private static ReviewPair[] BuildReviewPairs(IReadOnlyList<RawPreviewPair> orderedRawPreviewPairs, IReadOnlyList<ReviewChangeDetailsRecord> allChangeDetails)
    {
        var changeDetailsByCardKey = allChangeDetails.ToDictionary(
            static record => GetReviewPairKey(record.TargetId, record.Comparison.Index),
            static record => record.ChangeDetails,
            StringComparer.OrdinalIgnoreCase);

        var reviewPairs = new List<ReviewPair>();
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var selectedPreviewPair in orderedRawPreviewPairs)
        {
            var reviewPairKey = GetReviewPairKey(selectedPreviewPair.TargetId, selectedPreviewPair.Comparison.Index);
            if (!seen.Add(reviewPairKey))
            {
                continue;
            }

            var matchingPairs = orderedRawPreviewPairs
                .Where(pair => string.Equals(GetReviewPairKey(pair.TargetId, pair.Comparison.Index), reviewPairKey, StringComparison.OrdinalIgnoreCase))
                .ToArray();

            var surfaces = new List<ReviewSurface>();
            var seenSurfaceKinds = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (var matchingPair in matchingPairs)
            {
                var surfaceKind = matchingPair.Mode switch
                {
                    "front-panel" => "front-panel",
                    "block-diagram" => "block-diagram",
                    _ => string.Empty
                };
                if (string.IsNullOrWhiteSpace(surfaceKind) || !seenSurfaceKinds.Add(surfaceKind))
                {
                    continue;
                }

                surfaces.Add(new ReviewSurface
                {
                    SurfaceKind = surfaceKind,
                    SurfaceLabel = surfaceKind == "front-panel" ? "Front panel" : "Block diagram",
                    Mode = ReviewCompilerText.CleanString(matchingPair.Mode),
                    Label = matchingPair.Label,
                    PrimaryReviewerRelativePath = null,
                    DebugReportHtmlRelativePath = matchingPair.DebugReportHtmlRelativePath,
                    BaseImageRelativePath = matchingPair.BaseImageRelativePath,
                    HeadImageRelativePath = matchingPair.HeadImageRelativePath,
                    BaseByteLength = matchingPair.BaseByteLength,
                    HeadByteLength = matchingPair.HeadByteLength,
                    BaseImageSha256 = matchingPair.BaseImageSha256,
                    HeadImageSha256 = matchingPair.HeadImageSha256,
                    SortKey = matchingPair.SortKey
                });
            }

            changeDetailsByCardKey.TryGetValue(reviewPairKey, out var changeDetails);
            reviewPairs.Add(new ReviewPair
            {
                ReviewPairKey = reviewPairKey,
                TargetId = selectedPreviewPair.TargetId,
                TargetPath = selectedPreviewPair.TargetPath,
                Comparison = selectedPreviewPair.Comparison,
                SortKey = selectedPreviewPair.SortKey,
                PrimaryReviewerDestination = new ReviewerDestination
                {
                    Kind = "history-pair-review-page",
                    RelativePath = null
                },
                DebugDestinations = new DebugDestinations
                {
                    FrontPanelReportHtmlRelativePath = matchingPairs.FirstOrDefault(pair => string.Equals(pair.Mode, "front-panel", StringComparison.OrdinalIgnoreCase))?.DebugReportHtmlRelativePath,
                    BlockDiagramReportHtmlRelativePath = matchingPairs.FirstOrDefault(pair => string.Equals(pair.Mode, "block-diagram", StringComparison.OrdinalIgnoreCase))?.DebugReportHtmlRelativePath,
                    ChangeDetailsReportHtmlRelativePath = changeDetails?.DebugReportHtmlRelativePath
                },
                Surfaces = surfaces.ToArray(),
                ReviewerSummary = HtmlReviewParser.NewReviewerSummaryFromChangeDetails(changeDetails),
                ChangeDetails = changeDetails
            });
        }

        return reviewPairs.ToArray();
    }

    private static string GetReviewPairKey(string targetId, int comparisonIndex) => $"{targetId}|{comparisonIndex}";

    private static string? ResolveTargetRepositoryRoot(TargetRun target, string basePath)
    {
        var publicRunPath = PathHelpers.ResolveExistingFilePath(ReviewCompilerText.CleanString(target.PublicRunPath), basePath);
        if (string.IsNullOrWhiteSpace(publicRunPath))
        {
            return null;
        }

        PublicRunReceipt? publicRun;
        try
        {
            publicRun = PathHelpers.ReadJsonFile<PublicRunReceipt>(publicRunPath!);
        }
        catch
        {
            return null;
        }

        var repositoryRoot = ReviewCompilerText.CleanString(publicRun.Request?.Consumer?.RepositoryRoot);
        if (string.IsNullOrWhiteSpace(repositoryRoot))
        {
            return null;
        }

        var resolvedRepositoryRoot = PathHelpers.ResolveExistingDirectoryPath(repositoryRoot, basePath);
        if (string.IsNullOrWhiteSpace(resolvedRepositoryRoot))
        {
            return null;
        }

        var gitPath = Path.Combine(resolvedRepositoryRoot!, ".git");
        return File.Exists(gitPath) || Directory.Exists(gitPath) ? resolvedRepositoryRoot : null;
    }

    internal static ComparisonReceipt BuildComparisonReceipt(ComparisonManifest comparison, string? repositoryRoot)
    {
        var baseRef = ReviewCompilerText.CleanString(comparison.Base?.Ref);
        var headRef = ReviewCompilerText.CleanString(comparison.Head?.Ref);
        return new ComparisonReceipt
        {
            Index = comparison.Index,
            BaseRef = baseRef,
            HeadRef = headRef,
            BaseShortRef = ReviewCompilerText.CleanString(comparison.Base?.Short) ?? ReviewCompilerText.ConvertToShortRef(baseRef),
            HeadShortRef = ReviewCompilerText.CleanString(comparison.Head?.Short) ?? ReviewCompilerText.ConvertToShortRef(headRef),
            BaseSubject = PathHelpers.GetGitCommitSubject(repositoryRoot, baseRef),
            HeadSubject = PathHelpers.GetGitCommitSubject(repositoryRoot, headRef)
        };
    }

    private static int GetModeSortOrder(string? mode) => mode is not null && ModeOrder.TryGetValue(mode, out var order) ? order : 99;
    private static int GetSectionKindSortOrder(string? sectionKind) => sectionKind is not null && SectionKindOrder.TryGetValue(sectionKind, out var order) ? order : 99;

    private sealed class TargetContext(TargetRun target, List<RawPreviewPair> rawPreviewPairs)
    {
        public TargetRun Target { get; } = target;
        public List<RawPreviewPair> RawPreviewPairs { get; } = rawPreviewPairs;
    }
}
