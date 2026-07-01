import Foundation
import CoreGraphics

/// System input idle detection. Based on `CGEventSource`, read-only, requires no permissions.
enum IdleMonitor {
    /// Seconds elapsed since the last input event of any kind (keyboard / mouse / trackpad).
    static func secondsSinceLastInput() -> TimeInterval {
        // kCGAnyInputEventType == 0xFFFFFFFF
        guard let anyEvent = CGEventType(rawValue: ~0) else { return 0 }
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyEvent)
    }
}
