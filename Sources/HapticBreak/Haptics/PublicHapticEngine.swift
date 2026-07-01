import AppKit

/// Haptic engine based on the public `NSHapticFeedbackManager`.
///
/// Only three preset patterns, with no precise control over strength/waveform. Used as the fallback when
/// the private API is unavailable, and also as the basis for a future App Store build.
final class PublicHapticEngine: HapticEngine {

    var isAvailable: Bool { true }
    var backendName: String { L.t("backend.name.public") }

    func actuate(_ tone: ResolvedTone) {
        // The public API can't express timbre/dullness, so approximate with three coarse levels by the main scale float0.
        let pattern: NSHapticFeedbackManager.FeedbackPattern
        switch tone.float0 {
        case ..<0.6: pattern = .alignment
        case ..<1.2: pattern = .generic
        default:     pattern = .levelChange
        }
        // Haptic feedback must be triggered on the main thread.
        if Thread.isMainThread {
            NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
        } else {
            DispatchQueue.main.async {
                NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
            }
        }
    }
}
