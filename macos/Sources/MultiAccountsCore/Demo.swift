import Foundation

/// Synthetic accounts for the demo and the README screenshots. Nothing here touches the real
/// ChatGPT or its data: everything lives in a temporary folder, and ChatGPT is never started.
public enum Demo {
    struct Person {
        var name: String?
        var email: String
        var plan: String
        var open: Bool
        var size: Int64
    }

    static let main = Person(name: nil, email: "jamie@example.com", plan: "plus", open: true, size: 0)
    static let people = [
        Person(name: "Work · Northwind", email: "jamie.ng@northwind.example", plan: "team", open: true, size: 1_240_000_000),
        Person(name: "Client · Acme Studio", email: "jamie@acmestudio.example", plan: "pro", open: true, size: 868_000_000),
        Person(name: nil, email: "jamie.research@example.org", plan: "plus", open: false, size: 792_000_000),
    ]
    /// Who the demo "signs in to" when a new account's window opens.
    static let newcomers: [(email: String, plan: String)] = [
        ("side.project@example.net", "plus"), ("teaching@university.example", "edu"), ("trial@studio.example", "business"),
    ]

    /// Where the demo keeps its pretend ChatGPT and accounts.
    public static var root: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("ChatGPTMultiAccountsDemo", isDirectory: true)
    }

    /// Builds a fresh pretend Mac and returns a manager working on it: the main ChatGPT signed in to
    /// jamie@example.com, "Work · Northwind" and "Client · Acme Studio" open next to it, and a
    /// third account closed.
    public static func makeManager() throws -> AccountManager {
        let fm = FileManager.default
        let root = Self.root
        if fm.fileExists(atPath: root.path) { try fm.removeItem(at: root) }
        let layout = Layout(mainCodexHome: root.appendingPathComponent("main-codex", isDirectory: true),
                            mainData: root.appendingPathComponent("main-data", isDirectory: true),
                            home: root.appendingPathComponent("home", isDirectory: true),
                            chatgptApp: root.appendingPathComponent("ChatGPT.app", isDirectory: true),
                            appSupport: root.appendingPathComponent("Application Support", isDirectory: true),
                            trash: root.appendingPathComponent("Trash", isDirectory: true))
        try fm.createDirectory(at: layout.chatgptApp, withIntermediateDirectories: true)
        try fm.createDirectory(at: layout.mainData, withIntermediateDirectories: true)
        try writeSignIn(codexHome: layout.mainCodexHome, email: main.email, plan: main.plan)
        try Data("[desktop]\ndock-icon-preference = \"app-default\"\n".utf8)
            .write(to: layout.mainCodexHome.appendingPathComponent("config.toml"))

        let chatgpt = SimulatedChatGPT()
        chatgpt.quitDelay = 0.6
        var arrivals = 0
        chatgpt.signIn = { codexHome in
            // Plays someone signing in a moment after the new window opens.
            let person = newcomers[arrivals % newcomers.count]
            arrivals += 1
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                try? writeSignIn(codexHome: codexHome, email: person.email, plan: person.plan)
            }
        }
        try chatgpt.launchMain(app: layout.chatgptApp)

        let manager = AccountManager(layout: layout, chatgpt: chatgpt)
        manager.launchSpacing = 0.4
        manager.log = { _ in }
        manager.supportsSeparateCopies = { _ in true }

        var accounts: [Account] = []
        var sizes: [String: Int64] = [:]
        for (index, person) in people.enumerated() {
            let account = Account(id: "demo0\(index + 1)", name: person.name,
                                  addedAt: Registry.timestamp.string(from: Date().addingTimeInterval(-Double(12 - index * 4) * 86_400)))
            try writeSignIn(codexHome: layout.codexHome(of: account), email: person.email, plan: person.plan)
            try Files.privateFolder(layout.dataFolder(of: account))
            accounts.append(account)
            sizes[layout.folder(of: account).path] = person.size
        }
        try manager.saveAccounts(accounts)
        manager.sizeProvider = { folder in sizes[folder.path] ?? 610_000_000 }
        for (account, person) in zip(accounts, people) where person.open {
            try chatgpt.launchAccount(app: layout.chatgptApp, codexHome: layout.codexHome(of: account),
                                      dataFolder: layout.dataFolder(of: account))
        }
        return manager
    }

    /// Writes a synthetic sign-in into a CODEX_HOME: an `auth.json` whose ID token carries the
    /// given email and plan, and placeholder text instead of real tokens.
    public static func writeSignIn(codexHome: URL, email: String, plan: String) throws {
        try Files.privateFolder(codexHome)
        let local = email.split(separator: "@").first.map(String.init) ?? email
        let claims: [String: Any] = [
            "email": email,
            "name": local.split(separator: ".").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " "),
            SignIn.authClaims: [
                "chatgpt_plan_type": plan,
                "chatgpt_user_id": "user-demo-\(email.lowercased().utf8.reduce(5381) { ($0 &* 33 &+ Int($1)) % 1_000_003 })",
                "chatgpt_account_id": "demo-workspace-\(email.lowercased())",
            ],
        ]
        func base64URL(_ object: [String: Any]) throws -> String {
            try JSONSerialization.data(withJSONObject: object).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        let jwt = try "\(base64URL(["alg": "none", "typ": "JWT"])).\(base64URL(claims)).demo"
        try Files.writeJSON([
            "auth_mode": "chatgpt",
            "tokens": [
                "id_token": jwt,
                "access_token": "demo placeholder",
                "refresh_token": "demo placeholder",
                "account_id": "demo-workspace-\(email.lowercased())",
            ],
            "last_refresh": ISO8601DateFormatter().string(from: Date()),
        ], to: codexHome.appendingPathComponent(SignIn.file))
    }
}
