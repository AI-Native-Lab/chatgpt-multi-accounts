using System.Diagnostics;
using System.Management;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;

namespace ChatGPTMultiAccounts.Core;

/// <summary>Everything the account manager needs from the running system. Tests swap in a pretend ChatGPT.</summary>
public interface IChatGPTControl
{
    bool Installed { get; }
    /// <summary>The main ChatGPT: the copy running on ChatGPT's own folders.</summary>
    int? MainPid();
    /// <summary>The copy of ChatGPT running on an account's window data folder, if one runs.</summary>
    int? PidUsing(string dataFolder);
    /// <summary>Whether any copy of ChatGPT runs, the main one or an account's.</summary>
    bool AnyInstanceRunning();
    /// <summary>Asks one copy of ChatGPT to quit, as Windows does when it signs out, and waits until it and its
    /// helpers have. False when it is still running after <paramref name="timeout"/>. Never force-quits.</summary>
    bool Quit(int pid, TimeSpan timeout);
    /// <summary>Starts the main ChatGPT, or brings it forward when it runs.</summary>
    void LaunchMain();
    /// <summary>Starts another copy of ChatGPT on an account's folders, or brings that copy forward when it runs.</summary>
    void LaunchAccount(string codexHome, string dataFolder);
    /// <summary>Restores and raises a running copy's window, as far as Windows lets a background app do that.</summary>
    void BringForward(int pid);
}

/// <summary>The real ChatGPT on this PC.
///
/// ChatGPT takes a single-instance lock in its window data folder. It runs on other folders when told so with
/// <c>CODEX_HOME</c>, <c>CODEX_ELECTRON_USER_DATA_PATH</c> and Chromium's <c>--user-data-dir</c>, so the main
/// ChatGPT is the copy started without <c>--user-data-dir</c>, and an account's copy is the one whose switch names
/// that account's folder.</summary>
public sealed class SystemChatGPTControl : IChatGPTControl
{
    readonly Layout layout;
    readonly string mainData;

    public SystemChatGPTControl(Layout layout)
    {
        this.layout = layout;
        mainData = Files.Normalize(layout.MainData);
    }

    public bool Installed => layout.Launcher != null && File.Exists(layout.Launcher);

    sealed record ChatGPTProcess(int Pid, string? DataFolder, bool IsHelper)
    {
        public bool IsMainIn(string mainData) => DataFolder == null || DataFolder.Equals(mainData, StringComparison.OrdinalIgnoreCase);
    }

    // Quoted as a whole ("--user-data-dir=C:\a b"), quoted after the = (--user-data-dir="C:\a b"), or plain.
    static readonly Regex[] DataDirArgs =
    {
        new(@"""--user-data-dir=([^""]+)""", RegexOptions.Compiled),
        new(@"--user-data-dir=""([^""]+)""", RegexOptions.Compiled),
        new(@"--user-data-dir=(\S+)", RegexOptions.Compiled),
    };

    public static string? DataFolderIn(string commandLine)
    {
        foreach (var regex in DataDirArgs)
            if (regex.Match(commandLine) is { Success: true } m) return m.Groups[1].Value;
        return null;
    }

    // Reading every process's command line takes a moment; answers within half a second are reused.
    List<ChatGPTProcess>? cache;
    DateTime cachedAt;
    readonly object gate = new();

    List<ChatGPTProcess> Processes(bool fresh = false)
    {
        lock (gate)
        {
            if (!fresh && cache != null && DateTime.UtcNow - cachedAt < TimeSpan.FromMilliseconds(500)) return cache;
            var list = new List<ChatGPTProcess>();
            using var searcher = new ManagementObjectSearcher(
                $"SELECT ProcessId, ExecutablePath, CommandLine FROM Win32_Process WHERE Name = '{ChatGPTApp.Executable}'");
            foreach (ManagementObject p in searcher.Get())
            {
                using (p)
                {
                    string exe = p["ExecutablePath"] as string ?? "";
                    string cmd = p["CommandLine"] as string ?? "";
                    // Only the ChatGPT app that includes Codex (the older ChatGPT app has another package).
                    if (!exe.Contains($@"\{ChatGPTApp.PackageName}_", StringComparison.OrdinalIgnoreCase)) continue;
                    string? raw = DataFolderIn(cmd);
                    list.Add(new ChatGPTProcess(Convert.ToInt32(p["ProcessId"]), raw == null ? null : Files.Normalize(raw),
                        cmd.Contains("--type=", StringComparison.Ordinal)));
                }
            }
            cache = list;
            cachedAt = DateTime.UtcNow;
            return list;
        }
    }

    public int? MainPid() => Processes().FirstOrDefault(p => !p.IsHelper && p.IsMainIn(mainData))?.Pid;

    public int? PidUsing(string dataFolder)
    {
        string folder = Files.Normalize(dataFolder);
        if (folder.Equals(mainData, StringComparison.OrdinalIgnoreCase)) return MainPid();
        return Processes().FirstOrDefault(p => !p.IsHelper && folder.Equals(p.DataFolder, StringComparison.OrdinalIgnoreCase))?.Pid;
    }

    public bool AnyInstanceRunning() => Processes().Count > 0;

