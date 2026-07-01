import Foundation

/// L1 · Domain layer: the ring's "truth". **Pure Swift (Foundation only, no SwiftUI / no animation / no
/// timing)** — this import boundary is intentional: the domain layer doesn't depend on the UI, so it can
/// be fully covered by `--logictest` in milliseconds.
///
/// Responsibility: quantize `(remaining seconds, total seconds, running)` into hidden "whole-minute grids",
/// make a pure-function decision over **two consecutive frames**, and emit a semantic event (whether to
/// play the "bullet → hit → retract" animation). **It knows nothing of bullets/explosions/ballistics.**
///
/// Quantization contract: N minutes = N hidden grids (`ceil`). A natural countdown deducts exactly one
/// grid per minute crossed; the first grid (full ring) must also be deducted (historically onChange
/// re-read stale self, swallowing the first grid and lagging by a minute — fixed by "driving with the
/// delivered new value", and locked down by this layer's pure functions + LogicTests to prevent regression).
struct RingModel: Equatable {

    /// Derived-layer input snapshot: a change in any of the three may produce an event (used as the
    /// Equatable key for SwiftUI `onChange(of:)`; the closure drives `update(_:)` only with the **delivered
    /// new value**, never re-reading the view's self).
    struct Input: Equatable {
        var remaining: Int   // Remaining seconds
        var total: Int       // Total seconds
        var animated: Bool   // Running state (false when paused/waiting)
    }

    /// Semantic event describing how the minute ring should change.
    enum Event: Equatable {
        case none                        // Within the same minute: no change
        case deduct(from: Int, to: Int)  // Natural countdown decreased by exactly 1 grid → play "fire → fly → hit → retract"
        case align(to: Int)              // Jump / increase / interval change / paused across a minute → align directly, no animation
    }

    /// Currently lit grids (= logical remaining minutes, the **truth**; visual lag is held separately by L2 RingAnimator).
    private(set) var lit: Int
    /// Total grids (= total minutes).
    private(set) var grids: Int

    // MARK: - Pure functions (stateless, easy to unit test)

    /// Total grids = ⌈total seconds / 60⌉, at least 1.
    static func gridCount(_ totalSeconds: Int) -> Int {
        max(1, Int(ceil(Double(max(totalSeconds, 1)) / 60.0)))
    }

    /// Lit grids = ⌈remaining seconds / 60⌉, non-negative.
    static func litGrids(_ remainingSeconds: Int) -> Int {
        max(0, Int(ceil(Double(max(remainingSeconds, 0)) / 60.0)))
    }

    /// Two-consecutive-frame decision: the only "referee". `prevLit` is the previous frame's grids, `newLit` is the current.
    static func event(prevLit: Int, newLit: Int, animated: Bool) -> Event {
        if newLit == prevLit { return .none }
        if animated && newLit == prevLit - 1 { return .deduct(from: prevLit, to: newLit) }
        return .align(to: newLit)
    }

    // MARK: - Reducer

    init(_ input: Input) {
        grids = Self.gridCount(input.total)
        lit = min(Self.litGrids(input.remaining), grids)
    }

    /// Feed a new snapshot → advance the truth and return this event. **Idempotent**: repeated calls within
    /// the same minute only yield `.none`.
    mutating func update(_ input: Input) -> Event {
        grids = Self.gridCount(input.total)
        let newLit = min(Self.litGrids(input.remaining), grids)
        let ev = Self.event(prevLit: lit, newLit: newLit, animated: input.animated)
        lit = newLit
        return ev
    }
}
