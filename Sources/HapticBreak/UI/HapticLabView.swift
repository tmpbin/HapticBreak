import SwiftUI

/// Haptic Lab: a calibration bench based on reverse engineering + on-device testing. From "production"
/// down to "low level":
/// 1. **Timbre family assignment**: assign a representative `actuationID` to each of tap/crisp/low-buzz,
///    written to `HapticProfile` and persisted across launches.
/// 2. **Strength curve 1→10**: pick timbre + dullness, and audition end-to-end the float0 strength curve
///    the app actually uses.
/// 3. **Actuation browser**: feel every timbre × Light/Medium/Firm one by one, to pick IDs for the three families above.
/// 4. **Raw probe**: drive all parameters of `MTActuatorActuate` directly, for low-level verification.

// MARK: - Timbre catalog (ActuationID; the community-recognized `__tpad_act_plist` set, labels are measured semantics)

struct LabWaveform: Identifiable, Hashable {
    let id: Int32
    let nameKey: String
    var displayName: String { L.t(nameKey) }
}

enum HapticLabCatalog {
    static let waveforms: [LabWaveform] = [
        LabWaveform(id: 1,  nameKey: "lab.wf.1"),
        LabWaveform(id: 2,  nameKey: "lab.wf.2"),
        LabWaveform(id: 3,  nameKey: "lab.wf.3"),
        LabWaveform(id: 4,  nameKey: "lab.wf.4"),
        LabWaveform(id: 5,  nameKey: "lab.wf.5"),
        LabWaveform(id: 6,  nameKey: "lab.wf.6"),
        LabWaveform(id: 15, nameKey: "lab.wf.15"),
        LabWaveform(id: 16, nameKey: "lab.wf.16"),
    ]
}

// MARK: - Controller

/// Lab controller. Haptics fire on a dedicated serial queue (actuator create+open+actuate+close takes
/// time, avoid blocking the main thread); all `@Published` writes go back to the main thread. Sequence
/// playback uses `generation` guarding, so a new trigger cancels the old sequence.
final class HapticLab: ObservableObject, @unchecked Sendable {
    @Published var lastRet: Int32 = 0
    @Published var running = false
    @Published var nowPlaying: String = ""

    // Strength-curve audition controls (production three axes).
    @Published var curveTimbre: HapticTimbre = .crisp
    @Published var curveDullness: Double = 0.3
    @Published var curveStrength: Int = 5

    // Raw actuation probe: drive all parameters of MTActuatorActuate directly.
    @Published var rawActuationID: Int32 = 6
    @Published var rawStrengthFlags: UInt32 = 0       // 0=no level (production), 0x1=Light, 0x2=Medium, 0x4=Firm
    @Published var rawScale: Double = 1.0             // 4th arg float0: main scale
    @Published var rawTimeScale: Double = 0.4         // 5th arg float1: pulse width / timbre timing (dullness)

    /// Fire once on slide / param change, for continuously "sweeping" parameters to find the right feel. On by default.
    @Published var fireOnDrag = true

    let isAvailable: Bool
    let deviceDescription: String

    private let engine = PrivateHapticEngine(debug: false)
    private let queue = DispatchQueue(label: "com.aremind.hapticbreak.lab", qos: .userInteractive)
    private let lock = NSLock()
    private var generation = 0

    init() {
        isAvailable = engine.isAvailable
        deviceDescription = engine.deviceID.map { String(format: "0x%llx", $0) } ?? "—"
    }

    // MARK: Timbre family assignment

    /// Test a timbre family's currently assigned representative ID (mid strength, crisp), to confirm the ID is right.
    func fireTimbre(_ timbre: HapticTimbre) {
        let tone = HapticProfile.shared.resolve(timbre: timbre, strength: 6, dullness: 0.3, global: 6)
        fireRaw(id: tone.actuationID, flags: 0, scale: tone.float0, time: tone.float1)
    }

    func dragFireTimbre(_ timbre: HapticTimbre) {
        guard isAvailable, fireOnDrag, !running else { return }
        fireTimbre(timbre)
    }

    // MARK: Strength curve 1→10

    /// Resolve and fire once with the current (timbre, strength, dullness) — exactly matching the app's production path.
    func fireCurvePoint() {
        let tone = HapticProfile.shared.resolve(timbre: curveTimbre, strength: curveStrength, dullness: curveDullness, global: 6)
        fireRaw(id: tone.actuationID, flags: 0, scale: tone.float0, time: tone.float1)
    }

