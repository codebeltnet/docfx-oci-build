#:property PublishAot=false

using System.Collections;
using System.Reflection;
using System.Text.Json;

namespace Codebelt.Docfx;

internal static class ResolveDocfxProjects
{
    private static int Main(string[] args)
    {
        try
        {
            Resolve(args[0], args[1], args[2]);
            return 0;
        }
        catch (Exception error)
        {
            var cause = error is TargetInvocationException { InnerException: Exception inner } ? inner : error;
            Console.Error.WriteLine($"DocFX project discovery failed for '{args[1]}'. Verify the pinned DocFX tool installation and metadata.src file mappings.");
            Console.Error.WriteLine(cause);
            return 1;
        }
    }

    private static void Resolve(string tools, string configPath, string outputPath)
    {
        AppDomain.CurrentDomain.AssemblyResolve += (_, eventArgs) =>
        {
            var path = Path.Combine(tools, new AssemblyName(eventArgs.Name).Name + ".dll");
            return File.Exists(path) ? Assembly.LoadFrom(path) : null;
        };

        // Bind to the public mapping API in the pinned CLI's own assemblies.
        var glob = Assembly.LoadFrom(Path.Combine(tools, "Docfx.Glob.dll"));
        var mappingType = Assembly.LoadFrom(Path.Combine(tools, "Docfx.Common.dll")).GetType("Docfx.FileMapping", true)!;
        var expand = glob.GetType("Docfx.GlobUtility", true)!.GetMethod("ExpandFileMapping", [typeof(string), mappingType])
            ?? throw new MissingMethodException("DocFX's ExpandFileMapping signature changed. Update the resolver and run the framework-view regression tests before upgrading DocFX.");
        var jsonOptions = new JsonSerializerOptions { PropertyNameCaseInsensitive = true };
        using var config = JsonDocument.Parse(File.ReadAllText(configPath), new JsonDocumentOptions
        {
            CommentHandling = JsonCommentHandling.Skip,
            AllowTrailingCommas = true
        });
        var root = Path.GetDirectoryName(configPath)!;
        var groups = config.RootElement.GetProperty("metadata").EnumerateArray().Select(group =>
        {
            var sources = group.GetProperty("src");
            var mapping = JsonSerializer.Deserialize(sources, mappingType, jsonOptions);
            dynamic expanded = expand.Invoke(null, [root, mapping])!;
            return ((IEnumerable)expanded.Items).Cast<dynamic>().Select(item => new
            {
                source = (string)item.Src,
                files = ((IEnumerable)item.Files).Cast<string>().ToArray()
            }).ToArray();
        }).ToArray();
        File.WriteAllText(outputPath, JsonSerializer.Serialize(groups));
    }
}
