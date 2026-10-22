import AppKit
import Combine
import MultiAccountsCore

/// A menu item that runs a closure.
final class ActionItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, enabled: Bool = true, checked: Bool = false, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
        isEnabled = enabled
        state = checked ? .on : .off
    }

    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func fire() { handler() }
}

/// The menu bar item and the Dock icon's menu. Both are rebuilt from the model each time they open.
@MainActor
final class StatusMenuController: NSObject, NSMenuDelegate {
    private let model: AppModel
    private let settings: AppSettings
    private let openWindow: () -> Void
    private let openSettings: () -> Void
    private var item: NSStatusItem?
    private var observations: Set<AnyCancellable> = []

    init(model: AppModel, settings: AppSettings, openWindow: @escaping () -> Void, openSettings: @escaping () -> Void) {
        self.model = model
        self.settings = settings
        self.openWindow = openWindow
        self.openSettings = openSettings
        super.init()
        for publisher in [model.objectWillChange, settings.objectWillChange] {
            publisher.sink { [weak self] _ in DispatchQueue.main.async { self?.updateButton() } }
                .store(in: &observations)
        }
    }

    func setVisible(_ visible: Bool) {
        if visible, item == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            let menu = NSMenu()
            menu.delegate = self
            menu.autoenablesItems = false
            item.menu = menu
            self.item = item
            updateButton()
        } else if !visible, let item {
            NSStatusBar.system.removeStatusItem(item)
            self.item = nil
        }
    }

    func dockMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        addAccounts(to: menu)
        return menu
    }

    private func updateButton() {
        guard let button = item?.button else { return }
        let symbol = model.busy != nil ? "hourglass"
            : model.statuses.contains(where: { $0.sameAs != nil }) ? "exclamationmark.triangle"
            : "rectangle.stack"
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "ChatGPT Multi-Accounts")
        button.image?.isTemplate = true
        button.imagePosition = .imageLeading
        let count = settings.showCountInMenuBar && model.openCount > 0 ? " \(model.openCount)" : ""
        button.title = model.isDemo ? " Demo ·\(count)" : count
        button.toolTip = model.headline
    }

    func menuWillOpen(_ menu: NSMenu) {
        model.refresh()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(ActionItem(model.busy ?? model.headline, enabled: false) {})
        if model.busy == nil, !model.subheadline.isEmpty {
            menu.addItem(ActionItem(model.subheadline, enabled: false) {})
        }
        menu.addItem(.separator())
        menu.addItem(ActionItem("Open ChatGPT Multi-Accounts…") { [openWindow] in openWindow() })
        menu.addItem(.separator())
        addAccounts(to: menu)
        menu.addItem(.separator())
        menu.addItem(ActionItem("Settings…") { [openSettings] in openSettings() })
        menu.addItem(ActionItem("Quit ChatGPT Multi-Accounts") { NSApp.terminate(nil) })
    }

    /// The main ChatGPT and every account: a click brings an open one forward or opens a closed
    /// one; with ⌥ held, a click closes an open account.
    private func addAccounts(to menu: NSMenu) {
        let idle = model.busy == nil && model.snapshot != nil
        if let main = model.snapshot?.main {
            menu.addItem(ActionItem("Main ChatGPT — \(main.signIn?.email ?? "signed out")",
                                    enabled: idle && main.installed, checked: main.running) { [model] in model.openMain() })
        }
        for status in model.statuses {
            var title = status.displayName
            if !status.isSignedIn { title += status.isOpen ? "  (signing in)" : "  (not signed in)" }
            menu.addItem(ActionItem(title, enabled: idle, checked: status.isOpen) { [model] in model.open(status) })
            if status.isOpen {
                let close = ActionItem("Close \(status.displayName)", enabled: idle) { [model] in model.close(status) }
                close.isAlternate = true
                close.keyEquivalentModifierMask = [.option]
                menu.addItem(close)
            }
        }
        menu.addItem(.separator())
        menu.addItem(ActionItem("Open All Accounts", enabled: idle && model.canOpenAll) { [model] in model.openAll() })
        menu.addItem(ActionItem("Close All Accounts", enabled: idle && !(model.snapshot?.openAccounts.isEmpty ?? true)) { [model] in
            model.closeAll()
        })
        menu.addItem(ActionItem("Add Account…", enabled: idle && model.snapshot?.main.installed == true) { [model] in model.add() })
    }
}

/// The app's menus at the top of the screen while it shows in the Dock.
@MainActor
enum MainMenu {
    static func make() -> NSMenu {
        let main = NSMenu()

        let app = NSMenu()
        app.addItem(withTitle: "About ChatGPT Multi-Accounts", action: #selector(AppDelegate.showAbout(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Settings…", action: #selector(AppDelegate.showSettings(_:)), keyEquivalent: ",")
        app.addItem(.separator())
        app.addItem(withTitle: "Hide ChatGPT Multi-Accounts", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = app.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        app.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Quit ChatGPT Multi-Accounts", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        add(app, titled: "ChatGPT Multi-Accounts", to: main)

        let accounts = NSMenu(title: "Accounts")
        accounts.addItem(withTitle: "Add Account…", action: #selector(AppDelegate.addAccount(_:)), keyEquivalent: "n")
        accounts.addItem(.separator())
        accounts.addItem(withTitle: "Open All Accounts", action: #selector(AppDelegate.openAll(_:)), keyEquivalent: "o")
        let closeAll = accounts.addItem(withTitle: "Close All Accounts", action: #selector(AppDelegate.closeAll(_:)), keyEquivalent: "w")
        closeAll.keyEquivalentModifierMask = [.command, .option]
        add(accounts, titled: "Accounts", to: main)

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        add(edit, titled: "Edit", to: main)

        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        window.addItem(.separator())
        window.addItem(withTitle: "ChatGPT Multi-Accounts", action: #selector(AppDelegate.showMainWindow(_:)), keyEquivalent: "0")
        add(window, titled: "Window", to: main)
        NSApp.windowsMenu = window

        return main
    }

    private static func add(_ menu: NSMenu, titled title: String, to main: NSMenu) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        menu.title = title
        item.submenu = menu
        main.addItem(item)
    }
}
