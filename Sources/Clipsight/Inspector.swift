import SwiftUI

/// The right side of the panel: the selected clip in full, and what Clipsight understands about it.
struct Inspector: View {
    @EnvironmentObject private var store: ClipStore

    var body: some View {
        if let clip = store.selected {
            let image = store.image(for: clip)
            let xray = XRay(clip, imageSize: image?.size)
            let hidden = clip.isSecret && !store.revealed.contains(clip.id)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Header(clip: clip)
                    Preview(clip: clip, image: image, color: xray.color, hidden: hidden)

                    if !xray.facts.isEmpty && !hidden {
                        Section(title: "X-ray", symbol: "viewfinder") {
                            VStack(spacing: 0) {
                                ForEach(Array(xray.facts.enumerated()), id: \.element.id) { index, fact in
                                    FactRow(fact: fact)
                                    if index < xray.facts.count - 1 { Divider() }
                                }
                            }
                        }
                    }

                    if let body = xray.body, !hidden {
                        Section(title: xray.bodyTitle ?? "Decoded", symbol: "wand.and.stars") {
                            ZStack(alignment: .topTrailing) {
                                Text(body)
                                    .font(.system(size: 12, design: .monospaced))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(10)
                                CopyButton(text: body).padding(6)
                            }
                        }
                    }

                    if nil != clip.text, !hidden {
                        Section(title: "Transform", symbol: "arrow.triangle.2.circlepath") {
                            TransformGrid(clip: clip)
                        }
                    }
                }
                .padding(18)
            }
        } else {
            VStack(spacing: 10) {
                Image(systemName: "viewfinder")
                    .font(.system(size: 36))
                    .foregroundStyle(.tertiary)
                Text("Copy a link, JSON, a token, a colour or a timestamp\nand Clipsight shows what's inside.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct Header: View {
    @EnvironmentObject private var store: ClipStore
    let clip: Clip

    var body: some View {
        HStack(spacing: 12) {
            KindBadge(kind: clip.isSecret && .jwt != clip.kind ? .secret : clip.kind, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(clip.secretLabel ?? clip.kind.title).font(.title3.bold())
                HStack(spacing: 5) {
                    if let icon = AppIcons.icon(clip.sourceBundleID) {
                        Image(nsImage: icon).resizable().frame(width: 14, height: 14)
                    }
                    Text([clip.sourceName, clip.date.formatted(date: .abbreviated, time: .shortened)].compactMap { $0 }.joined(separator: " · "))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                store.togglePin(clip)
            } label: {
                Image(systemName: clip.pinned ? "pin.fill" : "pin")
            }
            .help(clip.pinned ? "Unpin (⌘P)" : "Pin (⌘P)")
            Button {
                store.delete(clip)
            } label: {
                Image(systemName: "trash")
            }
            .help("Delete (⌘⌫)")
            Button {
                PanelController.shared.paste(clip)
            } label: {
                Text("Paste")
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

private struct Preview: View {
    @EnvironmentObject private var store: ClipStore
    let clip: Clip
    let image: NSImage?
    let color: Detector.RGBA?
    let hidden: Bool

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: 220)
            } else if let color {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(nsColor: color.nsColor))
                    .frame(height: 110)
                    .overlay(alignment: .bottomLeading) {
                        Text(color.hex)
                            .font(.system(.title3, design: .monospaced).weight(.semibold))
                            .padding(8)
                            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
                            .padding(10)
                    }
            } else if let files = clip.files {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(files, id: \.self) { path in
                        HStack {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable().frame(width: 20, height: 20)
                            Text((path as NSString).abbreviatingWithTildeInPath).lineLimit(1).truncationMode(.middle)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else if hidden {
                SecretCover(clip: clip)
            } else {
                Text(clip.text ?? "")
                    .font(.system(size: 13, design: [.code, .json, .jwt, .base64, .secret].contains(clip.kind) || clip.isSecret ? .monospaced : .default))
                    .lineLimit(14)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct SecretCover: View {
    @EnvironmentObject private var store: ClipStore
    let clip: Clip

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(clip.preview)
                .font(.system(size: 15, design: .monospaced))
            if let expires = clip.expires {
                let total = Double(max(Prefs.int("secretSeconds"), 10))
                let left = max(0, expires.timeIntervalSince(store.now))
                ProgressView(value: left, total: total) {
                    Label("Kept in memory only. Forgotten in \(Int(left))s\(Prefs.bool("clearSecretClipboard") ? ", and cleared from the clipboard" : "").", systemImage: "lock.shield.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .tint(.red)
            }
            Button {
                store.revealed.insert(clip.id)
            } label: {
                Label("Reveal (⌘R)", systemImage: "eye")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct Section<Content: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            content
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }
}

private struct FactRow: View {
    @EnvironmentObject private var store: ClipStore
    let fact: Fact

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(fact.label)
                .foregroundStyle(.secondary)
                .frame(width: 120, alignment: .leading)
                .lineLimit(1)
            Text(fact.value)
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
            CopyButton(text: fact.value)
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}

private struct CopyButton: View {
    @EnvironmentObject private var store: ClipStore
    let text: String

    var body: some View {
        Button {
            store.copyText(text)
            store.showToast("Copied")
        } label: {
            Image(systemName: "doc.on.doc")
        }
        .buttonStyle(.borderless)
        .help("Copy")
    }
}

private struct TransformGrid: View {
    @EnvironmentObject private var store: ClipStore
    let clip: Clip

    var body: some View {
        let text = clip.text ?? ""
        // Only offer what would change something.
        let useful = Transform.allCases.filter { transform in
            guard let result = transform.apply(text) else { return false }
            return result != text && !result.isEmpty
        }

        LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 6)], alignment: .leading, spacing: 6) {
            ForEach(useful) { transform in
                Button(transform.rawValue) { store.copy(clip, applying: transform) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(8)
    }
}
