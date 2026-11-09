namespace ChatGPTMultiAccounts.Core;

/// <summary>An extra account and what it is doing now.</summary>
public sealed record AccountStatus(Account Account, int Number, int? Pid, SignIn? SignIn, string Folder)
{
    /// <summary>Where the same ChatGPT account is also signed in: "the main ChatGPT" or another account's name.
    /// Signing in twice to one account works, but is rarely what was meant.</summary>
    public string? SameAs { get; init; }
    public string Id => Account.Id;
    public bool IsOpen => Pid != null;
    public bool IsSignedIn => SignIn != null;
    /// <summary>The chosen name, else the email it signed in with.</summary>
    public string DisplayName => Account.Name ?? SignIn?.Email ?? $"New account {Number}";
}

/// <summary>The main ChatGPT: whether it runs and who it is signed in to.</summary>
public sealed record MainState(int? Pid, SignIn? SignIn, bool Installed)
{
    public bool Running => Pid != null;
    public string DisplayName => SignIn?.Email ?? "Main ChatGPT";
}

public sealed record Snapshot(MainState Main, List<AccountStatus> Accounts)
{
    /// <summary>How many ChatGPT accounts are open right now, the main one included.</summary>
    public int OpenCount => (Main.Running ? 1 : 0) + Accounts.Count(a => a.IsOpen);
    public List<AccountStatus> OpenAccounts => Accounts.Where(a => a.IsOpen).ToList();
    /// <summary>Accounts that can be opened with one click: signed in, and not open yet.</summary>
    public List<AccountStatus> ReadyToOpen => Accounts.Where(a => a.IsSignedIn && !a.IsOpen).ToList();
}

/// <summary>Adds, opens and closes ChatGPT accounts, each in its own copy of ChatGPT, all at the same time.
///
/// Rules that keep every sign-in and the main ChatGPT safe:
/// - The main ChatGPT's folders are only read, and the main ChatGPT is never quit or restarted.
/// - Each account signs in once, in its own copy of ChatGPT, on its own folders. Sign-ins are never copied between
///   folders, so no two copies ever share (and fight over) one set of tokens.
/// - Nothing is force-quit: closing an account is like Windows signing out of it. Nothing is sent to OpenAI.</summary>
public sealed class AccountManager
{
    public Layout Layout { get; }
    public TimeSpan QuitTimeout { get; set; } = TimeSpan.FromSeconds(30);
    /// <summary>How long a new copy may take to show up as a running process.</summary>
    public TimeSpan LaunchTimeout { get; set; } = TimeSpan.FromSeconds(20);
    /// <summary>Time between starting two copies with Open All, so they don't all load at once.</summary>
    public TimeSpan LaunchSpacing { get; set; } = TimeSpan.FromSeconds(1);

    readonly IChatGPTControl chatgpt;

    public AccountManager(Layout layout, IChatGPTControl? chatgpt = null)
    {
        Layout = layout;
        this.chatgpt = chatgpt ?? new SystemChatGPTControl(layout);
    }

    // MARK: Reading

    public List<Account> Accounts()
    {
        try { return Registry.Load(Layout.AccountsFile); }
        catch { return new(); }
    }

    public MainState MainState() => new(chatgpt.MainPid(), SignIn.Read(Layout.MainCodexHome), chatgpt.Installed);

    /// <summary>The main ChatGPT and every account, at once.</summary>
    public Snapshot Snapshot()
    {
        var main = MainState();
        var statuses = Accounts().Select((account, index) => new AccountStatus(account, index + 1,
            chatgpt.PidUsing(Layout.DataFolder(account)), SignIn.Read(Layout.CodexHome(account)), Layout.Folder(account))).ToList();
        for (int i = 0; i < statuses.Count; i++)
        {
            if (statuses[i].SignIn?.Identity is not string identity) continue;
            if (identity == main.SignIn?.Identity) statuses[i] = statuses[i] with { SameAs = "the main ChatGPT" };
            else if (statuses.Take(i).FirstOrDefault(s => s.SignIn?.Identity == identity) is AccountStatus earlier)
                statuses[i] = statuses[i] with { SameAs = $"“{earlier.DisplayName}”" };
        }
        return new Snapshot(main, statuses);
    }

