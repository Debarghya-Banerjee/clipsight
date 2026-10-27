import SwiftUI

extension ClipKind {
    var color: Color {
        switch self {
        case .text: .gray
        case .url: .blue
        case .json: .orange
        case .jwt: .purple
        case .color: .pink
        case .timestamp: .teal
        case .base64: .indigo
        case .email: .cyan
        case .path: Color(red: 0.3, green: 0.6, blue: 0.95)
        case .code: .green
        case .secret: .red
        case .image: .mint
        case .files: .brown
        }
    }
}

/// Finder icons of source apps, looked up once.
@MainActor
enum AppIcons {
    private static var cache: [String: NSImage] = [:]

    static func icon(_ bundleID: String?) -> NSImage? {
        guard let bundleID else { return nil }
        if let icon = cache[bundleID] { return icon }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        cache[bundleID] = icon
        return icon
    }
}

struct KindBadge: View {
    let kind: ClipKind
    var size: CGFloat = 28

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
            .fill(kind.color.gradient)
            .overlay {
                Image(systemName: kind.symbol)
                    .font(.system(size: size * 0.46, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: size, height: size)
    }
}

struct PanelView: View {
    @EnvironmentObject private var store: ClipStore
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            SearchBar(focused: $searchFocused)
            FilterChips()
            Divider()
            HStack(spacing: 0) {
                ClipList()
                    .frame(width: 330)
                Divider()
                Inspector()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            Footer()
        }
        .frame(minWidth: 640, minHeight: 380)
        .background(.regularMaterial)
        .onReceive(NotificationCenter.default.publisher(for: .panelShown)) { _ in
            searchFocused = true
        }
    }
}

struct SearchBar: View {
    @EnvironmentObject private var store: ClipStore
    @Environment(\.openSettings) private var openSettings
    var focused: FocusState<Bool>.Binding

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("Search, or describe what you copied…", text: $store.query)
                .textFieldStyle(.plain)
                .font(.system(size: 20))
                .focused(focused)
                .onKeyPress(phases: .down, action: handle)
                .onSubmit { if let clip = store.selected { PanelController.shared.paste(clip) } }
            if store.paused {
                Label("Paused", systemImage: "pause.circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
            }
            Button {
                PanelController.shared.hide()
                NSApp.activate()
                openSettings()
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help("Settings")
        }
        .padding(.horizontal, 18)
        .padding(.top, 18)
        .padding(.bottom, 10)
    }

    private func handle(_ press: KeyPress) -> KeyPress.Result {
        let command = press.modifiers.contains(.command)
        switch press.key {
        case .downArrow:
            store.moveSelection(1)
        case .upArrow:
            store.moveSelection(-1)
        case .return:
            guard let clip = store.selected else { return .handled }
            if command {
                store.copy(clip)
                PanelController.shared.hide()
            } else {
                PanelController.shared.paste(clip)
            }
        case .escape:
            if store.query.isEmpty {
                PanelController.shared.hide()
            } else {
                store.query = ""
            }
        case .tab:
            let all = Filter.allCases
            let index = all.firstIndex(of: store.filter) ?? 0
            store.filter = all[(index + (press.modifiers.contains(.shift) ? all.count - 1 : 1)) % all.count]
        case .delete where command:
            if let clip = store.selected {
                store.moveSelection(1)
                store.delete(clip)
            }
        default:
            guard command, let character = press.characters.first else { return .ignored }
            if let digit = character.wholeNumberValue, (1...9).contains(digit), digit <= store.results.count {
                PanelController.shared.paste(store.results[digit - 1])
            } else if "p" == character, let clip = store.selected {
                store.togglePin(clip)
            } else if "r" == character, let clip = store.selected, clip.isSecret {
                store.revealed.formSymmetricDifference([clip.id])
            } else {
                return .ignored
            }
        }
        return .handled
    }
}

struct FilterChips: View {
    @EnvironmentObject private var store: ClipStore

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Filter.allCases) { filter in
                let selected = store.filter == filter
                Button {
                    store.filter = filter
                } label: {
                    Label(filter.rawValue, systemImage: filter.symbol)
                        .font(.callout.weight(selected ? .semibold : .regular))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(selected ? Color.accentColor.opacity(0.2) : Color.primary.opacity(0.05), in: Capsule())
                        .foregroundStyle(selected ? Color.accentColor : .secondary)
                }
                .buttonStyle(.plain)
            }
            Spacer()
            Text("\(store.results.count)")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .monospacedDigit()
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }
}

