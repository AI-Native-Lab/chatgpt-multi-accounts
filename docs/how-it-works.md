# How ChatGPT Multi-Accounts works

The rules the app and the `chatgpt-multi` command follow, and what they read and write. Everything here was checked against ChatGPT 26.1013 (`com.openai.codex`, the ChatGPT desktop app that includes Codex) on macOS 26.

## The ChatGPT app

ChatGPT for macOS is an Electron app running on OpenAI's own Chromium-based runtime ("Owl"). Its main process is `ChatGPT.app/Contents/MacOS/ChatGPT`; renderers, the GPU process and the bundled `codex` app server run as helpers. It keeps its data in two folders:

| Folder | Holds | Chosen by |
|--------|-------|-----------|
| `~/.codex` | `auth.json` (the sign-in), `config.toml` (settings, including the app's own under `[desktop]`), local threads and history, plugins, sockets | `CODEX_HOME` |
| `~/Library/Application Support/Codex` | Chromium's profile: cookies, caches, local storage, `SingletonLock` | `CODEX_ELECTRON_USER_DATA_PATH` and `--user-data-dir` |

ChatGPT reads `CODEX_ELECTRON_USER_DATA_PATH` at startup and, when it is set, takes its single-instance lock in that folder and keeps the given `CODEX_HOME` even after it loads the login shell's environment. On macOS it holds no lock at all on its usual folders. So a copy started on other folders runs next to the main one.

One detail matters: Chromium's own process singleton runs before ChatGPT's code and uses the default folder unless it is given `--user-data-dir`. Without the switch, a second copy prints "Opening in existing browser session", hands its command line to the copy already running and exits.

## Opening an account

An account's copy is started through LaunchServices, so macOS treats it as ChatGPT (its permissions, its Dock icon), not as part of this app:

```bash
open -n -a /Applications/ChatGPT.app \
  --env CODEX_HOME=~/.chatgpt-multi-accounts/<id>/codex \
  --env CODEX_ELECTRON_USER_DATA_PATH=~/.chatgpt-multi-accounts/<id>/data \
  --env CODEX_SPARKLE_ENABLED=false \
  --args --user-data-dir=~/.chatgpt-multi-accounts/<id>/data
```

The paths are absolute in practice. `CODEX_SPARKLE_ENABLED=false` leaves update checks to the main ChatGPT. Variables this process inherited that start with `CODEX_`, `ELECTRON_` or `CMA_` are left out, so running the command inside a ChatGPT or editor terminal can't point a copy at the wrong folder (or, with `ELECTRON_RUN_AS_NODE`, stop it from opening a window).

The app then waits until the copy's process shows (up to 20 seconds) and reports it as open.

## Telling the copies apart

The app lists every process whose executable is `Contents/MacOS/ChatGPT` inside a bundle with the identifier `com.openai.codex`, and reads its command line and environment with `sysctl(KERN_PROCARGS2)`:

- no `--user-data-dir` and no `CODEX_ELECTRON_USER_DATA_PATH`: the **main ChatGPT**;
- `--user-data-dir` naming an account's `data` folder: **that account's copy**;
- anything else (a copy someone started on other folders, or one whose command line can't be read): left alone.

**Close** asks only that process to quit, through `NSRunningApplication.terminate()` (like ⌘Q in its window), falling back to `SIGTERM`, which Chromium also handles as a normal quit. It waits up to 30 seconds and never force-quits. The main ChatGPT is never asked to quit.

## Who an account is

ChatGPT saves its sign-in in `<CODEX_HOME>/auth.json` (`cli_auth_credentials_store = "file"`, its default): OAuth tokens and an ID token. The app decodes only the ID token's payload (the JWT's middle part, without checking its signature, since it only labels the list) for `email`, `name` and, under `https://api.openai.com/auth`, `chatgpt_plan_type`, `chatgpt_user_id` and `chatgpt_account_id` (the workspace). The tokens themselves are never copied, sent or shown.

Two folders with the same user and workspace are the same ChatGPT account; the app marks the later one ("Same as main", "Duplicate"), since that is rarely what was meant. The same person in two workspaces (say, personal and a Team workspace) counts as two accounts.

## Two app-wide ChatGPT settings

Every copy runs the same `ChatGPT.app`, and a few things ChatGPT does at startup act on the whole Mac. Two of them would let a new account's copy undo the main ChatGPT's choices, so the app looks after them.

### The Dock icon

ChatGPT's **Dock icon** setting (`dock-icon-preference` under `[desktop]` in `config.toml`) is applied to the app bundle itself, through its `launch-services-helper` and the `DockIconPreference` keys of `com.openai.codex` preferences. A copy on a new folder has no `config.toml`, so it would put the default icon back for every copy.

Before each start, the app copies the main ChatGPT's `dock-icon-preference` line into the account's `config.toml` (or removes it there when the main ChatGPT has none). Only that line changes; every other setting and table in the account's `config.toml` is kept as it is.

### The browser extension

ChatGPT's browser extension (ChatGPT for Chrome, also in Edge, Brave, Vivaldi, Opera and Chromium) reaches the app through a native-messaging host named `com.openai.codexextension`. About half a minute after it starts, every copy of ChatGPT:

- rewrites that host's manifest in each browser's `NativeMessagingHosts` folder to point at its own copy of the host, inside its `CODEX_HOME`;
- adds an entry for itself to the registry all copies share, `~/Library/Application Support/OpenAI/Codex/chrome-native-hosts-v2.json`.

The copy that started last would take the extension over. So, every two seconds while an account's copy runs (in the app), and for two minutes after `add` or `open` (in the command), the app:

1. reads the main ChatGPT's own registry, `~/.codex/chrome-native-hosts-v2.json`, for the main ChatGPT's host;
2. points every manifest of that host back at it, if the manifest points inside `~/.chatgpt-multi-accounts` (the rest of the manifest is kept);
3. takes the entries whose `codexHome` is inside `~/.chatgpt-multi-accounts` out of the shared registry.

Nothing else in those files changes, and nothing changes at all if the main ChatGPT never set the extension up. The activity log records each fix. `chatgpt-multi doctor` reports whether the extension is paired with the main ChatGPT.

## Socket paths

ChatGPT creates Unix sockets inside both folders; the longest is `<CODEX_HOME>/app-server-control/app-server-control.sock`. macOS allows 103 bytes for a socket path, so each account lives in `~/.chatgpt-multi-accounts/<id>`, with `<id>` six lowercase letters and digits. The app refuses to add an account whose folders would be too long and says so; `CMA_HOME` moves the accounts elsewhere.

## Files

```
~/.chatgpt-multi-accounts/                     (mode 700)
  accounts.json        {"version": 1, "accounts": [{"id": "k3f9q2", "name": "Work", "addedAt": "2026-10-22T15:30:00"}]}
  <id>/codex/          the account's CODEX_HOME
  <id>/data/           the account's Chromium profile
  activity.log         one line per change
  .lock                held while the app or the command changes something, so they never do so at once
  .guard.lock          held by the command's browser-extension guard; .guard-until is its deadline
```

An account without a `name` is shown by its email. Removing an account moves its folder to the Trash.

## What this app never does

- quit, restart or change the main ChatGPT, or write to `~/.codex` or `~/Library/Application Support/Codex`;
- copy, move or read the value of a token;
- send anything over the network;
- force-quit a process.

## Settings for tests

`CMA_HOME`, `CMA_MAIN_CODEX_HOME`, `CMA_MAIN_DATA`, `CMA_APP`, `CMA_APP_SUPPORT` and `CMA_TRASH` point the command at other folders. `CMA_FAKE_APP` replaces ChatGPT with a pretend one made of files (see `FileChatGPTControl`), which the end-to-end tests use.
