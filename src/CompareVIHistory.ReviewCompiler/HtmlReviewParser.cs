using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;

namespace CompareVIHistory.ReviewCompiler;

internal static class HtmlReviewParser
{
    private const int ReviewerChangeDetailGroupCap = 3;
    private const int ReviewerChangeDetailSampleCap = 3;
    private const int ReviewerSummarySignalCap = 3;

    public static ReviewChangeDetailsRecord? GetReviewerChangeDetailsFromReport(
        string reportHtmlPath,
        string resultsRoot,
        string targetId,
        string targetPath,
        ComparisonManifest comparison,
        string? repositoryRoot)
    {
        if (!File.Exists(reportHtmlPath))
        {
            return null;
        }

        var sectionReceipt = GetReviewerChangeDetailSectionsFromReport(reportHtmlPath, resultsRoot);
        if (string.IsNullOrWhiteSpace(sectionReceipt.ReportHtml))
        {
            return null;
        }

        var effectiveDebugReportHtmlRelativePath = ReviewCompilerText.CleanString(sectionReceipt.DebugReportHtmlRelativePath)
            ?? PathHelpers.ResolveRelativePath(reportHtmlPath, resultsRoot);
        var includedCategories = GetReportIncludedCategories(sectionReceipt.ReportHtml);
        var groupMap = new Dictionary<string, MutableChangeDetailGroup>(StringComparer.OrdinalIgnoreCase);
        var groupOrder = new List<string>();

        foreach (var section in sectionReceipt.Sections)
        {
            var sectionLinkRecord = new DebugChangeDetailSectionLink
            {
                SectionOrdinal = section.Ordinal,
                Label = $"section {section.Ordinal}",
                ReviewerRelativePath = null,
                DebugReportHtmlRelativePath = section.DebugReportHtmlRelativePath
            };
            var sectionGroupKeys = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (var detailLine in section.DetailLines)
            {
                var semanticHeading = GetReviewerSemanticHeadingFromSection(section.Heading, detailLine);
                if (!groupMap.TryGetValue(semanticHeading, out var groupRecord))
                {
                    groupRecord = new MutableChangeDetailGroup { Heading = semanticHeading };
                    groupMap[semanticHeading] = groupRecord;
                    groupOrder.Add(semanticHeading);
                }

                if (sectionGroupKeys.Add(semanticHeading))
                {
                    groupRecord.SectionCount += 1;
                    groupRecord.SectionLinks.Add(sectionLinkRecord);
                }

                groupRecord.DetailCount += 1;
                if (groupRecord.SampleDetails.Count < ReviewerChangeDetailSampleCap)
                {
                    groupRecord.SampleDetails.Add(detailLine);
                }
            }
        }

        if (groupOrder.Count == 0 && includedCategories.Count == 0)
        {
            return null;
        }

        var groupItems = new List<ReviewChangeDetailGroup>();
        var sectionCount = 0;
        var detailCount = 0;
        foreach (var heading in groupOrder.Take(ReviewerChangeDetailGroupCap))
        {
            var groupRecord = groupMap[heading];
            sectionCount += groupRecord.SectionCount;
            detailCount += groupRecord.DetailCount;
            groupItems.Add(new ReviewChangeDetailGroup
            {
                Heading = groupRecord.Heading,
                SectionCount = groupRecord.SectionCount,
                DetailCount = groupRecord.DetailCount,
                SampleDetails = groupRecord.SampleDetails.ToArray(),
                OmittedDetailCount = Math.Max(groupRecord.DetailCount - groupRecord.SampleDetails.Count, 0),
                PrimaryReviewerRelativePath = null,
                PrimaryDebugReportHtmlRelativePath = groupRecord.SectionLinks.FirstOrDefault()?.DebugReportHtmlRelativePath,
                SectionLinks = groupRecord.SectionLinks.ToArray()
            });
        }

        foreach (var heading in groupOrder.Skip(ReviewerChangeDetailGroupCap))
        {
            var groupRecord = groupMap[heading];
            sectionCount += groupRecord.SectionCount;
            detailCount += groupRecord.DetailCount;
        }

        var comparisonReceipt = ReviewBundleCompiler.BuildComparisonReceipt(comparison, repositoryRoot);
        return new ReviewChangeDetailsRecord
        {
            TargetId = targetId,
            TargetPath = targetPath,
            Comparison = comparisonReceipt,
            SortKey = $"{targetPath}|{comparisonReceipt.Index:D4}|change-details",
            ChangeDetails = new ReviewChangeDetails
            {
                Label = "Change details",
                SourceMode = "attributes",
                PrimaryReviewerRelativePath = null,
                DebugReportHtmlRelativePath = effectiveDebugReportHtmlRelativePath,
                IncludedCategories = includedCategories.ToArray(),
                GroupCount = groupOrder.Count,
                OmittedGroupCount = Math.Max(groupOrder.Count - groupItems.Count, 0),
                SectionCount = sectionCount,
                DetailCount = detailCount,
                Groups = groupItems.ToArray()
            }
        };
    }

