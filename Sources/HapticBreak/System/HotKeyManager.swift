import AppKit
import Carbon.HIToolbox

/// Global hotkey management (Carbon RegisterEventHotKey).
///
/// Compared to `NSEvent` global monitoring, Carbon hotkeys require no "Accessibility" permission, which
/// suits distribution. Bindings are user-editable (see `HotKeyBindings`); factory defaults:
/// ⌃⌥Space pause/resume, ⌃⌥S skip, ⌃⌥B buzz now, ⌃⌥⏎ acknowledge (start the break).
///
/// Observable so Settings can surface registration failures (a combo already taken by another app
/// fails silently at the Carbon level — the user deserves to know why their shortcut does nothing).
/// Registration only happens on shortcut changes, so observing this stays cheap.
final class HotKeyManager: ObservableObject {

    static let shared = HotKeyManager()
    private init() {}

    /// Display strings (⌃⌥Space) of combos the system rejected at registration. Main-thread only.
    @Published private(set) var failedBindings: [String] = []

    private var handlerInstalled = false
    private var hotKeyRefs: [EventHotKeyRef] = []
    private var actions: [UInt32: () -> Void] = [:]
    private var nextID: UInt32 = 1

    func registerBindings(_ bindings: HotKeyBindings,
                          togglePause: @escaping () -> Void,
                          skip: @escaping () -> Void,
                          breakNow: @escaping () -> Void,
                          acknowledge: @escaping () -> Void) {
        if bindings.pauseEnabled { register(bindings.pause, action: togglePause) }
        if bindings.skipEnabled { register(bindings.skip, action: skip) }
        if bindings.buzzEnabled { register(bindings.buzz, action: breakNow) }
        if bindings.acknowledgeEnabled { register(bindings.acknowledge, action: acknowledge) }
    }

    private func register(_ binding: HotKeyBinding, action: @escaping () -> Void) {
        installHandlerIfNeeded()
        let id = nextID; nextID += 1
        actions[id] = action
        let hotID = EventHotKeyID(signature: 0x4842_5254 /* 'HBRT' */, id: id)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(binding.keyCode, binding.modifiers, hotID,
                                         GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref = ref {
            hotKeyRefs.append(ref)
        } else {
            failedBindings.append(binding.display)
            Log.hotkeys.error("RegisterEventHotKey failed for \(binding.display, privacy: .public): \(status)")
        }
    }

    func unregisterAll() {
        for ref in hotKeyRefs { UnregisterEventHotKey(ref) }
        hotKeyRefs.removeAll()
        actions.removeAll()
        nextID = 1
        if !failedBindings.isEmpty { failedBindings = [] }
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