    public bool Quit(int pid, TimeSpan timeout)
    {
        var target = Processes(fresh: true).FirstOrDefault(p => p.Pid == pid);
        if (target == null) return true;
        bool isMain = target.IsMainIn(mainData);
        // Chromium quits like File > Exit when Windows says the session ends for this app. Closing the window would
        // only hide ChatGPT in the notification area.
        var windows = Native.TopLevelWindows(pid).Where(h => Native.ClassName(h) == "Chrome_WidgetWin_1").ToList();
        if (windows.Count == 0) return false;
        foreach (var h in windows)
            Native.SendMessageTimeout(h, Native.WM_QUERYENDSESSION, IntPtr.Zero, (IntPtr)Native.ENDSESSION_CLOSEAPP, Native.SMTO_ABORTIFHUNG, 5000, out _);
        foreach (var h in windows)
            Native.SendMessageTimeout(h, Native.WM_ENDSESSION, (IntPtr)1, (IntPtr)Native.ENDSESSION_CLOSEAPP, Native.SMTO_ABORTIFHUNG, 5000, out _);
        var deadline = DateTime.UtcNow + timeout;
        while (DateTime.UtcNow < deadline)
        {
            var all = Processes(fresh: true);
            bool alive = all.Any(p => p.Pid == pid);
            // Its helpers (GPU, network, renderers) name the same folder; wait for them too.
            bool helpers = all.Any(p => p.IsHelper && (isMain ? p.IsMainIn(mainData)
                : target.DataFolder!.Equals(p.DataFolder, StringComparison.OrdinalIgnoreCase)));
            if (!alive && !helpers) return true;
            Thread.Sleep(300);
        }
        return false;
    }

    public void LaunchMain() => Start(LaunchInfo());

    public void LaunchAccount(string codexHome, string dataFolder)
    {
        var info = LaunchInfo();
        info.Environment[ChatGPTApp.CodexHomeVariable] = codexHome;
        info.Environment[ChatGPTApp.UserDataVariable] = dataFolder;
        info.Environment[ChatGPTApp.UpdaterVariable] = "false";
        info.ArgumentList.Add(ChatGPTApp.UserDataSwitch + dataFolder);
        Start(info);
    }

    /// <summary>ChatGPT hands its environment to its terminals and tools. Keep out this tool's own variables,
    /// ChatGPT's (when this runs in one of its terminals, they name that copy's folders) and Electron's
    /// (ELECTRON_RUN_AS_NODE, set in an editor's terminal, would stop ChatGPT from opening a window).</summary>
    ProcessStartInfo LaunchInfo()
    {
        var info = new ProcessStartInfo(Launcher())
        {
            UseShellExecute = false,
            WorkingDirectory = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
        };
        foreach (var key in info.Environment.Keys.ToList())
            if (new[] { "CMA_", "CODEX_", "ELECTRON_" }.Any(p => key.StartsWith(p, StringComparison.OrdinalIgnoreCase)))
                info.Environment.Remove(key);
        return info;
    }

    public void BringForward(int pid)
    {
        foreach (var h in Native.TopLevelWindows(pid).Where(h => Native.ClassName(h) == "Chrome_WidgetWin_1" && Native.IsWindowVisible(h)))
        {
            if (Native.IsIconic(h)) Native.ShowWindow(h, Native.SW_RESTORE);
            Native.SetForegroundWindow(h);
        }
    }

    string Launcher()
    {
        if (!Installed) throw new MultiException("ChatGPT for Windows isn't installed. Install the ChatGPT desktop app from the Microsoft Store (chatgpt.com/download) and open it once.");
        return layout.Launcher!;
    }

    void Start(ProcessStartInfo info)
    {
        try { using var _ = Process.Start(info); }
        catch (Exception e) { throw new MultiException($"Couldn't open ChatGPT: {e.Message}"); }
        lock (gate) cache = null;
    }
}

static class Native
{
    public const uint WM_QUERYENDSESSION = 0x0011, WM_ENDSESSION = 0x0016, SMTO_ABORTIFHUNG = 0x0002;
    public const int ENDSESSION_CLOSEAPP = 0x00000001, SW_RESTORE = 9;

    delegate bool EnumProc(IntPtr hwnd, IntPtr lParam);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc proc, IntPtr lParam);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr hwnd, StringBuilder name, int max);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hwnd);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hwnd);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hwnd, int cmd);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hwnd);
    [DllImport("user32.dll")]
    public static extern IntPtr SendMessageTimeout(IntPtr hwnd, uint msg, IntPtr wParam, IntPtr lParam, uint flags, uint timeout, out IntPtr result);

    public static List<IntPtr> TopLevelWindows(int pid)
    {
        var found = new List<IntPtr>();
        EnumWindows((h, _) =>
        {
            GetWindowThreadProcessId(h, out uint owner);
            if (owner == pid) found.Add(h);
            return true;
        }, IntPtr.Zero);
        return found;
    }

    public static string ClassName(IntPtr hwnd)
    {
        var sb = new StringBuilder(256);
        GetClassName(hwnd, sb, sb.Capacity);
        return sb.ToString();
    }
}
