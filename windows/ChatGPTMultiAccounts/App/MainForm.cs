using System.Drawing.Drawing2D;
using ChatGPTMultiAccounts.Core;

namespace ChatGPTMultiAccounts.App;

/// <summary>The main window: the main ChatGPT, every other account, and which of them are open right now.</summary>
sealed class MainForm : Form
{
    readonly AppModel model;
    readonly Label headline = new() { AutoSize = true, Font = Theme.Title, ForeColor = Theme.Text };
    readonly Label subheadline = new() { AutoSize = true, ForeColor = Theme.Secondary };
    readonly Button closeAllButton = new() { Text = "Close All" };
    readonly Button openAllButton = new() { Text = "Open All" };
    readonly Button addButton = new() { Text = "+  Add Account" };
    readonly Button settingsButton = new() { Text = "Settings" };
    readonly FlowLayoutPanel list = new()
    {
        Dock = DockStyle.Fill, FlowDirection = FlowDirection.TopDown, WrapContents = false, AutoScroll = true,
        Padding = new Padding(20, 16, 20, 20),
    };
    readonly NotifyIcon tray = new();
    readonly System.Windows.Forms.Timer timer = new() { Interval = 2000 };
    readonly System.Windows.Forms.Timer sizeTimer = new() { Interval = 600_000 };
    readonly ToolTip tips = new();
    string drawn = "";
    bool quitting;

    public MainForm(AppModel model, bool startHidden, bool live = true)
    {
        this.model = model;
        Text = "ChatGPT Multi-Accounts";
        Icon = Theme.AppIcon();
        AutoScaleMode = AutoScaleMode.Dpi;
        Font = Theme.Body;
        BackColor = Theme.Window;
        ForeColor = Theme.Text;
        ClientSize = new Size(820, 580);
        MinimumSize = new Size(700, 440);
        StartPosition = FormStartPosition.CenterScreen;
        Prompt.Owner = this;

        Controls.Add(list);
        Controls.Add(BuildHeader());

        tray.Icon = Theme.AppIcon();
        tray.Text = "ChatGPT Multi-Accounts";
        tray.Visible = live;
        tray.ContextMenuStrip = new ContextMenuStrip();
        tray.ContextMenuStrip.Opening += (_, e) => { BuildTrayMenu(tray.ContextMenuStrip); e.Cancel = false; };
        tray.MouseClick += (_, e) => { if (e.Button == MouseButtons.Left) ShowWindow(); };

        model.Changed += Render;
        timer.Tick += (_, _) => model.Refresh();
        sizeTimer.Tick += (_, _) => model.RefreshSizes();
        Load += (_, _) =>
        {
            if (!live) return;
            model.Refresh();
            model.RefreshSizes();
            timer.Start();
            sizeTimer.Start();
            if (startHidden) BeginInvoke(Hide);
        };
        Render();
    }

