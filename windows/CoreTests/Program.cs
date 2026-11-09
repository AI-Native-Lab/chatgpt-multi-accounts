// End-to-end checks of the account rules against a pretend ChatGPT, in a temporary folder.
// Run: dotnet run --project windows\CoreTests
using System.Text;
using System.Text.Json.Nodes;
using ChatGPTMultiAccounts.Core;

if (args.Contains("--real")) return RealChatGPT.Run();

int failures = 0, passed = 0;
void Check(bool ok, string what)
{
    if (ok) { passed++; Console.WriteLine($"  ok   {what}"); }
    else { failures++; Console.WriteLine($"  FAIL {what}"); }
}
void Throws(Action action, string contains, string what)
{
    try { action(); Check(false, what + " (didn't refuse)"); }
    catch (MultiException e) { Check(e.Message.Contains(contains, StringComparison.OrdinalIgnoreCase), $"{what}: {e.Message}"); }
}

string root = Path.Combine(Path.GetTempPath(), "cma-tests-" + Guid.NewGuid().ToString("N")[..8]);
var layout = new Layout
{
    MainCodexHome = Path.Combine(root, "main-codex"), MainData = Path.Combine(root, "main-data"),
    Home = Path.Combine(root, "home"), Launcher = "fake", LocalAppData = Path.Combine(root, "local"),
    Trash = Path.Combine(root, "trash"),
};
var fake = new FakeChatGPT(layout);
var manager = new AccountManager(layout, fake) { LaunchSpacing = TimeSpan.Zero, LaunchTimeout = TimeSpan.FromMilliseconds(100) };

Directory.CreateDirectory(layout.MainCodexHome);
Fake.SignIn(layout.MainCodexHome, "me@example.com", "user-main", "ws-personal", "plus");
fake.MainRunning = true;

