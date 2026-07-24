import Foundation

/// Pure recognition logic for the three-finger triple-tap acknowledgment: consumes raw contact
/// frames `(fingerCount, timestamp)` and decides when the gesture fired. Extracted from
/// `TouchGestureMonitor` (which keeps the private-framework plumbing) so the recognition can be
/// unit-tested and tuned without hardware in the loop — same layering idea as `RingModel`.
///
/// The key idea is the **resting baseline**: any contact that stays down longer than a tap could
/// possibly be (a resting thumb, the heel of the palm, fingers parked on the trackpad to feel the
/// buzz — the product's own posture) is absorbed into `baseline`, and a tap is a *transient rise
/// of ≥ `requiredFingers` above that baseline*. The previous episode model ("first finger down →
/// ALL fingers up") required the count to return to zero, so any lingering contact made the
/// gesture completely unrecognizable — the main reason it felt unresponsive.
struct TapSequenceDetector {

    // MARK: - Tuning
    /// A tap must lift the finger count at least this far above the resting baseline.
    var requiredFingers = 3
    /// Qualifying taps needed to fire.
    var requiredTaps = 3
    /// Longest contact that still reads as a "tap"; anything longer is a rest and is absorbed
    /// into the baseline instead of resetting the sequence.
    var maxTapDuration = 0.55
    /// Longest pause between consecutive taps (measured end-to-end, so a tap's own duration is
    /// included via `maxTapDuration`) that keeps the sequence alive.
    var maxTapGap = 0.75

    // MARK: - State
    /// Sustained contact count: whatever has been touching longer than a tap could be.
    private var baseline = 0
    private var episodeActive = false
    private var episodeBeganAt = 0.0
    private var episodePeak = 0
    private var tapCount = 0
    private var lastTapEndedAt = 0.0

    /// Feed one contact frame. Returns `true` when a full tap sequence is recognized.
    mutating func handleFrame(fingerCount: Int, timestamp: Double) -> Bool {
        // Fingers lifted below the resting set → the baseline follows down immediately.
        if fingerCount < baseline { baseline = fingerCount }

        guard episodeActive else {
            if fingerCount > baseline {
                episodeActive = true
                episodeBeganAt = timestamp
                episodePeak = fingerCount
            }
            return false
        }

        episodePeak = max(episodePeak, fingerCount)

        if fingerCount <= baseline {
            // Released back to the resting set: evaluate the episode as a tap.
            episodeActive = false
            let duration = timestamp - episodeBeganAt
            let lifted = episodePeak - baseline
            guard duration <= maxTapDuration else { tapCount = 0; return false }
            guard lifted >= requiredFingers else {
                // A small blip (palm flicker, a stray single finger) is noise — ignore it
                // without resetting the taps already counted.
                return false
            }
            let gap = timestamp - lastTapEndedAt
            tapCount = (tapCount > 0 && gap <= maxTapGap + maxTapDuration) ? tapCount + 1 : 1
            lastTapEndedAt = timestamp
            if tapCount >= requiredTaps {
                tapCount = 0
                return true
            }
        } else if timestamp - episodeBeganAt > maxTapDuration {
            // The contact lingered past tap length: it's a rest, not a tap. Absorb it into the
            // baseline so the *next* tap on top of the resting fingers is still recognizable.
            let lifted = episodePeak - baseline
            baseline = fingerCount
            episodeActive = false
            // Only a tap-sized press held too long resets the sequence (a failed tap attempt);
            // a small re-planted contact (the palm settling back down) absorbs silently.
            if lifted >= requiredFingers { tapCount = 0 }
        }
        return false
    }
}
