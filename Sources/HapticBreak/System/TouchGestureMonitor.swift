import Foundation

/// Three-finger triple-tap detection on the trackpad, via the private `MultitouchSupport` contact
/// frame callback (the same framework that already drives the haptic actuator).
///
/// Design constraints:
/// - **Reminding-scoped**: the monitor is started only while a reminder awaits acknowledgment and
///   stopped immediately after — zero idle cost and zero chance of accidental triggers otherwise.
/// - **Count-only**: the callback's finger *count* and timestamp are all we read; the raw finger
///   struct layout (which varies across macOS builds) is never dereferenced.
/// - **Resting-contact tolerant**: recognition (see `TapSequenceDetector`) measures taps as
///   transient rises above a resting baseline, so a parked thumb / palm heel — the natural posture
///   when feeling the buzz — no longer makes the gesture unrecognizable.
/// - **Fail-quiet**: if any private symbol is missing or no device is found, `isSupported` is false
///   and everything degrades to the other ack channels (hotkey / panel / stepping away).
final class TouchGestureMonitor {

    static let shared = TouchGestureMonitor()

    /// Called on the main thread when a three-finger triple-tap is recognized.
    var onTripleTap: (() -> Void)?

    // MARK: - State (single MT callback thread + main thread; guarded by lock)
    private let lock = NSLock()
    private var running = false
    private var devices: [CFTypeRef] = []
    /// Recognition state machine (pure logic, unit-tested in TapSequenceDetectorTests).
    private var detector = TapSequenceDetector()

    private init() {}

    /// Whether the private contact-frame API resolved and at least one multitouch device exists.
    /// Probing enumerates devices (`MTDeviceCreateList`) — too heavy for per-render UI checks and
    /// per-settings-change re-evaluation (e.g. while dragging a slider), so the result is cached
    /// briefly; a hot-plugged external trackpad still shows up within seconds. Main-thread only.
    static var isSupported: Bool {
        if let cached = supportCache, Date().timeIntervalSince(cached.at) < supportCacheTTL {
            return cached.value
        }
        let value = probeSupport()
        supportCache = (value, Date())
        return value
    }

    private static var supportCache: (value: Bool, at: Date)?
    private static let supportCacheTTL: TimeInterval = 5

    private static func probeSupport() -> Bool {
        guard let mt = MultitouchSupport.shared,
              mt.registerContactFrameCallback != nil,
              mt.deviceStart != nil,
              let list = mt.deviceCreateList?()?.takeRetainedValue()
        else { return false }
        return CFArrayGetCount(list) > 0
    }

    /// Begin listening on all multitouch devices. Safe to call repeatedly.
    func start() {
        lock.lock(); defer { lock.unlock() }
        guard !running,
              let mt = MultitouchSupport.shared,
              let register = mt.registerContactFrameCallback,
              let deviceStart = mt.deviceStart,
              let list = mt.deviceCreateList?()?.takeRetainedValue()
        else { return }

        resetGestureState()
        let count = CFArrayGetCount(list)
        for i in 0..<count {
            guard let ptr = CFArrayGetValueAtIndex(list, i) else { continue }
            let device = unsafeBitCast(ptr, to: CFTypeRef.self)
            register(device, hbContactFrameCallback)
            deviceStart(device, 0)
            devices.append(device)
        }
        running = !devices.isEmpty
    }

    /// Stop listening and release the devices. Safe to call repeatedly.
    func stop() {
        lock.lock(); defer { lock.unlock() }
        guard running, let mt = MultitouchSupport.shared else { running = false; devices = []; return }
        for device in devices {
            mt.deviceStop?(device)
            mt.unregisterContactFrameCallback?(device, hbContactFrameCallback)
        }
        devices = []
        running = false
    }

    private func resetGestureState() {
        detector = TapSequenceDetector()
    }

    /// One contact frame: recognition is delegated to the pure `TapSequenceDetector`
    /// (resting-baseline model — see that type for the full semantics).
    fileprivate func handleFrame(fingerCount: Int, timestamp: Double) {
        lock.lock()
        let fire = detector.handleFrame(fingerCount: fingerCount, timestamp: timestamp)
        lock.unlock()
        if fire {
            DispatchQueue.main.async { [weak self] in self?.onTripleTap?() }
        }
    }
}

/// C callback trampoline (must be a top-level function for `@convention(c)`); routes to the singleton.
/// Only the finger count and timestamp are used — the touch data pointer is never dereferenced.
private func hbContactFrameCallback(_ device: CFTypeRef?,
                                    _ touches: UnsafeMutableRawPointer?,
                                    _ numTouches: Int32,
                                    _ timestamp: Double,
                                    _ frame: Int32) -> Int32 {
    TouchGestureMonitor.shared.handleFrame(fingerCount: Int(numTouches), timestamp: timestamp)
    return 0
}
