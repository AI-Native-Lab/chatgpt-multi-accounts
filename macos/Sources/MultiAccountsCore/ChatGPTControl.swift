import AppKit
import Darwin
import Foundation

/// Everything the account manager needs from the running system. Tests and the demo swap in a fake.
public protocol ChatGPTControl: AnyObject {
    /// The main ChatGPT: the copy running on ChatGPT's own folders.
    func mainPID() -> pid_t?
    /// The copy of ChatGPT running on an account's window data folder, if one runs.
    func pid(usingDataFolder dataFolder: URL) -> pid_t?
    /// Whether any copy of ChatGPT runs, the main one or an account's.
    func anyInstanceRunning() -> Bool
    /// Asks one copy of ChatGPT to quit, like ⌘Q in it, and waits until it has. Returns false
    /// when it is still running after `timeout`.
    func quit(pid: pid_t, timeout: TimeInterval) -> Bool
    /// Starts the main ChatGPT.
    func launchMain(app: URL) throws
    /// Starts another copy of ChatGPT on an account's folders.
    func launchAccount(app: URL, codexHome: URL, dataFolder: URL) throws
    /// Brings a running copy to the front.
    func activate(pid: pid_t)
}

/// The real ChatGPT app on this Mac.
///
/// ChatGPT holds no single-instance lock on macOS while it runs on its own folders, and runs on
/// other folders when told so with `CODEX_HOME`, `CODEX_ELECTRON_USER_DATA_PATH` and Chromium's
/// `--user-data-dir`. So the main ChatGPT is the copy started without `--user-data-dir`, and an
/// account's copy is the one whose switch names that account's folder.
public final class SystemChatGPTControl: ChatGPTControl {
    public init() {}

    public func mainPID() -> pid_t? {
        Self.instances().first { $0.isMain }?.pid
    }

    public func pid(usingDataFolder dataFolder: URL) -> pid_t? {
        let wanted = Self.canonical(dataFolder.path)
        return Self.instances().first { $0.known && $0.dataFolder.map(Self.canonical) == wanted }?.pid
    }

    public func anyInstanceRunning() -> Bool {
        !Self.instances().isEmpty
    }

