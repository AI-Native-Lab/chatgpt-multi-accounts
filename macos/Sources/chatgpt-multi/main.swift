import Darwin
import Foundation
import MultiAccountsCore

// chatgpt-multi: use several ChatGPT accounts at the same time, each in its own ChatGPT window,
// next to the main ChatGPT. The same engine as ChatGPT Multi-Accounts.app.

let usage = """
    chatgpt-multi: use several ChatGPT accounts at the same time, each in its own ChatGPT window

      list [--json]              the main ChatGPT and every account: who it is, whether it is open (alias: status)
      add [--name NAME]          add an account: a new ChatGPT window opens at its sign-in screen
      open ACCOUNT…              open accounts in their own ChatGPT windows, next to the main one
      open --all                 open every signed-in account, and the main ChatGPT, all at once
      show ACCOUNT               bring an open account's window forward (`main` = the main ChatGPT)
      close ACCOUNT…             quit accounts' windows; they stay signed in
      close --all                quit every account's window; the main ChatGPT keeps running
      main                       open the main ChatGPT, or bring it forward
      rename ACCOUNT NAME        rename an account
      remove ACCOUNT [--yes]     forget an account: its folders go to the Trash
      doctor                     check that this Mac's ChatGPT looks as expected
      paths                      where everything is kept

    ACCOUNT is a number, name or email from `list`. The main ChatGPT is never quit or changed.
    """

let environment = ProcessInfo.processInfo.environment
let arguments = Array(CommandLine.arguments.dropFirst())

var layout = Layout.system()
let fakeApp = environment["CMA_FAKE_APP"].map { URL(fileURLWithPath: $0) }
let chatgpt: ChatGPTControl
if let fakeApp {
    // Tests: a pretend ChatGPT made of files, and a pretend Trash.
    chatgpt = FileChatGPTControl(marker: fakeApp)
    layout.chatgptApp = fakeApp.deletingLastPathComponent()
    if layout.trash == nil { layout.trash = layout.home.appendingPathComponent("Trash", isDirectory: true) }
} else {
    chatgpt = SystemChatGPTControl()
}
let manager = AccountManager(layout: layout, chatgpt: chatgpt)
manager.quitTimeout = Double(environment["CMA_QUIT_TIMEOUT"] ?? "") ?? 30
if fakeApp != nil {
    manager.launchSpacing = 0
    manager.launchTimeout = 1
    manager.supportsSeparateCopies = { _ in true }
}

// MARK: - Arguments

struct Arguments {
    var positional: [String] = []
    var flags: Set<String> = []
    var values: [String: String] = [:]

    static let takesValue: Set<String> = ["--name"]

    init(_ raw: [String]) throws {
        var rest = raw[...]
        while let arg = rest.popFirst() {
            if Self.takesValue.contains(arg) {
                guard let value = rest.popFirst() else { throw MultiError.io("\(arg) needs a value.") }
                values[arg] = value
            } else if let eq = arg.firstIndex(of: "="), Self.takesValue.contains(String(arg[..<eq])) {
                values[String(arg[..<eq])] = String(arg[arg.index(after: eq)...])
            } else if arg.hasPrefix("-") && arg.count > 1 {
                flags.insert(arg == "-y" ? "--yes" : arg == "-a" ? "--all" : arg)
            } else {
                positional.append(arg)
            }
        }
    }

    func some(_ what: String, command: String) throws -> [String] {
        guard !positional.isEmpty else {
            throw MultiError.io("Which \(what)? For example: chatgpt-multi \(command) 1. See `chatgpt-multi list`.")
        }
        return positional
    }
}

// MARK: - Commands

