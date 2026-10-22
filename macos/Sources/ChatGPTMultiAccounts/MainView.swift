import MultiAccountsCore
import SwiftUI

/// The main window: the main ChatGPT, every other account, and which of them are open right now.
struct MainView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: AppSettings

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    banners
                    if let snapshot = model.snapshot {
                        MainRow(model: model, main: snapshot.main)
                        if snapshot.accounts.isEmpty {
                            EmptyState(model: model)
                        }
                    }
                    ForEach(model.statuses) { status in
                        AccountRow(model: model, status: status)
                    }
                    Text("Every account runs in its own ChatGPT window, with its own sign-in, chats and settings, all at the same time. Nothing is swapped or signed out, and the main ChatGPT is never quit or changed. ChatGPT's browser extension stays with the main ChatGPT.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                }
                .padding(20)
            }
        }
        .frame(minWidth: 700, minHeight: 500)
        .sheet(isPresented: $model.showingSettings) {
            SettingsView(model: model, settings: settings)
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 46, height: 46)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 10) {
                    Text(model.headline)
                        .font(.title2.weight(.semibold))
                    OpenFaces(model: model)
                }
                Text(model.subheadline)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            if !(model.snapshot?.openAccounts.isEmpty ?? true) {
                Button {
                    model.closeAll()
                } label: {
                    Label("Close All", systemImage: "xmark.rectangle")
                }
                .help("Quit every account's window. The main ChatGPT keeps running.")
                .disabled(model.busy != nil)
            }
            Button {
                model.openAll()
            } label: {
                Label("Open All", systemImage: "rectangle.stack")
            }
            .help("Open every signed-in account, each in its own ChatGPT window, and the main ChatGPT.")
            .disabled(model.busy != nil || !model.canOpenAll)
            Button {
                model.add()
            } label: {
                Label("Add Account", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.busy != nil || model.snapshot?.main.installed != true)
            Button {
                model.showingSettings = true
            } label: {
                Image(systemName: "gearshape")
            }
            .help("Settings")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    @ViewBuilder private var banners: some View {
        if model.isDemo {
            Banner(symbol: "theatermasks", tint: .blue,
                   text: "Demo with synthetic accounts. Everything happens in a temporary folder; the real ChatGPT on this Mac is never touched.")
        }
        ForEach(model.statuses.filter { $0.isOpen && !$0.isSignedIn }) { status in
            Banner(symbol: "person.crop.circle.badge.plus", tint: .blue,
                   text: "A new ChatGPT window is open at its sign-in screen. Sign in there with your other account; it shows here as soon as it has.") {
                Button("Show Window") { model.open(status) }
            }
        }
        ForEach(model.statuses.filter { $0.sameAs != nil }) { status in
            Banner(symbol: "exclamationmark.circle", tint: .orange,
                   text: "“\(status.displayName)” is signed in to the same ChatGPT account as \(status.sameAs!). To use another account there, log out in its window and sign in with the other one.") {
                if status.isOpen { Button("Show Window") { model.open(status) } }
            }
        }
        if let busy = model.busy {
            Banner(symbol: nil, tint: .accentColor, text: busy)
        }
    }
}

/// The open accounts' initials, overlapping: several accounts running at once.
struct OpenFaces: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let names = (model.snapshot?.main.running == true ? [model.snapshot!.main.displayName] : [])
            + (model.snapshot?.openAccounts.map(\.displayName) ?? [])
        if names.count > 1 {
            HStack(spacing: -8) {
                ForEach(Array(names.prefix(6).enumerated()), id: \.offset) { _, name in
                    Avatar(name: name, size: 24)
                        .overlay(Circle().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 2))
                }
            }
            .accessibilityLabel("\(names.count) accounts open")
        }
    }
}

/// Shown until the first extra account is added.
struct EmptyState: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: "rectangle.stack.badge.plus")
                .font(.system(size: 30))
                .foregroundStyle(Color.accentColor)
                .frame(width: 42)
            VStack(alignment: .leading, spacing: 8) {
                Text("Use another ChatGPT account at the same time")
                    .font(.headline)
                Text("Add an account and it opens in its own ChatGPT window, next to the main one. Sign in once; after that both stay signed in and run side by side: chat in one while a task runs in the other. Add as many accounts as you like and open them all with one click.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Add Account…") { model.add() }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.busy != nil || model.snapshot?.main.installed != true)
                    .padding(.top, 2)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.accentColor.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.accentColor.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
    }
}

/// The main ChatGPT, as the person uses it every day. Only shown and brought forward, never changed.
struct MainRow: View {
    @ObservedObject var model: AppModel
    let main: MainState

