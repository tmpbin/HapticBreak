import Foundation

/// Plays haptic patterns in time order on a background serial queue.
///
/// Each beat = a full single beat `{timbre, strength 1…10, dullness 0…1, gap}`, resolved by
/// `HapticProfile.resolve` together with the **global strength 1…10 (multiplicative gain)** into a
/// `ResolvedTone` before feeding the engine. A preset's internal strong/weak contrast is preserved at
/// any global level.
final class HapticPlayer {

    private let queue = DispatchQueue(label: "com.aremind.hapticbreak.player", qos: .userInteractive)
    private var engine: HapticEngine
    private let profile = HapticProfile.shared
    private var generation = 0
    /// Separate counter for one-shot transient previews (buzz-on-slide). Lets a fast drag coalesce to its
    /// latest value instead of backing up the serial queue, without cancelling full-pattern playback.
    private var transientGen = 0
    private let lock = NSLock()

    /// The single haptic channel: occupied through this instant while a high-priority haptic
    /// (reminder/test/heads-up) plays, so the background follow-the-second beat yields.
    private var busyUntil = Date.distantPast

    init(engine: HapticEngine) {
        self.engine = engine
    }

    var backendName: String { engine.backendName }
    var isAvailable: Bool { engine.isAvailable }

    /// Whether a high-priority haptic is currently playing (so the background beat yields, ensuring only
    /// one haptic at a time).
    var isBusy: Bool { lock.lock(); defer { lock.unlock() }; return Date() < busyUntil }

    func updateEngine(_ engine: HapticEngine) {
        lock.lock(); self.engine = engine; lock.unlock()
    }

    /// Gap (ms) between two repeats, so each pass is a distinguishable, standalone "reminder" rather
    /// than blending together.
    private static let interRepeatGapMs = 500
    /// Leave a small tail after the final beat fires, so the last hit still counts within the "busy window".
    private static let busyTailMs = 200

    private func occupyChannel(forMs ms: Int) {
        lock.lock(); busyUntil = Date().addingTimeInterval(Double(max(0, ms)) / 1000.0); lock.unlock()
    }

    /// Play a full pattern (real event path, scaled by the global 10 levels). Cancels the previous
    /// still-running playback.
    /// - Parameter strength: Global strength 1…10 (multiplicative main gain).
    /// - Parameter repeatCount: Number of times to repeat the whole pattern (≥1).
    /// - Parameter onRoundStart: Called once on the main thread at the start of each pass — so
    ///   "screen flash / sound" stays in sync and matches the count of the haptic.
    func play(_ pattern: HapticPattern, strength: Int, repeatCount: Int = 1,
              onRoundStart: (() -> Void)? = nil) {
        run(pattern, repeatCount: repeatCount, onRoundStart: onRoundStart) { [profile] step in
            profile.resolve(step: step, global: strength)
        }
    }

    /// Design preview: play at the designed strength as-is (global gain = 1.0, unaffected by the user's
    /// global strength). Used by the "Pattern Editor".
    func playDesign(_ pattern: HapticPattern) {
        run(pattern, repeatCount: 1, onRoundStart: nil) { [profile] step in
            profile.resolveDesign(step: step)
        }
    }

    private func run(_ pattern: HapticPattern, repeatCount: Int, onRoundStart: (() -> Void)?,
                     resolve: @escaping (HapticStep) -> ResolvedTone) {
        lock.lock(); generation += 1; let myGen = generation; let engine = self.engine; lock.unlock()
        let steps = pattern.steps
        guard !steps.isEmpty else { return }
        let rounds = max(1, repeatCount)
        let oneRoundMs = Int(pattern.estimatedDuration * 1000)
        occupyChannel(forMs: oneRoundMs * rounds + Self.interRepeatGapMs * (rounds - 1) + Self.busyTailMs)
        queue.async { [weak self] in
            guard let self = self else { return }
            for round in 0..<rounds {
                self.lock.lock(); let current = self.generation; self.lock.unlock()
                if current != myGen { return }
                if let onRoundStart { DispatchQueue.main.async(execute: onRoundStart) }
                for (index, step) in steps.enumerated() {
                    self.lock.lock(); let cur = self.generation; self.lock.unlock()
                    if cur != myGen { return }
                    engine.actuate(resolve(step))
                    if index < steps.count - 1 {
                        usleep(useconds_t(max(0, step.gapMsAfter) * 1000))
                    }
                }
                if round < rounds - 1 {
                    usleep(useconds_t(Self.interRepeatGapMs * 1000))
                }
            }
        }
    }

