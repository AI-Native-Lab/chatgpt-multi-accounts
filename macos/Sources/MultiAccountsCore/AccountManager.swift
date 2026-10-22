import Darwin
import Foundation

/// An extra account and what it is doing now.
public struct AccountStatus: Equatable, Identifiable, Sendable {
    public var account: Account
    /// Its place in the list, starting at 1; the command line accepts it instead of the name.
    public var number: Int
    /// Its own copy of ChatGPT, while open.
    public var pid: pid_t?
    /// Who it is signed in to. Nil until it has signed in (or after it signed out).
    public var signIn: SignIn?
    /// Where the same ChatGPT account is also signed in: "the main ChatGPT" or another account's
    /// name. Signing in twice to one account works, but is rarely what was meant.
    public var sameAs: String?
    public var folder: URL

    public var id: String { account.id }
    public var isOpen: Bool { pid != nil }
    public var isSignedIn: Bool { signIn != nil }
    /// The chosen name, else the email it signed in with.
    public var displayName: String { account.name ?? signIn?.email ?? "New account \(number)" }
}

/// The main ChatGPT: whether it runs and who it is signed in to.
public struct MainState: Equatable, Sendable {
    public var pid: pid_t?
    public var signIn: SignIn?
    public var installed: Bool

    public var running: Bool { pid != nil }
    public var displayName: String { signIn?.email ?? "Main ChatGPT" }
}

public struct Snapshot: Equatable, Sendable {
    public var main: MainState
    public var accounts: [AccountStatus]

    /// How many ChatGPT accounts are open right now, the main one included.
    public var openCount: Int { (main.running ? 1 : 0) + accounts.filter(\.isOpen).count }
    public var openAccounts: [AccountStatus] { accounts.filter(\.isOpen) }
    /// Accounts that can be opened with one click: signed in, and not open yet.
    public var readyToOpen: [AccountStatus] { accounts.filter { $0.isSignedIn && !$0.isOpen } }
}

/// Adds, opens and closes ChatGPT accounts, each in its own copy of ChatGPT, all at the same time.
///
/// Rules that keep every sign-in and the main ChatGPT safe:
/// - The main ChatGPT's folders are only read, and the main ChatGPT is never quit or restarted.
/// - Each account signs in once, in its own copy of ChatGPT, on its own folders. Sign-ins are
///   never copied between folders, so no two copies ever share (and fight over) one set of tokens.
/// - Nothing is force-quit: closing an account is ⌘Q in its window. Nothing is sent to OpenAI.
public final class AccountManager {
    public let layout: Layout
    public var quitTimeout: TimeInterval = 30
    /// How long a new copy may take to show up as a running process.
    public var launchTimeout: TimeInterval = 20
    /// Time between starting two copies with Open All, so they don't all load at once.
    public var launchSpacing: TimeInterval = 1
    /// How removed account folders leave; tests and the demo keep them out of the real Trash.
    public var moveToTrash: (URL) throws -> Void
    /// The space a folder takes; the demo replaces it to show realistic sizes.
    public var sizeProvider: (URL) -> Int64? = Disk.allocatedSize(of:)
    /// Whether the app is set up to run on other folders; `doctor` reads the app bundle for it.
    public var supportsSeparateCopies: (URL) -> Bool? = AccountManager.readSupportsSeparateCopies(app:)
    /// Where the account manager reports what it did, a line at a time.
    public var log: (String) -> Void

    let chatgpt: ChatGPTControl

    public init(layout: Layout = .system(), chatgpt: ChatGPTControl = SystemChatGPTControl()) {
        self.layout = layout
        self.chatgpt = chatgpt
        moveToTrash = { url in
            if let trash = layout.trash {
                try Files.privateFolder(trash)
                try FileManager.default.moveItem(
                    at: url, to: trash.appendingPathComponent("\(url.lastPathComponent)-\(UUID().uuidString.prefix(8))"))
            } else {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            }
        }
        log = { message in Self.appendLog(message, to: layout.logFile) }
    }

    // MARK: - Reading

    public func accounts() -> [Account] {
        (try? Registry.load(layout.accountsFile)) ?? []
    }

    public func mainState() -> MainState {
        MainState(pid: chatgpt.mainPID(), signIn: SignIn.read(codexHome: layout.mainCodexHome),
                  installed: Files.exists(layout.chatgptApp))
    }

