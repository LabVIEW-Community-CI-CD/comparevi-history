using System.Text;
using System.Text.Json;

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
}
