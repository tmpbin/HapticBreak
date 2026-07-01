import SwiftUI

/// Ring geometry: convert a "fractional position on the ring" into view coordinates. frac=0 is the top
/// (cutoff point), increasing clockwise — exactly matching the minute arc's trim+rotation(-90), so the
/// shimmer bullet/burst land strictly on the ring (SwiftUI's y grows downward, hence y uses -cos).
struct RingGeometry: Equatable {
    var size: CGFloat
    var lineWidth: CGFloat
    /// Stroke centerline radius: after the ring's padding(lineWidth/2) the centerline sits here; the second
    /// hand's tip uses the same radius → strictly pressed onto the ring.
    var centerRadius: CGFloat { (size - lineWidth) / 2 }
    func point(_ frac: Double) -> CGPoint {
        let t = frac * 2 * .pi
        // Pin sin/cos to the Double-returning overload explicitly: newer toolchains also surface a
        // CoreGraphics sin/cos(CGFloat), and with CGFloat↔Double interop the bare call is ambiguous.
        let sinT: Double = sin(t)
        let cosT: Double = cos(t)
        return CGPoint(x: size / 2 + centerRadius * CGFloat(sinT),
                       y: size / 2 - centerRadius * CGFloat(cosT))
    }
}

// MARK: - L3 pure render subviews (dumb views: consume explicit params only, no logic)

/// Minute ring: base ring + one continuous arc (length = lit/grids). Hit brightening is driven by flash;
/// arc-length changes retract via spring.
private struct MinuteArc: View {
    var lit: Int
    var grids: Int
    var color: Color
    var lineWidth: CGFloat
    var flash: Bool
    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.secondary.opacity(0.12), lineWidth: lineWidth)
                .padding(lineWidth / 2)

            // We don't draw the grids — a "grid" is a hidden internal deduction unit; here we just draw one
            // continuous arc by lit grids / total grids.
            Circle()
                .trim(from: 0, to: Double(lit) / Double(max(1, grids)))
                .stroke(color.gradient, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .padding(lineWidth / 2)
                .brightness(flash ? 0.18 : 0)
                .animation(.spring(response: 0.5, dampingFraction: 0.6), value: lit)
        }
    }
}