    /// The main ChatGPT and every account, at once.
    public func snapshot() -> Snapshot {
        let main = mainState()
        var statuses: [AccountStatus] = []
        for (index, account) in accounts().enumerated() {
            statuses.append(AccountStatus(account: account, number: index + 1,
                                          pid: chatgpt.pid(usingDataFolder: layout.dataFolder(of: account)),
                                          signIn: SignIn.read(codexHome: layout.codexHome(of: account)),
                                          folder: layout.folder(of: account)))
        }
        for index in statuses.indices {
            guard let identity = statuses[index].signIn?.identity else { continue }
            if identity == main.signIn?.identity {
                statuses[index].sameAs = "the main ChatGPT"
            } else if let earlier = statuses[..<index].first(where: { $0.signIn?.identity == identity }) {
                statuses[index].sameAs = "“\(earlier.displayName)”"
            }
        }
        return Snapshot(main: main, accounts: statuses)
    }

    /// Finds an account by list number, name or email (ignoring case), or folder name.
    public func find(_ query: String) throws -> AccountStatus {
        let statuses = snapshot().accounts
        if let number = Int(query), number >= 1, number <= statuses.count {
            return statuses[number - 1]
        }
        let matches: (AccountStatus) -> Bool = { status in
            [status.account.name, status.signIn?.email, status.account.id, status.displayName]
                .compactMap { $0 }
                .contains { $0.caseInsensitiveCompare(query) == .orderedSame }
        }
        if let match = statuses.first(where: matches) { return match }
        let names = statuses.map { "\($0.number). \($0.displayName)" }.joined(separator: ", ")
        throw MultiError.noSuchAccount(query, known: names.isEmpty ? "none yet" : names)
    }

    /// The space an account's folders take on disk.
    public func folderSize(of status: AccountStatus) -> Int64? {
        Files.exists(status.folder) ? sizeProvider(status.folder) : nil
    }

    // MARK: - Opening and closing

    /// Adds an account: makes its folders and opens its own ChatGPT window at the sign-in screen,
    /// next to the main ChatGPT and any account already open. It is named after the email it
    /// signs in with unless `name` is given.
    @discardableResult
    public func add(name: String?) throws -> Account {
        try withLock {
            var accounts = self.accounts()
            let clean = try name.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
                .map { try validName($0, ignoring: nil) }
            try requireChatGPT()
            try Files.privateFolder(layout.home)
            let account = Account(id: Account.newID(in: layout.home), name: clean, addedAt: Registry.now())
            if let problem = layout.socketPathProblem(for: account) { throw MultiError.pathTooLong(problem) }
            try Files.privateFolder(layout.codexHome(of: account))
            try Files.privateFolder(layout.dataFolder(of: account))
            accounts.append(account)
            try saveAccounts(accounts)
            log("Added \(clean.map { "“\($0)”" } ?? "a new account") in \(layout.folder(of: account).path)")
            try launch(account, label: clean.map { "“\($0)”" } ?? "The new account")
            return account
        }
    }

    /// Opens an account in its own ChatGPT window, or brings that window forward.
    @discardableResult
    public func open(_ query: String) throws -> String {
        try withLock {
            let status = try find(query)
            if let pid = status.pid {
                chatgpt.activate(pid: pid)
                return "Brought “\(status.displayName)” forward."
            }
            try launch(status.account, label: "“\(status.displayName)”")
            return status.isSignedIn
                ? "Opened “\(status.displayName)” in its own ChatGPT window."
                : "Opened “\(status.displayName)” at ChatGPT's sign-in screen."
        }
    }

    /// Opens every signed-in account, and the main ChatGPT, so they all run at once.
    @discardableResult
    public func openAll(progress: (String) -> Void = { _ in }) throws -> String {
        try withLock {
            let snapshot = self.snapshot()
            var opened: [String] = []
            if !snapshot.main.running && snapshot.main.installed {
                progress("Opening the main ChatGPT…")
                try launchMain()
                opened.append("the main ChatGPT")
                pause()
            }
            for (index, status) in snapshot.readyToOpen.enumerated() {
                progress("Opening “\(status.displayName)”…")
                try launch(status.account, label: "“\(status.displayName)”")
                opened.append("“\(status.displayName)”")
                if index < snapshot.readyToOpen.count - 1 { pause() }
            }
            guard !opened.isEmpty else { return "Every signed-in account is already open." }
            return "Opened \(Self.list(opened)). \(self.snapshot().openCount) ChatGPT accounts are open at once."
        }
    }

