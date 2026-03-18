namespace CompareVIHistory.ReviewCompiler;

internal sealed record CompilerOptions(string TargetRunsManifestPath, string ResultsDir, string OutputPath)
{
    public static CompilerOptions Parse(string[] args)
    {
        var values = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        for (var index = 0; index < args.Length; index += 1)
        {
            var key = args[index];
            if (!key.StartsWith("--", StringComparison.Ordinal))
            {
                throw new InvalidOperationException($"Unexpected argument '{key}'.");
            }

            if (index + 1 >= args.Length)
            {
                throw new InvalidOperationException($"Missing value for argument '{key}'.");
            }

            values[key[2..]] = args[index + 1];
            index += 1;
        }

        if (!values.TryGetValue("target-runs-manifest-path", out var manifestPath) || string.IsNullOrWhiteSpace(manifestPath))
        {
            throw new InvalidOperationException("Missing required argument '--target-runs-manifest-path'.");
        }

        if (!values.TryGetValue("results-dir", out var resultsDir) || string.IsNullOrWhiteSpace(resultsDir))
        {
            throw new InvalidOperationException("Missing required argument '--results-dir'.");
        }

        values.TryGetValue("output-path", out var outputPath);
        var basePath = Environment.CurrentDirectory;
        var resolvedManifestPath = PathHelpers.ResolveAbsolutePath(manifestPath, basePath);
        var resolvedResultsDir = PathHelpers.ResolveAbsolutePath(resultsDir, basePath);
        var resolvedOutputPath = string.IsNullOrWhiteSpace(outputPath)
            ? Path.Combine(resolvedResultsDir, "review-bundle.json")
            : PathHelpers.ResolveAbsolutePath(outputPath, basePath);

        return new CompilerOptions(resolvedManifestPath, resolvedResultsDir, resolvedOutputPath);
    }
}