    func dragFireCurve() { guard isAvailable, fireOnDrag, !running else { return }; fireCurvePoint() }

    /// Play the 1→10 curve end-to-end (same timbre + same dullness, only strength increasing), to confirm
    /// it's monotonic and distinguishable.
    func previewCurve() {
        let items: [RawItem] = (1...HapticProfile.strengthLevels).map { s in
            let tone = HapticProfile.shared.resolve(timbre: curveTimbre, strength: s, dullness: curveDullness, global: 6)
            return RawItem(id: tone.actuationID, flags: 0, scale: tone.float0, time: tone.float1,
                           label: L.t("lab.curve.now", s, Int(tone.actuationID)))
        }
        runRawSequence(items, gapMs: 600)
    }

    // MARK: Actuation browser

    /// Browser unit: fire once with a given timbre × level (scale=1.0), purely to feel each combination.
    func fireActuation(_ id: Int32, _ strength: HapticStrength) {
        fireRaw(id: id, flags: strength.flags, scale: 1.0, time: rawTimeScaleFloat)
    }

    // MARK: Raw probe

    /// Fire once with the current (actuationID, flags, scale, timeScale).
    func fireRawProbe() {
        fireRaw(id: rawActuationID, flags: rawStrengthFlags, scale: Float(rawScale), time: Float(rawTimeScale))
    }

    /// Buzz-on-slide: called when dragging the raw probe sliders / changing ID·level (does not interrupt sequence playback).
    func dragFireRaw() { guard isAvailable, fireOnDrag, !running else { return }; fireRawProbe() }

    /// Play Light → Medium → Firm in turn (scale=1.0, reusing the current ID), to confirm the three levels differ end-to-end.
    func sweepStrengthPresets() {
        let id = rawActuationID, ts = Float(rawTimeScale)
        let items = HapticStrength.allCases.map {
            RawItem(id: id, flags: $0.flags, scale: 1.0, time: ts, label: L.t("lab.raw.now", Int(id), $0.label))
        }
        runRawSequence(items, gapMs: 760)
    }

    func stop() { _ = bump(); running = false; nowPlaying = "" }

    // MARK: - Internals

    private var rawTimeScaleFloat: Float { Float(rawTimeScale) }
    private struct RawItem { let id: Int32; let flags: UInt32; let scale: Float; let time: Float; let label: String }

    /// Single trigger (cancels the in-progress sequence).
    /// Coalesces rapid drag fires: a fast slider drag enqueues many closures, but only the newest
    /// (matching `generation`) performs the heavy create→open→actuate→close; superseded ones bail before
    /// touching the actuator. This keeps buzz-on-slide in step with the finger instead of piling up a
    /// serial-queue backlog that lags further behind the longer you drag.
    private func fireRaw(id: Int32, flags: UInt32, scale: Float, time: Float) {
        let myGen = bump(); running = false; nowPlaying = ""
        queue.async { [weak self] in
            guard let self, !self.isStale(myGen) else { return }
            let ret = self.engine.actuateRaw(actuationID: id, strengthFlags: flags, scale: scale, timeScale: time)
            DispatchQueue.main.async { self.lastRet = ret }
        }
    }

    private func runRawSequence(_ items: [RawItem], gapMs: Int) {
        guard !items.isEmpty else { return }
        let myGen = bump()
        running = true
        queue.async { [weak self] in
            guard let self else { return }
            for it in items {
                if self.isStale(myGen) { break }
                DispatchQueue.main.async { self.nowPlaying = it.label }
                let ret = self.engine.actuateRaw(actuationID: it.id, strengthFlags: it.flags, scale: it.scale, timeScale: it.time)
                DispatchQueue.main.async { self.lastRet = ret }
                usleep(useconds_t(gapMs * 1000))
            }
            DispatchQueue.main.async {
                if !self.isStale(myGen) { self.running = false; self.nowPlaying = "" }
            }
        }
    }

    private func bump() -> Int { lock.lock(); generation += 1; let g = generation; lock.unlock(); return g }
    private func isStale(_ g: Int) -> Bool { lock.lock(); defer { lock.unlock() }; return generation != g }
}

