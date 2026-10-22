import XCTest
@testable import MultiAccountsCore

final class AccountManagerTests: XCTestCase {
    var root: URL!
    var layout: Layout!
    var chatgpt: SimulatedChatGPT!
    var manager: AccountManager!
    let fm = FileManager.default
    /// Who the next windows sign in to, in order.
    var arrivals: [String] = []

    override func setUpWithError() throws {
        // A short folder: ChatGPT's socket paths must fit in 103 bytes.
        root = URL(fileURLWithPath: "/tmp/cma-\(UUID().uuidString.prefix(8))", isDirectory: true)
        layout = Layout(mainCodexHome: root.appendingPathComponent("main-codex"), mainData: root.appendingPathComponent("main-data"),
                        home: root.appendingPathComponent("home"), chatgptApp: root.appendingPathComponent("ChatGPT.app"),
                        appSupport: root.appendingPathComponent("AppSupport"), trash: root.appendingPathComponent("Trash"))
        try fm.createDirectory(at: layout.chatgptApp, withIntermediateDirectories: true)
        try Demo.writeSignIn(codexHome: layout.mainCodexHome, email: "me@example.com", plan: "plus")
        try Data("model = \"gpt\"\n\n[desktop]\ndock-icon-preference = \"codex-system\"\n".utf8)
            .write(to: layout.mainCodexHome.appendingPathComponent("config.toml"))
        chatgpt = SimulatedChatGPT()
        chatgpt.signIn = { [unowned self] codexHome in
            guard !self.arrivals.isEmpty else { return }
            try? Demo.writeSignIn(codexHome: codexHome, email: self.arrivals.removeFirst(), plan: "team")
        }
        try chatgpt.launchMain(app: layout.chatgptApp)
        manager = AccountManager(layout: layout, chatgpt: chatgpt)
        manager.launchSpacing = 0
        manager.launchTimeout = 0.5
        manager.log = { _ in }
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: root)
    }

    func test_addOpensANewCopyOnItsOwnFoldersNextToTheMainOne() throws {
        let mainPID = try XCTUnwrap(chatgpt.mainPID())
        let account = try manager.add(name: nil)
        XCTAssertEqual(account.id.count, 6)
        let launch = try XCTUnwrap(chatgpt.launches.last)
        XCTAssertEqual(launch.codexHome.path, layout.codexHome(of: account).path)
        XCTAssertEqual(launch.dataFolder.path, layout.dataFolder(of: account).path)
        XCTAssertTrue(launch.codexHome.path.hasPrefix(layout.home.path + "/"), "never the main ChatGPT's folders")

        var status = try manager.find("1")
        XCTAssertTrue(status.isOpen)
        XCTAssertFalse(status.isSignedIn, "it opens at the sign-in screen")
        XCTAssertEqual(status.displayName, "New account 1")

        try Demo.writeSignIn(codexHome: layout.codexHome(of: account), email: "work@example.com", plan: "team")
        status = try manager.find("work@example.com")
        XCTAssertEqual(status.displayName, "work@example.com", "named after its email until renamed")
        XCTAssertEqual(status.signIn?.planName, "Team")
        XCTAssertEqual(chatgpt.mainPID(), mainPID, "the main ChatGPT keeps running")
    }

    func test_manyAccountsRunAtOnce() throws {
        arrivals = ["a@example.com", "b@example.com", "c@example.com"]
        try manager.add(name: "A")
        try manager.add(name: "B")
        try manager.add(name: nil)
        let snapshot = manager.snapshot()
        XCTAssertEqual(snapshot.openCount, 4, "the main ChatGPT and three accounts")
        XCTAssertEqual(snapshot.accounts.map(\.displayName), ["A", "B", "c@example.com"])
        XCTAssertEqual(Set(snapshot.accounts.compactMap(\.pid)).count, 3, "each in its own copy")
        XCTAssertTrue(snapshot.accounts.allSatisfy { $0.sameAs == nil })
    }

    func test_openAllOpensTheMainAndEverySignedInAccount() throws {
        arrivals = ["a@example.com", "b@example.com"]
        try manager.add(name: "A")
        try manager.add(name: "B")
        try manager.add(name: "Never signed in")
        XCTAssertEqual(try manager.closeAll(), "Closed 3 accounts. The main ChatGPT keeps running.")
        XCTAssertNotNil(chatgpt.mainPID(), "Close All never quits the main ChatGPT")
        _ = chatgpt.quit(pid: try XCTUnwrap(chatgpt.mainPID()), timeout: 1)

        let message = try manager.openAll()
        XCTAssertEqual(message, "Opened the main ChatGPT, “A” and “B”. 3 ChatGPT accounts are open at once.")
        XCTAssertFalse(try manager.find("Never signed in").isOpen, "only signed-in accounts open with Open All")
        XCTAssertEqual(try manager.openAll(), "Every signed-in account is already open.")
    }

    func test_openBringsAnOpenCopyForwardInsteadOfStartingAnother() throws {
        try manager.add(name: "A")
        let launches = chatgpt.launches.count
        XCTAssertEqual(try manager.open("A"), "Brought “A” forward.")
        XCTAssertEqual(chatgpt.launches.count, launches)
        XCTAssertEqual(chatgpt.activated, [try XCTUnwrap(manager.find("A").pid)])
    }

    func test_closingKeepsTheSignIn() throws {
        arrivals = ["a@example.com"]
        try manager.add(name: "A")
        XCTAssertEqual(try manager.close("A"), "Closed “A”. It stays signed in, ready to open again.")
        let status = try manager.find("A")
        XCTAssertFalse(status.isOpen)
        XCTAssertEqual(status.signIn?.email, "a@example.com")
        XCTAssertEqual(try manager.close("A"), "“A” isn't open.")
        XCTAssertEqual(try manager.open("A"), "Opened “A” in its own ChatGPT window.")
    }

    func test_signingInToAnAccountAlreadyHereIsFlagged() throws {
        arrivals = ["ME@example.com", "x@example.com", "x@example.com"]
        try manager.add(name: "Twin of main")
        try manager.add(name: "X")
        try manager.add(name: "Twin of X")
        let statuses = manager.snapshot().accounts
        XCTAssertEqual(statuses[0].sameAs, "the main ChatGPT")
        XCTAssertNil(statuses[1].sameAs)
        XCTAssertEqual(statuses[2].sameAs, "“X”")
    }

    func test_eachCopyGetsTheMainDockIconSetting() throws {
        let account = try manager.add(name: "A")
        let config = layout.codexHome(of: account).appendingPathComponent("config.toml")
        XCTAssertEqual(try String(contentsOf: config, encoding: .utf8), "[desktop]\ndock-icon-preference = \"codex-system\"\n")

        // The account's own settings stay; only the shared one follows the main ChatGPT.
        try Data("[desktop]\nfollowUpQueueMode = \"steer\"\ndock-icon-preference = \"app-default\"\n\n[plugins.x]\nenabled = true\n".utf8)
            .write(to: config)
        _ = try manager.close("A")
        _ = try manager.open("A")
        XCTAssertEqual(try String(contentsOf: config, encoding: .utf8),
                       "[desktop]\nfollowUpQueueMode = \"steer\"\ndock-icon-preference = \"codex-system\"\n\n[plugins.x]\nenabled = true\n")
    }

    func test_removeRefusesWhileOpenThenTrashesTheFolder() throws {
        let account = try manager.add(name: "A")
        XCTAssertThrowsError(try manager.remove("A")) { XCTAssertEqual($0 as? MultiError, .isOpen("A")) }
        _ = try manager.close("A")
        XCTAssertTrue(try manager.remove("A").hasPrefix("Removed “A”."))
        XCTAssertFalse(fm.fileExists(atPath: layout.folder(of: account).path))
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: layout.trash!.path).count, 1)
        XCTAssertTrue(manager.accounts().isEmpty)
    }

    func test_renameAndFind() throws {
        arrivals = ["a@example.com"]
        try manager.add(name: nil)
        try manager.add(name: "B")
        try manager.rename("a@example.com", to: "  Work ")
        XCTAssertEqual(try manager.find("work").displayName, "Work")
        XCTAssertEqual(try manager.find("A@EXAMPLE.COM").displayName, "Work", "the email still finds it")
        XCTAssertEqual(try manager.find("2").displayName, "B")
        XCTAssertThrowsError(try manager.rename("1", to: "b")) { XCTAssertEqual($0 as? MultiError, .nameTaken("b")) }
        XCTAssertThrowsError(try manager.add(name: "Work")) { XCTAssertEqual($0 as? MultiError, .nameTaken("Work")) }
        XCTAssertThrowsError(try manager.find("nobody")) {
            XCTAssertEqual($0 as? MultiError, .noSuchAccount("nobody", known: "1. Work, 2. B"))
        }
    }

    func test_aCopyThatDoesNotStartOrQuitIsReported() throws {
        chatgpt.failsToStart = true
        XCTAssertThrowsError(try manager.add(name: "A")) { XCTAssertEqual($0 as? MultiError, .didNotStart("“A”")) }
        XCTAssertEqual(manager.accounts().count, 1, "the account is kept, to open again")
        chatgpt.failsToStart = false
        _ = try manager.open("A")
        chatgpt.refusesToQuit = true
        XCTAssertThrowsError(try manager.close("A")) { XCTAssertEqual($0 as? MultiError, .didNotQuit("“A”")) }
    }

    func test_aHomeTooLongForChatGPTsSocketsIsRefused() throws {
        layout.home = root.appendingPathComponent(String(repeating: "x", count: 80))
        manager = AccountManager(layout: layout, chatgpt: chatgpt)
        manager.log = { _ in }
        XCTAssertThrowsError(try manager.add(name: nil)) { error in
            guard case .pathTooLong = error as? MultiError else { return XCTFail("\(error)") }
        }
        XCTAssertTrue(chatgpt.launches.isEmpty)
    }

    func test_signInReadsOnlyTheAccountsName() throws {
        let home = root.appendingPathComponent("probe")
        XCTAssertNil(SignIn.read(codexHome: home))
        try Demo.writeSignIn(codexHome: home, email: "jo.lee@example.com", plan: "pro")
        let signIn = try XCTUnwrap(SignIn.read(codexHome: home))
        XCTAssertEqual(signIn.email, "jo.lee@example.com")
        XCTAssertEqual(signIn.name, "Jo Lee")
        XCTAssertEqual(signIn.planName, "Pro")
        XCTAssertEqual(signIn.workspaceID, "demo-workspace-jo.lee@example.com")

        try Files.writeJSON(["auth_mode": "apikey", "OPENAI_API_KEY": "sk-placeholder"], to: home.appendingPathComponent("auth.json"))
        XCTAssertEqual(SignIn.read(codexHome: home)?.planName, "API key")
        try Files.writeJSON(["auth_mode": "chatgpt", "tokens": NSNull()], to: home.appendingPathComponent("auth.json"))
        XCTAssertNil(SignIn.read(codexHome: home), "signed out")
    }

    func test_launchEnvironmentLeavesOutInheritedChatGPTAndElectronVariables() {
        let environment = SystemChatGPTControl.launchEnvironment(
            ["PATH": "/usr/bin", "HOME": "/Users/me", "CODEX_HOME": "/elsewhere", "ELECTRON_RUN_AS_NODE": "1", "CMA_HOME": "/x"])
        XCTAssertEqual(environment, ["PATH": "/usr/bin", "HOME": "/Users/me"])
    }
}

