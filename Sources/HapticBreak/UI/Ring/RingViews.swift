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
/// The icon and status rows have fixed heights: hovering swaps in the tap-hint symbol/label, and
/// different SF Symbols / strings have different intrinsic heights — without the fixed frames the
/// whole centered stack (including the time) would shift vertically on every hover.
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
                .frame(height: 17)
            Text(timeText)
                .font(.system(size: 34, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
            Text(statusText)
                .font(.caption)
                .lineLimit(1)
                .foregroundStyle(.secondary)
                .frame(height: 15)
        }
    }
}

/// Rest-phase breathing halo: a soft glow behind the ring that swells and settles on an 8-second
/// breath cycle. Driven by the existing 1 Hz elapsed value — the target flips every 4 s and the
/// implicit ease interpolates, so there is **no repeatForever** (the panel-CPU hard rule).
private struct BreathingHalo: View {
    var color: Color
    var elapsed: Int
    var body: some View {
        let inhale = (elapsed / 4) % 2 == 0
        Circle()
            .fill(color.opacity(0.16))
            .blur(radius: 18)
            .scaleEffect(inhale ? 1.06 : 0.80)
            .animation(.easeInOut(duration: 4), value: inhale)
            .allowsHitTesting(false)
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
/// - **L3 subviews** (pure render): `MinuteArc / EnergyBullet / ImpactBurst / CenterReadout` in SwiftUI, plus the
///   **continuous** ornaments `ShimmerOrnament / SecondHandOrnament` on Core Animation layers (RingOrnaments.swift) —
///   render-server interpolation keeps the open panel at the no-animation CPU baseline (measured
///   ~10% → ~1%; the full rationale lives in RingOrnaments.swift's header comment).
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
    var breathing: Bool = false   // Rest phase: soft breathing halo behind the ring
    var onImpact: (() -> Void)? = nil   // Hit event (deduct one grid per minute): drives the upper layer's strong buzz etc.; UI doesn't hold the engine
    /// Click on the ring = the primary action (pause/resume, or acknowledge while reminding).
    /// The hover hint (symbol + label) temporarily replaces the status readout for discoverability.
    var onTap: (() -> Void)? = nil
    var tapHint: (symbol: String, label: String)? = nil

    private let lineWidth: CGFloat = 8

    /// L1 truth (lit/grids); L2 animation state.
    @State private var model = RingModel(.init(remaining: 0, total: 1, animated: true))
    @StateObject private var anim = RingAnimator()
    @State private var hovering = false

    private var input: RingModel.Input { .init(remaining: remaining, total: total, animated: animated) }
    private var geo: RingGeometry { RingGeometry(size: size, lineWidth: lineWidth) }

    var body: some View {
        ZStack {
            if breathing {
                BreathingHalo(color: color, elapsed: max(0, total - remaining))
            }

            MinuteArc(lit: anim.displayedLit, grids: model.grids,
                      color: color, lineWidth: lineWidth, flash: anim.minuteFlash)

            // Continuous ornaments live on Core Animation layers. The shimmer leaves the tree when the ring
            // is not running, so nothing spins in the background.
            if animated {
                ShimmerOrnament(lineWidth: lineWidth,
                                litFrac: Double(anim.displayedLit) / Double(max(1, model.grids)))
            }

            ImpactBurst(frac: anim.burstFrac, notchFrom: anim.notchFrom, notchTo: anim.notchTo,
                        burstScale: anim.burstScale, burstOpacity: anim.burstOpacity,
                        sparkScale: anim.sparkScale, sparkOpacity: anim.sparkOpacity,
                        notchScale: anim.notchScale, notchOpacity: anim.notchOpacity,
                        color: color, lineWidth: lineWidth, geo: geo)

            EnergyBullet(head: anim.bulletHead, opacity: anim.bulletOpacity,
                         color: color, lineWidth: lineWidth, geo: geo)

            // Second hand: sweeps 6°/s clockwise; natural −1 s ticks animate one step, jumps
            // (skip/postpone/interval change/reset/resume) snap without animation, and the per-minute
            // recoil is triggered by the logical truth model.lit — all diffed inside the ornament.
            SecondHandOrnament(color: color,
                               lineWidth: lineWidth,
                               remaining: remaining,
                               minuteTick: model.lit,
                               active: animated)

            // While hovering (and clickable) the readout previews the click action instead of the status.
            CenterReadout(timeText: timeText,
                          statusText: (hovering && tapHint != nil) ? tapHint!.label : statusText,
                          statusSymbol: (hovering && tapHint != nil) ? tapHint!.symbol : statusSymbol,
                          color: color)
        }
        .frame(width: size, height: size)
        .contentShape(Circle())
        .onTapGesture { onTap?() }
        .onHover { inside in
            if hovering != (inside && onTap != nil) { hovering = inside && onTap != nil }
        }
        .onAppear {
            model = RingModel(input)
            anim.onImpact = onImpact
            anim.setInitial(lit: model.lit)
        }
        // ⚠️ Drive L1 only with the closure-delivered **new value** newInput; never re-read self here (the old
        //    onChange would capture a self lagging by one tick, which once caused target to be a minute too
        //    high, the first grid swallowed, and deduction late by a minute). After L1 decides, hand the event to L2.
        .onChange(of: input) { newInput in
            let event = model.update(newInput)
            anim.apply(event, grids: model.grids)
        }
        .onChange(of: animated) { isOn in
            // Shimmer starts/stops purely by ShimmerOrnament entering/leaving the tree (see `if animated`
            // above), so its repeating animation is guaranteed to stop when the panel collapses.
            if !isOn { anim.snap(toLit: model.lit) }
        }
    }
}