    /// Quits an account's own ChatGPT window, like ⌘Q in it. Its sign-in stays in its folder.
    @discardableResult
    public func close(_ query: String) throws -> String {
        let status = try find(query)
        guard let pid = status.pid else { return "“\(status.displayName)” isn't open." }
        guard chatgpt.quit(pid: pid, timeout: quitTimeout) else { throw MultiError.didNotQuit("“\(status.displayName)”") }
        log("Closed “\(status.displayName)”")
        return "Closed “\(status.displayName)”. It stays signed in, ready to open again."
    }

    /// Closes every account's window. The main ChatGPT keeps running.
    @discardableResult
    public func closeAll(progress: (String) -> Void = { _ in }) throws -> String {
        let open = snapshot().openAccounts
        guard !open.isEmpty else { return "No account is open besides the main ChatGPT." }
        var stuck: [String] = []
        for status in open {
            progress("Closing “\(status.displayName)”…")
            if let pid = status.pid, !chatgpt.quit(pid: pid, timeout: quitTimeout) { stuck.append("“\(status.displayName)”") }
        }
        log("Closed \(open.count - stuck.count) account windows")
        if !stuck.isEmpty { throw MultiError.didNotQuit(Self.list(stuck)) }
        return "Closed \(open.count == 1 ? "1 account" : "\(open.count) accounts"). The main ChatGPT keeps running."
    }

    /// Brings the main ChatGPT forward, or opens it.
    public func openMain() throws {
        if let pid = chatgpt.mainPID() {
            chatgpt.activate(pid: pid)
        } else {
            try requireChatGPT()
            try launchMain()
        }
    }

    public func activate(pid: pid_t) {
        chatgpt.activate(pid: pid)
    }

    // MARK: - The list

    public func rename(_ query: String, to name: String) throws {
        try withLock {
            let status = try find(query)
            var accounts = self.accounts()
            guard let index = accounts.firstIndex(where: { $0.id == status.account.id }) else { return }
            accounts[index].name = try validName(name, ignoring: status.account.id)
            try saveAccounts(accounts)
        }
    }

    /// Forgets an account: its folders, with its sign-in, chats and settings on this Mac, go to
    /// the Trash. The ChatGPT account itself is untouched.
    @discardableResult
    public func remove(_ query: String) throws -> String {
        try withLock {
            let status = try find(query)
            if status.isOpen { throw MultiError.isOpen(status.displayName) }
            if Files.exists(status.folder) { try moveToTrash(status.folder) }
            try saveAccounts(accounts().filter { $0.id != status.account.id })
            keepBrowserExtensionWithMain()
            log("Removed “\(status.displayName)”")
            return "Removed “\(status.displayName)”. Its folder is in the Trash; the ChatGPT account itself is untouched."
        }
    }

    /// Puts the main ChatGPT back in charge of the browser extension after an account's copy took
    /// it over (see `BrowserExtension`). Returns what changed.
    @discardableResult
    public func keepBrowserExtensionWithMain() -> [String] {
        let changes = BrowserExtension.keepWithMain(layout)
        changes.forEach(log)
        return changes
    }

    /// Checks that this Mac's ChatGPT looks the way this tool expects.
    public func doctor() -> [(name: String, value: String, ok: Bool)] {
        var checks: [(String, String, Bool)] = []
        let bundle = Bundle(url: layout.chatgptApp)
        let version = bundle?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        checks.append(("ChatGPT app", "\(layout.chatgptApp.path)\(version.map { " (\($0))" } ?? "")",
                       Files.exists(layout.chatgptApp)))
        let id = bundle?.bundleIdentifier ?? "none"
        checks.append(("Bundle identifier", id, id == ChatGPTApp.bundleID))
        let separate = supportsSeparateCopies(layout.chatgptApp)
        checks.append(("Runs copies on separate folders", separate.map { $0 ? "yes" : "no" } ?? "unknown", separate ?? false))
        let main = mainState()
        checks.append(("Main ChatGPT running", main.running ? "yes" : "no", true))
        checks.append(("Main ChatGPT signed in", main.signIn.map { describe($0) } ?? "signed out", true))
        checks.append(("Main ChatGPT folders", "\(layout.mainCodexHome.path), \(layout.mainData.path)",
                       Files.exists(layout.mainCodexHome)))
        let probe = Account(id: "abcdef")
        checks.append(("Accounts folder", layout.home.path, layout.socketPathProblem(for: probe) == nil))
        let browser: (String, Bool) = switch BrowserExtension.isWithMain(layout) {
        case nil: ("not set up in the main ChatGPT", true)
        case true?: ("paired with the main ChatGPT", true)
        case false?: ("taken by an account's copy; run any command or open the app to fix it", false)
        }
        checks.append(("Browser extension", browser.0, browser.1))
        let snapshot = self.snapshot()
        checks.append(("Accounts", String(snapshot.accounts.count), true))
        checks.append(("Open now", "\(snapshot.openCount) (main ChatGPT \(main.running ? "included" : "not open"))", true))
        return checks
    }

