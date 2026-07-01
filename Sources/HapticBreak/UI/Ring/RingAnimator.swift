import SwiftUI

/// L2 · Presentation-logic layer: translates L1's semantic events into a human-facing animation timeline,
/// and centrally holds all animation state. Here you can freely rearrange the animation, tweak durations,
/// or reskin, **without touching L1's deduction correctness** — which is exactly the point of layering.
///
/// Data vs visual separation: `displayedLit` is the **visually lagged** value (retracts only at the moment
/// of impact), decoupled from L1's "logical truth lit", enabling "fly first, deduct later" — a data change
/// doesn't retract immediately; the grid decrements only when the bullet reaches the end and hits.
final class RingAnimator: ObservableObject {
    // Minute ring
    @Published var displayedLit: Int = 0      // Visually lit grids (continuous arc length = displayedLit/grids)
    @Published var minuteFlash: Bool = false  // Minute-ring brighten at the instant of impact

    // Shimmer bullet (head's progress fraction along the ring: 0 = the cutoff point at the top → oldFrac = arc end)
    @Published var bulletHead: Double = 0
    @Published var bulletOpacity: Double = 0

    // End-point hit burst (pinned at the hit point burstFrac) + the shot-down segment [notchFrom, notchTo]
    @Published var burstFrac: Double = 0
    @Published var burstScale: CGFloat = 0.2
    @Published var burstOpacity: Double = 0
    @Published var sparkScale: CGFloat = 0.2
    @Published var sparkOpacity: Double = 0
    @Published var notchFrom: Double = 0
    @Published var notchTo: Double = 0
    @Published var notchScale: CGFloat = 1
    @Published var notchOpacity: Double = 0

    // Shimmer phase
    @Published var shimmerAngle: Double = 0

    /// Flight duration of the shimmer bullet along the ring.
    private let flightDur: Double = 0.55

    /// Impact-event callback: fired at the moment the bullet hits the end (the app layer drives side effects
    /// like the strong buzz — L2 doesn't hold the haptic engine directly).
    var onImpact: (() -> Void)?

    // MARK: - Entry points

    /// On appear, align the visual to the logical truth.
    func setInitial(lit: Int) { displayedLit = lit }

    /// Consume an L1 event.
    func apply(_ event: RingModel.Event, grids: Int) {
        switch event {
        case .none:
            break
        case .align(let to):
            displayedLit = to                       // Jump / interval change: align directly (minute arc follows via spring)
        case .deduct(let from, let to):
            fire(fromLit: from, toLit: to, grids: grids)
        }
    }

    /// Pause: retract the in-flight bullet and align the visual to the truth (no deduction animation).
    func snap(toLit lit: Int) {
        bulletOpacity = 0
        displayedLit = lit
    }

    /// Start/restart the shimmer: the highlight phase orbits clockwise at constant speed, looping forever
    /// (running state only). Slow and gentle, in the same direction as the second hand.
    /// When `animated=false` (paused / panel collapsed), **explicitly stop** repeatForever — otherwise, even
    /// after the shimmer layer is removed from the view tree, this infinite animation keeps spinning in the
    /// animation engine, needlessly consuming background resources.
    func startShimmer(animated: Bool) {
        guard animated else { stopShimmer(); return }
        shimmerAngle = 0
        withAnimation(.linear(duration: 5.2).repeatForever(autoreverses: false)) { shimmerAngle = 360 }
    }

    /// Cancel the in-progress infinite shimmer animation (reset the phase in a no-animation transaction, breaking repeatForever).
    func stopShimmer() {
        var tx = Transaction(); tx.disablesAnimations = true
        withTransaction(tx) { shimmerAngle = 0 }
    }

    // MARK: - Deduction animation (fire → fly along the ring → hit and deduct at the end)

    /// The bullet head starts at the top (where the second hand resets) and flies clockwise along the ring to
    /// the **midpoint of the last grid** of the minute ring (hitFrac); on arrival it bursts and decrements the
    /// visual grid count by one (the minute ring retracts one grid via spring) — the visible causality of
    /// "one second-hand lap → bullet → deduct one grid".
    /// **Gravity motion**: the ring is vertical and the bullet departs from the top clockwise — top→bottom(0.5)
    /// **accelerates** under gravity, bottom→hit **decelerates** against gravity; if the hit point is in the top
    /// half (<0.5) there is only the falling/accelerating segment. Durations are split by arc distance, with the
    /// bottom as the fastest handover point.
    private func fire(fromLit oldLit: Int, toLit newLit: Int, grids: Int) {
        let n = Double(max(1, grids))
        let oldFrac = Double(oldLit) / n
        let newFrac = Double(newLit) / n
        let hitFrac = (oldFrac + newFrac) / 2   // Hit/burst point = midpoint of the deducted grid: the full-ring first deduction no longer stalls at the top
        bulletHead = 0
        bulletOpacity = 1
        let bottom = min(0.5, hitFrac)          // If the path crosses the bottom (0.5), split into two segments
        let ascend = max(0, hitFrac - bottom)   // Bottom→hit (anti-gravity decelerating segment)
        let span = max(0.0001, hitFrac)
        let tDown = flightDur * (bottom / span)
        let tUp   = flightDur * (ascend / span)
        // (1) Top→bottom: gravity acceleration (strong ease-in, faster as it nears the bottom).
        withAnimation(.timingCurve(0.3, 0, 0.7, 0, duration: tDown)) { bulletHead = bottom }
        // (2) Bottom→hit: anti-gravity deceleration (strong ease-out, slower as it rises) — only when the path crosses the bottom.
        if ascend > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + tDown) { [weak self] in
                guard let self else { return }
                withAnimation(.timingCurve(0.3, 1, 0.7, 1, duration: tUp)) { self.bulletHead = hitFrac }
            }
        }

        // (3) Hit (flight ends): burst at the midpoint + strong flash release of the deducted segment [newFrac, oldFrac] + visual grid −1 + trigger strong buzz.
        DispatchQueue.main.asyncAfter(deadline: .now() + flightDur) { [weak self] in
            guard let self else { return }
            withAnimation(.easeOut(duration: 0.18)) { self.bulletOpacity = 0 }
            self.burstFrac = hitFrac
            self.notchFrom = newFrac
            self.notchTo = oldFrac
            self.explode()
            self.displayedLit = newLit   // Minute arc's .animation(value:) triggers a spring retraction by one grid
            self.onImpact?()             // On hit, trigger the app layer's strong buzz (UI doesn't hold the engine)
        }
    }

    /// End-point burst: minute-ring strong flash + starburst sparks + double-layer shockwave + strong-flash zoom-out fade of the deducted segment.
    private func explode() {
        minuteFlash = true
        withAnimation(.easeOut(duration: 0.55)) { minuteFlash = false }

        sparkScale = 0.2;  sparkOpacity = 1
        burstScale = 0.2;  burstOpacity = 1
        notchScale = 1;    notchOpacity = 1
        withAnimation(.easeOut(duration: 0.55)) { sparkScale = 2.8; sparkOpacity = 0 }
        withAnimation(.easeOut(duration: 0.7))  { burstScale = 4.0; burstOpacity = 0 }
        withAnimation(.easeOut(duration: 0.85)) { notchScale = 1.7; notchOpacity = 0 }
    }
}
