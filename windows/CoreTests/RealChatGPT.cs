using ChatGPTMultiAccounts.Core;

/// <summary>Checks the real ChatGPT on this PC without touching the main ChatGPT: adds two throwaway accounts in a
/// temporary folder, opens both at once, brings one forward, closes both and removes them.
/// Run: dotnet run --project windows\CoreTests -- --real</summary>
static class RealChatGPT
{
    public static int Run()
    {
        var system = Layout.System();
        string root = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".cma-real-" + Guid.NewGuid().ToString("N")[..6]);
        var layout = new Layout
        {
            MainCodexHome = system.MainCodexHome, MainData = system.MainData, Launcher = system.Launcher,
            LocalAppData = system.LocalAppData, NativeHostKeys = system.NativeHostKeys,
            Home = Path.Combine(root, "home"), Trash = Path.Combine(root, "trash"),
        };
        var control = new SystemChatGPTControl(layout);
        var manager = new AccountManager(layout, control);
        bool ok = true;
        void Say(bool good, string what) { ok &= good; Console.WriteLine($"  {(good ? "ok  " : "FAIL")} {what}"); }

        var main = manager.MainState();
        Console.WriteLine($"Launcher:     {layout.Launcher} (installed: {control.Installed})");
        Console.WriteLine($"Main ChatGPT: pid {main.Pid?.ToString() ?? "-"}, signed in: {(main.SignIn != null ? manager.Describe(main.SignIn) : "no")}");
        Console.WriteLine($"Extension:    {BrowserExtension.IsWithMain(layout)?.ToString() ?? "not set up"} (with main)");
        if (!control.Installed) return 1;
        try
        {
            var a = manager.Add("Probe A");
            var b = manager.Add("Probe B");
            var snap = manager.Snapshot();
            Say(snap.Accounts.All(s => s.IsOpen && !s.IsSignedIn), $"two copies open at the sign-in screen (pids {string.Join(", ", snap.Accounts.Select(s => s.Pid))})");
            Say(manager.MainState().Pid == main.Pid, $"the main ChatGPT is as it was (pid {main.Pid?.ToString() ?? "-"})");
            Thread.Sleep(8000);
            Say(Directory.EnumerateFileSystemEntries(layout.CodexHome(a)).Any(), "copy A uses its own CODEX_HOME");
            int? pidA = snap.Accounts[0].Pid;
            manager.Open("Probe A");
            Thread.Sleep(3000);
            Say(manager.Snapshot().Accounts[0].Pid == pidA, "bringing A forward kept the same copy");
            var started = DateTime.UtcNow;
            Console.WriteLine("  " + manager.CloseAll());
            Say(manager.Snapshot().OpenAccounts.Count == 0, $"both closed in {(DateTime.UtcNow - started).TotalSeconds:0.0} s");
            Say(manager.MainState().Pid == main.Pid, "the main ChatGPT is still as it was");
            Say(manager.KeepBrowserExtensionWithMain().Count == 0, "the browser extension needed no fix");
            manager.Remove("Probe A");
            manager.Remove("Probe B");
            Say(manager.Snapshot().Accounts.Count == 0, "both removed");
        }
        catch (Exception e)
        {
            Say(false, e.Message);
            try { manager.CloseAll(); } catch { }
        }
        finally
        {
            try { Directory.Delete(root, recursive: true); } catch (Exception e) { Console.WriteLine($"  (left {root}: {e.Message})"); }
        }
        Console.WriteLine(ok ? "Real ChatGPT: all good" : "Real ChatGPT: problems above");
        return ok ? 0 : 1;
    }
}
