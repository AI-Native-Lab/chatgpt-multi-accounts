import Foundation

/// Keeps ChatGPT's browser extension (ChatGPT for Chrome, Edge, Brave…) paired with the main
/// ChatGPT.
///
/// The extension reaches ChatGPT through a native-messaging host. Every copy of ChatGPT that
/// starts registers its own host: it rewrites the browsers' manifests to point at its own copy of
/// the host, and adds itself to a registry shared by all copies,
/// `~/Library/Application Support/OpenAI/Codex/chrome-native-hosts-v2.json`. The copy that
/// started last would take the extension over. This puts the main ChatGPT's host back in the
/// manifests and takes the accounts' entries out of the shared registry. It changes nothing when
/// the main ChatGPT has never set the extension up.
enum BrowserExtension {
    /// The browsers whose manifests ChatGPT writes, as listed in ChatGPT 26.1013.
    static let manifestFolders = [
        "Google/Chrome/NativeMessagingHosts",
        "Google/Chrome for Testing/NativeMessagingHosts",
        "Google/ChromeForTesting/NativeMessagingHosts",
        "Chromium/NativeMessagingHosts",
        "Microsoft Edge/NativeMessagingHosts",
        "BraveSoftware/Brave-Browser/NativeMessagingHosts",
        "Vivaldi/NativeMessagingHosts",
        "com.operasoftware.Opera/NativeMessagingHosts",
    ]
    static let registryFile = "chrome-native-hosts-v2.json"

    static func sharedRegistry(_ layout: Layout) -> URL {
        layout.appSupport.appendingPathComponent("OpenAI/Codex/\(registryFile)")
    }

    /// The main ChatGPT's host for each host name, from its own registry. Only hosts that exist.
    static func mainHosts(_ layout: Layout) -> [String: String] {
        guard let registry = try? Files.readJSON(layout.mainCodexHome.appendingPathComponent(registryFile)),
              let entries = registry["entries"] as? [[String: Any]] else { return [:] }
        var hosts: [String: String] = [:]
        for entry in entries {
            guard let path = (entry["paths"] as? [String: Any])?["extensionHostPath"] as? String,
                  Files.exists(URL(fileURLWithPath: path)) else { continue }
            for name in entry["nativeHostNames"] as? [String] ?? [] { hosts[name] = path }
        }
        return hosts
    }

    /// The manifests of the main ChatGPT's hosts, wherever a browser has one.
    static func manifests(_ layout: Layout, hostNames: some Sequence<String>) -> [URL] {
        let folders = manifestFolders.map { layout.appSupport.appendingPathComponent($0, isDirectory: true) }
            + [layout.appSupport.appendingPathComponent("OpenAI/Codex/NativeMessagingHosts", isDirectory: true)]
        return hostNames.flatMap { name in
            folders.map { $0.appendingPathComponent("\(name).json") }.filter(Files.exists)
        }
    }

    /// Whether `path` is inside this tool's folder, so it belongs to one of the accounts' copies.
    static func isOurs(_ path: String, _ layout: Layout) -> Bool {
        let home = layout.home.standardizedFileURL.path
        return path == home || path.hasPrefix(home + "/")
    }

    /// Puts the main ChatGPT back in charge of the extension. Returns what it changed, one line each.
    @discardableResult
    static func keepWithMain(_ layout: Layout) -> [String] {
        let hosts = mainHosts(layout)
        guard !hosts.isEmpty else { return [] }
        var changes: [String] = []
        var fixed = 0, removed = 0
        for manifest in manifests(layout, hostNames: hosts.keys) {
            guard var object = try? Files.readJSON(manifest),
                  let name = object["name"] as? String, let mainHost = hosts[name],
                  let path = object["path"] as? String, isOurs(path, layout) else { continue }
            object["path"] = mainHost
            do {
                try Files.writeJSON(object, to: manifest, mode: 0o644)
                fixed += 1
            } catch {
                changes.append("Couldn't fix \(manifest.path): \(error.localizedDescription)")
            }
        }
        let registry = sharedRegistry(layout)
        if var object = try? Files.readJSON(registry), let entries = object["entries"] as? [[String: Any]] {
            let kept = entries.filter { entry in
                let home = (entry["paths"] as? [String: Any])?["codexHome"] as? String ?? ""
                return !isOurs(home, layout)
            }
            if kept.count != entries.count {
                object["entries"] = kept
                do {
                    try Files.writeJSON(object, to: registry, mode: 0o644)
                    removed = entries.count - kept.count
                } catch {
                    changes.append("Couldn't update \(registry.path): \(error.localizedDescription)")
                }
            }
        }
        if fixed + removed > 0 {
            func count(_ n: Int, _ one: String, _ many: String) -> String { "\(n) \(n == 1 ? one : many)" }
            changes.insert("Gave ChatGPT's browser extension back to the main ChatGPT ("
                + [fixed > 0 ? count(fixed, "browser manifest", "browser manifests") : nil,
                   removed > 0 ? count(removed, "account entry", "account entries") + " in the shared registry" : nil]
                    .compactMap { $0 }.joined(separator: ", ") + ")", at: 0)
        }
        return changes
    }

    /// For `doctor`: whether every manifest of the main ChatGPT's hosts points at it.
    static func isWithMain(_ layout: Layout) -> Bool? {
        let hosts = mainHosts(layout)
        guard !hosts.isEmpty else { return nil }
        return manifests(layout, hostNames: hosts.keys).allSatisfy { manifest in
            guard let object = try? Files.readJSON(manifest), let path = object["path"] as? String else { return true }
            return !isOurs(path, layout)
        }
    }
}
