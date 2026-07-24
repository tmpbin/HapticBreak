import Foundation

/// Pure logic for the editor's "tap a rhythm" recording mode: books the gap between consecutive
/// taps onto the previous beat, and keeps a pause-aware clock whose paused spans never leak into
/// the elapsed readout or the next tap's gap.
///
/// Same layering idea as `RingModel`: the state machine lives outside the SwiftUI view (`@State`
/// mutation still drives rendering), takes `now` as a parameter, and is unit-testable in
/// milliseconds. The view keeps only presentation concerns (playback highlight, drum-pad UI).
struct RhythmRecorder {

    /// Gap clamp between two recorded beats: below ~60 ms two taps blur into one buzz on the
    /// trackpad; beyond 2 s the pause reads as "thinking", not rhythm.
    static let minGapMs = 60
    static let maxGapMs = 2000

    private(set) var steps: [HapticStep] = []
    private(set) var isPaused = false

    private var startDate: Date?
    private var lastTapAt: Date?
    private var pauseStartedAt: Date?

    var isEmpty: Bool { steps.isEmpty }

    /// Begin (or restart) a recording session.
    mutating func start(at now: Date = Date()) {
        steps = []
        lastTapAt = nil
        isPaused = false
        pauseStartedAt = nil
        startDate = now
    }

    /// Drop the takes but keep recording (the "clear / re-record" button).
    mutating func clear(at now: Date = Date()) {
        steps = []
        lastTapAt = nil
        startDate = now
    }

    /// Record one beat. The time since the previous tap becomes the previous beat's gap (clamped).
    /// Ignored while paused.
    mutating func tap(_ step: HapticStep, at now: Date = Date()) {
        guard !isPaused else { return }
        if let last = lastTapAt, let lastIndex = steps.indices.last {
            let gap = Int(now.timeIntervalSince(last) * 1000)
            steps[lastIndex].gapMsAfter = max(Self.minGapMs, min(Self.maxGapMs, gap))
        }
        steps.append(step)
        lastTapAt = now
    }

    /// Pause / resume the recording clock. Every pause — manual or the implicit one during audition
    /// playback — books its span here: on resume the wall-clock anchors (`startDate`, `lastTapAt`)
    /// shift forward, so paused time never inflates the elapsed readout or the next tap's gap.
    mutating func setPaused(_ paused: Bool, at now: Date = Date()) {
        guard paused != isPaused else { return }
        isPaused = paused
        if paused {
            pauseStartedAt = now
        } else if let pauseStart = pauseStartedAt {
            let pauseDuration = now.timeIntervalSince(pauseStart)
            startDate = startDate?.addingTimeInterval(pauseDuration)
            lastTapAt = lastTapAt?.addingTimeInterval(pauseDuration)
            pauseStartedAt = nil
        }
    }

    /// Recording time on the session clock; frozen while paused.
    func elapsed(at now: Date = Date()) -> TimeInterval {
        guard let start = startDate else { return 0 }
        let reference = isPaused ? (pauseStartedAt ?? now) : now
        return max(0, reference.timeIntervalSince(start))
    }
}