    public static RawPreviewPair[] GetReportPreviewPairs(
        string reportHtmlPath,
        string resultsRoot,
        string targetId,
        string targetPath,
        string mode,
        ComparisonManifest comparison,
        string? repositoryRoot,
        int modeSortOrder,
        Func<string?, int> getSectionKindSortOrder)
    {
        if (!File.Exists(reportHtmlPath))
        {
            return [];
        }

        var reportHtml = File.ReadAllText(reportHtmlPath);
        if (string.IsNullOrWhiteSpace(reportHtml))
        {
            return [];
        }

        var reportDirectory = Path.GetDirectoryName(reportHtmlPath)!;
        var reportHtmlRelativePath = PathHelpers.ResolveRelativePath(reportHtmlPath, resultsRoot);
        var pairs = new List<RawPreviewPair>();
        var sectionOrdinal = 0;
        foreach (Match match in PreviewTableRegex.Matches(reportHtml))
        {
            var summaryAttributes = match.Groups["summaryAttrs"].Value;
            var summaryText = ReviewCompilerText.ConvertFromHtmlText(match.Groups["summary"].Value);
            var tableHtml = match.Groups["table"].Value;
            var surfaceCandidates = GetReportPreviewSurfaceCandidates(tableHtml, reportDirectory);
            var selectedSurface = SelectPreviewSurfaceCandidateForMode(surfaceCandidates, mode);
            if (selectedSurface is null)
            {
                continue;
            }

            var sectionKind = summaryAttributes.Contains("difference-heading", StringComparison.OrdinalIgnoreCase) ? "overview" : "detail";
            var label = !string.IsNullOrWhiteSpace(selectedSurface.Label)
                ? selectedSurface.Label
                : !string.IsNullOrWhiteSpace(summaryText)
                    ? summaryText
                    : "Preview";
            var comparisonReceipt = ReviewBundleCompiler.BuildComparisonReceipt(comparison, repositoryRoot);
            var sortKey = $"{targetPath}|{modeSortOrder:D2}|{comparisonReceipt.Index:D4}|{getSectionKindSortOrder(sectionKind):D2}|{sectionOrdinal:D4}|{ReviewCompilerText.ConvertToSlug(label, "preview")}";

            pairs.Add(new RawPreviewPair
            {
                TargetId = targetId,
                TargetPath = targetPath,
                Mode = mode,
                Comparison = comparisonReceipt,
                SectionKind = sectionKind,
                SectionOrdinal = sectionOrdinal,
                Label = label,
                DebugReportHtmlRelativePath = reportHtmlRelativePath,
                BaseImageRelativePath = PathHelpers.ResolveRelativePath(selectedSurface.BaseImagePath, resultsRoot),
                HeadImageRelativePath = PathHelpers.ResolveRelativePath(selectedSurface.HeadImagePath, resultsRoot),
                BaseByteLength = new FileInfo(selectedSurface.BaseImagePath).Length,
                HeadByteLength = new FileInfo(selectedSurface.HeadImagePath).Length,
                BaseImageSha256 = PathHelpers.GetFileSha256Hex(selectedSurface.BaseImagePath),
                HeadImageSha256 = PathHelpers.GetFileSha256Hex(selectedSurface.HeadImagePath),
                SortKey = sortKey
            });
            sectionOrdinal += 1;
        }

        return pairs.ToArray();
    }

