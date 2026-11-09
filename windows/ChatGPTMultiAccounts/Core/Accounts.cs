using System.Globalization;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.Json.Serialization;

namespace ChatGPTMultiAccounts.Core;

/// <summary>An extra ChatGPT account. Its sign-in, chats and window data live in its own folder (see
/// <see cref="Layout"/>), where its own copy of ChatGPT runs.</summary>
public sealed class Account
{
    /// <summary>The account folder's name: six lowercase letters and digits.</summary>
    [JsonPropertyName("id")] public string Id { get; set; } = "";
    /// <summary>The name chosen for it. Null until one is chosen: the list then shows its email.</summary>
    [JsonPropertyName("name"), JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? Name { get; set; }
    /// <summary>When it was added, in local time ("2026-10-22T09:30:00").</summary>
    [JsonPropertyName("addedAt"), JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? AddedAt { get; set; }

    public Account Clone() => (Account)MemberwiseClone();

    /// <summary>A new folder name that isn't taken in <paramref name="home"/>.</summary>
    public static string NewId(string home)
    {
        const string alphabet = "abcdefghijkmnpqrstuvwxyz23456789";
        while (true)
        {
            string id = string.Concat(Enumerable.Range(0, 6).Select(_ => alphabet[Random.Shared.Next(alphabet.Length)]));
            if (!Files.Exists(Path.Combine(home, id))) return id;
        }
    }
}

/// <summary>accounts.json: the names and order of the accounts. Same file format as the macOS app.</summary>
public static class Registry
{
    public const string Format = "yyyy-MM-dd'T'HH:mm:ss";

    sealed class FileShape
    {
        [JsonPropertyName("version")] public int Version { get; set; } = 1;
        [JsonPropertyName("accounts")] public List<Account> Accounts { get; set; } = new();
    }

    static readonly JsonSerializerOptions Options = new()
    {
        WriteIndented = true, Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
    };

    public static List<Account> Load(string path)
    {
        if (!File.Exists(path)) return new();
        return JsonSerializer.Deserialize<FileShape>(File.ReadAllText(path))?.Accounts ?? new();
    }

    public static void Save(List<Account> accounts, string path) =>
        Files.WriteAtomically(path, JsonSerializer.Serialize(new FileShape { Accounts = accounts }, Options));

    public static string Now() => DateTime.Now.ToString(Format, CultureInfo.InvariantCulture);
}

public static class Files
{
    /// <summary>Writes a file atomically: a temporary file next to it, then a replace.</summary>
    public static void WriteAtomically(string path, string text)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        string tmp = Path.Combine(Path.GetDirectoryName(path)!, $".{Path.GetFileName(path)}.{Environment.ProcessId}.tmp");
        using (var stream = new FileStream(tmp, FileMode.Create, FileAccess.Write, FileShare.None))
        using (var writer = new StreamWriter(stream, new System.Text.UTF8Encoding(false)))
        {
            writer.Write(text);
            writer.Flush();
            stream.Flush(true);
        }
        File.Move(tmp, path, overwrite: true);
    }

    public static bool Exists(string path) => File.Exists(path) || Directory.Exists(path);

    /// <summary>A JSON object from a file, or null when it is missing or isn't one.</summary>
    public static JsonObject? ReadJson(string path)
    {
        try { return JsonNode.Parse(File.ReadAllText(path)) as JsonObject; }
        catch { return null; }
    }

    public static void WriteJson(JsonObject json, string path) =>
        WriteAtomically(path, json.ToJsonString(new JsonSerializerOptions
        {
            WriteIndented = true, Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
        }) + "\n");

    public static long FolderSize(string path)
    {
        long total = 0;
        try
        {
            foreach (var f in new DirectoryInfo(path).EnumerateFiles("*", new EnumerationOptions
                     { RecurseSubdirectories = true, IgnoreInaccessible = true, AttributesToSkip = FileAttributes.ReparsePoint }))
                total += f.Length;
        }
        catch { }
        return total;
    }

    public static string FormatSize(long bytes)
    {
        string[] units = { "bytes", "KB", "MB", "GB", "TB" };
        double v = bytes; int i = 0;
        while (v >= 1000 && i < units.Length - 1) { v /= 1000; i++; }
        return i == 0 ? $"{bytes} bytes" : v >= 100 ? $"{v:0} {units[i]}" : $"{v:0.#} {units[i]}";
    }

    /// <summary>A full path with one kind of separator and no trailing one, for comparing folders.</summary>
    public static string Normalize(string path)
    {
        try { path = Path.GetFullPath(path.Trim().Trim('"')); } catch { }
        return path.Replace('/', '\\').TrimEnd('\\');
    }

    /// <summary>Whether <paramref name="path"/> is <paramref name="folder"/> or inside it, ignoring case.</summary>
    public static bool IsInside(string path, string folder)
    {
        string p = Normalize(path), f = Normalize(folder);
        return p.Equals(f, StringComparison.OrdinalIgnoreCase) || p.StartsWith(f + "\\", StringComparison.OrdinalIgnoreCase);
    }
}

/// <summary>Something that can't be done, said so the person knows what to do next.</summary>
public sealed class MultiException : Exception
{
    public MultiException(string message) : base(message) { }
}