    /// <summary>Finds an account by list number, name or email (ignoring case), or folder name.</summary>
    public AccountStatus Find(string query)
    {
        var statuses = Snapshot().Accounts;
        if (int.TryParse(query, out int number) && number >= 1 && number <= statuses.Count) return statuses[number - 1];
        var match = statuses.FirstOrDefault(s => new[] { s.Account.Name, s.SignIn?.Email, s.Account.Id, s.DisplayName }
            .Any(v => v != null && string.Equals(v, query, StringComparison.OrdinalIgnoreCase)));
        if (match != null) return match;
        string names = string.Join(", ", statuses.Select(s => $"{s.Number}. {s.DisplayName}"));
        throw new MultiException($"No account matches “{query}”. Accounts: {(names.Length == 0 ? "none yet" : names)}.");
    }

    public long? FolderSize(AccountStatus status) => Directory.Exists(status.Folder) ? Files.FolderSize(status.Folder) : null;

    // MARK: Opening and closing

    /// <summary>Adds an account: makes its folders and opens its own ChatGPT window at the sign-in screen, next to
    /// the main ChatGPT and any account already open. It is named after the email it signs in with unless
    /// <paramref name="name"/> is given.</summary>
    public Account Add(string? name) => WithLock(() =>
    {
        var accounts = Accounts();
        string? clean = string.IsNullOrWhiteSpace(name) ? null : ValidName(name, ignoring: null);
        RequireChatGPT();
        Directory.CreateDirectory(Layout.Home);
        var account = new Account { Id = Account.NewId(Layout.Home), Name = clean, AddedAt = Registry.Now() };
        Directory.CreateDirectory(Layout.CodexHome(account));
        Directory.CreateDirectory(Layout.DataFolder(account));
        accounts.Add(account);
        Registry.Save(accounts, Layout.AccountsFile);
        Log($"Added {(clean != null ? $"“{clean}”" : "a new account")} in {Layout.Folder(account)}");
        Launch(account, clean != null ? $"“{clean}”" : "The new account");
        return account;
    });

    /// <summary>Opens an account in its own ChatGPT window, or brings that window forward.</summary>
    public string Open(string query) => WithLock(() =>
    {
        var status = Find(query);
        if (status.Pid is int pid)
        {
            BringForward(status.Account, pid);
            return $"Brought “{status.DisplayName}” forward.";
        }
        Launch(status.Account, $"“{status.DisplayName}”");
        return status.IsSignedIn
            ? $"Opened “{status.DisplayName}” in its own ChatGPT window."
            : $"Opened “{status.DisplayName}” at ChatGPT's sign-in screen.";
    });

    /// <summary>Opens every signed-in account, and the main ChatGPT, so they all run at once.</summary>
    public string OpenAll(Action<string>? progress = null) => WithLock(() =>
    {
        var snapshot = Snapshot();
        var opened = new List<string>();
        if (!snapshot.Main.Running && snapshot.Main.Installed)
        {
            progress?.Invoke("Opening the main ChatGPT…");
            Log("Opening the main ChatGPT");
            chatgpt.LaunchMain();
            opened.Add("the main ChatGPT");
            Pause();
        }
        var ready = snapshot.ReadyToOpen;
        for (int i = 0; i < ready.Count; i++)
        {
            progress?.Invoke($"Opening “{ready[i].DisplayName}”…");
            Launch(ready[i].Account, $"“{ready[i].DisplayName}”");
            opened.Add($"“{ready[i].DisplayName}”");
            if (i < ready.Count - 1) Pause();
        }
        if (opened.Count == 0) return "Every signed-in account is already open.";
        return $"Opened {List(opened)}. {Snapshot().OpenCount} ChatGPT accounts are open at once.";
    });