    public static ReviewerSummary? NewReviewerSummaryFromChangeDetails(ReviewChangeDetails? changeDetails)
    {
        if (changeDetails is null)
        {
            return null;
        }

        var signalMap = new Dictionary<string, MutableReviewerSignal>(StringComparer.OrdinalIgnoreCase);
        foreach (var group in changeDetails.Groups ?? [])
        {
            var descriptor = GetReviewerSignalDescriptor(group.Heading, group.DetailCount, group.SectionCount);
            if (!signalMap.TryGetValue(descriptor.SignalKey, out var signalRecord))
            {
                signalRecord = new MutableReviewerSignal
                {
                    SignalKey = descriptor.SignalKey,
                    Label = descriptor.Label,
                    HeadlineLabel = descriptor.HeadlineLabel,
                    Severity = descriptor.Severity,
                    SortOrder = descriptor.SortOrder
                };
                signalMap[descriptor.SignalKey] = signalRecord;
            }

            if (GetReviewerSeverityRank(descriptor.Severity) > GetReviewerSeverityRank(signalRecord.Severity))
            {
                signalRecord.Severity = descriptor.Severity;
            }

            signalRecord.DetailCount += group.DetailCount;
            signalRecord.SectionCount += group.SectionCount;
            signalRecord.PrimaryDebugReportHtmlRelativePath ??= group.PrimaryDebugReportHtmlRelativePath;
            foreach (var sectionLink in group.SectionLinks ?? [])
            {
                if (string.IsNullOrWhiteSpace(sectionLink.DebugReportHtmlRelativePath) || string.IsNullOrWhiteSpace(sectionLink.Label))
                {
                    continue;
                }

                if (signalRecord.SectionLinkKeys.Add(sectionLink.DebugReportHtmlRelativePath))
                {
                    signalRecord.SectionLinks.Add(new DebugChangeDetailSectionLink
                    {
                        SectionOrdinal = sectionLink.SectionOrdinal,
                        Label = sectionLink.Label,
                        ReviewerRelativePath = null,
                        DebugReportHtmlRelativePath = sectionLink.DebugReportHtmlRelativePath
                    });
                }
            }
        }

        var orderedSignals = signalMap.Values
            .OrderByDescending(signal => GetReviewerSeverityRank(signal.Severity))
            .ThenBy(signal => signal.SortOrder)
            .ThenBy(signal => signal.Label, StringComparer.Ordinal)
            .ToArray();
        if (orderedSignals.Length == 0)
        {
            return null;
        }

        var signalItems = orderedSignals
            .Take(ReviewerSummarySignalCap)
            .Select(signalRecord => new ReviewerSignal
            {
                SignalKey = signalRecord.SignalKey,
                Label = signalRecord.Label,
                Severity = signalRecord.Severity,
                DetailCount = signalRecord.DetailCount,
                SectionCount = signalRecord.SectionCount,
                Summary = $"{signalRecord.DetailCount} details across {signalRecord.SectionCount} sections",
                PrimaryReviewerRelativePath = null,
                PrimaryDebugReportHtmlRelativePath = signalRecord.PrimaryDebugReportHtmlRelativePath,
                SectionLinks = signalRecord.SectionLinks.ToArray()
            })
            .ToArray();

        var overallSeverity = orderedSignals[0].Severity;
        var headlineLabels = orderedSignals.Take(2).Select(signal => signal.HeadlineLabel).ToArray();
        var headlineBody = headlineLabels.Length switch
        {
            0 => string.Empty,
            1 => headlineLabels[0],
            2 => $"{headlineLabels[0]} and {headlineLabels[1]}",
            _ => $"{headlineLabels[0]}, {headlineLabels[1]}, and more"
        };
        var headlinePrefix = overallSeverity switch
        {
            "high" => "High-change",
            "medium" => "Material",
            "low" => "Scoped",
            _ => "Observed"
        };

        return new ReviewerSummary
        {
            Label = "Reviewer summary",
            OverallSeverity = overallSeverity,
            Headline = string.IsNullOrWhiteSpace(headlineBody) ? headlinePrefix : $"{headlinePrefix} {headlineBody}",
            SignalCount = orderedSignals.Length,
            OmittedSignalCount = Math.Max(orderedSignals.Length - signalItems.Length, 0),
            Signals = signalItems
        };
    }

