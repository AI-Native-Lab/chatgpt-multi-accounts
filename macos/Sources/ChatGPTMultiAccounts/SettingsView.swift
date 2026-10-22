import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: AppSettings
    /// Drawn on its own for the screenshots, without the Done button's sheet.
    var showsDoneButton = true

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Where to find ChatGPT Multi-Accounts") {
                    Toggle("Show in the Dock", isOn: $settings.showDockIcon)
                    Toggle("Show in the menu bar", isOn: $settings.showMenuBarIcon)
                    Toggle("Show how many accounts are open next to the menu bar icon", isOn: $settings.showCountInMenuBar)
                        .disabled(!settings.showMenuBarIcon)
                    Text("On a MacBook with a notch, menu bar icons can hide behind it when the menu bar is full. The app can always be opened from the Dock, Launchpad or Spotlight.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if !settings.showDockIcon && !settings.showMenuBarIcon {
                        Label("Both icons are off. Open ChatGPT Multi-Accounts from Launchpad, Spotlight or the Applications folder to get back to this window.",
                              systemImage: "info.circle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                Section("Startup") {
                    Toggle("Open ChatGPT Multi-Accounts at login", isOn: Binding(
                        get: { settings.openAtLogin },
                        set: { on in
                            do { try settings.setOpenAtLogin(on) } catch { Prompt.error(error) }
                        }))
                    Toggle("Then open every signed-in account", isOn: $settings.openAllAtLogin)
                        .disabled(!settings.openAtLogin)
                    Text("Opened at login, the app waits in the menu bar without showing its window. With the second option, every account you signed in to opens in its own ChatGPT window, next to the main ChatGPT.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("Command line") {
                    LabeledContent("chatgpt-multi") {
                        if model.commandInstalled {
                            Text("Installed in ~/.local/bin").foregroundStyle(.secondary)
                        } else {
                            Button("Install in ~/.local/bin") { model.installCommand() }
                        }
                    }
                    Text("The same commands for Terminal and scripts: list, add, open, open --all, close, close --all.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("Data") {
                    LabeledContent("Accounts' folders") {
                        Button("Show in Finder") { model.showAccountsFolder() }
                    }
                    LabeledContent("Main ChatGPT's folder") {
                        Button("Show in Finder") { model.showMainFolder() }
                    }
                    LabeledContent("Activity log") {
                        Button("Open") { model.openLog() }
                    }
                    Text("Each account keeps its own sign-in, chats and settings in its folder, about 0.8 GB once ChatGPT has set it up. The main ChatGPT's folders are only read.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section {
                    LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–")
                    Text("ChatGPT Multi-Accounts is an independent project, not affiliated with or endorsed by OpenAI.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            if showsDoneButton {
                Divider()
                HStack {
                    Spacer()
                    Button("Done") { model.showingSettings = false }
                        .keyboardShortcut(.defaultAction)
                }
                .padding(14)
            }
        }
        .frame(width: 560, height: showsDoneButton ? 680 : 870)
    }
}
