import Foundation

/// Who a ChatGPT folder is signed in to, read from its `auth.json`.
///
/// ChatGPT keeps its sign-in in `<CODEX_HOME>/auth.json`: the OAuth tokens and the ID token
/// that names the account. Only the ID token's public claims (email, name, plan, workspace)
/// are read here. The tokens are never copied, sent anywhere or shown, and every copy of ChatGPT
/// signs in on its own, so no two copies ever share (and fight over) one set of tokens.
public struct SignIn: Equatable, Sendable {
    /// "chatgpt" for a ChatGPT account, "apikey" for an API key.
    public var mode: String
    public var email: String?
    public var name: String?
    /// "free", "plus", "pro", "team", "business", "enterprise", "edu"…
    public var plan: String?
    public var userID: String?
    /// The ChatGPT workspace (personal, or a Team or Enterprise workspace).
    public var workspaceID: String?

    public init(mode: String = "chatgpt", email: String? = nil, name: String? = nil, plan: String? = nil,
                userID: String? = nil, workspaceID: String? = nil) {
        self.mode = mode
        self.email = email
        self.name = name
        self.plan = plan
        self.userID = userID
        self.workspaceID = workspaceID
    }

    /// Two folders signed in to the same person in the same workspace are the same account.
    public var identity: String? {
        guard let who = userID ?? email?.lowercased() else { return nil }
        return "\(who)|\(workspaceID ?? "")"
    }

    /// "Plus", "Team"… for the list.
    public var planName: String? {
        guard mode == "chatgpt" else { return "API key" }
        guard let plan, !plan.isEmpty else { return nil }
        return plan.prefix(1).uppercased() + plan.dropFirst()
    }

    /// The email, or what else names the sign-in.
    public var label: String {
        email ?? name ?? (mode == "apikey" ? "an API key" : "a ChatGPT account")
    }

    static let file = "auth.json"
    static let authClaims = "https://api.openai.com/auth"

    /// The sign-in in a CODEX_HOME. Nil when it is signed out (or keeps its sign-in elsewhere).
    public static func read(codexHome: URL) -> SignIn? {
        guard let object = try? Files.readJSON(codexHome.appendingPathComponent(file)) else { return nil }
        let tokens = object["tokens"] as? [String: Any]
        let mode = object["auth_mode"] as? String ?? (tokens != nil ? "chatgpt" : "apikey")
        if mode == "apikey" || tokens == nil {
            let key = object["OPENAI_API_KEY"] as? String
            return key?.isEmpty == false ? SignIn(mode: "apikey") : nil
        }
        guard let idToken = tokens?["id_token"] as? String, !idToken.isEmpty else { return nil }
        let claims = Self.claims(of: idToken) ?? [:]
        let auth = claims[authClaims] as? [String: Any] ?? [:]
        return SignIn(mode: mode,
                      email: claims["email"] as? String,
                      name: claims["name"] as? String,
                      plan: auth["chatgpt_plan_type"] as? String,
                      userID: auth["chatgpt_user_id"] as? String ?? auth["user_id"] as? String ?? claims["sub"] as? String,
                      workspaceID: auth["chatgpt_account_id"] as? String ?? tokens?["account_id"] as? String)
    }

    /// The payload of a JWT, decoded without checking its signature: it only names the account.
    static func claims(of jwt: String) -> [String: Any]? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var base64 = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
