import Foundation

/// Three-finger triple-tap detection on the trackpad, via the private `MultitouchSupport` contact
/// frame callback (the same framework that already drives the haptic actuator).
///
/// Design constraints:
/// - **Reminding-scoped**: the monitor is started only while a reminder awaits acknowledgment and
///   stopped immediately after — zero idle cost and zero chance of accidental triggers otherwise.
/// - **Count-only**: the callback's finger *count* and timestamp are all we read; the raw finger
///   struct layout (which varies across macOS builds) is never dereferenced.
/// - **Fail-quiet**: if any private symbol is missing or no device is found, `isSupported` is false
///   and everything degrades to the other ack channels (hotkey / panel / stepping away).
final class TouchGestureMonitor {

    static let shared = TouchGestureMonitor()

    /// Called on the main thread when a three-finger triple-tap is recognized.
    var onTripleTap: (() -> Void)?

    // MARK: - Gesture parameters
    /// A tap qualifies when at least this many fingers touched during the episode.
    private static let requiredFingers = 3
    /// Maximum touch-down duration for an episode to count as a "tap" (not a rest/drag).
    private static let maxTapDuration = 0.45
    /// Maximum gap between consecutive taps to keep the sequence alive.
    private static let maxTapGap = 0.65
    private static let requiredTaps = 3

    // MARK: - State (single MT callback thread + main thread; guarded by lock)
    private let lock = NSLock()
    private var running = false
    private var devices: [CFTypeRef] = []

    private var episodeActive = false
    private var episodeBeganAt: Double = 0
    private var episodeMaxFingers = 0
    private var tapCount = 0
    private var lastTapEndedAt: Double = 0

    private init() {}

    /// Whether the private contact-frame API resolved and at least one multitouch device exists.
    static var isSupported: Bool {
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
        episodeActive = false
        episodeMaxFingers = 0
        tapCount = 0
        lastTapEndedAt = 0
    }

    /// One contact frame: track touch episodes by finger count only.
    /// Episode = first finger down → all fingers up; it counts as a tap when it was short and
    /// reached ≥3 fingers at some point (fingers land/lift asynchronously, so we track the max).
    fileprivate func handleFrame(fingerCount: Int, timestamp: Double) {
        lock.lock()
        var fire = false
        if fingerCount > 0 {
            if !episodeActive {
                episodeActive = true
                episodeBeganAt = timestamp
                episodeMaxFingers = fingerCount
            } else {
                episodeMaxFingers = max(episodeMaxFingers, fingerCount)
            }
        } else if episodeActive {
            episodeActive = false
            let duration = timestamp - episodeBeganAt
            let isTap = duration <= Self.maxTapDuration && episodeMaxFingers >= Self.requiredFingers
            episodeMaxFingers = 0
            if isTap {
                let gap = timestamp - lastTapEndedAt
                tapCount = (tapCount > 0 && gap <= Self.maxTapGap + Self.maxTapDuration) ? tapCount + 1 : 1
                lastTapEndedAt = timestamp
                if tapCount >= Self.requiredTaps {
                    tapCount = 0
                    fire = true
                }
            } else {
                tapCount = 0
            }
        }
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
