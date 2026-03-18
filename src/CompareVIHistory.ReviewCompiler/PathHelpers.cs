using System.Diagnostics;
using System.Collections.Concurrent;
using System.Security.Cryptography;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace CompareVIHistory.ReviewCompiler;

internal static class PathHelpers
{
    public static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNameCaseInsensitive = true,
        WriteIndented = true,
        DefaultIgnoreCondition = JsonIgnoreCondition.Never
    };

    private static readonly ConcurrentDictionary<string, string?> GitCommitSubjectCache = new(StringComparer.OrdinalIgnoreCase);

    public static string ResolveAbsolutePath(string path, string basePath)
    {
        return Path.IsPathRooted(path) ? Path.GetFullPath(path) : Path.GetFullPath(Path.Combine(basePath, path));
    }

    public static string? ResolveExistingFilePath(string? path, string basePath)
    {
        if (string.IsNullOrWhiteSpace(path))
        {
            return null;
        }

        var resolvedPath = ResolveAbsolutePath(path, basePath);
        return File.Exists(resolvedPath) ? resolvedPath : null;
    }

    public static string? ResolveExistingDirectoryPath(string? path, string basePath)
    {
        if (string.IsNullOrWhiteSpace(path))
        {
            return null;
        }

        var resolvedPath = ResolveAbsolutePath(path, basePath);
        return Directory.Exists(resolvedPath) ? resolvedPath : null;
    }

    public static string ResolveRelativePath(string path, string resultsRoot)
    {
        var resolvedPath = ResolveAbsolutePath(path, resultsRoot);
        return Path.GetRelativePath(resultsRoot, resolvedPath).Replace('\\', '/');
    }

    public static string GetFileSha256Hex(string path)
    {
        using var stream = File.OpenRead(path);
        using var sha256 = SHA256.Create();
        return Convert.ToHexString(sha256.ComputeHash(stream)).ToLowerInvariant();
    }

    public static T ReadJsonFile<T>(string path)
    {
        var raw = File.ReadAllText(path);
        if (string.IsNullOrWhiteSpace(raw))
        {
            throw new InvalidOperationException($"JSON file was empty: {path}");
        }

        return JsonSerializer.Deserialize<T>(raw, JsonOptions)
            ?? throw new InvalidOperationException($"Failed to deserialize JSON file: {path}");
    }

    public static string? GetGitCommitSubject(string? repositoryRoot, string? @ref)
    {
        repositoryRoot = ReviewCompilerText.CleanString(repositoryRoot);
        @ref = ReviewCompilerText.CleanString(@ref);
        if (string.IsNullOrWhiteSpace(repositoryRoot) || string.IsNullOrWhiteSpace(@ref))
        {
            return null;
        }

        var cacheKey = $"{repositoryRoot}|{@ref}";
        if (GitCommitSubjectCache.TryGetValue(cacheKey, out var cachedSubject))
        {
            return cachedSubject;
        }

        var processStartInfo = new ProcessStartInfo
        {
            FileName = "git",
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            CreateNoWindow = true,
            WorkingDirectory = repositoryRoot
        };
        processStartInfo.ArgumentList.Add("show");
        processStartInfo.ArgumentList.Add("-s");
        processStartInfo.ArgumentList.Add("--format=%s");
        processStartInfo.ArgumentList.Add(@ref);

        try
        {
            using var process = Process.Start(processStartInfo);
            if (process is null)
            {
                GitCommitSubjectCache[cacheKey] = null;
                return null;
            }

            var stdout = process.StandardOutput.ReadToEnd();
            process.WaitForExit();
            var subject = process.ExitCode == 0 ? ReviewCompilerText.CleanString(stdout) : null;
            GitCommitSubjectCache[cacheKey] = subject;
            return subject;
        }
        catch
        {
            GitCommitSubjectCache[cacheKey] = null;
            return null;
        }
    }
}
