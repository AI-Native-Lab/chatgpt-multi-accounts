import AppKit
import MultiAccountsCore

// The model only touches the manager on its serial queues: `work` for anything that reads the
// accounts or starts and quits ChatGPT, `sizeQueue` for measuring folders, which changes nothing.
extension AccountManager: @unchecked Sendable {}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var snapshot: Snapshot?
    @Published private(set) var busy: String?
    @Published private(set) var sizes: [String: Int64] = [:]
    @Published var showingSettings = false

    let isDemo: Bool
    let manager: AccountManager
    let settings: AppSettings
    private let work = DispatchQueue(label: "chatgpt-multi-accounts.work")
    private let sizeQueue = DispatchQueue(label: "chatgpt-multi-accounts.sizes")
    private var timers: [Timer] = []
    private var refreshQueued = false

    init(manager: AccountManager, settings: AppSettings, isDemo: Bool) {
        self.manager = manager
        self.settings = settings
        self.isDemo = isDemo
    }

    /// Starts keeping the state up to date: every 2 seconds, and folder sizes every 10 minutes.
    func start() {
        refresh()
        refreshSizes()
        timers = [
            Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            },
            Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.refreshSizes() }
            },
        ]
    }

    var statuses: [AccountStatus] { snapshot?.accounts ?? [] }
    var openCount: Int { snapshot?.openCount ?? 0 }
    var canOpenAll: Bool {
        guard let snapshot else { return false }
        return !snapshot.readyToOpen.isEmpty || (!snapshot.main.running && snapshot.main.installed)
    }

    var headline: String {
        guard let snapshot else { return "ChatGPT Multi-Accounts" }
        if !snapshot.main.installed { return "ChatGPT isn't installed" }
        switch snapshot.openCount {
        case 0: return "No ChatGPT account open"
        case 1: return "1 ChatGPT account open"
        default: return "\(snapshot.openCount) ChatGPT accounts open at once"
        }
    }

    var subheadline: String {
        guard let snapshot else { return "" }
        guard snapshot.main.installed else { return "Install the ChatGPT desktop app from chatgpt.com/download, then open it once." }
        var parts = ["Main: \(snapshot.main.signIn?.email ?? "signed out")\(snapshot.main.running ? "" : " (not open)")"]
        let open = snapshot.openAccounts.count
        if open > 0 { parts.append(open == 1 ? "1 other open" : "\(open) others open") }
        let closed = snapshot.accounts.count - open
        if closed > 0 { parts.append("\(closed) closed") }
        return parts.joined(separator: " · ")
    }

    func refresh() {
        guard !refreshQueued else { return }
        refreshQueued = true
        work.async { [manager] in
            let snapshot = manager.snapshot()
            // A copy of ChatGPT takes the browser extension over some seconds after it starts.
            if !snapshot.openAccounts.isEmpty { manager.keepBrowserExtensionWithMain() }
            Task { @MainActor in
                self.refreshQueued = false
                if self.snapshot != snapshot { self.snapshot = snapshot }
            }
        }
    }

    /// Reads everything at once and waits for it; used before drawing screenshots.
    func refreshNow() {
        snapshot = work.sync { manager.snapshot() }
        sizes = sizeQueue.sync { Self.readSizes(manager) }
    }

    func refreshSizes() {
        sizeQueue.async { [manager] in
            let sizes = Self.readSizes(manager)
            Task { @MainActor in self.sizes = sizes }
        }
    }

    private nonisolated static func readSizes(_ manager: AccountManager) -> [String: Int64] {
        var sizes: [String: Int64] = [:]
        for status in manager.snapshot().accounts {
            sizes[status.account.id] = manager.folderSize(of: status)
        }
        return sizes
    }

    // MARK: - Actions

    func add() {
        guard let name = Prompt.text(
            title: "Add a ChatGPT account",
            message: "A new ChatGPT window opens at its sign-in screen, next to your main ChatGPT, which keeps running. Sign in there with the other account; it then stays signed in, in its own window, as long as you like.\n\nIf the sign-in page goes straight to an account you already use here, log out on that page and sign in with the other one.\n\nName (optional; it is named after its email otherwise):",
            placeholder: "For example: Work", button: "Open Sign-In Window", allowEmpty: true
        ) else { return }
        perform("Opening a new ChatGPT window…") { manager, _ in
            _ = try manager.add(name: name.isEmpty ? nil : name)
        }
    }

    func open(_ status: AccountStatus) {
        if let pid = status.pid { return manager.activate(pid: pid) }
        perform("Opening \(status.displayName)…") { manager, _ in
            try manager.open(status.account.id)
        }
    }

    func openAll() {
        perform("Opening every account…") { manager, progress in
            try manager.openAll(progress: progress)
        }
    }

    func close(_ status: AccountStatus) {
        perform("Closing \(status.displayName)…") { manager, _ in
            try manager.close(status.account.id)
        }
    }

    func closeAll() {
        perform("Closing every account…") { manager, progress in
            try manager.closeAll(progress: progress)
        }
    }

    func openMain() {
        perform(nil) { manager, _ in try manager.openMain() }
    }

    func rename(_ status: AccountStatus) {
        guard let name = Prompt.text(title: "Rename “\(status.displayName)”", message: "New name:",
                                     placeholder: status.displayName, initial: status.account.name ?? "")
        else { return }
        perform(nil) { manager, _ in try manager.rename(status.account.id, to: name) }
    }

    func remove(_ status: AccountStatus) {
        guard Prompt.confirm(
            title: "Remove “\(status.displayName)”?",
            message: "Its folders go to the Trash, with its sign-in, chats and settings on this Mac. The ChatGPT account itself is not touched; to use it here again, add it again and sign in.",
            button: "Move to Trash"
        ) else { return }
        perform(nil) { manager, _ in try manager.remove(status.account.id) }
    }

    func showFolder(_ status: AccountStatus) {
        NSWorkspace.shared.activateFileViewerSelecting([status.folder])
    }

    func showAccountsFolder() {
        try? FileManager.default.createDirectory(at: manager.layout.home, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([manager.layout.home])
    }

    func showMainFolder() {
        NSWorkspace.shared.activateFileViewerSelecting([manager.layout.mainCodexHome])
    }

    func openLog() {
        let log = manager.layout.logFile
        if FileManager.default.fileExists(atPath: log.path) {
            NSWorkspace.shared.open(log)
        } else {
            Prompt.info(title: "No activity yet", message: "The log starts when the first account is added or opened.")
        }
    }

    // MARK: - The command line tool

    /// The command inside this app, which `Install Command` links into ~/.local/bin.
    var bundledCommand: URL? {
        Bundle.main.url(forAuxiliaryExecutable: "chatgpt-multi")
    }

    var installedCommand: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/chatgpt-multi")
    }

    var commandInstalled: Bool {
        guard let bundled = bundledCommand,
              let target = try? FileManager.default.destinationOfSymbolicLink(atPath: installedCommand.path) else { return false }
        return target == bundled.path
    }

    func installCommand() {
        guard let bundled = bundledCommand else {
            Prompt.info(title: "Not available", message: "This copy of the app has no command line tool inside it.")
            return
        }
        objectWillChange.send()
        do {
            let fm = FileManager.default
            try fm.createDirectory(at: installedCommand.deletingLastPathComponent(), withIntermediateDirectories: true)
            if (try? fm.destinationOfSymbolicLink(atPath: installedCommand.path)) != nil || fm.fileExists(atPath: installedCommand.path) {
                try fm.removeItem(at: installedCommand)
            }
            try fm.createSymbolicLink(at: installedCommand, withDestinationURL: bundled)
            let onPath = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":")
                .contains { $0 == installedCommand.deletingLastPathComponent().path }
            Prompt.info(title: "Installed chatgpt-multi",
                        message: "Linked \(installedCommand.path) to the copy inside this app, so it stays up to date with the app."
                            + (onPath ? "" : "\n\nAdd ~/.local/bin to your PATH to run it by name:\necho 'export PATH=\"$HOME/.local/bin:$PATH\"' >> ~/.zshrc"))
        } catch {
            Prompt.error(error)
        }
    }

    // MARK: - Helpers

    private func perform(_ label: String?,
                         _ action: @escaping (AccountManager, @escaping (String) -> Void) throws -> Void) {
        guard busy == nil else { return }
        busy = label ?? "Working…"
        work.async { [manager] in
            let progress = Self.progressSink { self.busy = $0 }
            var failure: Error?
            do { try action(manager, progress) } catch { failure = error }
            Task { @MainActor in
                self.busy = nil
                self.refresh()
                self.refreshSizes()
                if let failure { Prompt.error(failure) }
            }
        }
    }

    private nonisolated static func progressSink(_ update: @escaping @MainActor (String) -> Void) -> (String) -> Void {
        { message in Task { @MainActor in update(message) } }
    }
}