    private static ChangeDetailSectionReceipt GetReviewerChangeDetailSectionsFromReport(string reportHtmlPath, string resultsRoot)
    {
        var reportHtml = File.ReadAllText(reportHtmlPath);
        if (string.IsNullOrWhiteSpace(reportHtml))
        {
            return new ChangeDetailSectionReceipt { ReportHtml = reportHtml };
        }

        var sections = new List<ParsedChangeDetailSection>();
        var matches = DetailBlockRegex.Matches(reportHtml);
        if (matches.Count == 0)
        {
            return new ChangeDetailSectionReceipt { ReportHtml = reportHtml };
        }

        var builder = new StringBuilder();
        var cursor = 0;
        var sectionIndex = 0;
        var htmlChanged = false;

        foreach (Match match in matches)
        {
            builder.Append(reportHtml.AsSpan(cursor, match.Index - cursor));
            var blockHtml = match.Value;
            var bodyHtml = match.Groups["body"].Value;
            if (bodyHtml.Contains("detailed-description-list", StringComparison.OrdinalIgnoreCase))
            {
                sectionIndex += 1;
                var summaryText = ReviewCompilerText.ConvertFromHtmlText(match.Groups["summary"].Value);
                var heading = ReviewCompilerText.NormalizeReviewerChangeDetailHeading(summaryText) ?? "Change details";
                var sectionOrdinal = ReviewCompilerText.GetReviewerChangeDetailSectionOrdinal(summaryText) ?? sectionIndex;
                var anchorIdMatch = Regex.Match(match.Groups["detailsAttributes"].Value, "\\bid=\"(?<id>[^\"]+)\"");
                var anchorId = ReviewCompilerText.GetOptionalString(anchorIdMatch.Groups["id"].Value);
                if (string.IsNullOrWhiteSpace(anchorId))
                {
                    anchorId = $"comparevi-change-{sectionOrdinal:D3}-{ReviewCompilerText.ConvertToSlug(heading, "change-detail")}";
                    var openTag = match.Groups["open"].Value;
                    var updatedOpenTag = Regex.IsMatch(openTag, "\\bid=\"[^\"]+\"")
                        ? openTag
                        : openTag.Insert(openTag.Length - 1, $" id=\"{anchorId}\"");
                    blockHtml = updatedOpenTag + blockHtml[openTag.Length..];
                    htmlChanged = true;
                }

                var detailLines = DiffDetailRegex.Matches(bodyHtml)
                    .Select(detailMatch => ReviewCompilerText.ConvertFromHtmlText(detailMatch.Groups["detail"].Value))
                    .Where(detailLine => !string.IsNullOrWhiteSpace(detailLine))
                    .ToArray();
                if (detailLines.Length > 0)
                {
                    sections.Add(new ParsedChangeDetailSection
                    {
                        Index = sectionIndex,
                        Ordinal = sectionOrdinal,
                        Heading = heading,
                        AnchorId = anchorId!,
                        DetailLines = detailLines
                    });
                }
            }

            builder.Append(blockHtml);
            cursor = match.Index + match.Length;
        }

        if (cursor < reportHtml.Length)
        {
            builder.Append(reportHtml[cursor..]);
        }

        var updatedReportHtml = builder.ToString();
        var effectiveReportHtmlPath = reportHtmlPath;
        if (htmlChanged && !string.Equals(updatedReportHtml, reportHtml, StringComparison.Ordinal))
        {
            effectiveReportHtmlPath = GetReviewerAnchoredReportPath(reportHtmlPath);
            File.WriteAllText(effectiveReportHtmlPath, updatedReportHtml, Encoding.UTF8);
        }

        var effectiveDebugReportHtmlRelativePath = PathHelpers.ResolveRelativePath(effectiveReportHtmlPath, resultsRoot);
        foreach (var section in sections)
        {
            section.DebugReportHtmlRelativePath = $"{effectiveDebugReportHtmlRelativePath}#{section.AnchorId}";
        }

        return new ChangeDetailSectionReceipt
        {
            ReportHtml = updatedReportHtml,
            DebugReportHtmlRelativePath = effectiveDebugReportHtmlRelativePath,
            Sections = sections.ToArray()
        };
    }