    Control BuildHeader()
    {
        var header = new TableLayoutPanel
        {
            Dock = DockStyle.Top, Height = 84, ColumnCount = 6, RowCount = 1, Padding = new Padding(20, 16, 20, 12),
            BackColor = Theme.Card,
        };
        header.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 62));
        header.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        for (int i = 0; i < 4; i++) header.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        var icon = new PictureBox { Image = new Icon(Theme.AppIcon(), 48, 48).ToBitmap(), SizeMode = PictureBoxSizeMode.Zoom, Size = new Size(48, 48), Margin = new Padding(0, 2, 12, 0) };
        var titles = new FlowLayoutPanel { FlowDirection = FlowDirection.TopDown, AutoSize = true, WrapContents = false, Margin = new Padding(0, 2, 0, 0) };
        titles.Controls.Add(headline);
        titles.Controls.Add(subheadline);
        foreach (var b in new[] { closeAllButton, openAllButton, addButton, settingsButton })
        {
            Theme.StyleButton(b, prominent: b == addButton);
            b.Margin = new Padding(8, 10, 0, 0);
        }
        tips.SetToolTip(closeAllButton, "Quit every account's window. The main ChatGPT keeps running.");
        tips.SetToolTip(openAllButton, "Open every signed-in account, each in its own ChatGPT window, and the main ChatGPT.");
        closeAllButton.Click += (_, _) => model.CloseAll();
        openAllButton.Click += (_, _) => model.OpenAll();
        addButton.Click += (_, _) => model.Add();
        settingsButton.Click += (_, _) => ShowSettings();
        header.Controls.Add(icon, 0, 0);
        header.Controls.Add(titles, 1, 0);
        header.Controls.Add(closeAllButton, 2, 0);
        header.Controls.Add(openAllButton, 3, 0);
        header.Controls.Add(addButton, 4, 0);
        header.Controls.Add(settingsButton, 5, 0);
        header.Paint += (_, e) => { using var pen = new Pen(Theme.Border); e.Graphics.DrawLine(pen, 0, header.Height - 1, header.Width, header.Height - 1); };
        return header;
    }

    /// <summary>Redraws the list when what it shows has changed.</summary>
    void Render()
    {
        bool idle = model.Busy == null;
        headline.Text = model.Headline;
        subheadline.Text = model.Subheadline;
        closeAllButton.Visible = model.Snapshot?.OpenAccounts.Count > 0;
        closeAllButton.Enabled = idle;
        openAllButton.Enabled = idle && model.CanOpenAll;
        addButton.Enabled = idle && model.Installed;
        tray.Text = Truncate(model.Busy ?? model.Headline, 63);

        string signature = string.Join("|", new object?[]
        {
            model.Busy, model.Problem, model.Snapshot == null,
            model.Snapshot?.Main,
            string.Join(";", model.Statuses.Select(s => $"{s.Id},{s.Account.Name},{s.Pid},{s.SignIn},{s.SameAs},{(model.Sizes.TryGetValue(s.Id, out var z) ? z : -1)}")),
        });
        if (signature == drawn) return;
        drawn = signature;

        list.SuspendLayout();
        var old = list.Controls.Cast<Control>().ToList();
        list.Controls.Clear();
        foreach (var c in old) c.Dispose();
        int width = ListWidth();

        void Add(Control c) { c.Width = width; c.Margin = new Padding(0, 0, 0, 10); list.Controls.Add(c); }

        if (model.Problem != null) Add(new Banner(Theme.Orange, model.Problem));
        foreach (var status in model.Statuses.Where(s => s.IsOpen && !s.IsSignedIn))
            Add(new Banner(Theme.Blue, "A new ChatGPT window is open at its sign-in screen. Sign in there with your other account; it shows here as soon as it has.",
                ("Show Window", () => model.Open(status))));
        foreach (var status in model.Statuses.Where(s => s.SameAs != null))
        {
            var buttons = status.IsOpen ? new[] { ("Show Window", (Action)(() => model.Open(status))) } : Array.Empty<(string, Action)>();
            Add(new Banner(Theme.Orange, $"“{status.DisplayName}” is signed in to the same ChatGPT account as {status.SameAs}. To use another account there, log out in its window and sign in with the other one.", buttons));
        }
        if (model.Busy != null) Add(new Banner(Theme.Accent, "⏳  " + model.Busy));

        if (model.Snapshot is { } snapshot)
        {
            Add(MainCard(snapshot.Main));
            if (snapshot.Accounts.Count == 0) Add(new EmptyState(model));
        }
        foreach (var status in model.Statuses) Add(AccountCard(status));
        Add(new Label
        {
            Text = "Every account runs in its own ChatGPT window, with its own sign-in, chats and settings, all at the same time. Nothing is swapped or signed out, and the main ChatGPT is never quit or changed. ChatGPT's browser extension stays with the main ChatGPT.",
            ForeColor = Theme.Secondary, Font = Theme.Small, AutoSize = true, MaximumSize = new Size(width, 0), Margin = new Padding(0, 4, 0, 0),
        });
        list.ResumeLayout();
    }

    Card MainCard(MainState main)
    {
        var details = new List<string>();
        if (main.SignIn is { } signIn)
        {
            details.Add(signIn.Label);
            if (signIn.PlanName is string plan) details.Add(plan);
        }
        else details.Add("Signed out");
        details.Add("your usual ChatGPT, left as it is");
        var badges = new List<(string, Color)> { ("Main", Theme.Accent), (main.Running ? "● Open" : "Not open", main.Running ? Theme.Green : Theme.Gray) };
        var card = new Card(main.DisplayName, "Main ChatGPT", badges, string.Join(" · ", details), Theme.Accent, dim: false);
        card.AddButton(main.Running ? "Show" : "Open", model.OpenMain, enabled: model.Busy == null && main.Installed);
        return card;
    }

    Card AccountCard(AccountStatus status)
    {
        var badges = new List<(string, Color)>
        {
            (status.IsOpen, status.IsSignedIn) switch
            {
                (true, true) => ("● Open", Theme.Green),
                (true, false) => ("● Signing in", Theme.Blue),
                (false, true) => ("Closed", Theme.Gray),
                _ => ("Not signed in", Theme.Orange),
            },
        };
        if (status.SameAs != null) badges.Add((status.SameAs == "the main ChatGPT" ? "Same as main" : "Duplicate", Theme.Orange));

        var details = new List<string>();
        if (status.SignIn is { } signIn)
        {
            if (status.Account.Name != null) details.Add(signIn.Label);
            if (signIn.PlanName is string plan) details.Add(plan);
        }
        else details.Add(status.IsOpen ? "Sign in with your other account in its ChatGPT window" : "Open it to sign in");
        if (model.Sizes.TryGetValue(status.Id, out long size)) details.Add(Files.FormatSize(size));

        var card = new Card(status.DisplayName, status.DisplayName, badges, string.Join(" · ", details),
            status.IsOpen ? Theme.Green : null, dim: !status.IsOpen);
        bool idle = model.Busy == null;
        if (status.IsOpen)
        {
            card.AddButton("Show", () => model.Open(status), enabled: idle);
            card.AddButton("Close", () => model.Close(status), enabled: idle);
        }
        else
        {
            card.AddButton(status.IsSignedIn ? "Open" : "Open to Sign In", () => model.Open(status), prominent: true, enabled: idle);
        }
        var menu = new ContextMenuStrip();
        menu.Items.Add("Rename…", null, (_, _) => model.Rename(status));
        menu.Items.Add(new ToolStripMenuItem("Show Folder in File Explorer", null, (_, _) => model.ShowFolder(status)) { Enabled = Directory.Exists(status.Folder) });
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(new ToolStripMenuItem("Remove…", null, (_, _) => model.Remove(status)) { Enabled = !status.IsOpen });
        card.AddMenu(menu, enabled: idle);
        return card;
    }

    int ListWidth() => Math.Max(400, list.ClientSize.Width - list.Padding.Horizontal - SystemInformation.VerticalScrollBarWidth);

    protected override void OnResize(EventArgs e)
    {
        base.OnResize(e);
        if (list == null) return;
        int width = ListWidth();
        foreach (Control c in list.Controls)
        {
            if (c is Label { AutoSize: true } l) l.MaximumSize = new Size(width, 0);
            else c.Width = width;
        }
    }

    static string Truncate(string s, int max) => s.Length <= max ? s : s[..(max - 1)] + "…";

    public void ShowWindow()
    {
        Show();
        if (WindowState == FormWindowState.Minimized) WindowState = FormWindowState.Normal;
        Activate();
        model.Refresh();
    }

    void ShowSettings()
    {
        using var form = new SettingsForm(model);
        form.ShowDialog(this);
    }

    protected override void OnFormClosing(FormClosingEventArgs e)
    {
        if (!quitting && model.Settings.KeepInTray && e.CloseReason == CloseReason.UserClosing)
        {
            e.Cancel = true;
            Hide();
            return;
        }
        tray.Visible = false;
        base.OnFormClosing(e);
    }

    public void Quit()
    {
        quitting = true;
        tray.Visible = false;
        Application.Exit();
    }

    /// <summary>The notification-area menu: a click brings an open account forward or opens a closed one.</summary>
    void BuildTrayMenu(ContextMenuStrip menu)
    {
        model.Refresh();
        menu.Items.Clear();
        bool idle = model.Busy == null && model.Snapshot != null;
        menu.Items.Add(new ToolStripMenuItem(model.Busy ?? model.Headline) { Enabled = false });
        if (model.Busy == null && model.Subheadline.Length > 0) menu.Items.Add(new ToolStripMenuItem(model.Subheadline) { Enabled = false });
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(new ToolStripMenuItem("Open ChatGPT Multi-Accounts…", null, (_, _) => ShowWindow()) { Font = new Font(menu.Font, FontStyle.Bold) });
        menu.Items.Add(new ToolStripSeparator());

        if (model.Snapshot?.Main is { } main)
            menu.Items.Add(new ToolStripMenuItem($"Main ChatGPT — {main.SignIn?.Email ?? "signed out"}", null, (_, _) => model.OpenMain())
                { Checked = main.Running, Enabled = idle && main.Installed });
        foreach (var status in model.Statuses)
        {
            string title = status.DisplayName + (status.IsSignedIn ? "" : status.IsOpen ? "  (signing in)" : "  (not signed in)");
            var s = status;
            menu.Items.Add(new ToolStripMenuItem(title, null, (_, _) => model.Open(s)) { Checked = status.IsOpen, Enabled = idle });
        }
        var open = model.Statuses.Where(s => s.IsOpen).ToList();
        if (open.Count > 0)
        {
            var close = new ToolStripMenuItem("Close") { Enabled = idle };
            foreach (var s in open) close.DropDownItems.Add(s.DisplayName, null, (_, _) => model.Close(s));
            menu.Items.Add(close);
        }
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(new ToolStripMenuItem("Open All Accounts", null, (_, _) => model.OpenAll()) { Enabled = idle && model.CanOpenAll });
        menu.Items.Add(new ToolStripMenuItem("Close All Accounts", null, (_, _) => model.CloseAll()) { Enabled = idle && open.Count > 0 });
        menu.Items.Add(new ToolStripMenuItem("Add Account…", null, (_, _) => model.Add()) { Enabled = idle && model.Installed });
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add("Settings…", null, (_, _) => { ShowWindow(); ShowSettings(); });
        menu.Items.Add("Quit ChatGPT Multi-Accounts", null, (_, _) => Quit());
    }
}

