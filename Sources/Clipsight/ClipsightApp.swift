import ApplicationServices
import ServiceManagement
import SwiftUI

@main
struct ClipsightApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ObservedObject private var store = ClipStore.shared

    var body: some Scene {
        MenuBarExtra {
            MenuBarView().environmentObject(store)
        } label: {
            Image(systemName: store.paused ? "clipboard" : "doc.on.clipboard.fill")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView().environmentObject(store)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = ClipStore.shared
        Hotkey.shared.register(.current) { PanelController.shared.toggle() }
    }
}

struct MenuBarView: View {
    @EnvironmentObject private var store: ClipStore
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Clipsight").font(.headline)
                Spacer()
                Toggle("Watching", isOn: Binding(get: { !store.paused }, set: { store.paused = !$0 }))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
                    .help(store.paused ? "Resume watching the clipboard" : "Pause watching the clipboard")
            }

            VStack(spacing: 2) {
                ForEach(store.clips.prefix(6)) { clip in
                    Button {
                        store.copy(clip)
                        store.showToast("Copied")
                    } label: {
                        HStack(spacing: 8) {
                            KindBadge(kind: clip.isSecret && .jwt != clip.kind ? .secret : clip.kind, size: 20)
                            Text(clip.preview).lineLimit(1)
                            Spacer()
                        }
                        .padding(.vertical, 4)
                        .padding(.horizontal, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                if store.clips.isEmpty {
                    Text("Nothing copied yet").foregroundStyle(.secondary).padding(.vertical, 6)
                }
            }

            Divider()

            HStack {
                Button {
                    PanelController.shared.show()
                } label: {
                    Text("Open  \(Hotkey.Preset.current.label)")
                }
                .buttonStyle(.borderedProminent)
                Spacer()
                Button {
                    NSApp.activate()
                    openSettings()
                } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.borderless)
                .help("Settings")
                Button {
                    NSApp.terminate(nil)
                } label: {
                    Image(systemName: "power")
                }
                .buttonStyle(.borderless)
                .help("Quit Clipsight")
            }
        }
        .padding(14)
        .frame(width: 300)
    }
}

// MARK: - Settings

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            PrivacySettings().tabItem { Label("Privacy", systemImage: "lock.shield") }
        }
        .frame(width: 520, height: 470)
    }
}

struct GeneralSettings: View {
    @EnvironmentObject private var store: ClipStore
    @AppStorage("hotkey") private var hotkey = Hotkey.Preset.shiftCommandV.rawValue
    @AppStorage("pasteDirectly") private var pasteDirectly = true
    @AppStorage("cleanLinks") private var cleanLinks = true
    @AppStorage("historyLimit") private var historyLimit = 500

    var body: some View {
        Form {
            Section("Shortcut") {
                Picker("Open Clipsight", selection: $hotkey) {
                    ForEach(Hotkey.Preset.allCases) { Text($0.label).tag($0.rawValue) }
                }
                .onChange(of: hotkey) {
                    Hotkey.shared.register(.current) { PanelController.shared.toggle() }
                }
                Toggle("Paste into the app in front", isOn: $pasteDirectly)
                LabeledContent("Accessibility") {
                    if AXIsProcessTrusted() {
                        Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button("Allow…") { PanelController.requestAccessibility() }
                    }
                }
            }

            Section {
                Toggle("Remove tracking from copied links", isOn: $cleanLinks)
            } footer: {
                Text("Strips utm_, fbclid, gclid and other trackers the moment you copy a link.")
            }

            Section("History") {
                Stepper("Keep the last \(historyLimit) clips", value: $historyLimit, in: 50...5_000, step: 50)
                Toggle("Open at login", isOn: Binding(
                    get: { .enabled == SMAppService.mainApp.status },
                    set: { on in
                        if on {
                            try? SMAppService.mainApp.register()
                        } else {
                            try? SMAppService.mainApp.unregister()
                        }
                        store.objectWillChange.send()
                    }
                ))
            }
        }
        .formStyle(.grouped)
    }
}

struct PrivacySettings: View {
    @EnvironmentObject private var store: ClipStore
    @AppStorage("secretShield") private var secretShield = true
    @AppStorage("secretSeconds") private var secretSeconds = 90
    @AppStorage("clearSecretClipboard") private var clearSecretClipboard = true
    @AppStorage("ignoredApps") private var ignoredApps = Prefs.defaultIgnoredApps

    var body: some View {
        Form {
            Section {
                Toggle("Secret Shield", isOn: $secretShield)
                Stepper("Forget secrets after \(secretSeconds) seconds", value: $secretSeconds, in: 10...600, step: 10)
                    .disabled(!secretShield)
                Toggle("Also clear them from the clipboard", isOn: $clearSecretClipboard)
                    .disabled(!secretShield)
            } footer: {
                Text("API keys, tokens, private keys, JWTs, card numbers and credentials in .env lines are masked, kept in memory only and never written to disk.")
            }

            Section {
                TextEditor(text: $ignoredApps)
                    .font(.body.monospaced())
                    .frame(height: 90)
            } header: {
                Text("Never record from these apps")
            } footer: {
                Text("Bundle identifiers, one per line. Password managers that mark what they copy are skipped anyway.")
            }

            Section {
                HStack {
                    Button("Clear Unpinned") { store.clearHistory(keepPinned: true) }
                    Button("Clear Everything", role: .destructive) { store.clearHistory(keepPinned: false) }
                }
            } footer: {
                Text("History is stored in ~/Library/Application Support/Clipsight and never leaves this Mac.")
            }
        }
        .formStyle(.grouped)
    }
}
