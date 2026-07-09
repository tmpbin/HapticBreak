import AppKit
import Carbon.HIToolbox

/// Global hotkey management (Carbon RegisterEventHotKey).
///
/// Compared to `NSEvent` global monitoring, Carbon hotkeys require no "Accessibility" permission, which
/// suits distribution. Bindings are user-editable (see `HotKeyBindings`); factory defaults:
/// ⌃⌥Space pause/resume, ⌃⌥S skip, ⌃⌥B buzz now, ⌃⌥⏎ acknowledge (start the break).
final class HotKeyManager {

    static let shared = HotKeyManager()
    private init() {}

    private var handlerInstalled = false
    private var hotKeyRefs: [EventHotKeyRef] = []
    private var actions: [UInt32: () -> Void] = [:]
    private var nextID: UInt32 = 1

    func registerBindings(_ bindings: HotKeyBindings,
                          togglePause: @escaping () -> Void,
                          skip: @escaping () -> Void,
                          breakNow: @escaping () -> Void,
                          acknowledge: @escaping () -> Void) {
        if bindings.pauseEnabled {
            register(keyCode: bindings.pause.keyCode, modifiers: bindings.pause.modifiers, action: togglePause)
        }
        if bindings.skipEnabled {
            register(keyCode: bindings.skip.keyCode, modifiers: bindings.skip.modifiers, action: skip)
        }
        if bindings.buzzEnabled {
            register(keyCode: bindings.buzz.keyCode, modifiers: bindings.buzz.modifiers, action: breakNow)
        }
        if bindings.acknowledgeEnabled {
            register(keyCode: bindings.acknowledge.keyCode, modifiers: bindings.acknowledge.modifiers, action: acknowledge)
        }
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