try
{
    Console.WriteLine("Reading");
    var snap = manager.Snapshot();
    Check(snap.Main.Running && snap.Main.SignIn?.Email == "me@example.com", "main is running, signed in to me@example.com");
    Check(snap.Main.SignIn?.PlanName == "Plus", "plan read from the ID token");
    Check(snap.Accounts.Count == 0 && snap.OpenCount == 1, "no extra accounts yet, one open");

    Console.WriteLine("Adding");
    var work = manager.Add("Work");
    Check(Directory.Exists(layout.CodexHome(work)) && Directory.Exists(layout.DataFolder(work)), "the account's codex and data folders exist");
    var launch = fake.Launches.Last();
    Check(launch.CodexHome == layout.CodexHome(work) && launch.Data == layout.DataFolder(work), "its copy started on its own folders");
    snap = manager.Snapshot();
    Check(snap.Accounts.Single().IsOpen && !snap.Accounts.Single().IsSignedIn, "it is open at the sign-in screen");
    Check(snap.OpenCount == 2 && fake.MainRunning, "the main ChatGPT keeps running next to it");
    Check(File.ReadAllText(layout.AccountsFile).Contains("\"name\": \"Work\""), "accounts.json has its name");
    Throws(() => manager.Add("work"), "already called", "a second “work” is refused");

    Fake.SignIn(layout.CodexHome(work), "me@work.example", "user-work", "ws-team", "team");
    snap = manager.Snapshot();
    Check(snap.Accounts.Single().SignIn?.Email == "me@work.example" && snap.Accounts.Single().SameAs == null, "it signed in to another account");

    var unnamed = manager.Add(null);
    Fake.SignIn(layout.CodexHome(unnamed), "me@example.com", "user-main", "ws-personal", "plus");
    snap = manager.Snapshot();
    var second = snap.Accounts[1];
    Check(second.DisplayName == "me@example.com", "an unnamed account shows its email");
    Check(second.SameAs == "the main ChatGPT", "signing in to the main account again is flagged");
    Check(manager.Find("2").Id == unnamed.Id && manager.Find("ME@WORK.EXAMPLE").Id == work.Id && manager.Find("work").Id == work.Id,
        "found by number, email and name");
    Throws(() => manager.Find("nobody"), "No account matches", "an unknown account is refused");

    Console.WriteLine("Opening and closing");
    int launches = fake.Launches.Count, raised = fake.Raised.Count;
    manager.Open("Work");
    Check(fake.Raised.Count == raised + 1 && fake.Launches.Count == launches + 1 && fake.Running.Count == 2,
        "opening an open account raises it and hands a start to it, without a second copy");
    Check(fake.Launches.Last().CodexHome == layout.CodexHome(work), "…on its own CODEX_HOME");
    Check(manager.Close("Work").Contains("Closed"), "closing it");
    Check(!manager.Snapshot().Accounts[0].IsOpen && fake.MainRunning, "it is closed, the main ChatGPT still runs");
    Check(manager.Snapshot().Accounts[0].IsSignedIn, "and stays signed in");
    Check(manager.Close("Work").Contains("isn't open"), "closing it again says so");

    manager.Close("2");
    fake.MainRunning = false;
    string all = manager.OpenAll();
    snap = manager.Snapshot();
    Check(snap.OpenCount == 3 && fake.MainRunning, $"Open All opens the main ChatGPT and both accounts ({all})");
    Check(manager.OpenAll().Contains("already open"), "Open All again has nothing to do");

    fake.Stuck.Add(layout.DataFolder(unnamed));
    Throws(() => manager.CloseAll(), "didn't quit", "a copy that doesn't quit is reported");
    fake.Stuck.Clear();
    manager.CloseAll();
    snap = manager.Snapshot();
    Check(snap.OpenCount == 1 && snap.Main.Running, "Close All leaves only the main ChatGPT");

    fake.FailToStart = true;
    Throws(() => manager.Open("Work"), "didn't start", "a copy that never shows is reported");
    fake.FailToStart = false;

    Console.WriteLine("The browser extension");
    string mainHost = Path.Combine(layout.MainCodexHome, @"plugins\cache\chrome\extension-host.exe");
    string workHost = Path.Combine(layout.CodexHome(work), @"plugins\cache\chrome\extension-host.exe");
    foreach (var host in new[] { mainHost, workHost }) { Directory.CreateDirectory(Path.GetDirectoryName(host)!); File.WriteAllText(host, ""); }
    Check(manager.KeepBrowserExtensionWithMain().Count == 0 && BrowserExtension.IsWithMain(layout) == null,
        "nothing changes while the main ChatGPT hasn't set the extension up");
    Fake.WriteHostRegistry(Path.Combine(layout.MainCodexHome, BrowserExtension.RegistryFile), (layout.MainCodexHome, mainHost));
    string manifest = Path.Combine(BrowserExtension.ManifestFolder(layout), "com.openai.codexextension.json");
    Fake.WriteManifest(manifest, workHost);
    Fake.WriteHostRegistry(BrowserExtension.SharedRegistry(layout), (layout.MainCodexHome, mainHost), (layout.CodexHome(work), workHost));
    Check(BrowserExtension.IsWithMain(layout) == false, "an account's copy took the extension over");
    var changes = manager.KeepBrowserExtensionWithMain();
    Check(changes.Count == 1 && changes[0].Contains("1 browser manifest") && changes[0].Contains("1 account entry"), $"fixed: {changes.FirstOrDefault()}");
    var fixedManifest = Files.ReadJson(manifest)!;
    Check(fixedManifest["path"]!.GetValue<string>() == mainHost && fixedManifest["allowed_origins"] is JsonArray, "the manifest points at the main host again, the rest kept");
    var shared = Files.ReadJson(BrowserExtension.SharedRegistry(layout))!["entries"]!.AsArray();
    Check(shared.Count == 1 && shared[0]!["paths"]!["codexHome"]!.GetValue<string>() == layout.MainCodexHome, "only the main ChatGPT stays in the shared registry");
    Check(BrowserExtension.IsWithMain(layout) == true && manager.KeepBrowserExtensionWithMain().Count == 0, "then nothing more to do");

    Console.WriteLine("Command lines");
    Check(SystemChatGPTControl.DataFolderIn(@"""C:\x\ChatGPT.exe"" --user-data-dir=C:\a\data --flag") == @"C:\a\data", "plain switch");
    Check(SystemChatGPTControl.DataFolderIn(@"x.exe --type=gpu ""--user-data-dir=C:\John Doe\data"" --x") == @"C:\John Doe\data", "switch quoted as a whole");
    Check(SystemChatGPTControl.DataFolderIn(@"x.exe --type=renderer --user-data-dir=""C:\John Doe\data"" --x") == @"C:\John Doe\data", "path quoted after =");
    Check(SystemChatGPTControl.DataFolderIn(@"x.exe --no-sandbox") == null, "no switch: the main ChatGPT");

    Console.WriteLine("The list");
    manager.Rename("me@example.com", "Personal again");
    Check(manager.Snapshot().Accounts[1].DisplayName == "Personal again", "renamed");
    manager.Open("Work");
    Throws(() => manager.Remove("Work"), "is open", "an open account can't be removed");
    manager.Close("Work");
    manager.Remove("Work");
    Check(!Directory.Exists(layout.Folder(work)) && Directory.EnumerateDirectories(layout.Trash!).Any(d => Path.GetFileName(d).StartsWith(work.Id)),
        "its folder went to the trash");
    Check(manager.Snapshot().Accounts.Count == 1 && Directory.Exists(layout.MainCodexHome), "the other account and the main ChatGPT are untouched");
    Check(File.ReadAllText(layout.LogFile).Contains("Removed “Work”"), "the activity log records it");

    using (new FileStream(layout.LockFile, FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None))
        Throws(() => manager.Add("Busy"), "already running", "a change while another runs is refused");
}
finally
{
    try { Directory.Delete(root, recursive: true); } catch { }
}

Console.WriteLine($"\n{passed} passed, {failures} failed");
return failures == 0 ? 0 : 1;

/// <summary>A pretend ChatGPT: copies are entries in a list, keyed by their data folder.</summary>
sealed class FakeChatGPT : IChatGPTControl
{
    readonly Layout layout;
    public FakeChatGPT(Layout layout) => this.layout = layout;

    public readonly Dictionary<string, int> Running = new(StringComparer.OrdinalIgnoreCase);
    public readonly List<(string CodexHome, string Data)> Launches = new();
    public readonly List<int> Raised = new();
    public readonly HashSet<string> Stuck = new(StringComparer.OrdinalIgnoreCase);
    public bool FailToStart;
    int nextPid = 1000;
    const int MainPidValue = 999;

    public bool MainRunning { get; set; }
    public bool Installed => true;
    public int? MainPid() => MainRunning ? MainPidValue : null;
    public int? PidUsing(string dataFolder) => Running.TryGetValue(dataFolder, out int pid) ? pid : null;
    public bool AnyInstanceRunning() => MainRunning || Running.Count > 0;

    public bool Quit(int pid, TimeSpan timeout)
    {
        if (pid == MainPidValue) throw new InvalidOperationException("The main ChatGPT must never be quit.");
        var entry = Running.FirstOrDefault(e => e.Value == pid);
        if (entry.Key == null) return true;
        if (Stuck.Contains(entry.Key)) return false;
        Running.Remove(entry.Key);
        return true;
    }

    public void LaunchMain() => MainRunning = true;

    public void LaunchAccount(string codexHome, string dataFolder)
    {
        Launches.Add((codexHome, dataFolder));
        if (!FailToStart && !Running.ContainsKey(dataFolder)) Running[dataFolder] = nextPid++;
    }

    public void BringForward(int pid) => Raised.Add(pid);
}

static class Fake
{
    /// <summary>Writes an auth.json like ChatGPT's, with an unsigned ID token carrying these claims.</summary>
    public static void SignIn(string codexHome, string email, string userId, string workspace, string plan)
    {
        static string B64(string s) => Convert.ToBase64String(Encoding.UTF8.GetBytes(s)).TrimEnd('=').Replace('+', '-').Replace('/', '_');
        var claims = new JsonObject
        {
            ["email"] = email, ["sub"] = "auth0|" + userId,
            ["https://api.openai.com/auth"] = new JsonObject
            {
                ["chatgpt_plan_type"] = plan, ["chatgpt_user_id"] = userId, ["chatgpt_account_id"] = workspace,
            },
        };
        var auth = new JsonObject
        {
            ["auth_mode"] = "chatgpt", ["OPENAI_API_KEY"] = null,
            ["tokens"] = new JsonObject
            {
                ["id_token"] = $"{B64("{\"alg\":\"none\"}")}.{B64(claims.ToJsonString())}.sig",
                ["access_token"] = "secret-access", ["refresh_token"] = "secret-refresh", ["account_id"] = workspace,
            },
        };
        Directory.CreateDirectory(codexHome);
        Files.WriteJson(auth, Path.Combine(codexHome, ChatGPTMultiAccounts.Core.SignIn.File));
    }

    public static void WriteManifest(string path, string host)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        Files.WriteJson(new JsonObject
        {
            ["allowed_origins"] = new JsonArray("chrome-extension://abc/"), ["name"] = "com.openai.codexextension",
            ["path"] = host, ["type"] = "stdio",
        }, path);
    }

    public static void WriteHostRegistry(string path, params (string CodexHome, string Host)[] entries)
    {
        var list = new JsonArray();
        foreach (var (home, host) in entries)
            list.Add(new JsonObject
            {
                ["nativeHostNames"] = new JsonArray("com.openai.codexextension"),
                ["paths"] = new JsonObject { ["codexHome"] = home, ["extensionHostPath"] = host },
            });
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        Files.WriteJson(new JsonObject { ["schemaVersion"] = 2, ["entries"] = list }, path);
    }
}
