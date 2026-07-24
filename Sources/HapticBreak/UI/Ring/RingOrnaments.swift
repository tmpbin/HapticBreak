import SwiftUI
import AppKit
import CoreImage

// The ring's two *continuous* ornaments — the orbiting shimmer and the sweeping second hand — are
// implemented on Core Animation layers instead of SwiftUI animations. Rationale (measured
// on-device): SwiftUI's `repeatForever` / chained `withAnimation` drive the
// whole hosting view's ViewGraph **in-process on every frame** (~10% CPU at 120Hz with the panel open),
// while a `CABasicAnimation` is interpolated out-of-process by the render server — the app commits
// O(1) transactions per second and measures at the no-animation baseline (~1%).
//
// Everything event-driven (minute-arc spring, bullet, burst, center readout) stays in SwiftUI: those
// animations run for ~1s per minute, which amortizes to noise.

/// AppKit only manages `contentsScale` for a view's backing layer; manually added sublayers (and their
/// masks) default to 1× and would rasterize blurry on Retina. Propagate the window's scale to a subtree.
private func propagateContentsScale(_ scale: CGFloat, to layer: CALayer) {
    layer.contentsScale = scale
    if let mask = layer.mask { propagateContentsScale(scale, to: mask) }
    for sub in layer.sublayers ?? [] { propagateContentsScale(scale, to: sub) }
}

// MARK: - Shimmer

/// A soft highlight band slowly orbiting the ring (5.2 s per lap, clockwise — matching the second
/// hand), layered so there are **no seams anywhere**: a faint *base* band covers the entire ring
/// (a closed circle — no endpoints, no caps), and an *extra* band masked to exactly the colored
/// arc (round caps mirroring it) adds the lit/track brightness contrast on top. Any pixel of the
/// arc — cap discs included — receives base + extra; any track pixel receives base only, so the
/// only brightness step coincides with the arc's own color edge and nothing "appears" at the ends.
/// Each band is a conic gradient spinning *inside* a fixed mask; the spins are repeating
/// render-server animations committed once, and only the arc mask changes (once per minute,
/// spring-following the arc's retraction).
struct ShimmerOrnament: NSViewRepresentable {
    var lineWidth: CGFloat
    var litFrac: Double

    func makeNSView(context: Context) -> ShimmerOrnamentView {
        let v = ShimmerOrnamentView(lineWidth: lineWidth)
        v.setLitFrac(litFrac)
        return v
    }
    func updateNSView(_ view: ShimmerOrnamentView, context: Context) {
        view.setLitFrac(litFrac)
    }
}

final class ShimmerOrnamentView: NSView {
    private let lineWidth: CGFloat
    /// Extra band clipped to the colored arc; base band covering the full ring (closed circle).
    private let litGradient = CAGradientLayer()
    private let litMask = CAShapeLayer()
    private let trackGradient = CAGradientLayer()
    private let trackMask = CAShapeLayer()
    private var builtSize: CGSize = .zero
    private var litFrac: Double = 0

    init(lineWidth: CGFloat) {
        self.lineWidth = lineWidth
        super.init(frame: .zero)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError("unsupported") }