    private static string GetReviewerAnchoredReportPath(string reportHtmlPath)
    {
        var directory = Path.GetDirectoryName(reportHtmlPath)!;
        var fileNameWithoutExtension = Path.GetFileNameWithoutExtension(reportHtmlPath);
        var extension = Path.GetExtension(reportHtmlPath);
        return Path.Combine(directory, $"{fileNameWithoutExtension}.reviewer-anchors{extension}");
    }

    private static List<string> GetReportIncludedCategories(string reportHtml)
    {
        var includedCategories = new List<string>();
        var includedBlockMatch = IncludedAttributesRegex.Match(reportHtml);
        if (!includedBlockMatch.Success)
        {
            return includedCategories;
        }

        foreach (Match itemMatch in CheckedAttributeRegex.Matches(includedBlockMatch.Groups["list"].Value))
        {
            var itemText = ReviewCompilerText.ConvertFromHtmlText(itemMatch.Groups["item"].Value);
            if (!string.IsNullOrWhiteSpace(itemText))
            {
                includedCategories.Add(itemText);
            }
        }

        return includedCategories;
    }

    private static PreviewSurfaceCandidate[] GetReportPreviewSurfaceCandidates(string tableHtml, string reportDirectory)
    {
        var candidates = new List<PreviewSurfaceCandidate>();
        foreach (Match surfaceMatch in PreviewSurfaceRegex.Matches(tableHtml))
        {
            var caption = ReviewCompilerText.ConvertFromHtmlText(surfaceMatch.Groups["caption"].Value);
            var imageSources = ImageSourceRegex.Matches(surfaceMatch.Groups["images"].Value)
                .Select(match => ReviewCompilerText.GetOptionalString(match.Groups["src"].Value))
                .Where(static value => !string.IsNullOrWhiteSpace(value))
                .Cast<string>()
                .ToArray();
            if (imageSources.Length < 2)
            {
                continue;
            }

            var baseImagePath = PathHelpers.ResolveExistingFilePath(imageSources[0], reportDirectory);
            var headImagePath = PathHelpers.ResolveExistingFilePath(imageSources[1], reportDirectory);
            if (string.IsNullOrWhiteSpace(baseImagePath) || string.IsNullOrWhiteSpace(headImagePath))
            {
                continue;
            }

            candidates.Add(new PreviewSurfaceCandidate(caption, baseImagePath!, headImagePath!));
        }

        return candidates.ToArray();
    }

    private static PreviewSurfaceCandidate? SelectPreviewSurfaceCandidateForMode(PreviewSurfaceCandidate[] candidates, string mode)
    {
        if (candidates.Length == 0)
        {
            return null;
        }

        var matchingCandidate = candidates.FirstOrDefault(candidate => PreviewSurfaceMatchesMode(candidate, mode));
        if (matchingCandidate is not null)
        {
            return matchingCandidate;
        }

        return string.Equals(mode, "front-panel", StringComparison.OrdinalIgnoreCase) ? candidates[0] : null;
    }

