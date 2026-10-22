import Foundation

/// A pretend ChatGPT for the demo and the tests: it remembers which folders are "open" and
/// starts nothing.
public final class SimulatedChatGPT: ChatGPTControl, @unchecked Sendable {
    private let lock = NSLock()
    private var main: pid_t?
    private var copies: [String: pid_t] = [:]
    private var nextPID: pid_t = 41_001

    /// How long quitting takes.
    public var quitDelay: TimeInterval = 0
    /// Makes quitting fail, like a ChatGPT stuck on a "Quit anyway?" prompt.
    public var refusesToQuit = false
    /// Makes account copies fail to start, like a ChatGPT that exits at once.
    public var failsToStart = false
    /// Called when a copy starts on a CODEX_HOME without a sign-in, to play the person signing in.
    public var signIn: ((URL) -> Void)?
    /// Every account copy started, in order: its CODEX_HOME and window data folder.
    public private(set) var launches: [(codexHome: URL, dataFolder: URL)] = []
    public private(set) var activated: [pid_t] = []

    public init() {}

    public func mainPID() -> pid_t? {
        lock.withLock { main }
    }

    public func pid(usingDataFolder dataFolder: URL) -> pid_t? {
        lock.withLock { copies[SystemChatGPTControl.canonical(dataFolder.path)] }
    }

    public func anyInstanceRunning() -> Bool {
        lock.withLock { main != nil || !copies.isEmpty }
    }

    public func quit(pid: pid_t, timeout: TimeInterval) -> Bool {
        if refusesToQuit { return false }
        Thread.sleep(forTimeInterval: quitDelay)
        lock.withLock {
            if main == pid { main = nil }
            copies = copies.filter { $0.value != pid }
        }
        return true
    }

    public func launchMain(app: URL) throws {
        lock.withLock { main = takePID() }
    }

    public func launchAccount(app: URL, codexHome: URL, dataFolder: URL) throws {
        if failsToStart { return }
        lock.withLock {
            copies[SystemChatGPTControl.canonical(dataFolder.path)] = takePID()
            launches.append((codexHome, dataFolder))
        }
        if SignIn.read(codexHome: codexHome) == nil { signIn?(codexHome) }
    }

    public func activate(pid: pid_t) {
        lock.withLock { activated.append(pid) }
    }

    private func takePID() -> pid_t {
        defer { nextPID += 1 }
        return nextPID
    }
}

/// A pretend ChatGPT whose state is files, so separate runs of the command line tool share it.
/// Used by the command's end-to-end tests through `CMA_FAKE_APP`:
///
///     <CMA_FAKE_APP>          exists while the main ChatGPT "runs"
///     <CMA_FAKE_APP>.copies/  one file per account copy, named by its pid, holding its data folder
///
/// `CMA_FAKE_SIGN_IN=<email>` signs a new copy in to that email, `CMA_FAKE_STUCK` makes copies
/// refuse to quit and `CMA_FAKE_NO_START` makes them fail to start.
public final class FileChatGPTControl: ChatGPTControl {
    let marker: URL
    let environment: [String: String]
    static let mainFakePID: pid_t = 90_000

    public init(marker: URL, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.marker = marker
        self.environment = environment
    }

    private var copiesFolder: URL { URL(fileURLWithPath: marker.path + ".copies", isDirectory: true) }

    private func copies() -> [(pid: pid_t, file: URL, folder: String)] {
        let files = (try? FileManager.default.contentsOfDirectory(at: copiesFolder, includingPropertiesForKeys: nil)) ?? []
        return files.compactMap { file in
            guard let folder = try? String(contentsOf: file, encoding: .utf8), let pid = pid_t(file.lastPathComponent)
            else { return nil }
            return (pid, file, folder)
        }
    }

    public func mainPID() -> pid_t? {
        Files.exists(marker) ? Self.mainFakePID : nil
    }

    public func pid(usingDataFolder dataFolder: URL) -> pid_t? {
        let wanted = SystemChatGPTControl.canonical(dataFolder.path)
        return copies().first { $0.folder == wanted }?.pid
    }

    public func anyInstanceRunning() -> Bool {
        mainPID() != nil || !copies().isEmpty
    }

    public func quit(pid: pid_t, timeout: TimeInterval) -> Bool {
        if environment["CMA_FAKE_STUCK"] != nil { return false }
        if pid == Self.mainFakePID {
            try? FileManager.default.removeItem(at: marker)
        }
        for copy in copies() where copy.pid == pid { try? FileManager.default.removeItem(at: copy.file) }
        return true
    }

    public func launchMain(app: URL) throws {
        FileManager.default.createFile(atPath: marker.path, contents: nil)
    }

    public func launchAccount(app: URL, codexHome: URL, dataFolder: URL) throws {
        guard environment["CMA_FAKE_NO_START"] == nil else { return }
        try FileManager.default.createDirectory(at: copiesFolder, withIntermediateDirectories: true)
        let pid = (copies().map(\.pid).max() ?? Self.mainFakePID) + 1
        try Data(SystemChatGPTControl.canonical(dataFolder.path).utf8)
            .write(to: copiesFolder.appendingPathComponent(String(pid)))
        if let email = environment["CMA_FAKE_SIGN_IN"], SignIn.read(codexHome: codexHome) == nil {
            try Demo.writeSignIn(codexHome: codexHome, email: email, plan: "plus")
        }
    }

    public func activate(pid: pid_t) {}
}