final class TOMLTests: XCTestCase {
    func test_readsAKeyOfOneTableOnly() {
        let text = "dock-icon-preference = \"top\"\n[desktop]\n# a comment\n\"dock-icon-preference\" = \"codex-system\"\n[other]\ndock-icon-preference = \"no\"\n"
        XCTAssertEqual(TOML.value(of: "dock-icon-preference", inTable: "desktop", in: text), "\"codex-system\"")
        XCTAssertNil(TOML.value(of: "missing", inTable: "desktop", in: text))
        XCTAssertNil(TOML.value(of: "dock-icon-preference", inTable: "nope", in: text))
    }

    func test_setsAddsAndRemovesWithoutTouchingOtherLines() {
        let text = "a = 1\n\n[desktop]\nx = 2\n\n[plugins.\"p@q\"]\nenabled = true\n"
        let added = TOML.setting("k", to: "\"v\"", inTable: "desktop", in: text)
        XCTAssertEqual(added, "a = 1\n\n[desktop]\nk = \"v\"\nx = 2\n\n[plugins.\"p@q\"]\nenabled = true\n")
        XCTAssertEqual(TOML.setting("k", to: "\"w\"", inTable: "desktop", in: added),
                       "a = 1\n\n[desktop]\nk = \"w\"\nx = 2\n\n[plugins.\"p@q\"]\nenabled = true\n")
        XCTAssertEqual(TOML.setting("k", to: nil, inTable: "desktop", in: added), text)
        XCTAssertEqual(TOML.setting("k", to: nil, inTable: "missing", in: text), text)
        XCTAssertEqual(TOML.setting("k", to: "1", inTable: "new", in: "a = 1"), "a = 1\n\n[new]\nk = 1\n")
        XCTAssertEqual(TOML.setting("k", to: "1", inTable: "new", in: ""), "[new]\nk = 1\n")
    }
}