    public func quit(pid: pid_t, timeout: TimeInterval) -> Bool {
        guard isAlive(pid) else { return true }
        // NSRunningApplication addresses this copy alone; AppleScript's `tell application` would
        // pick any of them. If the quit request can't be sent, SIGTERM makes ChatGPT quit just as
        // gracefully.
        if NSRunningApplication(processIdentifier: pid)?.terminate() != true {
            kill(pid, SIGTERM)
        }
        let deadline = Date().addingTimeInterval(timeout)
        while isAlive(pid) {
            if Date() > deadline { return false }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return true
    }

    public func launchMain(app: URL) throws {
        // With an account's copy running, a plain `open` would only bring that one forward.
        var args = ["-a", app.path]
        if anyInstanceRunning() { args.insert("-n", at: 0) }
        try runOpen(args)
    }

    public func launchAccount(app: URL, codexHome: URL, dataFolder: URL) throws {
        try runOpen(["-n", "-a", app.path,
                     "--env", "\(ChatGPTApp.codexHomeVariable)=\(codexHome.path)",
                     "--env", "\(ChatGPTApp.userDataVariable)=\(dataFolder.path)",
                     "--env", "\(ChatGPTApp.updaterVariable)=false",
                     "--args", ChatGPTApp.userDataSwitch + dataFolder.path])
    }

    public func activate(pid: pid_t) {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return }
        let bringForward = {
            if #available(macOS 14.0, *) {
                // macOS 14 lets an app come forward when the active app hands over to it.
                NSApp?.yieldActivation(to: app)
                app.activate(options: [.activateAllWindows])
            } else {
                app.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
            }
        }
        if Thread.isMainThread { bringForward() } else { DispatchQueue.main.async(execute: bringForward) }
    }

    private func isAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    private func runOpen(_ args: [String]) throws {
        do {
            try run("/usr/bin/open", args, environment: Self.launchEnvironment())
        } catch {
            throw MultiError.launchFailed(String(describing: error))
        }
    }

    /// `open` hands this process's environment to ChatGPT, which hands it to its terminals and
    /// tools. Keep out this tool's own variables, ChatGPT's (when this runs in one of its
    /// terminals, they name that copy's folders) and Electron's (ELECTRON_RUN_AS_NODE, set in an
    /// editor's terminal, would stop ChatGPT from opening a window).
    static func launchEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        environment.filter { key, _ in
            !["CMA_", "CODEX_", "ELECTRON_"].contains { key.hasPrefix($0) }
        }
    }

    // MARK: - Processes

    struct Instance {
        var pid: pid_t
        /// The `--user-data-dir` it was started with; nil for the main ChatGPT.
        var dataFolder: String?
        /// False when its command line couldn't be read: it is then neither the main ChatGPT nor
        /// any account's copy, so nothing is done on a guess.
        var known = true
        /// Started on other folders by something else (`CODEX_ELECTRON_USER_DATA_PATH` without the
        /// switch): not the main ChatGPT.
        var otherFolders = false

        var isMain: Bool { known && dataFolder == nil && !otherFolders }
    }

    /// Every running copy of ChatGPT's main executable (its helpers, renderers and CLI excluded).
    static func instances() -> [Instance] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let filled = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        var result: [Instance] = []
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        for pid in pids.prefix(Int(max(filled, 0))) where pid > 0 {
            guard proc_pidpath(pid, &path, UInt32(path.count)) > 0,
                  String(cString: path).hasSuffix("/" + ChatGPTApp.executable),
                  isChatGPT(executable: String(cString: path)) else { continue }
            guard let process = commandLine(of: pid) else {
                result.append(Instance(pid: pid, dataFolder: nil, known: false))
                continue
            }
            let folder = process.arguments.dropFirst().last { $0.hasPrefix(ChatGPTApp.userDataSwitch) }
                .map { String($0.dropFirst(ChatGPTApp.userDataSwitch.count)) }
            result.append(Instance(pid: pid, dataFolder: folder,
                                   otherFolders: folder == nil && process.environment[ChatGPTApp.userDataVariable] != nil))
        }
        return result
    }

    /// Whether an executable belongs to a ChatGPT app bundle (com.openai.codex).
    private static func isChatGPT(executable: String) -> Bool {
        let bundle = URL(fileURLWithPath: executable).deletingLastPathComponent()  // MacOS
            .deletingLastPathComponent().deletingLastPathComponent()               // ChatGPT.app
        return Bundle(url: bundle)?.bundleIdentifier == ChatGPTApp.bundleID
    }

    /// A process's arguments and environment, read with sysctl(KERN_PROCARGS2).
    static func commandLine(of pid: pid_t) -> (arguments: [String], environment: [String: String])? {
        var argmax: Int32 = 0
        var size = MemoryLayout<Int32>.size
        var mib: [Int32] = [CTL_KERN, KERN_ARGMAX]
        guard sysctl(&mib, 2, &argmax, &size, nil, 0) == 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: Int(argmax))
        size = buffer.count
        mib = [CTL_KERN, KERN_PROCARGS2, pid]
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        // Layout: argc, the executable path, NUL padding, argc NUL-terminated arguments, then the
        // environment's NAME=value strings up to an empty one.
        let argc = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
        var i = MemoryLayout<Int32>.size
        while i < size && buffer[i] != 0 { i += 1 }
        while i < size && buffer[i] == 0 { i += 1 }
        func next() -> String? {
            guard i < size else { return nil }
            let start = i
            while i < size && buffer[i] != 0 { i += 1 }
            defer { i += 1 }
            return String(decoding: buffer[start..<i], as: UTF8.self)
        }
        var arguments: [String] = []
        while arguments.count < argc, let argument = next() { arguments.append(argument) }
        var environment: [String: String] = [:]
        while let entry = next(), !entry.isEmpty {
            guard let equals = entry.firstIndex(of: "=") else { continue }
            environment[String(entry[..<equals])] = String(entry[entry.index(after: equals)...])
        }
        return (arguments, environment)
    }

    /// The path with symbolic links resolved, as realpath(3) gives it, for comparing folders.
    static func canonical(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return URL(fileURLWithPath: path).standardizedFileURL.path }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}

struct CommandFailed: Error, CustomStringConvertible {
    var description: String
}

@discardableResult
func run(_ tool: String, _ args: [String], allowFailure: Bool = false, environment: [String: String]? = nil) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: tool)
    process.arguments = args
    if let environment { process.environment = environment }
    let out = Pipe(), err = Pipe()
    process.standardOutput = out
    process.standardError = err
    try process.run()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    let errData = err.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 || allowFailure else {
        let message = String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        throw CommandFailed(description: "\(tool) exited with \(process.terminationStatus): \(message)")
    }
    return String(decoding: data, as: UTF8.self)
}