    // Top-left origin so geometry and rotation direction match SwiftUI exactly.
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        rebuildIfNeeded()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            syncScale()
            startSpin()
        }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        syncScale()
    }

    private func syncScale() {
        guard let layer, let scale = window?.backingScaleFactor, scale > 0 else { return }
        propagateContentsScale(scale, to: layer)
    }

    func setLitFrac(_ frac: Double) {
        let clamped = max(0, min(1, frac))
        guard clamped != litFrac else { return }
        litFrac = clamped
        guard builtSize != .zero else { return }   // Pre-layout: rebuildIfNeeded will snap it in place
        applyArcMask(animated: true)
    }

    /// Same travelling-band stops as the SwiftUI original; only the crest opacity differs per band.
    private func configureBand(_ gradient: CAGradientLayer, peak: CGFloat) {
        // The gradient square spins inside a fixed mask, so it must cover the circle at every angle.
        let side = bounds.width * 1.5
        gradient.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        gradient.position = CGPoint(x: bounds.midX, y: bounds.midY)
        gradient.type = .conic
        gradient.startPoint = CGPoint(x: 0.5, y: 0.5)
        gradient.endPoint = CGPoint(x: 1, y: 0.5)   // location 0 at 3 o'clock, like SwiftUI's AngularGradient
        gradient.colors = [0, 0.26, 0.63, 1.0, 0.63, 0.26, 0].map {
            NSColor.white.withAlphaComponent($0 * peak).cgColor
        }
        gradient.locations = [0, 0.18, 0.34, 0.5, 0.66, 0.82, 1]
    }

    /// A ring-stroke mask; the whole mask layer is pre-rotated −90° so arcs start at 12 o'clock,
    /// exactly like the old `Circle().trim(...).rotationEffect(-90°)`. Round caps so the arc mask
    /// mirrors the colored arc's geometry pixel for pixel (irrelevant for the closed base circle).
    private func configureMask(_ mask: CAShapeLayer) {
        mask.bounds = bounds
        mask.position = CGPoint(x: bounds.midX, y: bounds.midY)
        mask.path = CGPath(ellipseIn: bounds.insetBy(dx: lineWidth / 2, dy: lineWidth / 2),
                           transform: nil)
        mask.fillColor = nil
        mask.strokeColor = NSColor.white.cgColor
        mask.lineWidth = lineWidth
        mask.lineCap = .round
        mask.setValue(-CGFloat.pi / 2, forKeyPath: "transform.rotation.z")
    }

    /// Keep the extra band congruent with the colored arc (round caps included) — cap discs get
    /// exactly the same light as the arc body, so nothing special ever happens at the ends. The
    /// minute deduction retracts the arc with a 0.5 s spring (`MinuteArc`); the mask follows with
    /// the same spring so the sheen never outruns the arc.
    private func applyArcMask(animated: Bool) {
        setStroke(litMask, keyPath: "strokeEnd", to: litFrac, animated: animated)
    }

    /// Matches MinuteArc's `.spring(response: 0.5, dampingFraction: 0.6)`.
    private func setStroke(_ mask: CAShapeLayer, keyPath: String, to value: Double, animated: Bool) {
        let from = (mask.presentation() ?? mask).value(forKeyPath: keyPath)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mask.setValue(value, forKeyPath: keyPath)
        CATransaction.commit()
        guard animated else { mask.removeAnimation(forKey: keyPath); return }
        let spring = CASpringAnimation(keyPath: keyPath)
        spring.fromValue = from
        spring.toValue = value
        spring.mass = 1
        spring.stiffness = pow(2 * .pi / 0.5, 2)
        spring.damping = 2 * 0.6 * sqrt(spring.stiffness)
        spring.duration = spring.settlingDuration
        mask.add(spring, forKey: keyPath)
    }

    private func rebuildIfNeeded() {
        guard bounds.size != builtSize, bounds.width > 0, let root = layer else { return }
        builtSize = bounds.size

        // Hosts pin the masks in place while the gradient squares spin inside them.
        // The bands stack additively on the arc: base 0.10 everywhere + extra 0.22 on the arc
        // = the committed 0.32 total, with the track keeping its faint 0.10.
        configureBand(litGradient, peak: 0.22)
        configureBand(trackGradient, peak: 0.10)
        configureMask(litMask)
        configureMask(trackMask)
        trackMask.strokeStart = 0   // The base band is a closed circle: no endpoints exist at all
        trackMask.strokeEnd = 1

        let litHost = CALayer()
        let trackHost = CALayer()
        for (host, gradient, mask) in [(litHost, litGradient, litMask),
                                       (trackHost, trackGradient, trackMask)] {
            host.frame = bounds
            host.mask = mask
            host.addSublayer(gradient)
            // The SwiftUI original blended the sheen with `.plusLighter`; linear dodge is the CA twin.
            host.compositingFilter = "linearDodgeBlendMode"
            root.addSublayer(host)
        }
        applyArcMask(animated: false)
        syncScale()
        startSpin()
    }

    /// One commit per band; the render server interpolates every frame thereafter (shared phase:
    /// both animations are added in the same transaction with the same clock).
    private func startSpin() {
        guard litGradient.superlayer != nil else { return }
        for gradient in [litGradient, trackGradient] {
            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.fromValue = 0
            spin.toValue = 2 * CGFloat.pi   // clockwise in flipped geometry, same as rotationEffect 0→360°
            spin.duration = 5.2
            spin.repeatCount = .infinity
            gradient.add(spin, forKey: "spin")
        }
    }
}