/// <summary>A notice above the accounts.</summary>
sealed class Banner : Panel
{
    readonly Color tint;

    public Banner(Color tint, string text, params (string Label, Action Action)[] buttons)
    {
        this.tint = tint;
        DoubleBuffered = true;
        Padding = new Padding(14, 10, 10, 10);
        var layout = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = buttons.Length + 1, RowCount = 1, BackColor = Color.Transparent };
        layout.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        for (int i = 0; i < buttons.Length; i++) layout.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        var label = new Label { Text = text, AutoSize = true, ForeColor = Theme.Text, Anchor = AnchorStyles.Left, Margin = new Padding(0, 6, 8, 6) };
        layout.Controls.Add(label, 0, 0);
        int col = 1;
        foreach (var (title, action) in buttons)
        {
            var b = new Button { Text = title, Anchor = AnchorStyles.Right, Margin = new Padding(6, 0, 0, 0) };
            Theme.StyleButton(b);
            b.Click += (_, _) => action();
            layout.Controls.Add(b, col++, 0);
        }
        Controls.Add(layout);
        Height = 54;
        Resize += (_, _) =>
        {
            int buttonsWidth = layout.Controls.OfType<Button>().Sum(b => b.PreferredSize.Width + 6);
            label.MaximumSize = new Size(Math.Max(100, Width - Padding.Horizontal - buttonsWidth - 12), 0);
            Height = Math.Max(54, label.PreferredHeight + Padding.Vertical + 12);
        };
    }

    protected override void OnPaintBackground(PaintEventArgs e)
    {
        e.Graphics.Clear(Parent?.BackColor ?? Theme.Window);
        e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
        using var path = Theme.Rounded(new Rectangle(0, 0, Width - 1, Height - 1), 8);
        using var brush = new SolidBrush(Theme.Tint(tint, 0.12));
        e.Graphics.FillPath(brush, path);
    }
}

