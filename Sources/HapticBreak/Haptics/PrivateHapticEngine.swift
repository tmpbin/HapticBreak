import Foundation

/// Haptic engine based on the private MultitouchSupport.framework, offering full waveform control.
///
/// Key implementation details (all verified on-device):
/// - The device ID is read from a struct byte offset while iterating the devices returned by
///   `MTDeviceCreateList`, validated by "whether the actuator opens successfully", automatically
///   adapting to offset differences across models/OS versions.
/// - The actuator is "one-shot": every buzz must re-create + open, then close after use.
final class PrivateHapticEngine: HapticEngine {

    private let mt: MultitouchSupport?
    private(set) var deviceID: UInt64?
    private let debug: Bool

    init(debug: Bool = false) {
        self.debug = debug
        self.mt = MultitouchSupport.shared
        self.deviceID = mt.flatMap { Self.resolveDeviceID(using: $0, debug: debug) }
    }

    var isAvailable: Bool { mt != nil && deviceID != nil }
    var backendName: String { L.t("backend.name.private") }

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
        guard let mt = mt, let id = deviceID else { return -1 }
        guard let unmanaged = mt.createFromDeviceID(id) else { return -1 }
        let actuator = unmanaged.takeRetainedValue()
        defer { /* CFTypeRef released by ARC at end of scope */ }
        let openRet = mt.actuatorOpen(actuator, 0)
        guard openRet == 0 else {
            if debug { NSLog("[HapticBreak] actuatorOpen failed 0x%x", openRet) }
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
                var offset = 0
                while offset <= 256 {
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