    private static bool PreviewSurfaceMatchesMode(PreviewSurfaceCandidate candidate, string mode)
    {
        var label = candidate.Label.ToLowerInvariant();
        var baseName = Path.GetFileName(candidate.BaseImagePath).ToLowerInvariant();
        var headName = Path.GetFileName(candidate.HeadImagePath).ToLowerInvariant();
        return mode switch
        {
            "front-panel" => label.Contains("front panel", StringComparison.Ordinal) || baseName.StartsWith("fp_", StringComparison.Ordinal) || headName.StartsWith("fp_", StringComparison.Ordinal),
            "block-diagram" => label.Contains("block diagram", StringComparison.Ordinal) || baseName.StartsWith("bd_", StringComparison.Ordinal) || headName.StartsWith("bd_", StringComparison.Ordinal),
            "attributes" => label.Contains("attribute", StringComparison.Ordinal),
            _ => false
        };
    }

    private static string GetReviewerSemanticHeadingFromSection(string sectionHeading, string? detailLine)
    {
        var normalizedHeading = ReviewCompilerText.NormalizeReviewerChangeDetailHeading(sectionHeading);
        if (string.IsNullOrWhiteSpace(normalizedHeading))
        {
            return "Change details";
        }

        var (subject, action) = ReviewCompilerText.GetReviewerChangeDetailLineParts(detailLine);
        action = ReviewCompilerText.CleanString(action)?.ToLowerInvariant();
        return normalizedHeading switch
        {
            "Block Diagram objects" => action switch
            {
                "moved" => "Block diagram moves",
                "resized" => "Block diagram resizing",
                "deleted" => "Removed block diagram objects",
                "added" => "Added block diagram objects",
                _ => "Block diagram object changes"
            },
            "Front Panel objects" => action switch
            {
                "moved" => "Front panel layout moves",
                "resized" => "Front panel resizing",
                "deleted" => "Removed front panel objects",
                "added" => "Added front panel objects",
                _ => "Front panel object changes"
            },
            var value when value.StartsWith("VI Attribute", StringComparison.Ordinal) => subject switch
            {
                not null when subject.StartsWith("VI Version", StringComparison.Ordinal) => "VI version changes",
                not null when subject.StartsWith("Execution", StringComparison.Ordinal) => "Execution changes",
                not null when subject.StartsWith("Icon", StringComparison.Ordinal) => "Icon changes",
                _ => "VI attribute changes"
            },
            _ => normalizedHeading
        };
    }

    private static ReviewerSignalDescriptor GetReviewerSignalDescriptor(string? heading, int detailCount, int sectionCount)
    {
        var normalizedHeading = ReviewCompilerText.NormalizeReviewerChangeDetailHeading(heading);
        if (string.IsNullOrWhiteSpace(normalizedHeading))
        {
            return new ReviewerSignalDescriptor("diagnostic-change", "Additional diagnostic changes", "additional diagnostic changes", "low", 90);
        }

        return normalizedHeading switch
        {
            "Block diagram moves" => new ReviewerSignalDescriptor("logic-movement", "Logic-affecting movement", "logic-affecting movement", detailCount >= 10 || sectionCount >= 3 ? "high" : "medium", 10),
            "Block diagram resizing" => new ReviewerSignalDescriptor("structure-resizing", "Structure resizing", "structure resizing", detailCount >= 5 || sectionCount >= 2 ? "medium" : "low", 20),
            "Added block diagram objects" or "Removed block diagram objects" => new ReviewerSignalDescriptor("object-topology", "Object additions or removals", "object additions or removals", "high", 5),
            "Front panel layout moves" or "Front panel resizing" or "Front panel object changes" or "Added front panel objects" or "Removed front panel objects" => new ReviewerSignalDescriptor("layout-changes", "Layout changes", "layout changes", detailCount >= 8 || sectionCount >= 3 ? "medium" : "low", 40),
            "Execution changes" => new ReviewerSignalDescriptor("execution-behavior", "Execution behavior changes", "execution behavior changes", "high", 15),
            "VI version changes" => new ReviewerSignalDescriptor("version-compatibility", "Version or compatibility changes", "version or compatibility changes", "medium", 30),
            "Icon changes" => new ReviewerSignalDescriptor("visual-presentation", "Visual presentation changes", "visual presentation changes", "low", 60),
            "VI attribute changes" => new ReviewerSignalDescriptor("metadata", "Metadata changes", "metadata changes", "low", 50),
            _ => new ReviewerSignalDescriptor("diagnostic-change", "Additional diagnostic changes", "additional diagnostic changes", "low", 90)
        };
    }

