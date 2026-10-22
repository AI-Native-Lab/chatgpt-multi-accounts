import Foundation

/// An extra ChatGPT account. Its sign-in, chats and window data live in its own folder (see
/// `Layout`), where its own copy of ChatGPT runs.
public struct Account: Codable, Equatable, Identifiable, Sendable {
    /// The account folder's name: six lowercase letters and digits, short because ChatGPT puts
    /// sockets inside it.
    public var id: String
    /// The name chosen for it. Nil until one is chosen: the list then shows its email.
    public var name: String?
    /// When it was added, in local time ("2026-10-22T09:30:00").
    public var addedAt: String?

    public init(id: String, name: String? = nil, addedAt: String? = nil) {
        self.id = id
        self.name = name
        self.addedAt = addedAt
    }

    public var addedDate: Date? { addedAt.flatMap(Registry.timestamp.date(from:)) }

    /// A new folder name that isn't taken in `home`.
    static func newID(in home: URL) -> String {
        let alphabet = Array("abcdefghijkmnpqrstuvwxyz23456789")
        while true {
            let id = String((0..<6).map { _ in alphabet.randomElement()! })
            if !Files.exists(home.appendingPathComponent(id)) { return id }
        }
    }
}

/// `accounts.json`: the names and order of the accounts.
struct Registry: Codable {
    var version = 1
    var accounts: [Account]

    static func load(_ url: URL) throws -> [Account] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode(Registry.self, from: Data(contentsOf: url)).accounts
    }

    static func save(_ accounts: [Account], to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        try Files.writeAtomically(encoder.encode(Registry(accounts: accounts)), to: url)
    }

    static let timestamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return formatter
    }()

    static func now() -> String { timestamp.string(from: Date()) }
}

enum Files {
    /// Writes a file atomically, readable only by its owner unless `mode` says otherwise.
    static func writeAtomically(_ data: Data, to url: URL, mode: mode_t = 0o600) throws {
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(getpid()).tmp")
        let fd = open(tmp.path, O_WRONLY | O_CREAT | O_TRUNC, mode)
        guard fd >= 0 else { throw MultiError.io("Can't write \(tmp.path): \(String(cString: strerror(errno)))") }
        fchmod(fd, mode)
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        try handle.write(contentsOf: data)
        try handle.synchronize()
        try handle.close()
        guard rename(tmp.path, url.path) == 0 else {
            throw MultiError.io("Can't replace \(url.path): \(String(cString: strerror(errno)))")
        }
    }

    /// Creates a folder (and its parents) readable only by its owner.
    @discardableResult
    static func privateFolder(_ url: URL) throws -> URL {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        return url
    }

    static func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    static func readJSON(_ url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MultiError.io("\(url.path) isn't a JSON object.")
        }
        return object
    }

    static func writeJSON(_ object: [String: Any], to url: URL, mode: mode_t = 0o600) throws {
        var data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .withoutEscapingSlashes])
        data.append(0x0A)
        try writeAtomically(data, to: url, mode: mode)
    }
}