func list(json: Bool) throws {
    let snapshot = manager.snapshot()
    let main = snapshot.main
    if json {
        func signIn(_ signIn: SignIn?) -> Any {
            guard let signIn else { return NSNull() }
            return ["email": signIn.email as Any? ?? NSNull(), "plan": signIn.plan as Any? ?? NSNull(), "mode": signIn.mode]
        }
        let accounts: [[String: Any]] = snapshot.accounts.map { status in
            [
                "number": status.number,
                "id": status.account.id,
                "name": status.account.name as Any? ?? NSNull(),
                "displayName": status.displayName,
                "open": status.isOpen,
                "pid": status.pid.map { Int($0) } as Any? ?? NSNull(),
                "signIn": signIn(status.signIn),
                "sameAs": status.sameAs as Any? ?? NSNull(),
                "folder": status.folder.path,
            ]
        }
        let object: [String: Any] = [
            "main": ["open": main.running, "installed": main.installed, "signIn": signIn(main.signIn)],
            "accounts": accounts,
            "openCount": snapshot.openCount,
        ]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        print(String(decoding: data, as: UTF8.self))
        return
    }

    let who = main.signIn.map(manager.describe) ?? "signed out"
    print("Main ChatGPT (\(main.running ? "open" : "not open")): \(who)")
    if snapshot.accounts.isEmpty {
        print("\nNo other accounts yet. Run `chatgpt-multi add` to sign in to another one in its own window.")
        return
    }
    let width = snapshot.accounts.map(\.displayName.count).max() ?? 0
    print()
    for status in snapshot.accounts {
        let mark = status.isOpen ? "●" : " "
        let name = status.displayName.padding(toLength: width, withPad: " ", startingAt: 0)
        var note: String
        if let signIn = status.signIn {
            note = status.account.name == nil ? (signIn.planName ?? "") : manager.describe(signIn)
            if let sameAs = status.sameAs { note += "  (same account as \(sameAs))" }
        } else {
            note = status.isOpen ? "waiting for sign-in in its window" : "not signed in (open it to sign in)"
        }
        print(" \(mark) \(status.number). \(name)  \(status.isOpen ? "open  " : "closed")  \(note)")
    }
    print("\n" + (snapshot.openCount > 1 ? "\(snapshot.openCount) ChatGPT accounts are open at once." : "\(snapshot.openCount) ChatGPT account open."))
}

func add(_ args: Arguments) throws {
    let account = try manager.add(name: args.values["--name"] ?? args.positional.first)
    guardBrowserExtension()
    print("A new ChatGPT window opened at its sign-in screen. Sign in there with your other account;")
    print("the main ChatGPT keeps running. The account is in `chatgpt-multi list` as number \(manager.accounts().count)"
          + "\(account.name.map { ", “\($0)”" } ?? ", named after its email once signed in").")
}

func openAccounts(_ args: Arguments) throws {
    if args.flags.contains("--all") {
        print(try manager.openAll(progress: { print($0) }))
    } else {
        for query in try args.some("account", command: "open") { print(try manager.open(query)) }
    }
    guardBrowserExtension()
}

func show(_ args: Arguments) throws {
    let query = try args.some("account", command: "show")[0]
    if query.lowercased() == "main" {
        try manager.openMain()
        return
    }
    let status = try manager.find(query)
    guard let pid = status.pid else { throw MultiError.io("“\(status.displayName)” isn't open. Open it with: chatgpt-multi open \(status.number)") }
    manager.activate(pid: pid)
}

func closeAccounts(_ args: Arguments) throws {
    if args.flags.contains("--all") {
        print(try manager.closeAll(progress: { print($0) }))
        return
    }
    for query in try args.some("account", command: "close") {
        if query.lowercased() == "main" {
            throw MultiError.io("This tool never quits the main ChatGPT. Quit it there with ⌘Q.")
        }
        print(try manager.close(query))
    }
}

func remove(_ args: Arguments) throws {
    let status = try manager.find(try args.some("account", command: "remove")[0])
    if !args.flags.contains("--yes") {
        guard isatty(STDIN_FILENO) != 0 else { throw MultiError.io("Add --yes to confirm.") }
        Swift.print("Forget “\(status.displayName)” on this Mac? Its folders, with its sign-in and chats, go to the Trash. [y/N] ",
                    terminator: "")
        guard let answer = readLine(), ["y", "yes"].contains(answer.trimmingCharacters(in: .whitespaces).lowercased()) else {
            print("Kept it.")
            return
        }
    }
    print(try manager.remove(status.account.id))
}

func doctor() {
    manager.keepBrowserExtensionWithMain()
    for check in manager.doctor() {
        print("\(check.ok ? "ok " : "BAD")  \(check.name): \(check.value)")
    }
}

