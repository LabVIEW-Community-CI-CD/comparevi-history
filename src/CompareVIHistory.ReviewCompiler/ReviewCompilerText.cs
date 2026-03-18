using System.Globalization;
using System.Net;
using System.Text.RegularExpressions;

namespace CompareVIHistory.ReviewCompiler;

internal static class ReviewCompilerText
{
    public static string? GetOptionalString(string? value)
    {
        if (string.IsNullOrWhiteSpace(value))
        {
            return null;
        }

        return value.Trim();
    }

    public static string? CleanString(string? value)
    {
        if (string.IsNullOrWhiteSpace(value))
        {
            return null;
        }

        return value.Trim();
    }

    public static string ConvertFromHtmlText(string? value)
    {
        if (string.IsNullOrWhiteSpace(value))
        {
            return string.Empty;
        }

        var decoded = WebUtility.HtmlDecode(value);
        var withoutTags = Regex.Replace(decoded, "<[^>]+>", " ");
        return Regex.Replace(withoutTags, "\\s+", " ").Trim();
    }

    public static string ConvertToSlug(string? value, string fallback)
    {
        var normalized = CleanString(value);
        if (string.IsNullOrWhiteSpace(normalized))
        {
            return fallback;
        }

        var slug = Regex.Replace(normalized.ToLowerInvariant(), "[^a-z0-9]+", "-").Trim('-');
        return string.IsNullOrWhiteSpace(slug) ? fallback : slug;
    }

    public static string? ConvertToShortRef(string? @ref)
    {
        var refValue = CleanString(@ref);
        if (string.IsNullOrWhiteSpace(refValue))
        {
            return null;
        }

        return refValue.Length <= 12 ? refValue : refValue[..12];
    }

    public static string? NormalizeReviewerChangeDetailHeading(string? heading)
    {
        var normalizedHeading = CleanString(heading);
        return string.IsNullOrWhiteSpace(normalizedHeading)
            ? null
            : Regex.Replace(normalizedHeading, "^\\d+\\.\\s*", string.Empty).Trim();
    }

    public static int? GetReviewerChangeDetailSectionOrdinal(string? heading)
    {
        var normalizedHeading = CleanString(heading);
        if (string.IsNullOrWhiteSpace(normalizedHeading))
        {
            return null;
        }

        var ordinalMatch = Regex.Match(normalizedHeading, "^\\s*(?<ordinal>\\d+)\\.");
        return ordinalMatch.Success ? int.Parse(ordinalMatch.Groups["ordinal"].Value, CultureInfo.InvariantCulture) : null;
    }

    public static (string? Subject, string? Action) GetReviewerChangeDetailLineParts(string? detailLine)
    {
        var normalizedDetailLine = CleanString(detailLine);
        if (string.IsNullOrWhiteSpace(normalizedDetailLine))
        {
            return (null, null);
        }

        var prefix = normalizedDetailLine;
        var colonIndex = prefix.IndexOf(':');
        if (colonIndex >= 0)
        {
            prefix = prefix[..colonIndex];
        }

        prefix = Regex.Replace(prefix, "\\s+", " ").Trim();
        if (string.IsNullOrWhiteSpace(prefix))
        {
            return (null, null);
        }

        var subject = prefix;
        string? action = null;
        var actionMatch = Regex.Match(prefix, "^(?<subject>.*?)\\s*-\\s*(?<action>[^-].+?)$");
        if (actionMatch.Success)
        {
            subject = Regex.Replace(actionMatch.Groups["subject"].Value, "\\s+", " ").Trim();
            action = Regex.Replace(actionMatch.Groups["action"].Value, "\\s+", " ").Trim();
        }

        return (CleanString(subject), CleanString(action));
    }
}
