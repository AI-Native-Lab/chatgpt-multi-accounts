using System.Text.Json.Nodes;
using Microsoft.Win32;

namespace ChatGPTMultiAccounts.Core;

/// <summary>Keeps ChatGPT's browser extension (ChatGPT for Chrome, also in Edge, Brave…) paired with the main
/// ChatGPT.
///
/// The extension reaches ChatGPT through a native-messaging host. On Windows, ChatGPT writes one manifest for it,
/// <c>%LOCALAPPDATA%\OpenAI\extension\com.openai.codexextension.json</c>, which the browsers find through
/// <c>HKCU\Software\Google\Chrome\NativeMessagingHosts</c>, and adds itself to a registry shared by all copies,
/// <c>%LOCALAPPDATA%\OpenAI\Codex\chrome-native-hosts-v2.json</c>. Every copy that starts points the manifest at
/// its own copy of the host, inside its CODEX_HOME, so the copy that started last would take the extension over.
/// This puts the main ChatGPT's host back in the manifests and takes the accounts' entries out of the shared
/// registry. It changes nothing when the main ChatGPT has never set the extension up, and never touches the
/// Windows registry.</summary>
public static class BrowserExtension
{
    public const string RegistryFile = "chrome-native-hosts-v2.json";

    /// <summary>Where browsers look for native-messaging hosts, under HKEY_CURRENT_USER.</summary>
    public static readonly string[] BrowserKeys =
    {
        @"Software\Google\Chrome\NativeMessagingHosts",
        @"Software\Google\Chrome for Testing\NativeMessagingHosts",
        @"Software\Chromium\NativeMessagingHosts",
        @"Software\Microsoft\Edge\NativeMessagingHosts",
        @"Software\BraveSoftware\Brave-Browser\NativeMessagingHosts",
        @"Software\Vivaldi\NativeMessagingHosts",
        @"Software\Opera Software\NativeMessagingHosts",
    };

    public static string SharedRegistry(Layout layout) => Path.Combine(layout.LocalAppData, "OpenAI", "Codex", RegistryFile);
    public static string ManifestFolder(Layout layout) => Path.Combine(layout.LocalAppData, "OpenAI", "extension");

    /// <summary>The main ChatGPT's host for each host name, from its own registry. Only hosts that exist.</summary>
    public static Dictionary<string, string> MainHosts(Layout layout)
    {
        var hosts = new Dictionary<string, string>(StringComparer.Ordinal);
        if (Files.ReadJson(Path.Combine(layout.MainCodexHome, RegistryFile))?["entries"] is not JsonArray entries) return hosts;
        foreach (var entry in entries.OfType<JsonObject>())
        {
            if (Str((entry["paths"] as JsonObject)?["extensionHostPath"]) is not string path || !File.Exists(path)) continue;
            foreach (var name in (entry["nativeHostNames"] as JsonArray ?? new JsonArray()).Select(Str).OfType<string>())
                hosts[name] = path;
        }
        return hosts;
    }

    /// <summary>The manifests of these hosts: ChatGPT's own folder, and wherever a browser's registry key points.</summary>
    public static List<string> Manifests(Layout layout, IEnumerable<string> hostNames)
    {
        var found = new List<string>();
        foreach (string name in hostNames)
        {
            var candidates = new List<string> { Path.Combine(ManifestFolder(layout), name + ".json") };
            foreach (string key in layout.NativeHostKeys)
            {
                try
                {
                    using var sub = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(key + "\\" + name);
                    if (sub?.GetValue(null) is string path && path.Length > 0) candidates.Add(path);
                }
                catch { }
            }
            foreach (string path in candidates)
                if (File.Exists(path) && !found.Any(f => Files.Normalize(f).Equals(Files.Normalize(path), StringComparison.OrdinalIgnoreCase)))
                    found.Add(path);
        }
        return found;
    }

    static bool IsOurs(string path, Layout layout) => path.Length > 0 && Files.IsInside(path, layout.Home);

    /// <summary>Puts the main ChatGPT back in charge of the extension. Returns what it changed, one line each.</summary>
    public static List<string> KeepWithMain(Layout layout)
    {
        var changes = new List<string>();
        var hosts = MainHosts(layout);
        if (hosts.Count == 0) return changes;
        int fixedCount = 0, removed = 0;
        foreach (string manifest in Manifests(layout, hosts.Keys))
        {
            if (Files.ReadJson(manifest) is not JsonObject json) continue;
            if (Str(json["name"]) is not string name || !hosts.TryGetValue(name, out var mainHost)) continue;
            if (Str(json["path"]) is not string path || !IsOurs(path, layout)) continue;
            json["path"] = mainHost;
            try { Files.WriteJson(json, manifest); fixedCount++; }
            catch (Exception e) { changes.Add($"Couldn't fix {manifest}: {e.Message}"); }
        }
        string registry = SharedRegistry(layout);
        if (Files.ReadJson(registry) is JsonObject shared && shared["entries"] is JsonArray all)
        {
            var kept = all.Where(entry => !IsOurs(Str((entry?["paths"] as JsonObject)?["codexHome"]) ?? "", layout)).ToList();
            if (kept.Count != all.Count)
            {
                var copy = new JsonArray();
                foreach (var entry in kept) copy.Add(entry?.DeepClone());
                shared["entries"] = copy;
                try { Files.WriteJson(shared, registry); removed = all.Count - kept.Count; }
                catch (Exception e) { changes.Add($"Couldn't update {registry}: {e.Message}"); }
            }
        }
        if (fixedCount + removed > 0)
        {
            static string Count(int n, string one, string many) => $"{n} {(n == 1 ? one : many)}";
            var parts = new List<string>();
            if (fixedCount > 0) parts.Add(Count(fixedCount, "browser manifest", "browser manifests"));
            if (removed > 0) parts.Add(Count(removed, "account entry", "account entries") + " in the shared registry");
            changes.Insert(0, $"Gave ChatGPT's browser extension back to the main ChatGPT ({string.Join(", ", parts)})");
        }
        return changes;
    }

    /// <summary>Whether every manifest of the main ChatGPT's hosts points at it; null when it isn't set up.</summary>
    public static bool? IsWithMain(Layout layout)
    {
        var hosts = MainHosts(layout);
        if (hosts.Count == 0) return null;
        return Manifests(layout, hosts.Keys).All(m => Str(Files.ReadJson(m)?["path"]) is not string path || !IsOurs(path, layout));
    }

    static string? Str(JsonNode? node)
    {
        try { return node?.GetValue<string>(); }
        catch { return null; }
    }
}
