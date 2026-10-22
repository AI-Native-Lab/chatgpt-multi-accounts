import AppKit
import ServiceManagement

/// The person's choices, kept in the app's preferences. The demo keeps its own copy, so trying
/// the demo never changes the real app's settings.
@MainActor
final class AppSettings: ObservableObject {
    private enum Key {
        static let showMenuBarIcon = "showMenuBarIcon"
        static let showDockIcon = "showDockIcon"
        static let showCountInMenuBar = "showCountInMenuBar"
        static let openAllAtLogin = "openAllAtLogin"
    }

    private let defaults: UserDefaults
    private let isDemo: Bool
    private var demoOpenAtLogin = false

    @Published var showMenuBarIcon: Bool {
        didSet { defaults.set(showMenuBarIcon, forKey: Key.showMenuBarIcon) }
    }
    @Published var showDockIcon: Bool {
        didSet { defaults.set(showDockIcon, forKey: Key.showDockIcon) }
    }
    /// Shows how many ChatGPT accounts are open next to the menu bar icon.
    @Published var showCountInMenuBar: Bool {
        didSet { defaults.set(showCountInMenuBar, forKey: Key.showCountInMenuBar) }
    }
    /// When the Mac opens the app at login, it opens every signed-in account too.
    @Published var openAllAtLogin: Bool {
        didSet { defaults.set(openAllAtLogin, forKey: Key.openAllAtLogin) }
    }

    init(isDemo: Bool) {
        self.isDemo = isDemo
        defaults = isDemo ? UserDefaults(suiteName: "local.chatgpt-multi-accounts.demo") ?? .standard : .standard
        defaults.register(defaults: [Key.showMenuBarIcon: true, Key.showDockIcon: true,
                                     Key.showCountInMenuBar: true, Key.openAllAtLogin: false])
        showMenuBarIcon = defaults.bool(forKey: Key.showMenuBarIcon)
        showDockIcon = defaults.bool(forKey: Key.showDockIcon)
        showCountInMenuBar = defaults.bool(forKey: Key.showCountInMenuBar)
        openAllAtLogin = defaults.bool(forKey: Key.openAllAtLogin)
    }

    var openAtLogin: Bool {
        isDemo ? demoOpenAtLogin : SMAppService.mainApp.status == .enabled
    }

    func setOpenAtLogin(_ on: Bool) throws {
        objectWillChange.send()
        if isDemo {
            demoOpenAtLogin = on
        } else if on {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