    /// Try a single beat (editor "test this beat" / buzz-on-slide) — design preview, global gain = 1.0.
    /// Occupies the single channel. Coalesces rapid drags: only the newest queued preview actuates.
    func testStepDesign(_ step: HapticStep) {
        lock.lock(); transientGen += 1; let g = transientGen; let engine = self.engine; lock.unlock()
        occupyChannel(forMs: Self.busyTailMs)
        let tone = profile.resolveDesign(step: step)
        queue.async { [weak self] in
            guard let self, self.isTransientCurrent(g) else { return }
            engine.actuate(tone)
        }
    }

    /// Try a transient tone (for settings/preview, scaled by global). Coalesces rapid drags.
    func testTone(timbre: HapticTimbre, strength: Int, dullness: Double, strengthGlobal: Int) {
        lock.lock(); transientGen += 1; let g = transientGen; let engine = self.engine; lock.unlock()
        occupyChannel(forMs: Self.busyTailMs)
        let tone = profile.resolve(timbre: timbre, strength: strength, dullness: dullness, global: strengthGlobal)
        queue.async { [weak self] in
            guard let self, self.isTransientCurrent(g) else { return }
            engine.actuate(tone)
        }
    }

    /// Whether `g` is still the latest transient preview generation (drops superseded drag fires).
    private func isTransientCurrent(_ g: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }; return transientGen == g
    }

    /// Recorder audition: fire one design-strength beat with NO drag-coalescing — the playback
    /// loop paces the calls itself and every recorded beat must sound (coalescing would drop
    /// closely spaced beats whenever an actuation outlasts the gap to the next one).
    func auditionStepDesign(_ step: HapticStep) {
        lock.lock(); let engine = self.engine; lock.unlock()
        occupyChannel(forMs: Self.busyTailMs)
        let tone = profile.resolveDesign(step: step)
        queue.async { engine.actuate(tone) }
    }

    /// Background-level "follow-the-second" beat: take one full beat from the "heartbeat" pattern
    /// (strong→weak lub-dub), scaled to 0.85 overall and by the global strength. Skipped if a
    /// high-priority haptic is playing (`isBusy`); does not occupy the channel nor interrupt real playback.
    func ambientTick(strength: Int) {
        guard !isBusy else { return }
        lock.lock(); let engine = self.engine; lock.unlock()
        let beats = HapticPattern.heartbeat.steps
        guard let lub = beats.first else { return }
        let dub = beats.count > 1 ? beats[1] : nil
        let scale = { (s: Int) in max(1, Int((Double(s) * 0.85).rounded())) }
        let toneLub = profile.resolve(timbre: lub.timbre, strength: scale(lub.strength), dullness: lub.dullness, global: strength)
        let gapMs = max(60, lub.gapMsAfter)   // lub→dub gap within a heartbeat
        let toneDub = dub.map { profile.resolve(timbre: $0.timbre, strength: scale($0.strength), dullness: $0.dullness, global: strength) }
        queue.async { [weak self] in
            guard let self = self, !self.isBusy else { return }
            engine.actuate(toneLub)
            if let toneDub {
                usleep(useconds_t(gapMs * 1000))
                guard !self.isBusy else { return }
                engine.actuate(toneDub)
            }
        }
    }

    /// Strong feedback for the ring's "deduct one minute" hit: a single stronger crisp buzz (clearly
    /// stronger than the background beat).
    func impact(strength: Int) {
        guard !isBusy else { return }
        lock.lock(); let engine = self.engine; lock.unlock()
        occupyChannel(forMs: Self.busyTailMs)
        let tone = profile.resolve(timbre: .crisp, strength: 7, dullness: 0.3, global: strength)
        queue.async { engine.actuate(tone) }
    }

    /// Stop the current playback (only prevents subsequent steps; already-emitted haptics can't be undone).
    func stop() {
        lock.lock(); generation += 1; lock.unlock()
    }
}