    /// <summary>Quits an account's own ChatGPT window. Its sign-in stays in its folder.</summary>
    public string Close(string query)
    {
        var status = Find(query);
        if (status.Pid is not int pid) return $"“{status.DisplayName}” isn't open.";
        if (!chatgpt.Quit(pid, QuitTimeout)) throw DidNotQuit($"“{status.DisplayName}”");
        Log($"Closed “{status.DisplayName}”");
        return $"Closed “{status.DisplayName}”. It stays signed in, ready to open again.";
    }

    /// <summary>Closes every account's window. The main ChatGPT keeps running.</summary>
    public string CloseAll(Action<string>? progress = null)
    {
        var open = Snapshot().OpenAccounts;
        if (open.Count == 0) return "No account is open besides the main ChatGPT.";
        var stuck = new List<string>();
        foreach (var status in open)
        {
            progress?.Invoke($"Closing “{status.DisplayName}”…");
            if (status.Pid is int pid && !chatgpt.Quit(pid, QuitTimeout)) stuck.Add($"“{status.DisplayName}”");
        }
        Log($"Closed {open.Count - stuck.Count} account windows");
        if (stuck.Count > 0) throw DidNotQuit(List(stuck));
        return $"Closed {(open.Count == 1 ? "1 account" : $"{open.Count} accounts")}. The main ChatGPT keeps running.";
    }

    /// <summary>Brings the main ChatGPT forward, or opens it.</summary>
    public void OpenMain()
    {
        RequireChatGPT();
        if (chatgpt.MainPid() is int pid) chatgpt.BringForward(pid);
        else Log("Opening the main ChatGPT");
        // Starting it again hands over to the running copy, which shows its window even from the notification area.
        chatgpt.LaunchMain();
    }

    /// <summary>Brings an open account's window forward.</summary>
    public void Show(AccountStatus status)
    {
        if (status.Pid is int pid) BringForward(status.Account, pid);
    }

    // MARK: The list

    public void Rename(string query, string name) => WithLock(() =>
    {
        var status = Find(query);
        var accounts = Accounts();
        int index = accounts.FindIndex(a => a.Id == status.Account.Id);
        if (index < 0) return 0;
        accounts[index].Name = ValidName(name, ignoring: status.Account.Id);
        Registry.Save(accounts, Layout.AccountsFile);
        return 0;
    });

    /// <summary>Forgets an account: its folders, with its sign-in, chats and settings on this PC, go to the Recycle
    /// Bin. The ChatGPT account itself is untouched.</summary>
    public string Remove(string query) => WithLock(() =>
    {
        var status = Find(query);
        if (status.IsOpen) throw new MultiException($"“{status.DisplayName}” is open. Close its ChatGPT window first.");
        if (Directory.Exists(status.Folder)) MoveToTrash(status.Folder);
        Registry.Save(Accounts().Where(a => a.Id != status.Account.Id).ToList(), Layout.AccountsFile);
        KeepBrowserExtensionWithMain();
        Log($"Removed “{status.DisplayName}”");
        return $"Removed “{status.DisplayName}”. Its folder is in the Recycle Bin; the ChatGPT account itself is untouched.";
    });

    /// <summary>Puts the main ChatGPT back in charge of the browser extension after an account's copy took it over
    /// (see <see cref="BrowserExtension"/>). Returns what changed.</summary>
    public List<string> KeepBrowserExtensionWithMain()
    {
        var changes = BrowserExtension.KeepWithMain(Layout);
        changes.ForEach(Log);
        return changes;
    }

    public string Describe(SignIn signIn) => signIn.Label + (signIn.PlanName is string plan ? $" ({plan})" : "");

    // MARK: Helpers