/// Shimmer: a wide, soft highlight band slowly orbits clockwise along a ring segment (same direction as
/// the second hand), giving the ring a living sense of "energy flowing". Rendered twice from one orbit
/// phase: a bright band on the lit (colored) arc, and a faint one on the remaining gray track — so the
/// whole ring, not just the colored part, feels alive.
private struct ShimmerOverlay: View {
    var from: Double            // Trim start (fraction around the ring)
    var to: Double              // Trim end
    var angle: Double
    var lineWidth: CGFloat
    var peak: Double            // Max opacity of the highlight band's crest
    var body: some View {
        AngularGradient(
            gradient: Gradient(stops: [
                .init(color: .white.opacity(0.0),         location: 0.0),
                .init(color: .white.opacity(peak * 0.26), location: 0.18),
                .init(color: .white.opacity(peak * 0.63), location: 0.34),
                .init(color: .white.opacity(peak),        location: 0.50),
                .init(color: .white.opacity(peak * 0.63), location: 0.66),
                .init(color: .white.opacity(peak * 0.26), location: 0.82),
                .init(color: .white.opacity(0.0),         location: 1.0)
            ]),
            center: .center)
            .rotationEffect(.degrees(angle))
            .mask(
                Circle()
                    .trim(from: max(0, min(1, from)), to: max(0, min(1, to)))
                    .stroke(style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .padding(lineWidth / 2)
            )
            .blendMode(.plusLighter)
            .allowsHitTesting(false)
    }
}

/// Shimmer bullet: a fixed shape (ring-hugging comet tail + a white-core head pinned at the top) rotated
/// clockwise as a whole via rotationEffect(head·360°) for positioning (the transform naturally hugs the
/// ring, animates smoothly, and is screenshot-able). Always in the tree; shown/hidden via opacity.
private struct EnergyBullet: View {
    var head: Double
    var opacity: Double
    var color: Color
    var lineWidth: CGFloat
    var geo: RingGeometry
    var body: some View {
        ZStack {
            Circle()
                .trim(from: 1 - 0.14, to: 1)
                .stroke(
                    AngularGradient(
                        gradient: Gradient(stops: [
                            .init(color: color.opacity(0),   location: 1 - 0.14),
                            .init(color: color.opacity(0.7), location: 1)
                        ]),
                        center: .center, startAngle: .degrees(0), endAngle: .degrees(360)),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .padding(lineWidth / 2)
                .blur(radius: 1.5)
            Circle()
                .fill(.white)
                .frame(width: lineWidth * 1.7, height: lineWidth * 1.7)
                .shadow(color: color, radius: 7)
                .shadow(color: color.opacity(0.85), radius: 13)
                .offset(y: -geo.centerRadius)
        }
        .frame(width: geo.size, height: geo.size)
        .rotationEffect(.degrees(head * 360))
        .opacity(opacity)
        .allowsHitTesting(false)
    }
}

/// End-point hit burst (heightened explosion): the shot-down segment flashes and expands + starburst sparks
/// + double-layer shockwave + strong-flash white core. Always in the tree; shown/hidden via opacity.
private struct ImpactBurst: View {
    var frac: Double
    var notchFrom: Double
    var notchTo: Double
    var burstScale: CGFloat
    var burstOpacity: Double
    var sparkScale: CGFloat
    var sparkOpacity: Double
    var notchScale: CGFloat
    var notchOpacity: Double
    var color: Color
    var lineWidth: CGFloat
    var geo: RingGeometry
    var body: some View {
        ZStack {
            // The shot-down minute: the segment beyond the end ([notchFrom, notchTo] = [new end, old end])
            // flashes strongly at impact, then zooms/blurs out.
            Circle()
                .trim(from: notchFrom, to: notchTo)
                .stroke(.white, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .padding(lineWidth / 2)
                .scaleEffect(notchScale)
                .blur(radius: (notchScale - 1) * 16)
                .opacity(notchOpacity)

            // Burst pinned at the end hit point: starburst sparks + double-layer shockwave + white core.
            ZStack {
                ZStack {
                    ForEach(0..<8, id: \.self) { i in
                        Capsule()
                            .fill(color)
                            .frame(width: 2.5, height: lineWidth * 1.6)
                            .offset(y: -lineWidth * 1.7)
                            .rotationEffect(.degrees(Double(i) / 8 * 360))
                    }
                }
                .scaleEffect(sparkScale)
                .opacity(sparkOpacity)

                Circle().stroke(color, lineWidth: 3)
                    .frame(width: lineWidth * 3.4, height: lineWidth * 3.4)
                    .scaleEffect(burstScale)
                    .opacity(burstOpacity)
                Circle().stroke(.white, lineWidth: 1.6)
                    .frame(width: lineWidth * 3.4, height: lineWidth * 3.4)
                    .scaleEffect(burstScale * 0.6)
                    .opacity(burstOpacity)
                Circle().fill(.white)
                    .frame(width: lineWidth * 2.1, height: lineWidth * 2.1)
                    .blur(radius: 1)
                    .opacity(burstOpacity)
            }
            .position(geo.point(frac))
        }
        .frame(width: geo.size, height: geo.size)
        .allowsHitTesting(false)
    }
}

/// Center readout: status icon + large countdown + status text.
private struct CenterReadout: View {
    var timeText: String
    var statusText: String
    var statusSymbol: String
    var color: Color
    var body: some View {
        VStack(spacing: 3) {
            Image(systemName: statusSymbol)
                .font(.system(size: 14))
                .foregroundStyle(color)
            Text(timeText)
                .font(.system(size: 34, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
            Text(statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Assembly: CountdownRing (L0 BreakTimer → L1 RingModel → L2 RingAnimator → L3 subviews)

/// Countdown ring. The ring itself is the only colored anchor in the panel (color = status). Two rings:
/// the minute ring + the second hand (seconds ring).
///
/// ★ Core design contract: **the second hand completes one lap (= 1 minute) → fire a shimmer bullet → the
///   bullet flies along the ring to the minute ring's end → it hits a "virtual grid" → the minute ring
///   deducts one minute.** A "grid" is a metaphor, invisible to the user (N minutes = N hidden grids); the
///   minute ring only draws one **continuous arc + shimmer**.
///
/// Layering (so changes no longer ripple everywhere):
/// - **L1 `RingModel`** (pure logic): quantization + deduction decision → semantic events. Fully covered by `--logictest`.
/// - **L2 `RingAnimator`** (presentation logic): events → bullet/burst/retract timeline, holds all animation state.
/// - **L3 subviews** (pure render): `MinuteArc / ShimmerOverlay / EnergyBullet / ImpactBurst / SecondHand / CenterReadout`.
/// Data flows one way, downward; the deduction decision **no longer lives in the view's onChange self re-read**
/// (which was the root cause of the first grid being swallowed).
struct CountdownRing: View {
    var remaining: Int            // Remaining seconds: drives the second-hand angle and minute quantization
    var total: Int                // Total seconds: quantizes the minute ring into whole-minute grids
    var color: Color
    var timeText: String
    var statusText: String
    var statusSymbol: String
    var animated: Bool = true     // false when paused/waiting: the second hand dims and doesn't trigger deductions
    var size: CGFloat = 146
    var onImpact: (() -> Void)? = nil   // Hit event (deduct one grid per minute): drives the upper layer's strong buzz etc.; UI doesn't hold the engine

    private let lineWidth: CGFloat = 8

    /// L1 truth (lit/grids); L2 animation state.
    @State private var model = RingModel(.init(remaining: 0, total: 1, animated: true))
    @StateObject private var anim = RingAnimator()

    /// Second-hand angle (6°/sec, accumulating clockwise). Driven by explicit state: natural ticking sweeps
    /// smoothly; when the remaining time **jumps** (skip/postpone/interval change/reset/resume), it snaps into
    /// place without animation, resetting only once, instead of treating a huge angle delta as an animation
    /// and "spinning wildly".
    @State private var handAngle: Double = 0
    @State private var prevRemaining: Int = 0

    private var input: RingModel.Input { .init(remaining: remaining, total: total, animated: animated) }
    private var geo: RingGeometry { RingGeometry(size: size, lineWidth: lineWidth) }
    private func handTarget(_ seconds: Int) -> Double { -6.0 * Double(seconds) }

    var body: some View {
        ZStack {
            MinuteArc(lit: anim.displayedLit, grids: model.grids,
                      color: color, lineWidth: lineWidth, flash: anim.minuteFlash)

            if animated {
                let litFrac = Double(anim.displayedLit) / Double(max(1, model.grids))
                // Faint sheen sweeping the remaining gray track.
                ShimmerOverlay(from: litFrac, to: 1, angle: anim.shimmerAngle, lineWidth: lineWidth, peak: 0.08)
                // Brighter shimmer sweeping the lit (colored) arc.
                ShimmerOverlay(from: 0, to: litFrac, angle: anim.shimmerAngle, lineWidth: lineWidth, peak: 0.27)
            }

            ImpactBurst(frac: anim.burstFrac, notchFrom: anim.notchFrom, notchTo: anim.notchTo,
                        burstScale: anim.burstScale, burstOpacity: anim.burstOpacity,
                        sparkScale: anim.sparkScale, sparkOpacity: anim.sparkOpacity,
                        notchScale: anim.notchScale, notchOpacity: anim.notchOpacity,
                        color: color, lineWidth: lineWidth, geo: geo)

            EnergyBullet(head: anim.bulletHead, opacity: anim.bulletOpacity,
                         color: color, lineWidth: lineWidth, geo: geo)

            // Second hand: on reset (returning to the top cutoff point) it fires a bullet clockwise ahead;
            // the reset recoil is triggered by the logical truth model.lit.
            SecondHand(color: color,
                       tipRadius: geo.centerRadius,
                       lineWidth: lineWidth,
                       minuteTick: model.lit,
                       secondTick: remaining,
                       active: animated)
                .rotationEffect(.degrees(handAngle))
                .opacity(animated ? 1 : 0.25)

            CenterReadout(timeText: timeText, statusText: statusText,
                          statusSymbol: statusSymbol, color: color)
        }
        .frame(width: size, height: size)
        .onAppear {
            model = RingModel(input)
            prevRemaining = remaining
            handAngle = handTarget(remaining)
            anim.onImpact = onImpact
            anim.setInitial(lit: model.lit)
            anim.startShimmer(animated: animated)
        }
        // ⚠️ Drive L1 only with the closure-delivered **new value** newInput; never re-read self here (the old
        //    onChange would capture a self lagging by one tick, which once caused target to be a minute too
        //    high, the first grid swallowed, and deduction late by a minute). After L1 decides, hand the event to L2.
        .onChange(of: input) { newInput in
            let event = model.update(newInput)
            anim.apply(event, grids: model.grids)
        }
        // Second hand: only "natural ticking (running and exactly −1 second)" sweeps one step linearly; all else
        // is treated as a jump → snap without animation, resetting only once.
        .onChange(of: remaining) { newRemaining in
            let isTick = animated && (prevRemaining - newRemaining == 1)
            prevRemaining = newRemaining
            let target = handTarget(newRemaining)
            if isTick {
                withAnimation(.linear(duration: 1)) { handAngle = target }
            } else {
                var tx = Transaction(); tx.disablesAnimations = true
                withTransaction(tx) { handAngle = target }
            }
        }
        .onChange(of: animated) { isOn in
            anim.startShimmer(animated: isOn)   // on → start shimmer; off → stop shimmer (break repeatForever, no idle spinning in background)
            if !isOn { anim.snap(toLit: model.lit) }
        }
    }
}

/// Second hand: a thin needle sweeping from mid-radius onto the ring + a glowing tip pressed on the minute
/// ring + a comet tail behind it (reinforcing the clockwise direction).
/// - Each second: a light pulse at the tip (so "per-second" is perceptible).
/// - Each minute crossed (reset back to the top cutoff point): the tip recoils + a shockwave ring expands
///   outward = "the recoil of firing".
private struct SecondHand: View {
    var color: Color
    var tipRadius: CGFloat      // = minute-ring stroke centerline radius, so the tip is strictly pressed on the ring
    var lineWidth: CGFloat
    var minuteTick: Int         // changes once per whole minute → tip burst
    var secondTick: Int         // changes once per second → tip light pulse
    var active: Bool

    @State private var slam: CGFloat = 1          // deduction burst scale
    @State private var pulseScale: CGFloat = 0.4  // shockwave
    @State private var pulseOpacity: Double = 0
    @State private var tick: CGFloat = 1          // per-second micro pulse

    private var diameter: CGFloat { tipRadius * 2 }
    private let tailFrac: CGFloat = 0.14
    private var handLength: CGFloat { tipRadius * 0.7 }   // extends from the hub area (fading) onto the ring, like a clock's second hand

    var body: some View {
        ZStack {
            // Comet tail: hugs the ring, fading out behind the tip (counterclockwise side), trailing behind during clockwise sweeping.
            Circle()
                .trim(from: 1 - tailFrac, to: 1)
                .stroke(
                    AngularGradient(
                        gradient: Gradient(stops: [
                            .init(color: color.opacity(0), location: 1 - Double(tailFrac)),
                            .init(color: color.opacity(0.55), location: 1)
                        ]),
                        center: .center, startAngle: .degrees(0), endAngle: .degrees(360)),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .frame(width: diameter, height: diameter)
                .opacity(active ? 1 : 0)

            // Needle body: status-colored thin needle, brightening from the hub area (faded) to the tip (bright) — a clearly visible "second hand".
            Capsule()
                .fill(LinearGradient(colors: [color.opacity(0), color.opacity(0.95)],
                                     startPoint: .bottom, endPoint: .top))
                .frame(width: 3, height: handLength)
                .offset(y: -(tipRadius - handLength / 2))

            // Tip: status-colored glow + white core, a high-contrast moving highlight pressed on the ring.
            tip.offset(y: -tipRadius)
        }
        .frame(width: diameter, height: diameter)
        .onChange(of: minuteTick) { _ in guard active else { return }; slamTip() }
        .onChange(of: secondTick) { _ in guard active else { return }; tickPulse() }
    }

    private var tip: some View {
        ZStack {
            // Shockwave: expands outward and fades at the instant of deduction.
            Circle()
                .stroke(color, lineWidth: 2)
                .frame(width: lineWidth * 2.8, height: lineWidth * 2.8)
                .scaleEffect(pulseScale)
                .opacity(pulseOpacity)
            // Status-colored glow.
            Circle()
                .fill(color)
                .frame(width: lineWidth * 2.0, height: lineWidth * 2.0)
                .blur(radius: 2.5)
                .opacity(0.9)
                .scaleEffect(slam * tick)
            // White core.
            Circle()
                .fill(.white)
                .frame(width: lineWidth, height: lineWidth)
                .scaleEffect(slam * tick)
        }
    }

    /// Burst on reaching the cutoff point: the tip bounces + a shockwave ring expands.
    private func slamTip() {
        slam = 2.2
        pulseScale = 0.4
        pulseOpacity = 0.9
        withAnimation(.spring(response: 0.4, dampingFraction: 0.45)) { slam = 1 }
        withAnimation(.easeOut(duration: 0.85)) {
            pulseScale = 3.2
            pulseOpacity = 0
        }
    }

    /// A light pulse once per second, so "per-second" stays clearly perceptible under a minute-level countdown.
    private func tickPulse() {
        tick = 1.35
        withAnimation(.easeOut(duration: 0.5)) { tick = 1 }
    }
}