    private static int GetReviewerSeverityRank(string? severity) => severity switch
    {
        "high" => 3,
        "medium" => 2,
        "low" => 1,
        _ => 0
    };

    private sealed class MutableChangeDetailGroup
    {
        public string Heading { get; init; } = string.Empty;
        public int SectionCount { get; set; }
        public int DetailCount { get; set; }
        public List<string> SampleDetails { get; } = [];
        public List<DebugChangeDetailSectionLink> SectionLinks { get; } = [];
    }

    private sealed class MutableReviewerSignal
    {
        public string SignalKey { get; init; } = string.Empty;
        public string Label { get; init; } = string.Empty;
        public string HeadlineLabel { get; init; } = string.Empty;
        public string Severity { get; set; } = "low";
        public int SortOrder { get; init; }
        public int DetailCount { get; set; }
        public int SectionCount { get; set; }
        public string? PrimaryDebugReportHtmlRelativePath { get; set; }
        public HashSet<string> SectionLinkKeys { get; } = new(StringComparer.OrdinalIgnoreCase);
        public List<DebugChangeDetailSectionLink> SectionLinks { get; } = [];
    }

    private sealed record PreviewSurfaceCandidate(string Label, string BaseImagePath, string HeadImagePath);
    private sealed record ReviewerSignalDescriptor(string SignalKey, string Label, string HeadlineLabel, string Severity, int SortOrder);

    private sealed class ChangeDetailSectionReceipt
    {
        public string? ReportHtml { get; init; }
        public string? DebugReportHtmlRelativePath { get; init; }
        public ParsedChangeDetailSection[] Sections { get; init; } = [];
    }

    private sealed class ParsedChangeDetailSection
    {
        public int Index { get; init; }
        public int Ordinal { get; init; }
        public string Heading { get; init; } = string.Empty;
        public string AnchorId { get; init; } = string.Empty;
        public string[] DetailLines { get; init; } = [];
        public string? DebugReportHtmlRelativePath { get; set; }
    }

    private static readonly Regex DetailBlockRegex = new("(?is)(?<open><details(?<detailsAttributes>[^>]*)>)\\s*<summary(?<summaryAttributes>[^>]*)>(?<summary>.*?)</summary>(?<body>.*?)</details>", RegexOptions.Compiled);
    private static readonly Regex DiffDetailRegex = new("(?is)<li class=\"[^\"]*diff-detail[^\"]*\">(?<detail>.*?)</li>", RegexOptions.Compiled);
    private static readonly Regex IncludedAttributesRegex = new("(?is)<div class=\"included-attributes\".*?<ul[^>]*>(?<list>.*?)</ul>", RegexOptions.Compiled);
    private static readonly Regex CheckedAttributeRegex = new("(?is)<li class=\"checked\">(?<item>.*?)</li>", RegexOptions.Compiled);
    private static readonly Regex PreviewTableRegex = new("(?is)<details(?<detailsAttrs>[^>]*)>\\s*<summary(?<summaryAttrs>[^>]*)>(?<summary>.*?)</summary>\\s*<table class=\"difference\">(?<table>.*?)</table>\\s*</details>", RegexOptions.Compiled);
    private static readonly Regex PreviewSurfaceRegex = new("(?is)<tr class=\"compared-vi-image-captions\">.*?<td class=\"compared-vi-image-caption\">(?<caption>.*?)</td>.*?</tr>\\s*<tr class=\"compared-images\">(?<images>.*?)</tr>", RegexOptions.Compiled);
    private static readonly Regex ImageSourceRegex = new("(?is)<img[^>]+src=\"(?<src>[^\"]+)\"", RegexOptions.Compiled);
}