/// <summary>Shown until the first extra account is added.</summary>
sealed class EmptyState : Panel
{
    public EmptyState(AppModel model)
    {
        DoubleBuffered = true;
        Padding = new Padding(18, 16, 18, 16);
        var layout = new FlowLayoutPanel { Dock = DockStyle.Fill, FlowDirection = FlowDirection.TopDown, WrapContents = false, BackColor = Color.Transparent };
        var title = new Label { Text = "Use another ChatGPT account at the same time", Font = Theme.Heading, AutoSize = true, ForeColor = Theme.Text, Margin = new Padding(0, 0, 0, 6) };
        var text = new Label
        {
            Text = "Add an account and it opens in its own ChatGPT window, next to the main one. Sign in once; after that both stay signed in and run side by side: chat in one while a task runs in the other. Add as many accounts as you like and open them all with one click.",
            AutoSize = true, ForeColor = Theme.Secondary, Margin = new Padding(0, 0, 0, 10),
        };
        var add = new Button { Text = "Add Account…", Enabled = model.Busy == null && model.Installed };
        Theme.StyleButton(add, prominent: add.Enabled);
        add.Click += (_, _) => model.Add();
        layout.Controls.Add(title);
        layout.Controls.Add(text);
        layout.Controls.Add(add);
        Controls.Add(layout);
        // Measured with the window's font, which it only inherits once it is in the list.
        Font = Theme.Body;
        void Fit()
        {
            int width = Math.Max(200, Width - Padding.Horizontal - 8);
            text.MaximumSize = new Size(width, 0);
            Height = Padding.Vertical + layout.GetPreferredSize(new Size(width, 0)).Height + 4;
        }
        Resize += (_, _) => Fit();
        ParentChanged += (_, _) => Fit();
    }

