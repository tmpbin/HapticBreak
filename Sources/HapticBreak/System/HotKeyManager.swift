import AppKit
import Carbon.HIToolbox

/// Global hotkey management (Carbon RegisterEventHotKey).
///
/// Compared to `NSEvent` global monitoring, Carbon hotkeys require no "Accessibility" permission, which
/// suits distribution. Default bindings: ⌃⌥Space pause/resume, ⌃⌥S skip, ⌃⌥B break now.
final class HotKeyManager {

    static let shared = HotKeyManager()
    private init() {}

    private var handlerInstalled = false
    private var hotKeyRefs: [EventHotKeyRef] = []
    private var actions: [UInt32: () -> Void] = [:]
    private var nextID: UInt32 = 1

    private static let ctrl = UInt32(controlKey)
    private static let opt  = UInt32(optionKey)

    func registerDefaults(togglePause: @escaping () -> Void,
                          skip: @escaping () -> Void,
                          breakNow: @escaping () -> Void) {
        register(keyCode: UInt32(kVK_Space),  modifiers: Self.ctrl | Self.opt, action: togglePause)
        register(keyCode: UInt32(kVK_ANSI_S), modifiers: Self.ctrl | Self.opt, action: skip)
        register(keyCode: UInt32(kVK_ANSI_B), modifiers: Self.ctrl | Self.opt, action: breakNow)
    }

    func register(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        installHandlerIfNeeded()
        let id = nextID; nextID += 1
        actions[id] = action
        let hotID = EventHotKeyID(signature: 0x4842_5254 /* 'HBRT' */, id: id)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(keyCode, modifiers, hotID,
                                         GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref = ref {
            hotKeyRefs.append(ref)
        } else {
            NSLog("[HapticBreak] RegisterEventHotKey failed: %d", status)
        }
    }

    func unregisterAll() {
        for ref in hotKeyRefs { UnregisterEventHotKey(ref) }
        hotKeyRefs.removeAll()
        actions.removeAll()
        nextID = 1
    }

    private func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { (_, event, _) -> OSStatus in
            var hkID = EventHotKeyID()
            GetEventParameter(event,
                              EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID),
                              nil,
                              MemoryLayout<EventHotKeyID>.size,
                              nil,
                              &hkID)
            HotKeyManager.shared.fire(id: hkID.id)
            return noErr
        }, 1, &spec, nil, nil)
    }

    private func fire(id: UInt32) {
        guard let action = actions[id] else { return }
        DispatchQueue.main.async { action() }
    }
}