    var body: some View {
        HStack(spacing: 14) {
            Avatar(name: main.displayName)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text("Main ChatGPT").font(.headline)
                    Badge(text: "Main", color: .accentColor)
                    Badge(text: main.running ? "Open" : "Not open", color: main.running ? .green : .gray, dot: main.running)
                }
                Text(details)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            Button(main.running ? "Show" : "Open") { model.openMain() }
                .disabled(model.busy != nil || !main.installed)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.accentColor.opacity(0.6), lineWidth: 1.5))
    }

    private var details: String {
        var parts: [String] = []
        if let signIn = main.signIn {
            parts.append(signIn.label)
            if let plan = signIn.planName { parts.append(plan) }
        } else {
            parts.append("Signed out")
        }
        parts.append("your usual ChatGPT, left as it is")
        return parts.joined(separator: " · ")
    }
}

/// One extra account, in its own ChatGPT window.
struct AccountRow: View {
    @ObservedObject var model: AppModel
    let status: AccountStatus

    var body: some View {
        HStack(spacing: 14) {
            Avatar(name: status.displayName)
                .opacity(status.isOpen ? 1 : 0.55)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(status.displayName).font(.headline)
                    badge
                    if let sameAs = status.sameAs {
                        Badge(text: sameAs == "the main ChatGPT" ? "Same as main" : "Duplicate", color: .orange)
                    }
                }
                Text(details)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            actions
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(status.isOpen ? Color.green.opacity(0.45) : Color.primary.opacity(0.08),
                              lineWidth: status.isOpen ? 1.5 : 1)
        )
    }

    private var badge: some View {
        switch (status.isOpen, status.isSignedIn) {
        case (true, true): return Badge(text: "Open", color: .green, dot: true)
        case (true, false): return Badge(text: "Signing in", color: .blue, dot: true)
        case (false, true): return Badge(text: "Closed", color: .gray)
        case (false, false): return Badge(text: "Not signed in", color: .orange)
        }
    }

    private var details: String {
        var parts: [String] = []
        if let signIn = status.signIn {
            if status.account.name != nil { parts.append(signIn.label) }
            if let plan = signIn.planName { parts.append(plan) }
        } else {
            parts.append(status.isOpen ? "Sign in with your other account in its ChatGPT window" : "Open it to sign in")
        }
        if let size = model.sizes[status.account.id] { parts.append(Disk.format(size)) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var actions: some View {
        HStack(spacing: 8) {
            if status.isOpen {
                Button("Show") { model.open(status) }
                Button("Close") { model.close(status) }
            } else {
                Button(status.isSignedIn ? "Open" : "Open to Sign In") { model.open(status) }
                    .buttonStyle(.borderedProminent)
            }
            Menu {
                Button("Rename…") { model.rename(status) }
                Button("Show Folder in Finder") { model.showFolder(status) }
                    .disabled(!FileManager.default.fileExists(atPath: status.folder.path))
                Divider()
                Button("Remove…") { model.remove(status) }
                    .disabled(status.isOpen)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .disabled(model.busy != nil)
    }
}

/// A small coloured label, with a dot for something running now.
struct Badge: View {
    let text: String
    let color: Color
    var dot = false

    var body: some View {
        HStack(spacing: 4) {
            if dot { Circle().fill(color).frame(width: 6, height: 6) }
            Text(text)
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .foregroundStyle(color)
        .background(Capsule().fill(color.opacity(0.15)))
    }
}

/// A notice above the accounts.
struct Banner<Trailing: View>: View {
    let symbol: String?
    let tint: Color
    let text: String
    let trailing: Trailing

    init(symbol: String?, tint: Color, text: String, @ViewBuilder trailing: () -> Trailing) {
        self.symbol = symbol
        self.tint = tint
        self.text = text
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            if let symbol {
                Image(systemName: symbol).foregroundStyle(tint)
            } else {
                ProgressView().controlSize(.small)
            }
            Text(text).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            trailing
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(tint.opacity(0.10)))
    }
}

extension Banner where Trailing == EmptyView {
    init(symbol: String?, tint: Color, text: String) {
        self.init(symbol: symbol, tint: tint, text: text) { EmptyView() }
    }
}

/// A round badge with the account's initials, in a colour that stays the same for a name.
struct Avatar: View {
    let name: String
    var size: CGFloat = 42

    private static let colors: [Color] = [
        Color(red: 0.06, green: 0.55, blue: 0.45), .indigo, .orange, .pink, .purple, .blue, .teal, Color(red: 0.85, green: 0.47, blue: 0.34),
    ]

    var body: some View {
        // For an email, the part before the @ ("jamie.ng" → JN).
        let base = name.contains("@") ? String(name.prefix { $0 != "@" }) : name
        let words = base.split { !$0.isLetter && !$0.isNumber }
        let initials = [words.first, words.count > 1 && size >= 32 ? words.last : nil]
            .compactMap { $0?.first.map { String($0).uppercased() } }
            .joined()
        let index = name.lowercased().unicodeScalars.reduce(5381) { ($0 &* 33 &+ Int($1.value)) % 1_000_003 } % Self.colors.count
        return Text(initials.isEmpty ? "?" : initials)
            .font(.system(size: size * 0.36, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Circle().fill(Self.colors[index].gradient))
    }
}