// MARK: - Second hand

/// The sweeping second hand: comet tail hugging the ring + needle + glowing tip pressed on the minute
/// ring. Per-second sweeps, tip pulses, and the per-minute recoil (spring slam + expanding shockwave)
/// are all short explicit Core Animation animations — the app's per-second work is a couple of tiny
/// transactions; every in-between frame is interpolated out of process.
struct SecondHandOrnament: NSViewRepresentable {
    var color: Color
    var lineWidth: CGFloat
    var remaining: Int     // countdown seconds → hand angle (natural −1 ticks sweep, jumps snap)
    var minuteTick: Int    // changes once per whole minute → recoil burst
    var active: Bool       // paused/waiting: dimmed, tail hidden, no pulses

    func makeNSView(context: Context) -> SecondHandOrnamentView {
        let v = SecondHandOrnamentView(lineWidth: lineWidth)
        v.configure(color: color, remaining: remaining, minuteTick: minuteTick, active: active)
        return v
    }
    func updateNSView(_ view: SecondHandOrnamentView, context: Context) {
        view.configure(color: color, remaining: remaining, minuteTick: minuteTick, active: active)
    }
}

final class SecondHandOrnamentView: NSView {
    private let lineWidth: CGFloat

    /// Rotates as a whole about the ring center (the equivalent of `rotationEffect(handAngle)`).
    private let handContainer = CALayer()
    private let tailAssembly = CALayer()
    private let tailGradient = CAGradientLayer()
    private let tailMask = CAShapeLayer()
    private let needle = CAGradientLayer()
    /// Glow + white core; scaled together by the slam/tick pulses (`scaleEffect(slam * tick)`).
    private let tipPulseGroup = CALayer()
    private let tipGlow = CALayer()
    private let tipCore = CALayer()
    private let shockwave = CAShapeLayer()

    private var builtSize: CGSize = .zero
    /// SwiftUI Color kept for cheap Equatable change detection; resolved to NSColor for the layers.
    private var swiftUIColor: Color?
    private var color: NSColor = .controlAccentColor
    private var remaining: Int = .min
    private var minuteTick: Int = .min
    private var active = true

