import Foundation
import Combine

/// Haptic profile (a small amount of machine-tunable truth).
///
/// Carries two things:
/// 1. The **three timbre families → representative `actuationID`** mapping (defaults 1/6/16, editable in
///    the "Haptic Lab" and persisted across launches);
/// 2. The **three axes → low-level parameters** math: strength 1…10 → `float0`, global gain 1…10,
///    dullness 0…1 → `float1`.
///
/// Threading: `@Published` is UI-mutated on the main thread only; the engine reads `actuationID` from an
/// `NSLock`-guarded snapshot on a background queue.
final class HapticProfile: ObservableObject {

    static let shared = HapticProfile()

    /// Number of levels for global/per-beat strength (1…10).
    static let strengthLevels = 10

    @Published var softID:  Int32 { didSet { sync() } }
    @Published var crispID: Int32 { didSet { sync() } }
    @Published var buzzID:  Int32 { didSet { sync() } }

    private let lock = NSLock()
    private var snap: (soft: Int32, crisp: Int32, buzz: Int32)
    /// Shared preference store (in-memory in ephemeral runs — never bypass to UserDefaults directly).
    private let store: KeyValueStore = RuntimeMode.settingsDefaults()

    private enum Key {
        static let soft  = "hb.profile.softID"
        static let crisp = "hb.profile.crispID"
        static let buzz  = "hb.profile.buzzID"
    }

    private init() {
        let s = (store.object(forKey: Key.soft)  as? Int).map(Int32.init) ?? HapticTimbre.soft.defaultActuationID
        let c = (store.object(forKey: Key.crisp) as? Int).map(Int32.init) ?? HapticTimbre.crisp.defaultActuationID
        let b = (store.object(forKey: Key.buzz)  as? Int).map(Int32.init) ?? HapticTimbre.buzz.defaultActuationID
        snap = (s, c, b)
        softID = s; crispID = c; buzzID = b   // Assignments inside init do not trigger didSet
    }

    // MARK: - Timbre family → ActuationID

    /// Set the representative ID for a timbre family (Lab use, main thread).
    func setActuationID(_ v: Int32, for timbre: HapticTimbre) {
        switch timbre {
        case .soft:  softID = v
        case .crisp: crispID = v
        case .buzz:  buzzID = v
        }
    }

    /// Thread-safe: get the current representative ID of a timbre family (called by the engine in the background).
    func actuationID(for timbre: HapticTimbre) -> Int32 {
        lock.lock(); defer { lock.unlock() }
        switch timbre {
        case .soft:  return snap.soft
        case .crisp: return snap.crisp
        case .buzz:  return snap.buzz
        }
    }

    func resetToDefault() {
        softID  = HapticTimbre.soft.defaultActuationID
        crispID = HapticTimbre.crisp.defaultActuationID
        buzzID  = HapticTimbre.buzz.defaultActuationID
    }

    // MARK: - Three axes → low-level parameters (centralized in one place for unified tuning)

    /// Per-beat design strength 1…10 → `float0` (0.15…2.0).
    static func stepFloat0(_ strength: Int) -> Float {
        let s = Float(max(1, min(strengthLevels, strength)))
        return 0.15 + (s - 1) / Float(strengthLevels - 1) * 1.85
    }

    /// Global strength 1…10 → multiplicative gain (0.40…1.50, neutral ≈ g6). Preserves a preset's internal
    /// strong/weak contrast while scaling the whole.
    static func globalGain(_ g: Int) -> Float {
        let x = Float(max(1, min(strengthLevels, g)))
        return 0.40 + (x - 1) / Float(strengthLevels - 1) * 1.10
    }

    /// Dullness 0…1 → `float1` (0.30 crisp … 1.80 dull).
    static func float1(forDullness d: Double) -> Float {
        let dd = Float(max(0, min(1, d)))
        return 0.30 + dd * 1.50
    }

    /// Resolve one actuation: timbre family → ID, `stepFloat0 × globalGain` → float0 (clamped 0.05…2.0),
    /// dullness → float1.
    func resolve(timbre: HapticTimbre, strength: Int, dullness: Double, global: Int) -> ResolvedTone {
        let f0 = min(2.0, max(0.05, Self.stepFloat0(strength) * Self.globalGain(global)))
        return ResolvedTone(actuationID: actuationID(for: timbre),
                            float0: f0,
                            float1: Self.float1(forDullness: dullness))
    }

    /// Resolve from a single beat + global strength.
    func resolve(step: HapticStep, global: Int) -> ResolvedTone {
        resolve(timbre: step.timbre, strength: step.strength, dullness: step.dullness, global: global)
    }

    /// Design-reference resolution (global gain fixed at 1.0): used by "pattern design / lab" preview —
    /// unaffected by the user's global strength, so the designer hears exactly the absolute strength set
    /// (global scaling applies only to real events, not pattern design or the lab).
    func resolveDesign(timbre: HapticTimbre, strength: Int, dullness: Double) -> ResolvedTone {
        let f0 = min(2.0, max(0.05, Self.stepFloat0(strength)))
        return ResolvedTone(actuationID: actuationID(for: timbre),
                            float0: f0,
                            float1: Self.float1(forDullness: dullness))
    }

    func resolveDesign(step: HapticStep) -> ResolvedTone {
        resolveDesign(timbre: step.timbre, strength: step.strength, dullness: step.dullness)
    }

    private func sync() {
        lock.lock(); snap = (softID, crispID, buzzID); lock.unlock()
        store.set(Int(softID),  forKey: Key.soft)
        store.set(Int(crispID), forKey: Key.crisp)
        store.set(Int(buzzID),  forKey: Key.buzz)
    }
}
