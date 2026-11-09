using System.Diagnostics;
using ChatGPTMultiAccounts.Core;

namespace ChatGPTMultiAccounts.App;

/// <summary>The state the window and the tray menu show, and every action they offer. Anything that reads the
/// accounts or starts and quits ChatGPT runs on one background queue, one thing at a time; the UI hears about it on
/// its thread.</summary>
sealed class AppModel
{
    public Snapshot? Snapshot { get; private set; }
    public string? Problem { get; private set; }
    public string? Busy { get; private set; }
    public Dictionary<string, long> Sizes { get; private set; } = new();
    public event Action? Changed;

    public readonly AccountManager Manager;
    public readonly AppSettings Settings;
    readonly SynchronizationContext ui;
    readonly TaskFactory work = new(new ConcurrentExclusiveSchedulerPair().ExclusiveScheduler);
    bool refreshing;

    public AppModel(AccountManager manager, AppSettings settings)
    {
        Manager = manager;
        Settings = settings;
        ui = SynchronizationContext.Current as WindowsFormsSynchronizationContext
             ?? throw new InvalidOperationException("AppModel must be made on the UI thread, after WinForms is set up.");
    }

    public List<AccountStatus> Statuses => Snapshot?.Accounts ?? new();
    public int OpenCount => Snapshot?.OpenCount ?? 0;
    public bool Installed => Snapshot?.Main.Installed == true;

    public bool CanOpenAll => Snapshot is { } s && (s.ReadyToOpen.Count > 0 || (!s.Main.Running && s.Main.Installed));

    public string Headline
    {
        get
        {
            if (Snapshot == null) return Problem == null ? "ChatGPT Multi-Accounts" : "Something is wrong";
            if (!Snapshot.Main.Installed) return "ChatGPT isn't installed";
            return Snapshot.OpenCount switch
            {
                0 => "No ChatGPT account open",
                1 => "1 ChatGPT account open",
                var n => $"{n} ChatGPT accounts open at once",
            };
        }
    }

    public string Subheadline
    {
        get
        {
            if (Snapshot == null) return Problem ?? "";
            if (!Snapshot.Main.Installed) return "Install the ChatGPT desktop app from the Microsoft Store, then open it once.";
            var parts = new List<string> { $"Main: {Snapshot.Main.SignIn?.Email ?? "signed out"}{(Snapshot.Main.Running ? "" : " (not open)")}" };
            int open = Snapshot.OpenAccounts.Count;
            if (open > 0) parts.Add(open == 1 ? "1 other open" : $"{open} others open");
            int closed = Snapshot.Accounts.Count - open;
            if (closed > 0) parts.Add($"{closed} closed");
            return string.Join(" · ", parts);
        }
    }

    void Post(Action action) => ui.Post(_ => { action(); Changed?.Invoke(); }, null);

    public void Refresh()
    {
        if (refreshing) return;
        refreshing = true;
        work.StartNew(() =>
        {
            Snapshot? snapshot = null;
            string? problem = null;
            try
            {
                snapshot = Manager.Snapshot();
                // A copy of ChatGPT takes the browser extension over some seconds after it starts.
                if (snapshot.OpenAccounts.Count > 0) Manager.KeepBrowserExtensionWithMain();
            }
            catch (Exception e) { problem = e.Message; }
            Post(() => { Snapshot = snapshot; Problem = problem; refreshing = false; });
        });
    }

    /// <summary>Reads everything at once and waits for it; used before drawing screenshots.</summary>
    public void RefreshNow()
    {
        try { Snapshot = Manager.Snapshot(); Problem = null; }
        catch (Exception e) { Snapshot = null; Problem = e.Message; }
        foreach (var status in Snapshot?.Accounts ?? new())
            if (Manager.FolderSize(status) is long size) Sizes[status.Id] = size;
        Changed?.Invoke();
    }

    public void RefreshSizes()
    {
        Task.Run(() =>
        {
            var sizes = new Dictionary<string, long>();
            foreach (var status in Snapshot?.Accounts ?? new())
                if (Manager.FolderSize(status) is long size) sizes[status.Id] = size;
            Post(() => Sizes = sizes);
        });
    }

    // MARK: Actions

    public void Add()
    {
        if (Prompt.Text("Add a ChatGPT account",
                "A new ChatGPT window opens at its sign-in screen, next to your main ChatGPT, which keeps running. Sign in there with the other account; it then stays signed in, in its own window, as long as you like.\n\nIf the sign-in page goes straight to an account you already use here, log out on that page and sign in with the other one.\n\nName (optional; it is named after its email otherwise):",
                "For example: Work", "Open Sign-In Window", allowEmpty: true) is not string name) return;
        Perform("Opening a new ChatGPT window…", _ => Manager.Add(name.Length == 0 ? null : name));
    }

    public void Open(AccountStatus status) =>
        Perform(status.IsOpen ? null : $"Opening {status.DisplayName}…", _ => Manager.Open(status.Id));

    public void OpenAll() => Perform("Opening every account…", progress => Manager.OpenAll(progress));

    public void Close(AccountStatus status) => Perform($"Closing {status.DisplayName}…", _ => Manager.Close(status.Id));

    public void CloseAll() => Perform("Closing every account…", progress => Manager.CloseAll(progress));

    public void OpenMain() => Perform(null, _ => Manager.OpenMain());

    public void Rename(AccountStatus status)
    {
        if (Prompt.Text($"Rename “{status.DisplayName}”", "New name:", status.DisplayName,
                initial: status.Account.Name ?? "") is not string name) return;
        Perform(null, _ => Manager.Rename(status.Id, name));
    }

    public void Remove(AccountStatus status)
    {
        if (!Prompt.Confirm($"Remove “{status.DisplayName}”?",
                "Its folders go to the Recycle Bin, with its sign-in, chats and settings on this PC. The ChatGPT account itself is not touched; to use it here again, add it again and sign in.",
                "Move to Recycle Bin")) return;
        Perform(null, _ => Manager.Remove(status.Id));
    }

    public void ShowFolder(AccountStatus status) => Reveal(status.Folder);

    public void ShowAccountsFolder()
    {
        Directory.CreateDirectory(Manager.Layout.Home);
        Reveal(Manager.Layout.Home);
    }

    public void ShowMainFolder() => Reveal(Manager.Layout.MainCodexHome);

    public void OpenLog()
    {
        if (File.Exists(Manager.Layout.LogFile))
            Process.Start(new ProcessStartInfo(Manager.Layout.LogFile) { UseShellExecute = true });
        else
            Prompt.Info("No activity yet", "The log starts when the first account is added or opened.");
    }

    static void Reveal(string path)
    {
        if (Directory.Exists(path)) Process.Start("explorer.exe", $"\"{path}\"");
    }

    void Perform(string? label, Action<Action<string>> action)
    {
        if (Busy != null) return;
        Busy = label ?? "Working…";
        Changed?.Invoke();
        work.StartNew(() =>
        {
            Exception? failure = null;
            try { action(message => Post(() => Busy = message)); }
            catch (Exception e) { failure = e; }
            Post(() =>
            {
                Busy = null;
                Refresh();
                RefreshSizes();
                if (failure != null) Prompt.Error(failure);
            });
        });
    }
}