    protected override void OnPaintBackground(PaintEventArgs e)
    {
        e.Graphics.Clear(Parent?.BackColor ?? Theme.Window);
        e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
        using var path = Theme.Rounded(new Rectangle(0, 0, Width - 1, Height - 1), 10);
        using var brush = new SolidBrush(Theme.Tint(Theme.Accent, 0.07));
        using var pen = new Pen(Theme.Tint(Theme.Accent, 0.4)) { DashStyle = DashStyle.Dash };
        e.Graphics.FillPath(brush, path);
        e.Graphics.DrawPath(pen, path);
    }
}

/// <summary>One ChatGPT account: the main one or an extra one.</summary>
sealed class Card : Panel
{
    static readonly Color[] AvatarColors =
    {
        Color.FromArgb(16, 140, 115), Color.FromArgb(92, 107, 192), Color.FromArgb(245, 124, 0), Color.FromArgb(216, 27, 96),
        Color.FromArgb(142, 36, 170), Color.FromArgb(30, 136, 229), Color.FromArgb(0, 150, 136), Color.FromArgb(217, 120, 87),
    };

    readonly string avatarName;
    readonly Color? highlight;
    readonly bool dim;
    readonly FlowLayoutPanel actions = new() { Dock = DockStyle.Right, AutoSize = true, WrapContents = false, BackColor = Color.Transparent, Padding = new Padding(0, 9, 0, 0) };

