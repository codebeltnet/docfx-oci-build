#:property PublishAot=false

using System.Collections;
using System.Reflection;
using System.Text.Json;

namespace Codebelt.Docfx;

internal static class ResolveDocfxProjects
{
    private static void Main(string[] args)
    {
        var tools = args[0];
        AppDomain.CurrentDomain.AssemblyResolve += (_, eventArgs) =>
        {
            var path = Path.Combine(tools, new AssemblyName(eventArgs.Name).Name + ".dll");
            return File.Exists(path) ? Assembly.LoadFrom(path) : null;
        };

        // Use the same file-mapping expansion as the installed DocFX CLI.
        var glob = Assembly.LoadFrom(Path.Combine(tools, "Docfx.Glob.dll"));
        var expand = glob.GetType("Docfx.GlobUtility", true)!.GetMethod("ExpandFileMapping")!;
        var mappingType = expand.ReturnType;
        var itemType = mappingType.GetProperty("Items")!.PropertyType.GetGenericArguments().Single();
        var jsonOptions = new JsonSerializerOptions { PropertyNameCaseInsensitive = true };
        using var config = JsonDocument.Parse(File.ReadAllText(args[1]), new JsonDocumentOptions
        {
            CommentHandling = JsonCommentHandling.Skip,
            AllowTrailingCommas = true
        });
        var root = Path.GetDirectoryName(args[1])!;
        var groups = config.RootElement.GetProperty("metadata").EnumerateArray().Select(group =>
        {
            var sources = group.GetProperty("src");
            var items = JsonSerializer.Deserialize(sources, itemType.MakeArrayType(), jsonOptions);
            var mapping = Activator.CreateInstance(mappingType, new[] { items });
            dynamic expanded = expand.Invoke(null, new[] { root, mapping })!;
            return ((IEnumerable)expanded.Items).Cast<dynamic>().Select(item => new
            {
                source = (string)item.Src,
                files = ((IEnumerable)item.Files).Cast<string>().ToArray()
            }).ToArray();
        }).ToArray();
        File.WriteAllText(args[2], JsonSerializer.Serialize(groups));
    }
}