final class BrowserExtensionTests: XCTestCase {
    var root: URL!
    var layout: Layout!
    let fm = FileManager.default
    var mainHost: String!
    var accountHost: String!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: "/tmp/cma-\(UUID().uuidString.prefix(8))", isDirectory: true)
        layout = Layout(mainCodexHome: root.appendingPathComponent("main-codex"), mainData: root.appendingPathComponent("main-data"),
                        home: root.appendingPathComponent("home"), chatgptApp: root.appendingPathComponent("ChatGPT.app"),
                        appSupport: root.appendingPathComponent("AppSupport"))
        mainHost = layout.mainCodexHome.appendingPathComponent("plugins/chrome/ChatGPT for Chrome").path
        accountHost = layout.home.appendingPathComponent("abc123/codex/plugins/chrome/ChatGPT for Chrome").path
        try fm.createDirectory(atPath: (mainHost as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        fm.createFile(atPath: mainHost, contents: Data())
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: root)
    }

    func entry(home: String, host: String) -> [String: Any] {
        ["nativeHostNames": ["com.openai.codexextension"], "paths": ["codexHome": home, "extensionHostPath": host]]
    }

    func manifest(_ folder: String, path: String) throws -> URL {
        let url = layout.appSupport.appendingPathComponent(folder).appendingPathComponent("com.openai.codexextension.json")
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Files.writeJSON(["name": "com.openai.codexextension", "path": path, "type": "stdio",
                             "allowed_origins": ["chrome-extension://abc/"]], to: url, mode: 0o644)
        return url
    }

    func test_putsTheMainChatGPTBackAndTakesAccountsOutOfTheSharedRegistry() throws {
        try Files.writeJSON(["schemaVersion": 2, "entries": [entry(home: layout.mainCodexHome.path, host: mainHost)]],
                            to: layout.mainCodexHome.appendingPathComponent("chrome-native-hosts-v2.json"))
        let chrome = try manifest("Google/Chrome/NativeMessagingHosts", path: accountHost)
        let edge = try manifest("Microsoft Edge/NativeMessagingHosts", path: mainHost)
        let registry = BrowserExtension.sharedRegistry(layout)
        try fm.createDirectory(at: registry.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Files.writeJSON(["schemaVersion": 2, "entries": [
            entry(home: layout.mainCodexHome.path, host: mainHost),
            entry(home: layout.home.appendingPathComponent("abc123/codex").path, host: accountHost),
        ]], to: registry)
        XCTAssertEqual(BrowserExtension.isWithMain(layout), false)

        XCTAssertEqual(BrowserExtension.keepWithMain(layout),
                       ["Gave ChatGPT's browser extension back to the main ChatGPT (1 browser manifest, 1 account entry in the shared registry)"])
        let fixed = try Files.readJSON(chrome)
        XCTAssertEqual(fixed["path"] as? String, mainHost)
        XCTAssertEqual(fixed["allowed_origins"] as? [String], ["chrome-extension://abc/"], "the rest of the manifest stays")
        XCTAssertEqual(try Files.readJSON(edge)["path"] as? String, mainHost)
        let entries = try XCTUnwrap(Files.readJSON(registry)["entries"] as? [[String: Any]])
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual((entries[0]["paths"] as? [String: Any])?["codexHome"] as? String, layout.mainCodexHome.path)
        XCTAssertEqual(BrowserExtension.isWithMain(layout), true)
        XCTAssertEqual(BrowserExtension.keepWithMain(layout), [], "nothing left to fix")
    }

    func test_changesNothingWhenTheMainChatGPTNeverSetTheExtensionUp() throws {
        let chrome = try manifest("Google/Chrome/NativeMessagingHosts", path: accountHost)
        XCTAssertNil(BrowserExtension.isWithMain(layout))
        XCTAssertEqual(BrowserExtension.keepWithMain(layout), [])
        XCTAssertEqual(try Files.readJSON(chrome)["path"] as? String, accountHost)
    }
}
