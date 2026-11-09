namespace ChatGPTMultiAccounts.Core;

/// <summary>Where ChatGPT and the accounts live on disk.
///
/// The main ChatGPT keeps its sign-in, chats and settings in <c>%USERPROFILE%\.codex</c> and its window data in
/// <c>%APPDATA%\Codex</c>. This tool never changes either. Each extra account gets its own pair of folders under
/// <c>&lt;home&gt;\&lt;id&gt;\</c>, and its own copy of ChatGPT runs on them:
/// <code>
///   &lt;home&gt;\&lt;id&gt;\codex   the account's CODEX_HOME: sign-in (auth.json), chats, settings
///   &lt;home&gt;\&lt;id&gt;\data    the account's window data: cookies, caches (Chromium's user data)
/// </code></summary>
public sealed class Layout
{
    /// <summary>The main ChatGPT's CODEX_HOME.</summary>
    public string MainCodexHome { get; init; } = "";
    /// <summary>The main ChatGPT's window data. Only used to recognise the main ChatGPT.</summary>
    public string MainData { get; init; } = "";
    /// <summary>This tool's folder: the account list, every account's folders and the activity log.</summary>
    public string Home { get; init; } = "";
    /// <summary>What starts ChatGPT: the Microsoft Store app's execution alias.</summary>
    public string? Launcher { get; init; }
    /// <summary>%LOCALAPPDATA%, where ChatGPT keeps its browser extension's manifest and shared registry.</summary>
    public string LocalAppData { get; init; } = "";
    /// <summary>The registry keys (under HKEY_CURRENT_USER) where browsers look for native-messaging hosts. Empty in
    /// tests, so they never read the real registry.</summary>
    public string[] NativeHostKeys { get; init; } = Array.Empty<string>();
    /// <summary>Where removed account folders go. Null means the Recycle Bin.</summary>
    public string? Trash { get; init; }

    public string AccountsFile => Path.Combine(Home, "accounts.json");
    public string LogFile => Path.Combine(Home, "activity.log");
    public string SettingsFile => Path.Combine(Home, "settings.json");
    public string LockFile => Path.Combine(Home, ".lock");

    /// <summary>An account's folder, holding its <c>codex</c> and <c>data</c> folders.</summary>
    public string Folder(Account account) => Path.Combine(Home, account.Id);
    /// <summary>The account's CODEX_HOME.</summary>
    public string CodexHome(Account account) => Path.Combine(Folder(account), "codex");
    /// <summary>The account's window data, ChatGPT's --user-data-dir.</summary>
    public string DataFolder(Account account) => Path.Combine(Folder(account), "data");

    /// <summary>The real layout of the current user. <c>CMA_HOME</c>, <c>CMA_MAIN_CODEX_HOME</c>,
    /// <c>CMA_MAIN_DATA</c> and <c>CMA_APP</c> point it elsewhere.</summary>
    public static Layout System()
    {
        string profile = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        string roaming = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
        string local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        string Env(string key, string fallback) =>
            Environment.GetEnvironmentVariable(key) is { Length: > 0 } v ? Environment.ExpandEnvironmentVariables(v) : fallback;

        // ChatGPT (Owl) keeps the main window data in %APPDATA%\Codex\web\Codex; older builds used %APPDATA%\Codex.
        string data = Path.Combine(roaming, "Codex", "web", "Codex");
        if (!Directory.Exists(data)) data = Path.Combine(roaming, "Codex");
        return new Layout
        {
            MainCodexHome = Env("CMA_MAIN_CODEX_HOME", Path.Combine(profile, ".codex")),
            MainData = Env("CMA_MAIN_DATA", data),
            Home = Env("CMA_HOME", Path.Combine(profile, ".chatgpt-multi-accounts")),
            Launcher = Env("CMA_APP", Path.Combine(local, "Microsoft", "WindowsApps", ChatGPTApp.ExecutionAlias)),
            LocalAppData = local,
            NativeHostKeys = BrowserExtension.BrowserKeys,
        };
    }
}

public static class ChatGPTApp
{
    /// <summary>The ChatGPT desktop app that includes Codex, from the Microsoft Store (package OpenAI.Codex).</summary>
    public const string PackageName = "OpenAI.Codex";
    /// <summary>The command the Store app registers to start it.</summary>
    public const string ExecutionAlias = "chatgpt-desktop.exe";
    /// <summary>Its main executable; its helpers (GPU, renderers…) run the same file with --type=.</summary>
    public const string Executable = "ChatGPT.exe";
    /// <summary>Chromium's switch for the window data folder. Without it, a second copy hands itself over to the
    /// copy already running and exits.</summary>
    public const string UserDataSwitch = "--user-data-dir=";
    /// <summary>ChatGPT's own variables for running on other folders: it then keeps its single-instance lock in that
    /// folder, so copies on different folders run side by side.</summary>
    public const string UserDataVariable = "CODEX_ELECTRON_USER_DATA_PATH";
    public const string CodexHomeVariable = "CODEX_HOME";
    /// <summary>Only the main ChatGPT checks for updates; the copies run the same app.</summary>
    public const string UpdaterVariable = "CODEX_SPARKLE_ENABLED";
}
