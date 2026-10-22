import AppKit
import Foundation

/// Where ChatGPT and the accounts live on disk.
///
/// The main ChatGPT keeps its sign-in, chats and settings in `~/.codex` and its window data in
/// `~/Library/Application Support/Codex`. This tool never changes either. Each extra account gets
/// its own pair of folders under `<home>/<id>/`, and its own copy of ChatGPT runs on them:
///
///     <home>/<id>/codex   the account's CODEX_HOME: sign-in (auth.json), chats, settings
///     <home>/<id>/data    the account's window data: cookies, caches (Chromium's user data)
public struct Layout {
    /// The main ChatGPT's CODEX_HOME.
    public var mainCodexHome: URL
    /// The main ChatGPT's window data.
    public var mainData: URL
    /// This tool's folder: the account list, every account's folders and the activity log.
    public var home: URL
    public var chatgptApp: URL
    /// `~/Library/Application Support`, where browsers keep the native-messaging manifests of
    /// ChatGPT's browser extension.
    public var appSupport: URL
    /// Where removed account folders go. Nil means the Trash.
    public var trash: URL?

    public init(mainCodexHome: URL, mainData: URL, home: URL, chatgptApp: URL, appSupport: URL, trash: URL? = nil) {
        self.mainCodexHome = mainCodexHome
        self.mainData = mainData
        self.home = home
        self.chatgptApp = chatgptApp
        self.appSupport = appSupport
        self.trash = trash
    }

    public var accountsFile: URL { home.appendingPathComponent("accounts.json") }
    public var logFile: URL { home.appendingPathComponent("activity.log") }
    var lockFile: URL { home.appendingPathComponent(".lock") }

    /// An account's folder, holding its `codex` and `data` folders.
    public func folder(of account: Account) -> URL {
        home.appendingPathComponent(account.id, isDirectory: true)
    }

    /// The account's CODEX_HOME.
    public func codexHome(of account: Account) -> URL {
        folder(of: account).appendingPathComponent("codex", isDirectory: true)
    }

    /// The account's window data, ChatGPT's `--user-data-dir`.
    public func dataFolder(of account: Account) -> URL {
        folder(of: account).appendingPathComponent("data", isDirectory: true)
    }

    /// ChatGPT puts Unix sockets inside both folders (the longest is
    /// `app-server-control/app-server-control.sock`), and macOS allows a socket path of 103 bytes,
    /// so an account's folders must have short paths. Nil when they fit; otherwise the problem.
    public func socketPathProblem(for account: Account) -> String? {
        let longest = [codexHome(of: account).path + "/" + ChatGPTApp.longestSocketSuffix,
                       dataFolder(of: account).path + "/" + ChatGPTApp.longestSocketSuffix]
            .max { $0.utf8.count < $1.utf8.count }!
        guard longest.utf8.count > ChatGPTApp.socketPathLimit else { return nil }
        return "\(home.path) is too long a path for ChatGPT's sockets (\(longest.utf8.count) of \(ChatGPTApp.socketPathLimit) bytes). "
            + "Set CMA_HOME to a shorter folder."
    }

    /// The real layout of the current user. `CMA_HOME`, `CMA_MAIN_CODEX_HOME`, `CMA_MAIN_DATA`,
    /// `CMA_APP`, `CMA_APP_SUPPORT` and `CMA_TRASH` point it elsewhere for tests.
    public static func system(environment: [String: String] = ProcessInfo.processInfo.environment) -> Layout {
        var home = FileManager.default.homeDirectoryForCurrentUser
        // The account's home from the user database, so a stray $HOME can't point at the wrong folder.
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            home = URL(fileURLWithPath: String(cString: dir), isDirectory: true)
        }
        func path(_ key: String, default value: URL) -> URL {
            guard let override = environment[key], !override.isEmpty else { return value }
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        }
        var app = URL(fileURLWithPath: "/Applications/ChatGPT.app", isDirectory: true)
        if Bundle(url: app)?.bundleIdentifier != ChatGPTApp.bundleID,
           let found = NSWorkspace.shared.urlForApplication(withBundleIdentifier: ChatGPTApp.bundleID) {
            app = found
        }
        let appSupport = home.appendingPathComponent("Library/Application Support", isDirectory: true)
        return Layout(
            mainCodexHome: path("CMA_MAIN_CODEX_HOME", default: home.appendingPathComponent(".codex", isDirectory: true)),
            mainData: path("CMA_MAIN_DATA", default: appSupport.appendingPathComponent("Codex", isDirectory: true)),
            home: path("CMA_HOME", default: home.appendingPathComponent(".chatgpt-multi-accounts", isDirectory: true)),
            chatgptApp: path("CMA_APP", default: app),
            appSupport: path("CMA_APP_SUPPORT", default: appSupport),
            trash: environment["CMA_TRASH"].map { URL(fileURLWithPath: $0, isDirectory: true) })
    }
}

public enum ChatGPTApp {
    /// The ChatGPT desktop app, which since October 2026 includes Codex.
    public static let bundleID = "com.openai.codex"
    /// The main executable inside ChatGPT.app; its helpers have other names.
    static let executable = "Contents/MacOS/ChatGPT"
    /// Chromium's switch for the window data folder. Without it, a second copy hands itself over
    /// to the copy already running ("Opening in existing browser session") and exits.
    static let userDataSwitch = "--user-data-dir="
    /// ChatGPT's own variables for running on other folders: it then keeps its single-instance
    /// lock in that folder, so copies on different folders run side by side.
    static let userDataVariable = "CODEX_ELECTRON_USER_DATA_PATH"
    static let codexHomeVariable = "CODEX_HOME"
    /// Only the main ChatGPT checks for updates; the copies run the same app bundle.
    static let updaterVariable = "CODEX_SPARKLE_ENABLED"
    /// The longest socket path ChatGPT creates inside either folder, and the macOS limit.
    static let longestSocketSuffix = "app-server-control/app-server-control.sock"
    static let socketPathLimit = 103
}
