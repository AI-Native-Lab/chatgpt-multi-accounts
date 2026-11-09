namespace ChatGPTMultiAccounts.App;

sealed class SettingsForm : Form
{
    public SettingsForm(AppModel model)
    {
        var settings = model.Settings;
        Text = "Settings";
        Icon = Theme.AppIcon();
        AutoScaleMode = AutoScaleMode.Dpi;
        Font = Theme.Body;
        BackColor = Theme.Window;
        ForeColor = Theme.Text;
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MaximizeBox = MinimizeBox = false;
        ShowInTaskbar = false;
        StartPosition = FormStartPosition.CenterParent;
        AutoSize = true;
        AutoSizeMode = AutoSizeMode.GrowAndShrink;
        Padding = new Padding(20);

        var layout = new FlowLayoutPanel { FlowDirection = FlowDirection.TopDown, WrapContents = false, AutoSize = true, Dock = DockStyle.Fill };

        Label Section(string text) => new() { Text = text, Font = Theme.Heading, AutoSize = true, Margin = new Padding(0, 10, 0, 4) };
        Label Note(string text) => new() { Text = text, AutoSize = true, ForeColor = Theme.Secondary, MaximumSize = new Size(470, 0), Margin = new Padding(20, 0, 0, 6) };
        CheckBox Check(string text, bool value, Action<bool> set)
        {
            var box = new CheckBox { Text = text, Checked = value, AutoSize = true, Margin = new Padding(0, 4, 0, 2) };
            box.CheckedChanged += (_, _) => { set(box.Checked); settings.Save(); };
            return box;
        }

        layout.Controls.Add(Section("This app"));
        layout.Controls.Add(Check("Keep running in the notification area when the window is closed", settings.KeepInTray, v => settings.KeepInTray = v));

        layout.Controls.Add(Section("Startup"));
        bool startup = false;
        try { startup = AppSettings.StartWithWindows; } catch { }
        var openAll = Check("Then open every signed-in account", settings.OpenAllAtStartup, v => settings.OpenAllAtStartup = v);
        openAll.Margin = new Padding(20, 2, 0, 2);
        openAll.Enabled = startup;
        var startBox = new CheckBox { Text = "Start ChatGPT Multi-Accounts with Windows (in the notification area)", Checked = startup, AutoSize = true, Margin = new Padding(0, 4, 0, 2) };
        startBox.CheckedChanged += (_, _) =>
        {
            try { AppSettings.StartWithWindows = startBox.Checked; openAll.Enabled = startBox.Checked; }
            catch (Exception e) { Prompt.Error(e); }
        };
        layout.Controls.Add(startBox);
        layout.Controls.Add(openAll);
        layout.Controls.Add(Note("Started with Windows, the app waits in the notification area without showing its window. With the second option, every account you signed in to opens in its own ChatGPT window, next to the main ChatGPT."));

        layout.Controls.Add(Section("Data"));
        var folders = new FlowLayoutPanel { AutoSize = true, WrapContents = false, Margin = new Padding(0, 4, 0, 0) };
        foreach (var (title, action) in new (string, Action)[]
                 {
                     ("Accounts' Folders", model.ShowAccountsFolder),
                     ("Main ChatGPT's Folder", model.ShowMainFolder),
                     ("Activity Log", model.OpenLog),
                 })
        {
            var b = new Button { Text = title, Margin = new Padding(0, 0, 8, 0) };
            Theme.StyleButton(b);
            b.Click += (_, _) => action();
            folders.Controls.Add(b);
        }
        layout.Controls.Add(folders);
        var paths = Note($"Each account keeps its own sign-in, chats and settings in its folder. The main ChatGPT's folders are only read.\nAccounts: {model.Manager.Layout.Home}\nMain ChatGPT: {model.Manager.Layout.MainCodexHome}");
        paths.Margin = new Padding(0, 8, 0, 0);
        layout.Controls.Add(paths);

        layout.Controls.Add(new Label
        {
            Text = $"ChatGPT Multi-Accounts {Application.ProductVersion.Split('+')[0]} for Windows · beta · AI Native Lab\nAn independent project, not affiliated with or endorsed by OpenAI. Sends nothing to OpenAI; sign-ins stay on this PC.",
            AutoSize = true, ForeColor = Theme.Secondary, Font = Theme.Small, MaximumSize = new Size(490, 0), Margin = new Padding(0, 16, 0, 8),
        });
        var close = new Button { Text = "Done", DialogResult = DialogResult.OK };
        Theme.StyleButton(close, prominent: true);
        close.Anchor = AnchorStyles.Right;
        layout.Controls.Add(close);
        AcceptButton = close;
        CancelButton = close;
        Controls.Add(layout);
    }
}