func paths() {
    print("Main ChatGPT, sign-in and chats:  \(layout.mainCodexHome.path)")
    print("Main ChatGPT, window data:        \(layout.mainData.path)")
    print("This tool's folder:               \(layout.home.path)")
    print("Activity log:                     \(layout.logFile.path)")
    for status in manager.snapshot().accounts {
        print("  \(status.number). \(status.displayName): \(status.folder.path)")
    }
}

// MARK: - Keeping the browser extension with the main ChatGPT

/// A copy of ChatGPT takes ChatGPT's browser extension over some seconds after it starts. The
/// app puts it back while it runs; the command leaves a small process behind for two minutes to
/// do the same (`_guard`), then it exits.
func guardBrowserExtension() {
    manager.keepBrowserExtensionWithMain()
    guard fakeApp == nil else { return }
    _ = try? spawnDetached(arguments: ["_guard", "120"])
}

/// One guard runs at a time: a later one moves the shared deadline in `.guard-until` and leaves.
func guardLoop(seconds: Double) {
    let until = layout.home.appendingPathComponent(".guard-until")
    func deadline() -> Double { (try? String(contentsOf: until, encoding: .utf8)).flatMap(Double.init) ?? 0 }
    let mine = Date().timeIntervalSince1970 + seconds
    if mine > deadline() { try? String(mine).write(to: until, atomically: true, encoding: .utf8) }
    let fd = Darwin.open(layout.home.appendingPathComponent(".guard.lock").path, O_RDWR | O_CREAT, 0o600)
    guard fd >= 0, flock(fd, LOCK_EX | LOCK_NB) == 0 else { return }
    defer { Darwin.close(fd) }
    while Date().timeIntervalSince1970 < deadline() {
        manager.keepBrowserExtensionWithMain()
        Thread.sleep(forTimeInterval: 3)
    }
}

/// Starts this command again in a session of its own, so it outlives the terminal.
func spawnDetached(arguments: [String]) throws -> pid_t {
    let executable = Bundle.main.executablePath ?? CommandLine.arguments[0]
    var attributes: posix_spawnattr_t?
    posix_spawnattr_init(&attributes)
    defer { posix_spawnattr_destroy(&attributes) }
    posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID))
    var actions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&actions)
    defer { posix_spawn_file_actions_destroy(&actions) }
    for fd: Int32 in [0, 1, 2] {
        posix_spawn_file_actions_addopen(&actions, fd, "/dev/null", fd == 0 ? O_RDONLY : O_WRONLY, 0)
    }
    let argv = ([executable] + arguments).map { strdup($0) } + [nil]
    let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
    defer {
        argv.forEach { free($0) }
        envp.forEach { free($0) }
    }
    var pid: pid_t = 0
    let code = posix_spawn(&pid, executable, &actions, &attributes, argv, envp)
    guard code == 0 else { throw MultiError.io(String(cString: strerror(code))) }
    return pid
}

// MARK: - Main

func main() -> Int32 {
    var raw = arguments
    let command = raw.isEmpty ? "list" : raw.removeFirst()
    do {
        let args = try Arguments(raw)
        switch command {
        case "list", "status":
            manager.keepBrowserExtensionWithMain()
            try list(json: args.flags.contains("--json"))
        case "add": try add(args)
        case "open": try openAccounts(args)
        case "show": try show(args)
        case "close": try closeAccounts(args)
        case "main": try manager.openMain()
        case "rename":
            guard args.positional.count == 2 else { throw MultiError.io("Usage: chatgpt-multi rename ACCOUNT NAME") }
            try manager.rename(args.positional[0], to: args.positional[1])
            print("Named it “\(args.positional[1].trimmingCharacters(in: .whitespaces))”.")
        case "remove": try remove(args)
        case "doctor": doctor()
        case "paths": paths()
        case "_guard": guardLoop(seconds: Double(args.positional.first ?? "") ?? 120)
        case "help", "-h", "--help": print(usage)
        default:
            FileHandle.standardError.write(Data("Unknown command “\(command)”.\n\n\(usage)\n".utf8))
            return 2
        }
        return 0
    } catch {
        FileHandle.standardError.write(Data("Error: \(error.localizedDescription)\n".utf8))
        return 1
    }
}

exit(main())