    public Card(string avatarName, string title, List<(string Text, Color Color)> badges, string details, Color? highlight, bool dim)
    {
        this.avatarName = avatarName;
        this.highlight = highlight;
        this.dim = dim;
        DoubleBuffered = true;
        Height = 78;
        Padding = new Padding(70, 12, 12, 12);

        var text = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 1, RowCount = 2, BackColor = Color.Transparent };
        var top = new FlowLayoutPanel { AutoSize = true, WrapContents = false, Margin = new Padding(0, 2, 0, 2), BackColor = Color.Transparent };
        top.Controls.Add(new Label { Text = title, AutoSize = true, Font = Theme.Name, ForeColor = Theme.Text, Margin = new Padding(0, 0, 6, 0) });
        foreach (var (badge, color) in badges) top.Controls.Add(new Pill(badge, color) { Margin = new Padding(0, 3, 6, 0) });
        text.Controls.Add(top, 0, 0);
        text.Controls.Add(new Label
        {
            Text = details, AutoSize = false, Dock = DockStyle.Fill, ForeColor = Theme.Secondary,
            AutoEllipsis = true, Margin = new Padding(0, 2, 8, 0),
        }, 0, 1);
        Controls.Add(text);
        Controls.Add(actions);
    }

    public void AddButton(string title, Action action, bool prominent = false, bool enabled = true)
    {
        var b = new Button { Text = title, Margin = new Padding(6, 0, 0, 0), Enabled = enabled };
        Theme.StyleButton(b, prominent && enabled);
        b.Click += (_, _) => action();
        actions.Controls.Add(b);
    }

    public void AddMenu(ContextMenuStrip menu, bool enabled)
    {
        var more = new Button { Text = "···", Margin = new Padding(6, 0, 0, 0), Enabled = enabled };
        Theme.StyleButton(more);
        more.Click += (_, _) => menu.Show(more, new Point(0, more.Height));
        actions.Controls.Add(more);
    }

    protected override void OnPaintBackground(PaintEventArgs e)
    {
        var g = e.Graphics;
        g.Clear(Parent?.BackColor ?? Theme.Window);
        g.SmoothingMode = SmoothingMode.AntiAlias;
        using (var path = Theme.Rounded(new Rectangle(0, 0, Width - 1, Height - 1), 10))
        using (var fill = new SolidBrush(Theme.Card))
        using (var pen = new Pen(highlight.HasValue ? Theme.Tint(highlight.Value, 0.6) : Theme.Border, highlight.HasValue ? 1.5f : 1f))
        {
            g.FillPath(fill, path);
            g.DrawPath(pen, path);
        }
        // A round badge with the account's initials, in a colour that stays the same for a name. For an email, the
        // part before the @ ("jamie.ng" → JN).
        string name = avatarName.Contains('@') ? avatarName[..avatarName.IndexOf('@')] : avatarName;
        var words = name.Split(c => !char.IsLetterOrDigit(c));
        string initials = string.Concat(new[] { words.FirstOrDefault(), words.Length > 1 ? words[^1] : null }
            .Where(w => !string.IsNullOrEmpty(w)).Select(w => char.ToUpperInvariant(w![0])));
        int index = avatarName.ToLowerInvariant().Aggregate(5381, (acc, c) => (acc * 33 + c) % 1_000_003) % AvatarColors.Length;
        var color = dim ? Theme.Tint(AvatarColors[index], 0.55) : AvatarColors[index];
        var circle = new Rectangle(16, (Height - 42) / 2, 42, 42);
        using (var brush = new LinearGradientBrush(circle, ControlPaint.Light(color, 0.2f), color, 90f))
            g.FillEllipse(brush, circle);
        using var font = new Font("Segoe UI Semibold", 11.5f);
        TextRenderer.DrawText(g, initials.Length == 0 ? "?" : initials, font, circle, Color.White,
            TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter);
    }
}

static class StringSplit
{
    public static string[] Split(this string s, Func<char, bool> separator)
    {
        var parts = new List<string>();
        var current = new System.Text.StringBuilder();
        foreach (char c in s)
        {
            if (separator(c)) { if (current.Length > 0) { parts.Add(current.ToString()); current.Clear(); } }
            else current.Append(c);
        }
        if (current.Length > 0) parts.Add(current.ToString());
        return parts.ToArray();
    }
}

/// <summary>A small rounded label.</summary>
sealed class Pill : Control
{
    readonly Color color;

    public Pill(string text, Color color)
    {
        this.color = color;
        Text = text;
        Font = Theme.Badge;
        SetStyle(ControlStyles.SupportsTransparentBackColor | ControlStyles.OptimizedDoubleBuffer | ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint, true);
        BackColor = Color.Transparent;
        var size = TextRenderer.MeasureText(text, Font);
        Size = new Size(size.Width + 14, size.Height + 4);
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
        using var path = Theme.Rounded(new Rectangle(0, 0, Width - 1, Height - 1), (Height - 1) / 2);
        using var brush = new SolidBrush(Theme.Tint(color, 0.15));
        e.Graphics.FillPath(brush, path);
        TextRenderer.DrawText(e.Graphics, Text, Font, ClientRectangle, color, TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter);
    }
}