// MARK: - View

struct HapticLabView: View {
    @StateObject private var lab = HapticLab()
    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var profile = HapticProfile.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if !lab.isAvailable { unavailableNotice }
                timbreSection
                curveSection
                browserSection
                rawProbeSection
                if lab.running { runningBar }
                footer
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 480, minHeight: 640)
    }

    // MARK: Title + diagnostics

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L.t("lab.title")).font(.system(size: 20, weight: .semibold))
            Text(L.t("lab.subtitle")).font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 14) {
                diagChip(symbol: lab.isAvailable ? "checkmark.seal.fill" : "xmark.seal.fill",
                         text: lab.isAvailable ? L.t("lab.diag.ready") : L.t("lab.diag.unavailable"),
                         tint: lab.isAvailable ? .green : .orange)
                diagChip(symbol: "cpu", text: "device \(lab.deviceDescription)", tint: .secondary)
                diagChip(symbol: "number", text: String(format: "ret 0x%x", lab.lastRet),
                         tint: lab.lastRet == 0 ? .secondary : .orange)
            }
            .font(.caption)
            Toggle(isOn: $lab.fireOnDrag) { Text(L.t("lab.fireOnDrag")).font(.caption) }
                .toggleStyle(.switch).controlSize(.mini).fixedSize()
        }
    }

    private func diagChip(symbol: String, text: String, tint: Color) -> some View {
        Label(text, systemImage: symbol).foregroundStyle(tint)
    }

    private var unavailableNotice: some View {
        Label(L.t("lab.unavailable.note"), systemImage: "exclamationmark.triangle.fill")
            .font(.callout).foregroundStyle(.orange)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: Timbre family assignment (production)

    private var timbreSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle(L.t("lab.timbre.title"), L.t("lab.timbre.hint"))
            ForEach(HapticTimbre.allCases) { t in timbreRow(t) }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.08))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.accentColor.opacity(0.35), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func timbreRow(_ t: HapticTimbre) -> some View {
        HStack(spacing: 10) {
            Label(t.displayName, systemImage: t.symbol).frame(width: 120, alignment: .leading)
            Picker("", selection: Binding(
                get: { profile.actuationID(for: t) },
                set: { profile.setActuationID($0, for: t); lab.dragFireTimbre(t) })) {
                ForEach(HapticLabCatalog.waveforms) { wf in Text("ID \(wf.id)").tag(wf.id) }
            }
            .labelsHidden().frame(width: 96)
            Spacer()
            Button { lab.fireTimbre(t) } label: { Image(systemName: "hand.tap.fill") }
                .buttonStyle(.bordered).disabled(!lab.isAvailable)
        }
    }

    // MARK: Strength curve 1→10 (production)

    private var curveSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle(L.t("lab.curve.title"), L.t("lab.curve.hint"))
            Picker("", selection: Binding(get: { lab.curveTimbre }, set: { lab.curveTimbre = $0; lab.dragFireCurve() })) {
                ForEach(HapticTimbre.allCases) { t in Text(t.displayName).tag(t) }
            }
            .pickerStyle(.segmented).labelsHidden()

            HStack(spacing: 10) {
                Text(L.t("lab.curve.strength")).font(.caption).foregroundStyle(.secondary).frame(width: 96, alignment: .leading)
                Slider(value: Binding(get: { Double(lab.curveStrength) }, set: { lab.curveStrength = Int($0.rounded()) }), in: 1...10, step: 1)
                    .onChange(of: lab.curveStrength) { _ in lab.dragFireCurve() }
                Text("\(lab.curveStrength)").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 26, alignment: .trailing)
            }
            HStack(spacing: 10) {
                Text(L.t("lab.curve.dullness")).font(.caption).foregroundStyle(.secondary).frame(width: 96, alignment: .leading)
                Slider(value: $lab.curveDullness, in: 0...1, step: 0.05)
                    .onChange(of: lab.curveDullness) { _ in lab.dragFireCurve() }
                Text(String(format: "%.2f", lab.curveDullness)).font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 40, alignment: .trailing)
            }
            HStack(spacing: 10) {
                Button { lab.fireCurvePoint() } label: {
                    Label(L.t("lab.raw.fire"), systemImage: "hand.tap.fill").frame(maxWidth: .infinity)
                }
                .controlSize(.large).disabled(!lab.isAvailable)
                Button { lab.previewCurve() } label: {
                    Label(L.t("lab.curve.preview"), systemImage: "play.fill").frame(maxWidth: .infinity)
                }
                .controlSize(.large).buttonStyle(.borderedProminent)
                .disabled(!lab.isAvailable || lab.running)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: Actuation browser (all timbres × three levels)

    private var browserSection: some View {
        sectionCard {
            sectionTitle(L.t("lab.browser.title"), L.t("lab.browser.hint"))
            VStack(spacing: 8) {
                ForEach(HapticLabCatalog.waveforms) { wf in browserRow(wf) }
            }
        }
    }

    private func browserRow(_ wf: LabWaveform) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text("ID \(wf.id)").font(.system(size: 12, weight: .semibold, design: .rounded))
                Text(wf.displayName).font(.caption2).foregroundStyle(.secondary)
            }
            .frame(width: 96, alignment: .leading)
            ForEach(HapticStrength.allCases) { st in
                Button { lab.fireActuation(wf.id, st) } label: {
                    Text(st.label).font(.caption).frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered).disabled(!lab.isAvailable)
            }
        }
    }

    // MARK: Raw actuation probe (low-level verification)

    private var rawProbeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle(L.t("lab.raw.title"), L.t("lab.raw.hint"))
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L.t("lab.raw.id")).font(.caption).foregroundStyle(.secondary)
                    Picker("", selection: $lab.rawActuationID) {
                        ForEach(HapticLabCatalog.waveforms) { wf in Text("ID \(wf.id)").tag(wf.id) }
                    }
                    .labelsHidden().frame(width: 96)
                    .onChange(of: lab.rawActuationID) { _ in lab.dragFireRaw() }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(L.t("lab.raw.strength")).font(.caption).foregroundStyle(.secondary)
                    Picker("", selection: $lab.rawStrengthFlags) {
                        Text(L.t("lab.raw.none")).tag(UInt32(0))
                        Text("Light").tag(UInt32(0x1))
                        Text("Medium").tag(UInt32(0x2))
                        Text("Firm").tag(UInt32(0x4))
                    }
                    .pickerStyle(.segmented).labelsHidden()
                    .id("lab.raw.flags.\(l10n.language.rawValue)")
                    .onChange(of: lab.rawStrengthFlags) { _ in lab.dragFireRaw() }
                }
            }
            sliderRow(L.t("lab.raw.scale"), value: $lab.rawScale) { lab.dragFireRaw() }
            sliderRow(L.t("lab.raw.time"), value: $lab.rawTimeScale) { lab.dragFireRaw() }
            HStack(spacing: 10) {
                Button { lab.fireRawProbe() } label: {
                    Label(L.t("lab.raw.fire"), systemImage: "hand.tap.fill").frame(maxWidth: .infinity)
                }
                .controlSize(.large).buttonStyle(.borderedProminent)
                .disabled(!lab.isAvailable)
                Button { lab.sweepStrengthPresets() } label: {
                    Label(L.t("lab.raw.sweep"), systemImage: "chart.bar.fill").frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .disabled(!lab.isAvailable || lab.running)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.green.opacity(0.08))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.green.opacity(0.35), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func sliderRow(_ title: String, value: Binding<Double>, onEdit: @escaping () -> Void = {}) -> some View {
        HStack(spacing: 10) {
            Text(title).font(.caption).foregroundStyle(.secondary).frame(width: 96, alignment: .leading)
            Slider(value: value, in: 0...2, step: 0.05)
                .onChange(of: value.wrappedValue) { _ in onEdit() }
            Text(String(format: "%.2f", value.wrappedValue))
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 40, alignment: .trailing)
        }
    }

    // MARK: Running status bar + footer

    private var runningBar: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(lab.nowPlaying).font(.callout).monospacedDigit().foregroundStyle(.secondary)
            Spacer()
            Button(L.t("lab.stop")) { lab.stop() }.controlSize(.small)
        }
        .padding(.horizontal, 4)
    }

    private var footer: some View {
        Text(L.t("lab.footer"))
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Helpers

    private func sectionCard<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 12) { content() }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func sectionTitle(_ title: String, _ hint: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 14, weight: .semibold))
            Text(hint).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
