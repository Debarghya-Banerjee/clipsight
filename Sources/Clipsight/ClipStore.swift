import AppKit
import CryptoKit
import NaturalLanguage
import Vision

enum Prefs {
    static let defaults = UserDefaults.standard

    static let defaultIgnoredApps = [
        "com.1password.1password", "com.agilebits.onepassword7", "com.bitwarden.desktop",
        "com.apple.keychainaccess", "com.apple.Passwords", "com.lastpass.LastPass", "com.dashlane.dashlanephonefinal",
    ].joined(separator: "\n")

    static func register() {
        defaults.register(defaults: [
            "paused": false,
            "historyLimit": 500,
            "cleanLinks": true,
            "secretShield": true,
            "secretSeconds": 90,
            "clearSecretClipboard": true,
            "pasteDirectly": true,
            "hotkey": Hotkey.Preset.shiftCommandV.rawValue,
            "ignoredApps": defaultIgnoredApps,
        ])
    }

    static func bool(_ key: String) -> Bool { defaults.bool(forKey: key) }
    static func int(_ key: String) -> Int { defaults.integer(forKey: key) }

    static var ignoredApps: Set<String> {
        Set((defaults.string(forKey: "ignoredApps") ?? "").split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) })
    }
}

enum Filter: String, CaseIterable, Identifiable {
    case all = "All"
    case pinned = "Pinned"
    case text = "Text"
    case links = "Links"
    case images = "Images"
    case dev = "Dev"
    case secrets = "Secrets"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .all: "tray.full"
        case .pinned: "pin.fill"
        case .text: "text.alignleft"
        case .links: "link"
        case .images: "photo"
        case .dev: "curlybraces"
        case .secrets: "lock.fill"
        }
    }

    func includes(_ clip: Clip) -> Bool {
        switch self {
        case .all: true
        case .pinned: clip.pinned
        case .text: [.text, .email].contains(clip.kind)
        case .links: .url == clip.kind
        case .images: .image == clip.kind
        case .dev: [.json, .jwt, .base64, .timestamp, .color, .code, .path].contains(clip.kind)
        case .secrets: clip.isSecret
        }
    }
}

@MainActor
final class ClipStore: ObservableObject {
    static let shared = ClipStore()

    @Published private(set) var clips: [Clip] = []
    @Published private(set) var results: [Clip] = []
    /// Results found by meaning rather than by the words typed.
    @Published private(set) var related: Set<UUID> = []
    @Published var paused = Prefs.bool("paused") {
        didSet { Prefs.defaults.set(paused, forKey: "paused") }
    }

    // Panel state, kept here because the Command Line Tools ship without SwiftUI's @State macro.
    @Published var query = "" { didSet { refresh() } }
    @Published var filter = Filter.all { didSet { refresh() } }
    @Published var selection: UUID?
    @Published var revealed: Set<UUID> = []
    @Published var toast: String?
    @Published var now = Date()
    @Published var hovered: UUID?

    private let pasteboard = NSPasteboard.general
    private var lastChange = NSPasteboard.general.changeCount
    /// Change counts of secrets as they were copied, so the clipboard is only cleared if it still holds them.
    private var secretChanges: [UUID: Int] = [:]
    private var vectors: [UUID: [Double]] = [:]
    private var thumbnails: [String: NSImage] = [:]
    private var saveTask: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?

