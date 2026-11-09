# ChatGPT Multi-Accounts for Windows (beta)

Several ChatGPT accounts at the same time in the ChatGPT desktop app for Windows: each account opens in its own
ChatGPT window, signed in on its own, next to your main ChatGPT. The same rules and the same `accounts.json` format
as the [macOS app](../macos), ported to C# / WinForms.

## Install

1. Download `ChatGPTMultiAccounts-<version>-windows-x64.zip` from the releases and unzip it anywhere (for example
   `%LOCALAPPDATA%\Programs\ChatGPTMultiAccounts`).
2. Run `ChatGPTMultiAccounts.exe`. It is one file with .NET included; Windows 10 or 11, 64-bit.
   SmartScreen may warn the first time because the file isn't signed: **More info → Run anyway**.

Needs the ChatGPT desktop app that includes Codex, from the Microsoft Store (package `OpenAI.Codex`, checked with
26.1103). Open it once before adding accounts.

## Use

- **Add Account**: a new ChatGPT window opens at its sign-in screen; the main ChatGPT keeps running. Sign in there
  with the other account. If the sign-in page goes straight to an account you already use, log out on that page
  and sign in with the other one. The account shows in the list as soon as it has signed in.
- **Open** starts a signed-in account in its own window; **Show** brings an open one forward; **Close** quits that
  window, and the account stays signed in.
- **Open All** starts every signed-in account, and the main ChatGPT; **Close All** quits every account's window
  and leaves the main ChatGPT running.
- The notification-area icon (next to the clock) lists the main ChatGPT and every account: one click opens it or
  brings it forward.
- **Settings**: keep running in the notification area, start with Windows, and open every account at startup.

## How it differs from the Mac

The rules are those of [docs/how-it-works.md](../docs/how-it-works.md). What is different on Windows:

| | macOS | Windows |
|---|---|---|
| ChatGPT app | `/Applications/ChatGPT.app` (`com.openai.codex`) | Microsoft Store package `OpenAI.Codex`, `ChatGPT.exe` |
| Main ChatGPT's folders | `~/.codex`, `~/Library/Application Support/Codex` | `%USERPROFILE%\.codex`, `%APPDATA%\Codex` |
| Starting a copy | `open -n -a ChatGPT --env … --args --user-data-dir=…` | `chatgpt-desktop.exe --user-data-dir=…` (the Store app's execution alias), with `CODEX_HOME`, `CODEX_ELECTRON_USER_DATA_PATH` and `CODEX_SPARKLE_ENABLED=false` in its environment |
| Telling copies apart | `sysctl(KERN_PROCARGS2)` | each `ChatGPT.exe`'s command line, through WMI; helpers (`--type=`) are left out |
| Quitting a copy | `NSRunningApplication.terminate()` | `WM_QUERYENDSESSION` + `WM_ENDSESSION` (`ENDSESSION_CLOSEAPP`) to its window, as Windows does when signing out; ChatGPT quits normally. Closing the window would only hide it in the notification area, so it isn't used. Nothing is force-quit. |
| Bringing a copy forward | `NSRunningApplication.activate` | starting it again on the same folders: ChatGPT hands that start to the running copy, which shows its window |
| Browser extension | manifests under `~/Library/Application Support/<browser>/NativeMessagingHosts`; shared registry `~/Library/Application Support/OpenAI/Codex/chrome-native-hosts-v2.json` | the manifest `%LOCALAPPDATA%\OpenAI\extension\com.openai.codexextension.json` (and any other the browsers' `HKCU\Software\…\NativeMessagingHosts` keys point at); shared registry `%LOCALAPPDATA%\OpenAI\Codex\chrome-native-hosts-v2.json`. The Windows registry itself is only read. |
| Dock icon setting | copied from the main ChatGPT before each start | not needed: Windows has no Dock icon setting |
| Socket paths | 103 bytes at most, so account folders stay short | no such limit |
| Removing | Trash | Recycle Bin |
| This tool's folder | `~/.chatgpt-multi-accounts` | `%USERPROFILE%\.chatgpt-multi-accounts` (`CMA_HOME` moves it) |

Checked on ChatGPT 26.1103 for Windows: two account copies run next to the main ChatGPT, each on its own
`CODEX_HOME` and window data; starting one again brings it forward without a second copy; both quit in a few
seconds; the main ChatGPT keeps the same process throughout.

Not ported yet: the `chatgpt-multi` command line tool and the `--demo` mode.

## Build

```powershell
windows\scripts\build.ps1        # runs the tests, then writes windows\dist\ChatGPTMultiAccounts.exe and a zip
dotnet run --project windows\CoreTests              # the account rules against a pretend ChatGPT
dotnet run --project windows\CoreTests -- --real    # adds, opens, brings forward, closes and removes two throwaway accounts
```

Needs the .NET 8 SDK. `windows\scripts\make-icon.ps1` makes `AppIcon.ico` from `assets/icon/AppIcon-1024.png`.
