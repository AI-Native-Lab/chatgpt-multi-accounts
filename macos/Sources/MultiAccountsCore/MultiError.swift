import Foundation

public enum MultiError: LocalizedError, Equatable {
    case chatgptNotInstalled(String)
    case noSuchAccount(String, known: String)
    case nameTaken(String)
    case emptyName
    case isOpen(String)
    case didNotQuit(String)
    case didNotStart(String)
    case pathTooLong(String)
    case busy
    case launchFailed(String)
    case io(String)

    public var errorDescription: String? {
        switch self {
        case .chatgptNotInstalled(let path):
            return "ChatGPT isn't installed at \(path). Install the ChatGPT desktop app from chatgpt.com/download and open it once."
        case .noSuchAccount(let query, let known):
            return "No account matches “\(query)”. Accounts: \(known)."
        case .nameTaken(let name):
            return "Another account is already called “\(name)”."
        case .emptyName:
            return "The name is empty."
        case .isOpen(let name):
            return "“\(name)” is open. Close its ChatGPT window first."
        case .didNotQuit(let name):
            return "\(name) didn't quit. If ChatGPT asked to confirm quitting, confirm and try again."
        case .didNotStart(let name):
            return "\(name) didn't start. See ~/Library/Logs/com.openai.codex for ChatGPT's own log."
        case .pathTooLong(let message):
            return message
        case .busy:
            return "Another change is already running. Try again in a moment."
        case .launchFailed(let reason):
            return "Couldn't open ChatGPT: \(reason)"
        case .io(let message):
            return message
        }
    }
}