    public func describe(_ signIn: SignIn) -> String {
        signIn.label + (signIn.planName.map { " (\($0))" } ?? "")
    }

    // MARK: - Helpers

    /// Starts an account's own copy of ChatGPT and waits until its process shows. The lock is
    /// held by the caller.
    func launch(_ account: Account, label: String) throws {
        try requireChatGPT()
        if let problem = layout.socketPathProblem(for: account) { throw MultiError.pathTooLong(problem) }
        let codexHome = try Files.privateFolder(layout.codexHome(of: account))
        let data = try Files.privateFolder(layout.dataFolder(of: account))
        try SharedSettings.sync(from: layout.mainCodexHome, to: codexHome)
        try chatgpt.launchAccount(app: layout.chatgptApp, codexHome: codexHome, dataFolder: data)
        let deadline = Date().addingTimeInterval(launchTimeout)
        while chatgpt.pid(usingDataFolder: data) == nil {
            if Date() > deadline { throw MultiError.didNotStart(label) }
            Thread.sleep(forTimeInterval: 0.2)
        }
        log("Opened \(label) (\(account.id))")
    }

    func launchMain() throws {
        log("Opening the main ChatGPT")
        try chatgpt.launchMain(app: layout.chatgptApp)
    }

    func pause() {
        if launchSpacing > 0 { Thread.sleep(forTimeInterval: launchSpacing) }
    }

    func requireChatGPT() throws {
        guard Files.exists(layout.chatgptApp) else { throw MultiError.chatgptNotInstalled(layout.chatgptApp.path) }
    }

    func validName(_ name: String, ignoring id: String?) throws -> String {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw MultiError.emptyName }
        if snapshot().accounts.contains(where: { $0.account.id != id && $0.displayName.caseInsensitiveCompare(clean) == .orderedSame }) {
            throw MultiError.nameTaken(clean)
        }
        return clean
    }

    func saveAccounts(_ accounts: [Account]) throws {
        try Files.privateFolder(layout.home)
        try Registry.save(accounts, to: layout.accountsFile)
    }

    /// Runs `body` holding `<home>/.lock`, so the app and the command never change things at once.
    func withLock<T>(_ body: () throws -> T) throws -> T {
        try Files.privateFolder(layout.home)
        let fd = Darwin.open(layout.lockFile.path, O_RDWR | O_CREAT, 0o600)
        guard fd >= 0 else { throw MultiError.io("Can't open \(layout.lockFile.path).") }
        defer { Darwin.close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw MultiError.busy }
        return try body()
    }

    static func appendLog(_ message: String, to url: URL) {
        _ = try? Files.privateFolder(url.deletingLastPathComponent())
        let line = "[\(Registry.now())] \(message)\n"
        let fd = Darwin.open(url.path, O_WRONLY | O_CREAT | O_APPEND, 0o600)
        guard fd >= 0 else { return }
        defer { Darwin.close(fd) }
        _ = line.withCString { write(fd, $0, strlen($0)) }
    }

    /// "A", "A and B", "A, B and C".
    static func list(_ items: [String]) -> String {
        guard items.count > 1 else { return items.first ?? "" }
        return items.dropLast().joined(separator: ", ") + " and " + items.last!
    }

    /// Whether ChatGPT's code knows `CODEX_ELECTRON_USER_DATA_PATH`, the setting that lets copies
    /// run on separate folders. Reads app.asar (about 0.5 GB) once, in pieces.
    public static func readSupportsSeparateCopies(app: URL) -> Bool? {
        let asar = app.appendingPathComponent("Contents/Resources/app.asar")
        guard let handle = try? FileHandle(forReadingFrom: asar) else { return nil }
        defer { try? handle.close() }
        let needle = Data(ChatGPTApp.userDataVariable.utf8)
        var carry = Data()
        while let chunk = try? handle.read(upToCount: 8 << 20), !chunk.isEmpty {
            let window = carry + chunk
            if window.range(of: needle) != nil { return true }
            carry = window.suffix(needle.count - 1)
        }
        return false
    }
}
