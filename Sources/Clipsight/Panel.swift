import AppKit
import ApplicationServices
import SwiftUI

/// A floating panel like Spotlight's. It takes the keyboard without activating Clipsight,
/// so the app you were in stays in front and receives the paste.
final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func resignKey() {
        super.resignKey()
        // Clicking anywhere else dismisses it.
        if isVisible { orderOut(nil) }
    }

    override func cancelOperation(_ sender: Any?) {
        orderOut(nil)
    }
}

@MainActor
final class PanelController {
    static let shared = PanelController()

    private lazy var panel: FloatingPanel = {
        let panel = FloatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 520),
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.minSize = NSSize(width: 640, height: 380)
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.contentView = NSHostingView(rootView: PanelView().environmentObject(ClipStore.shared))
        panel.setFrameAutosaveName("ClipsightPanel")
        return panel
    }()

    var isVisible: Bool { panel.isVisible }

    func toggle() {
        isVisible ? hide() : show()
    }

    func show() {
        let store = ClipStore.shared
        store.query = ""
        store.filter = .all
        store.selection = store.results.first?.id
        store.revealed = []

        // Open on the screen with the mouse, a little above centre.
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main {
            let visible = screen.visibleFrame
            let size = panel.frame.size
            panel.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2 + visible.height * 0.08))
        }
        panel.makeKeyAndOrderFront(nil)
        NotificationCenter.default.post(name: .panelShown, object: nil)
    }

    func hide() {
        panel.orderOut(nil)
    }

    /// Copies the clip and, when allowed, pastes it into the app in front.
    func paste(_ clip: Clip) {
        ClipStore.shared.copy(clip)
        hide()
        guard Prefs.bool("pasteDirectly") else { return }
        guard AXIsProcessTrusted() else {
            ClipStore.shared.showToast("Copied. Allow Accessibility in Settings to paste directly.")
            return
        }
        // Give the previous app a moment to take the keyboard back.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            let source = CGEventSource(stateID: .combinedSessionState)
            for down in [true, false] {
                let event = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: down)
                event?.flags = .maskCommand
                event?.post(tap: .cghidEventTap)
            }
        }
    }

    static func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }
}

extension Notification.Name {
    static let panelShown = Notification.Name("ClipsightPanelShown")
}