    private let tailFrac: CGFloat = 0.14
    /// Gaussian sigma of the tip glow (the previous SwiftUI `.blur(radius: 2.5)`).
    private static let glowBlur: CGFloat = 2.5
    /// Blur in gamma (sRGB) space — CI's default linear working space brightens soft edges, which
    /// would make the glow visibly hotter than the SwiftUI original.
    private static let ciContext = CIContext(options: [
        .useSoftwareRenderer: false,
        .workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB) as Any
    ])

    init(lineWidth: CGFloat) {
        self.lineWidth = lineWidth
        super.init(frame: .zero)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError("unsupported") }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        rebuildIfNeeded()
    }

    /// Dynamic (light/dark-aware) colors were resolved to CGColor at assignment time — re-resolve.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    // MARK: State sync (called from updateNSView on every SwiftUI commit; diffed here)

    func configure(color: Color, remaining: Int, minuteTick: Int, active: Bool) {
        if swiftUIColor != color {
            swiftUIColor = color
            self.color = NSColor(color)
            applyColors()
        }
        if self.active != active {
            self.active = active
            applyActive()
        }
        if self.minuteTick != minuteTick {
            let isInitial = self.minuteTick == .min
            self.minuteTick = minuteTick
            if !isInitial && active { slam() }
        }
        if self.remaining != remaining {
            let prev = self.remaining
            self.remaining = remaining
            if prev == .min {
                snap(to: remaining)
            } else if active && prev - remaining == 1 {
                sweep(from: prev, to: remaining)
                tickPulse()
            } else {
                snap(to: remaining)
                if active { tickPulse() }
            }
        }
    }

    // MARK: Layer tree

    private func rebuildIfNeeded() {
        guard bounds.size != builtSize, bounds.width > 0, let root = layer else { return }
        builtSize = bounds.size

        let tipRadius = (bounds.width - lineWidth) / 2
        let center = CGPoint(x: bounds.midX, y: bounds.midY)

        // ⚠️ Transformed layers must be laid out via bounds+position, never `.frame`: frame is derived
        // from the transform, and setting it while a rotation is applied computes garbage bounds (exact
        // multiples of 90° happen to survive, which is why a ±90° visual QA can miss it).
        handContainer.bounds = bounds
        handContainer.position = center
        if handContainer.superlayer == nil { root.addSublayer(handContainer) }

        // Comet tail: conic gradient fading in behind the tip, clipped to the last `tailFrac` of the
        // ring stroke; the assembly is pre-rotated −90° so the arc ends at 12 o'clock (where the tip
        // sits), exactly like the old `Circle().trim(0.86, 1).rotationEffect(-90°)`.
        tailAssembly.bounds = bounds
        tailAssembly.position = center
        tailGradient.frame = bounds
        tailGradient.type = .conic
        tailGradient.startPoint = CGPoint(x: 0.5, y: 0.5)
        tailGradient.endPoint = CGPoint(x: 1, y: 0.5)
        tailGradient.locations = [0, NSNumber(value: 1 - Double(tailFrac)), 1]
        tailMask.frame = bounds
        tailMask.path = CGPath(ellipseIn: bounds.insetBy(dx: lineWidth / 2, dy: lineWidth / 2),
                               transform: nil)
        tailMask.fillColor = nil
        tailMask.strokeColor = NSColor.white.cgColor
        tailMask.lineWidth = lineWidth
        tailMask.lineCap = .round
        tailMask.strokeStart = 1 - tailFrac
        tailMask.strokeEnd = 1
        tailGradient.mask = tailMask
        tailAssembly.setValue(-CGFloat.pi / 2, forKeyPath: "transform.rotation.z")
        if tailGradient.superlayer == nil { tailAssembly.addSublayer(tailGradient) }
        if tailAssembly.superlayer == nil { handContainer.addSublayer(tailAssembly) }

        // Needle: thin capsule brightening from the hub area (faded) to the tip (bright).
        let handLength = tipRadius * 0.7
        needle.frame = CGRect(x: center.x - 1.5, y: center.y - tipRadius, width: 3, height: handLength)
        needle.startPoint = CGPoint(x: 0.5, y: 1)   // bottom (hub side) = transparent
        needle.endPoint = CGPoint(x: 0.5, y: 0)     // top (tip side) = bright
        needle.cornerRadius = 1.5
        if needle.superlayer == nil { handContainer.addSublayer(needle) }

        // Tip pinned on the ring at 12 o'clock: glow (an exact offscreen-blurred disc, drawn once —
        // the previous `Circle().blur(2.5)`) + white core, grouped so pulses scale both together.
        let glowDiameter = lineWidth * 2 + Self.glowBlur * 6   // room for the gaussian tail
        tipPulseGroup.bounds = CGRect(x: 0, y: 0, width: glowDiameter, height: glowDiameter)
        tipPulseGroup.position = CGPoint(x: center.x, y: center.y - tipRadius)
        tipGlow.frame = tipPulseGroup.bounds
        tipGlow.opacity = 0.9
        tipGlow.contentsGravity = .resize
        if tipGlow.superlayer == nil { tipPulseGroup.addSublayer(tipGlow) }
        tipCore.frame = CGRect(x: (glowDiameter - lineWidth) / 2, y: (glowDiameter - lineWidth) / 2,
                               width: lineWidth, height: lineWidth)
        tipCore.backgroundColor = NSColor.white.cgColor
        tipCore.cornerRadius = lineWidth / 2
        if tipCore.superlayer == nil { tipPulseGroup.addSublayer(tipCore) }
        if tipPulseGroup.superlayer == nil { handContainer.addSublayer(tipPulseGroup) }

        // Shockwave ring: expands and fades on the per-minute recoil; invisible otherwise.
        let waveDiameter = lineWidth * 2.8
        shockwave.bounds = CGRect(x: 0, y: 0, width: waveDiameter, height: waveDiameter)
        shockwave.position = CGPoint(x: center.x, y: center.y - tipRadius)
        shockwave.path = CGPath(ellipseIn: CGRect(x: 1, y: 1, width: waveDiameter - 2,
                                                  height: waveDiameter - 2), transform: nil)
        shockwave.fillColor = nil
        shockwave.lineWidth = 2
        shockwave.opacity = 0
        if shockwave.superlayer == nil { handContainer.addSublayer(shockwave) }

        applyColors()
        applyActive()
        if remaining != .min { snap(to: remaining) }
    }

    private func applyColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            tailGradient.colors = [color.withAlphaComponent(0).cgColor,
                                   color.withAlphaComponent(0).cgColor,
                                   color.withAlphaComponent(0.55).cgColor]
            needle.colors = [color.withAlphaComponent(0).cgColor,
                             color.withAlphaComponent(0.95).cgColor]
            tipGlow.contents = glowImage()
            shockwave.strokeColor = color.cgColor
        }
    }

    /// Render the glow once: a `lineWidth*2` disc of the accent color, gaussian-blurred — pixel-wise
    /// the same falloff as the old per-frame `Circle().fill(color).blur(radius: 2.5)`.
    private func glowImage() -> CGImage? {
        let scale: CGFloat = 2
        let disc = lineWidth * 2
        let pad = Self.glowBlur * 3
        let px = Int(ceil((disc + pad * 2) * scale))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        ctx.setFillColor(color.cgColor)
        ctx.fillEllipse(in: CGRect(x: pad, y: pad, width: disc, height: disc))
        guard let flat = ctx.makeImage() else { return nil }
        // SwiftUI's blur radius maps to a gaussian σ of about half the radius (CSS convention).
        let blurred = CIImage(cgImage: flat)
            .applyingGaussianBlur(sigma: Self.glowBlur * scale / 2)
            .cropped(to: CGRect(x: 0, y: 0, width: px, height: px))
        return Self.ciContext.createCGImage(blurred, from: blurred.extent)
    }

    /// Paused/waiting: the hand dims and the tail disappears (same as the old SwiftUI opacities).
    private func applyActive() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        handContainer.opacity = active ? 1 : 0.25
        tailAssembly.opacity = active ? 1 : 0
        CATransaction.commit()
    }

    // MARK: Motion

    /// 6°/s accumulating clockwise; in flipped geometry the sign convention matches `rotationEffect`.
    private func angle(for remaining: Int) -> CGFloat {
        CGFloat(-6.0 * Double(remaining)) * .pi / 180
    }

    /// Jump into place without animation (initial placement, skip/postpone/reset/resume).
    private func snap(to remaining: Int) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        handContainer.removeAnimation(forKey: "sweep")
        handContainer.setValue(angle(for: remaining), forKeyPath: "transform.rotation.z")
        CATransaction.commit()
    }

    /// Natural 1 s countdown tick: sweep one step linearly (the render server interpolates).
    private func sweep(from prev: Int, to remaining: Int) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        handContainer.setValue(angle(for: remaining), forKeyPath: "transform.rotation.z")
        CATransaction.commit()
        let anim = CABasicAnimation(keyPath: "transform.rotation.z")
        anim.fromValue = angle(for: prev)
        anim.toValue = angle(for: remaining)
        anim.duration = 1.0
        anim.timingFunction = CAMediaTimingFunction(name: .linear)
        handContainer.add(anim, forKey: "sweep")
    }

    /// A light pulse once per second, so "per-second" stays clearly perceptible.
    private func tickPulse() {
        let pulse = CABasicAnimation(keyPath: "transform.scale")
        pulse.fromValue = 1.35
        pulse.toValue = 1.0
        pulse.duration = 0.5
        pulse.timingFunction = CAMediaTimingFunction(name: .easeOut)
        tipPulseGroup.add(pulse, forKey: "pulse")
    }

    /// Per-minute recoil: the tip bounces (spring, ≈ `.spring(response: 0.4, dampingFraction: 0.45)`)
    /// + a shockwave ring expands outward and fades.
    private func slam() {
        let spring = CASpringAnimation(keyPath: "transform.scale")
        spring.fromValue = 2.2
        spring.toValue = 1.0
        spring.mass = 1
        spring.stiffness = pow(2 * .pi / 0.4, 2)               // response 0.4 s
        spring.damping = 2 * 0.45 * sqrt(spring.stiffness)     // dampingFraction 0.45
        spring.duration = spring.settlingDuration
        tipPulseGroup.add(spring, forKey: "slam")

        let expand = CABasicAnimation(keyPath: "transform.scale")
        expand.fromValue = 0.4
        expand.toValue = 3.2
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.9
        fade.toValue = 0
        let wave = CAAnimationGroup()
        wave.animations = [expand, fade]
        wave.duration = 0.85
        wave.timingFunction = CAMediaTimingFunction(name: .easeOut)
        shockwave.add(wave, forKey: "wave")
    }
}
