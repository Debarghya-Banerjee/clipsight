import Carbon

/// A system-wide shortcut. Carbon's hot keys need no Accessibility permission.
@MainActor
final class Hotkey {
    enum Preset: String, CaseIterable, Identifiable {
        case shiftCommandV, optionCommandV, controlOptionV, shiftCommandC, optionSpace

        var id: String { rawValue }

        var label: String {
            switch self {
            case .shiftCommandV: "⇧⌘V"
            case .optionCommandV: "⌥⌘V"
            case .controlOptionV: "⌃⌥V"
            case .shiftCommandC: "⇧⌘C"
            case .optionSpace: "⌥Space"
            }
        }

        fileprivate var keyCode: UInt32 {
            switch self {
            case .shiftCommandC: UInt32(kVK_ANSI_C)
            case .optionSpace: UInt32(kVK_Space)
            default: UInt32(kVK_ANSI_V)
            }
        }

        fileprivate var modifiers: UInt32 {
            switch self {
            case .shiftCommandV, .shiftCommandC: UInt32(cmdKey | shiftKey)
            case .optionCommandV: UInt32(cmdKey | optionKey)
            case .controlOptionV: UInt32(controlKey | optionKey)
            case .optionSpace: UInt32(optionKey)
            }
        }

        static var current: Preset {
            Preset(rawValue: Prefs.defaults.string(forKey: "hotkey") ?? "") ?? .shiftCommandV
        }
    }

    static let shared = Hotkey()

    private var ref: EventHotKeyRef?
    private var installed = false
    fileprivate var action: (() -> Void)?

    func register(_ preset: Preset, action: @escaping () -> Void) {
        self.action = action
        if !installed {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                DispatchQueue.main.async { MainActor.assumeIsolated { Hotkey.shared.action?() } }
                return noErr
            }, 1, &spec, nil, nil)
            installed = true
        }
        if let ref { UnregisterEventHotKey(ref) }
        let id = EventHotKeyID(signature: OSType(0x434C_5053), id: 1)
        RegisterEventHotKey(preset.keyCode, preset.modifiers, id, GetApplicationEventTarget(), 0, &ref)
    }
}
