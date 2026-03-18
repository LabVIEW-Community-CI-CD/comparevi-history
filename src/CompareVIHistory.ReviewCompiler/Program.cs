using System.Text;
using System.Text.Json;
using System.Reflection;

namespace CompareVIHistory.ReviewCompiler;

internal static class Program
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNameCaseInsensitive = true,
        WriteIndented = true,
        DefaultIgnoreCondition = System.Text.Json.Serialization.JsonIgnoreCondition.Never
    };

    public static int Main(string[] args)
    {
        try
        {
            if (args.Length == 1 && string.Equals(args[0], "--version", StringComparison.Ordinal))
            {
                Console.WriteLine(GetVersionString());
                return 0;
            }

            var options = CompilerOptions.Parse(args);
            var bundle = ReviewBundleCompiler.Build(options);
            Directory.CreateDirectory(Path.GetDirectoryName(options.OutputPath)!);
            var json = JsonSerializer.Serialize(bundle, JsonOptions);
            File.WriteAllText(options.OutputPath, json, Encoding.UTF8);
            Console.WriteLine(json);
            return 0;
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine(ex.Message);
            return 1;
        }
    }

    private static string GetVersionString()
    {
        var assembly = typeof(Program).Assembly;
        return assembly.GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion
            ?? assembly.GetName().Version?.ToString()
            ?? "0.0.0";
    }
}
