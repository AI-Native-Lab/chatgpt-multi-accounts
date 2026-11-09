using System.Text.Json;
using Microsoft.Win32;

namespace ChatGPTMultiAccounts.App;

/// <summary>The app's own preferences, kept next to the accounts in settings.json.</summary>
public sealed class AppSettings
{
    /// <summary>Closing the window leaves the app running in the notification area.</summary>
    public bool KeepInTray { get; set; } = true;
    /// <summary>When Windows starts the app, it opens every signed-in account too.</summary>
    public bool OpenAllAtStartup { get; set; }

    string path = "";

    public static AppSettings Load(string path)
    {
        AppSettings settings;
        try { settings = JsonSerializer.Deserialize<AppSettings>(File.ReadAllText(path)) ?? new(); }
        catch { settings = new(); }
        settings.path = path;
        return settings;
    }

    public void Save()
    {
        try { Core.Files.WriteAtomically(path, JsonSerializer.Serialize(this, new JsonSerializerOptions { WriteIndented = true })); }
        catch { }
    }

    const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    const string RunName = "ChatGPT Multi-Accounts";

    /// <summary>Starts with Windows, in the notification area.</summary>
    public static bool StartWithWindows
    {
        get
        {
            using var key = Registry.CurrentUser.OpenSubKey(RunKey);
            return key?.GetValue(RunName) is string;
        }
        set
        {
            using var key = Registry.CurrentUser.CreateSubKey(RunKey);
            if (value) key.SetValue(RunName, $"\"{Environment.ProcessPath}\" --background");
            else key.DeleteValue(RunName, throwOnMissingValue: false);
        }
    }
}
