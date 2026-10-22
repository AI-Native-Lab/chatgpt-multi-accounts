import Foundation

/// The few ChatGPT settings that act on the whole Mac rather than on one copy of ChatGPT.
///
/// ChatGPT keeps its settings in the `[desktop]` table of `<CODEX_HOME>/config.toml`, so each
/// copy has its own. Most are harmless to differ, but the Dock icon is applied to the ChatGPT app
/// bundle itself: a copy on a new folder would put the default icon back for every copy. So each
/// account's copy is given the main ChatGPT's choice before it starts.
enum SharedSettings {
    static let table = "desktop"
    static let keys = ["dock-icon-preference"]

    /// Gives an account's config.toml the main ChatGPT's value of each shared setting. A setting the
    /// main ChatGPT doesn't have is removed, so the account uses the same default.
    static func sync(from mainCodexHome: URL, to codexHome: URL) throws {
        let mainText = (try? String(contentsOf: mainCodexHome.appendingPathComponent("config.toml"), encoding: .utf8)) ?? ""
        let url = codexHome.appendingPathComponent("config.toml")
        let original = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        var text = original
        for key in keys {
            text = TOML.setting(key, to: TOML.value(of: key, inTable: table, in: mainText), inTable: table, in: text)
        }
        if text != original {
            try Files.privateFolder(codexHome)
            try Files.writeAtomically(Data(text.utf8), to: url)
        }
    }
}

/// Just enough TOML to read and set one `key = value` line of a table, leaving every other line,
/// comment and table exactly as it was.
enum TOML {
    /// The raw value of `key` in `[table]` ("\"codex-system\"", with its quotes), or nil.
    static func value(of key: String, inTable table: String, in text: String) -> String? {
        let lines = text.components(separatedBy: "\n")
        guard let range = tableRange(table, in: lines) else { return nil }
        for line in lines[range] {
            if let (name, value) = keyValue(line), name == key { return value }
        }
        return nil
    }

    /// `text` with `key` in `[table]` set to the raw `value`, or removed when `value` is nil.
    static func setting(_ key: String, to value: String?, inTable table: String, in text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        if let range = tableRange(table, in: lines) {
            if let index = range.first(where: { keyValue(lines[$0])?.key == key }) {
                if let value {
                    lines[index] = "\(key) = \(value)"
                } else {
                    lines.remove(at: index)
                }
            } else if let value {
                lines.insert("\(key) = \(value)", at: range.lowerBound)
            }
            return lines.joined(separator: "\n")
        }
        guard let value else { return text }
        var result = text
        if !result.isEmpty && !result.hasSuffix("\n") { result += "\n" }
        if !result.isEmpty { result += "\n" }
        return result + "[\(table)]\n\(key) = \(value)\n"
    }

    /// The lines inside `[table]`, after its header and before the next table.
    private static func tableRange(_ table: String, in lines: [String]) -> Range<Int>? {
        guard let header = lines.firstIndex(where: { tableName($0) == table }) else { return nil }
        let end = lines[(header + 1)...].firstIndex { tableName($0) != nil } ?? lines.count
        return (header + 1)..<end
    }

    /// The name of a `[table]` or `[[array]]` header line.
    private static func tableName(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("["), let close = trimmed.lastIndex(of: "]") else { return nil }
        let inner = trimmed[trimmed.index(after: trimmed.startIndex)..<close]
        return inner.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
    }

    private static func keyValue(_ line: String) -> (key: String, value: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.hasPrefix("#"), let equals = trimmed.firstIndex(of: "=") else { return nil }
        var key = trimmed[..<equals].trimmingCharacters(in: .whitespaces)
        if key.count >= 2, key.hasPrefix("\""), key.hasSuffix("\"") { key = String(key.dropFirst().dropLast()) }
        let value = trimmed[trimmed.index(after: equals)...].trimmingCharacters(in: .whitespaces)
        return (key, value)
    }
}
