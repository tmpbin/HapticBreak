import Foundation

/// Haptic engine based on the private MultitouchSupport.framework, offering full waveform control.
///
/// Key implementation details (all verified on-device):
/// - The device ID is read from a struct byte offset while iterating the devices returned by
///   `MTDeviceCreateList`, validated by "whether the actuator opens successfully", automatically
///   adapting to offset differences across models/OS versions.
/// - The actuator is "one-shot": every buzz must re-create + open, then close after use.
/// - The device is **re-resolved (throttled) when missing**: a Bluetooth Magic Trackpad that
///   connects after launch (clamshell mode at login) is picked up within seconds instead of the
///   engine staying dead for the whole run; a failed open invalidates the cache so a reconnect
///   recovers the same way.
final class PrivateHapticEngine: HapticEngine {

    private let mt: MultitouchSupport?
    private let debug: Bool

    /// Guards the device cache: `actuate` runs on the player's background queue while
    /// `isAvailable` is read from the main thread.
    private let lock = NSLock()
    private var cachedDeviceID: UInt64?
    private var lastResolveAt: Date = .distantPast
    private static let resolveRetryInterval: TimeInterval = 10

    init(debug: Bool = false) {
        self.debug = debug
        self.mt = MultitouchSupport.shared
        self.cachedDeviceID = mt.flatMap { Self.resolveDeviceID(using: $0, debug: debug) }
        self.lastResolveAt = Date()
    }

    /// Current device ID (diagnostics / `--hapticscan`); re-resolves when missing, throttled.
    var deviceID: UInt64? { currentDeviceID() }

    var isAvailable: Bool { mt != nil && currentDeviceID() != nil }
    var backendName: String { L.t("backend.name.private") }

    /// Cached device, or a throttled re-resolution attempt when the cache is empty.
    private func currentDeviceID() -> UInt64? {
        lock.lock(); defer { lock.unlock() }
        if let id = cachedDeviceID { return id }
        guard let mt, Date().timeIntervalSince(lastResolveAt) >= Self.resolveRetryInterval else {
            return nil
        }
        lastResolveAt = Date()
        cachedDeviceID = Self.resolveDeviceID(using: mt, debug: debug)
        return cachedDeviceID
    }

    /// The device stopped opening (disconnected): drop the cache so the next call re-resolves.
    private func invalidateDevice() {
        lock.lock(); cachedDeviceID = nil; lock.unlock()
    }

    func actuate(_ tone: ResolvedTone) {
        // Production path: fix flags=0, use float0 as the linear main strength control and float1 for dullness
        // (timbre ID resolved by HapticProfile).
        _ = actuateWaveform(tone.actuationID, flags: 0, scale: tone.float0, timeScale: tone.float1)
    }

    /// Haptic Lab "raw actuation probe": exposes all parameters of `MTActuatorActuate` directly, to
    /// empirically study the strength model on real hardware.
    ///
    /// Disassembly conclusions (macOS 26.5 / `MultitouchSupport`, verified line by line):
    /// `MTActuatorActuate(ref, actuationID, flags, float0, float1)`
    /// - `actuationID`: actuation/waveform ID (key into the embedded curve table `__tpad_act_plist`, e.g. 1,2,3,4,5,6,15,16).
    /// - `strengthFlags`: strength level **bit selection** — `0x1`=Light, `0x2`=Medium, `0x4`=Firm (Apple tuned
    ///   them per model via `ActuatorRevision`); `0`=no level, drive base+timbre linearly via `scale` (used in production).
    /// - `scale`: main scale (4th arg `float0`).
    /// - `timeScale`: 5th arg `float1`, changes pulse width / timbre timing (dullness).
    @discardableResult
    func actuateRaw(actuationID: Int32, strengthFlags: UInt32, scale: Float, timeScale: Float) -> Int32 {
        actuateWaveform(actuationID, flags: strengthFlags, scale: scale, timeScale: timeScale)
    }

    @discardableResult
    private func actuateWaveform(_ actuationID: Int32, flags: UInt32, scale: Float, timeScale: Float) -> Int32 {
        guard let mt = mt, let id = currentDeviceID() else { return -1 }
        guard let unmanaged = mt.createFromDeviceID(id) else {
            invalidateDevice()
            return -1
        }
        let actuator = unmanaged.takeRetainedValue()
        defer { /* CFTypeRef released by ARC at end of scope */ }
        let openRet = mt.actuatorOpen(actuator, 0)
        guard openRet == 0 else {
            if debug { NSLog("[HapticBreak] actuatorOpen failed 0x%x", openRet) }
            invalidateDevice()
            return openRet
        }
        let ret = mt.actuatorActuate(actuator, actuationID, flags, scale, timeScale)
        if debug {
            NSLog("[HapticBreak] actuate id=%d flags=0x%x float0=%.2f float1=%.2f ret=0x%x",
                  actuationID, flags, scale, timeScale, ret)
        }
        _ = mt.actuatorClose(actuator)
        return ret
    }

    // MARK: - Device discovery

    private static func actuatorOpens(_ id: UInt64, using mt: MultitouchSupport) -> Bool {
        guard let unmanaged = mt.createFromDeviceID(id) else { return false }
        let actuator = unmanaged.takeRetainedValue()
        let ok = mt.actuatorOpen(actuator, 0) == 0
        if ok { _ = mt.actuatorClose(actuator) }
        return ok
    }

    private static func resolveDeviceID(using mt: MultitouchSupport, debug: Bool) -> UInt64? {
        if let listFn = mt.deviceCreateList, let unmanaged = listFn() {
            let array = unmanaged.takeRetainedValue()
            let count = CFArrayGetCount(array)
            for i in 0..<count {
                guard let devPtr = CFArrayGetValueAtIndex(array, i) else { continue }
                // Scan struct offsets that may hold the device ID; validate correctness by "whether the actuator opens".
                // Bound the scan by the actual heap allocation so a smaller device object on a future
                // macOS can never be read past its end (malloc_size returns 0 for non-malloc pointers,
                // in which case keep the legacy 256-byte bound).
                let objectSize = malloc_size(devPtr)
                let maxOffset = objectSize > 0 ? min(256, objectSize - MemoryLayout<UInt64>.size) : 256
                var offset = 0
                while offset <= maxOffset {
                    let candidate = devPtr.loadUnaligned(fromByteOffset: offset, as: UInt64.self)
                    if candidate != 0, actuatorOpens(candidate, using: mt) {
                        if debug {
                            NSLog("[HapticBreak] resolved deviceID=0x%llx @offset %d", candidate, offset)
                        }
                        return candidate
                    }
                    offset += 8
                }
            }
        }
        // Fallback: fixed IDs used by some models/older versions.
        for id in [UInt64(0x0200_0000_0100_0000)] where actuatorOpens(id, using: mt) {
            return id
        }
        return nil
    }
}