// MARK: - List

struct ClipList: View {
    @EnvironmentObject private var store: ClipStore

    var body: some View {
        if store.results.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: store.query.isEmpty ? "doc.on.clipboard" : "magnifyingglass")
                    .font(.system(size: 30))
                    .foregroundStyle(.tertiary)
                Text(store.query.isEmpty ? "Copy something to start" : "No matches")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(store.results.enumerated()), id: \.element.id) { index, clip in
                            if store.related.contains(clip.id) && !store.related.contains(store.results[max(index - 1, 0)].id) {
                                Label("Related by meaning", systemImage: "sparkles")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 10)
                                    .padding(.top, 8)
                            }
                            ClipRow(clip: clip, index: index)
                                .id(clip.id)
                        }
                    }
                    .padding(8)
                }
                .onChange(of: store.selection) {
                    if let selection = store.selection {
                        proxy.scrollTo(selection)
                    }
                }
            }
        }
    }
}

struct ClipRow: View {
    @EnvironmentObject private var store: ClipStore
    let clip: Clip
    let index: Int

    var body: some View {
        let selected = store.selected?.id == clip.id

        HStack(spacing: 10) {
            if .image == clip.kind, let image = store.image(for: clip) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 30, height: 30)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            } else if .color == clip.kind, let rgba = Detector.color(clip.text ?? "") {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color(nsColor: rgba.nsColor))
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(.primary.opacity(0.15)))
                    .frame(width: 30, height: 30)
            } else {
                KindBadge(kind: clip.isSecret && .jwt != clip.kind ? .secret : clip.kind, size: 30)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(clip.preview)
                    .lineLimit(2)
                    .font(.system(size: 13, design: [.code, .json, .jwt, .base64, .secret].contains(clip.kind) ? .monospaced : .default))
                HStack(spacing: 5) {
                    if let icon = AppIcons.icon(clip.sourceBundleID) {
                        Image(nsImage: icon).resizable().frame(width: 12, height: 12)
                    }
                    if let expires = clip.expires {
                        Label("Forgets in \(max(0, Int(expires.timeIntervalSince(store.now))))s", systemImage: "timer")
                            .foregroundStyle(.red)
                    } else {
                        Text(clip.date, format: .relative(presentation: .named))
                    }
                    if clip.pinned {
                        Image(systemName: "pin.fill").foregroundStyle(.orange)
                    }
                    if 0 < clip.cleanedTrackers {
                        Image(systemName: "shield.lefthalf.filled").foregroundStyle(.green).help("Trackers removed")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 0)
            if index < 9 {
                Text("⌘\(index + 1)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(selected ? Color.accentColor.opacity(0.22) : (store.hovered == clip.id ? Color.primary.opacity(0.05) : .clear))
        }
        .contentShape(Rectangle())
        .onHover { store.hovered = $0 ? clip.id : (store.hovered == clip.id ? nil : store.hovered) }
        .onTapGesture(count: 2) { PanelController.shared.paste(clip) }
        .onTapGesture { store.selection = clip.id }
        .contextMenu {
            Button("Paste") { PanelController.shared.paste(clip) }
            Button("Copy") { store.copy(clip) }
            Button(clip.pinned ? "Unpin" : "Pin") { store.togglePin(clip) }
            Divider()
            Button("Delete", role: .destructive) { store.delete(clip) }
        }
    }
}

struct Footer: View {
    @EnvironmentObject private var store: ClipStore

    var body: some View {
        HStack(spacing: 14) {
            if let toast = store.toast {
                Label(toast, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else {
                Hint(keys: "↩", label: "Paste")
                Hint(keys: "⌘↩", label: "Copy")
                Hint(keys: "⌘P", label: "Pin")
                Hint(keys: "⌘⌫", label: "Delete")
                Hint(keys: "⇥", label: "Filter")
            }
            Spacer()
            Label("On this Mac only", systemImage: "lock.shield")
                .foregroundStyle(.tertiary)
        }
        .font(.caption)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .animation(.spring(duration: 0.3), value: store.toast)
    }
}

struct Hint: View {
    let keys: String
    let label: String

    var body: some View {
        HStack(spacing: 4) {
            Text(keys)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
            Text(label).foregroundStyle(.secondary)
        }
    }
}