    static let folder: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = support.appending(path: "Clipsight")
        // Clipsight was called Flotsam during development. Bring its history along.
        let old = support.appending(path: "Flotsam")
        if !FileManager.default.fileExists(atPath: url.path), FileManager.default.fileExists(atPath: old.path) {
            try? FileManager.default.moveItem(at: old, to: url)
        }
        try? FileManager.default.createDirectory(at: url.appending(path: "images"), withIntermediateDirectories: true)
        return url
    }()

    private static let historyFile = folder.appending(path: "history.json")
    private static let imagesFolder = folder.appending(path: "images")
    nonisolated static let embedding = NLEmbedding.sentenceEmbedding(for: .english)

    var selected: Clip? { results.first { $0.id == selection } ?? results.first }

    init() {
        Prefs.register()
        load()
        refresh()
        Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        Task { await indexAll() }
    }

    // MARK: - Watching the clipboard

    private func poll() {
        let change = pasteboard.changeCount
        guard change != lastChange else { return }
        lastChange = change
        guard !paused else { return }

        // Apps mark passwords and generated data so clipboard managers leave them alone (nspasteboard.org).
        let types = Set((pasteboard.types ?? []).map(\.rawValue))
        let marked = ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType", "org.nspasteboard.AutoGeneratedType", "com.agilebits.onepassword"]
        guard types.isDisjoint(with: marked) else { return }

        let source = NSWorkspace.shared.frontmostApplication
        guard !Prefs.ignoredApps.contains(source?.bundleIdentifier ?? "") else { return }

        var clip: Clip
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            clip = Clip(kind: .files, files: urls.map(\.path))
        } else if let string = pasteboard.string(forType: .string), !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            clip = textClip(string)
        } else if let data = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff), let png = pngData(data), png.count < 25_000_000 {
            let name = SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined().prefix(24) + ".png"
            try? png.write(to: Self.imagesFolder.appending(path: String(name)))
            clip = Clip(kind: .image, imageFile: String(name))
        } else {
            return
        }

        clip.sourceBundleID = source?.bundleIdentifier
        clip.sourceName = source?.localizedName
        insert(clip)
    }

    private func textClip(_ string: String) -> Clip {
        var text = string
        var cleaned = 0
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if Prefs.bool("cleanLinks"), let link = Detector.cleanLink(trimmed) {
            text = link.url
            cleaned = link.removed
            write { $0.setString(link.url, forType: .string) }
            showToast("Removed \(cleaned) \(1 == cleaned ? "tracker" : "trackers") from the link")
        }

        var clip = Clip(kind: Detector.kind(of: text), text: text, cleanedTrackers: cleaned)
        if Prefs.bool("secretShield"), let label = Detector.secretLabel(text) {
            clip.secretLabel = label
            clip.expires = Date().addingTimeInterval(Double(max(Prefs.int("secretSeconds"), 10)))
            secretChanges[clip.id] = pasteboard.changeCount
        }
        return clip
    }

    private func insert(_ clip: Clip) {
        var clip = clip
        // Copying something again moves it to the top and keeps its pin.
        if let index = clips.firstIndex(where: { sameContent($0, clip) }) {
            clip.pinned = clips[index].pinned
            clip.ocrText = clips[index].ocrText
            clips.remove(at: index)
        }
        clips.insert(clip, at: 0)

        let limit = max(Prefs.int("historyLimit"), 20)
        while limit < clips.count, let last = clips.lastIndex(where: { !$0.pinned }) {
            delete(clips[last], save: false)
        }

        selection = nil
        refresh()
        save()

        if .image == clip.kind && nil == clip.ocrText {
            recognizeText(clip)
        } else {
            index(clip)
        }
    }

    private func sameContent(_ a: Clip, _ b: Clip) -> Bool {
        a.kind == b.kind && a.text == b.text && a.imageFile == b.imageFile && a.files == b.files
    }

    /// Forgets secrets whose time is up, and clears them from the clipboard if they're still on it.
    private func tick() {
        now = Date()
        let expired = clips.filter { ($0.expires ?? .distantFuture) <= now }
        guard !expired.isEmpty else { return }
        for clip in expired {
            if Prefs.bool("clearSecretClipboard"), secretChanges[clip.id] == pasteboard.changeCount {
                write { _ in }
                showToast("Cleared a \(clip.secretLabel?.lowercased() ?? "secret") from the clipboard")
            }
            delete(clip, save: false)
        }
        refresh()
    }

    // MARK: - Actions

    /// Puts a clip back on the clipboard and moves it to the top.
    func copy(_ clip: Clip) {
        write { pasteboard in
            switch clip.kind {
            case .image:
                if let image = image(for: clip) { pasteboard.writeObjects([image]) }
            case .files:
                pasteboard.writeObjects((clip.files ?? []).map { URL(fileURLWithPath: $0) as NSURL })
            default:
                pasteboard.setString(clip.text ?? "", forType: .string)
            }
        }
        if let index = clips.firstIndex(where: { $0.id == clip.id }) {
            var moved = clips.remove(at: index)
            moved.date = Date()
            clips.insert(moved, at: 0)
            if moved.isSecret {
                secretChanges[moved.id] = pasteboard.changeCount
            }
            refresh()
            save()
        }
    }

    /// Copies a rewritten version of a clip as a new clip.
    func copy(_ clip: Clip, applying transform: Transform) {
        guard let text = clip.text, let result = transform.apply(text), result != text else {
            showToast("\(transform.rawValue) didn't change anything")
            return
        }
        copyText(result, from: clip)
        showToast("Copied · \(transform.rawValue)")
    }

    func copyText(_ text: String, from clip: Clip? = nil) {
        write { $0.setString(text, forType: .string) }
        var new = Clip(kind: Detector.kind(of: text), text: text)
        if Prefs.bool("secretShield"), let label = Detector.secretLabel(text) {
            new.secretLabel = label
            new.expires = Date().addingTimeInterval(Double(max(Prefs.int("secretSeconds"), 10)))
            secretChanges[new.id] = pasteboard.changeCount
        }
        new.sourceName = clip?.sourceName
        new.sourceBundleID = clip?.sourceBundleID
        insert(new)
        selection = new.id
    }

    func togglePin(_ clip: Clip) {
        guard let index = clips.firstIndex(where: { $0.id == clip.id }) else { return }
        clips[index].pinned.toggle()
        // A pinned secret is still forgotten on time.
        refresh()
        save()
    }

    func delete(_ clip: Clip, save shouldSave: Bool = true) {
        clips.removeAll { $0.id == clip.id }
        vectors[clip.id] = nil
        secretChanges[clip.id] = nil
        revealed.remove(clip.id)
        if let file = clip.imageFile, !clips.contains(where: { $0.imageFile == file }) {
            try? FileManager.default.removeItem(at: Self.imagesFolder.appending(path: file))
            thumbnails[file] = nil
        }
        if shouldSave {
            refresh()
            save()
        }
    }

    func clearHistory(keepPinned: Bool) {
        for clip in clips where !(keepPinned && clip.pinned) {
            delete(clip, save: false)
        }
        refresh()
        save()
    }

    func moveSelection(_ step: Int) {
        guard !results.isEmpty else { return }
        let current = results.firstIndex { $0.id == selection } ?? 0
        selection = results[min(max(current + step, 0), results.count - 1)].id
    }

    func image(for clip: Clip) -> NSImage? {
        guard let file = clip.imageFile else { return nil }
        if let cached = thumbnails[file] { return cached }
        let image = NSImage(contentsOf: Self.imagesFolder.appending(path: file))
        thumbnails[file] = image
        return image
    }

    func showToast(_ message: String) {
        toast = message
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(for: .seconds(2.5))
            if !Task.isCancelled { toast = nil }
        }
    }

    private func write(_ fill: (NSPasteboard) -> Void) {
        pasteboard.clearContents()
        fill(pasteboard)
        lastChange = pasteboard.changeCount
    }

    private func pngData(_ data: Data) -> Data? {
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return data }
        return NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:])
    }

    // MARK: - Search

    /// Words typed match first, newest first. Clips that only match by meaning follow, closest first.
    func refresh() {
        let pool = clips.filter { filter.includes($0) }
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        guard !query.isEmpty else {
            results = pool.filter(\.pinned) + pool.filter { !$0.pinned }
            related = []
            keepSelection()
            return
        }

        let words = query.split(separator: " ")
        // Secrets are matched by where they came from, never by their content.
        let literal = pool.filter { clip in
            let haystack = (clip.isSecret ? [clip.sourceName, clip.secretLabel].compactMap { $0 }.joined(separator: " ") : clip.searchText).lowercased()
            return words.allSatisfy { haystack.contains($0) }
        }

        var byMeaning: [Clip] = []
        if 4 <= query.count, let embedding = Self.embedding, let target = embedding.vector(for: query) {
            let ids = Set(literal.map(\.id))
            let scored = pool
                .filter { !ids.contains($0.id) && !$0.isSecret }
                .compactMap { clip in vectors[clip.id].map { (clip, cosine(target, $0)) } }
                .sorted { $0.1 > $1.1 }
            // On-device similarity is noisy, so only clear winners count: close to the best match and strong on their own.
            let best = scored.first?.1 ?? 0
            byMeaning = scored.filter { 0.45 <= $0.1 && best - 0.07 <= $0.1 }.prefix(8).map(\.0)
        }

        results = literal + byMeaning
        related = Set(byMeaning.map(\.id))
        keepSelection()
    }

    private func keepSelection() {
        if !results.contains(where: { $0.id == selection }) {
            selection = results.first?.id
        }
    }

    private func cosine(_ a: [Double], _ b: [Double]) -> Double {
        var dot = 0.0, na = 0.0, nb = 0.0
        for i in 0..<min(a.count, b.count) {
            dot += a[i] * b[i]
            na += a[i] * a[i]
            nb += b[i] * b[i]
        }
        return dot / max((na * nb).squareRoot(), 1e-9)
    }

    private func index(_ clip: Clip) {
        guard !clip.isSecret else { return }
        let text = String(clip.searchText.prefix(1_000))
        Task.detached(priority: .utility) {
            let vector = Self.embedding?.vector(for: text)
            await MainActor.run { self.vectors[clip.id] = vector }
        }
    }

    private func indexAll() async {
        let pending = clips.filter { !$0.isSecret }.map { ($0.id, String($0.searchText.prefix(1_000))) }
        let computed = await Task.detached(priority: .utility) {
            pending.compactMap { id, text in Self.embedding?.vector(for: text).map { (id, $0) } }
        }.value
        for (id, vector) in computed { vectors[id] = vector }
    }

    /// Reads the text in a copied image on the Mac, so screenshots can be searched.
    private func recognizeText(_ clip: Clip) {
        guard let file = clip.imageFile else { return }
        let url = Self.imagesFolder.appending(path: file)
        Task.detached(priority: .utility) {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            try? VNImageRequestHandler(cgImage: image).perform([request])
            let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
            await MainActor.run {
                guard let index = self.clips.firstIndex(where: { $0.id == clip.id }) else { return }
                self.clips[index].ocrText = text
                self.index(self.clips[index])
                self.refresh()
                self.save()
            }
        }
    }

    // MARK: - Saving

    private func load() {
        guard let data = try? Data(contentsOf: Self.historyFile) else { return }
        guard let saved = try? JSONDecoder().decode([Clip].self, from: data) else {
            // Keep a file this version can't read instead of saving over it.
            let aside = Self.folder.appending(path: "history-unreadable-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: Self.historyFile, to: aside)
            return
        }
        clips = saved
    }

    /// Writes history to disk shortly after the last change. Secrets are never written.
    private func save() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            let data = try? JSONEncoder().encode(clips.filter { !$0.isSecret })
            try? data?.write(to: Self.historyFile, options: [.atomic, .completeFileProtection])
        }
    }
}