    /// <summary>Starts an account's own copy of ChatGPT and waits until its process shows. The lock is held by the
    /// caller.</summary>
    void Launch(Account account, string label)
    {
        RequireChatGPT();
        string codexHome = Layout.CodexHome(account), data = Layout.DataFolder(account);
        Directory.CreateDirectory(codexHome);
        Directory.CreateDirectory(data);
        chatgpt.LaunchAccount(codexHome, data);
        var deadline = DateTime.UtcNow + LaunchTimeout;
        while (chatgpt.PidUsing(data) == null)
        {
            if (DateTime.UtcNow > deadline)
                throw new MultiException($"{label} didn't start. ChatGPT's own log is in %LOCALAPPDATA%\\Codex\\Logs.");
            Thread.Sleep(200);
        }
        Log($"Opened {label} ({account.Id})");
    }

    /// <summary>Raises the window, then starts the copy again on the same folders: ChatGPT hands that start to the
    /// running copy, which shows its window even from the notification area. With the same CODEX_HOME, so even if the
    /// copy has just quit, the new one opens on the right account.</summary>
    void BringForward(Account account, int pid)
    {
        chatgpt.BringForward(pid);
        chatgpt.LaunchAccount(Layout.CodexHome(account), Layout.DataFolder(account));
    }

    void Pause()
    {
        if (LaunchSpacing > TimeSpan.Zero) Thread.Sleep(LaunchSpacing);
    }

    void RequireChatGPT()
    {
        if (!chatgpt.Installed)
            throw new MultiException("ChatGPT for Windows isn't installed. Install the ChatGPT desktop app from the Microsoft Store (chatgpt.com/download) and open it once.");
    }

    static MultiException DidNotQuit(string names) =>
        new($"{names} didn't quit. If ChatGPT asked to confirm quitting, confirm and try again.");

    string ValidName(string name, string? ignoring)
    {
        string clean = name.Trim();
        if (clean.Length == 0) throw new MultiException("The name is empty.");
        if (Snapshot().Accounts.Any(s => s.Account.Id != ignoring && string.Equals(s.DisplayName, clean, StringComparison.OrdinalIgnoreCase)))
            throw new MultiException($"Another account is already called “{clean}”.");
        return clean;
    }

    void MoveToTrash(string folder)
    {
        if (Layout.Trash != null)
        {
            Directory.CreateDirectory(Layout.Trash);
            Directory.Move(folder, Path.Combine(Layout.Trash, $"{Path.GetFileName(folder)}-{Guid.NewGuid().ToString("N")[..8]}"));
        }
        else
        {
            Microsoft.VisualBasic.FileIO.FileSystem.DeleteDirectory(folder,
                Microsoft.VisualBasic.FileIO.UIOption.OnlyErrorDialogs, Microsoft.VisualBasic.FileIO.RecycleOption.SendToRecycleBin);
        }
    }

    /// <summary>Runs <paramref name="body"/> holding &lt;home&gt;\.lock, so two copies of this app never change
    /// things at once.</summary>
    T WithLock<T>(Func<T> body)
    {
        Directory.CreateDirectory(Layout.Home);
        FileStream handle;
        try { handle = new FileStream(Layout.LockFile, FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None); }
        catch (IOException) { throw new MultiException("Another change is already running. Try again in a moment."); }
        using (handle) return body();
    }

    void Log(string message) => AppendLog(message, Layout.LogFile);

    public static void AppendLog(string message, string path)
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            using var stream = new FileStream(path, FileMode.Append, FileAccess.Write, FileShare.ReadWrite);
            using var writer = new StreamWriter(stream);
            writer.WriteLine($"[{Registry.Now()}] {message}");
        }
        catch { }
    }

    /// <summary>"A", "A and B", "A, B and C".</summary>
    public static string List(List<string> items) =>
        items.Count <= 1 ? items.FirstOrDefault() ?? "" : string.Join(", ", items.Take(items.Count - 1)) + " and " + items[^1];
}
