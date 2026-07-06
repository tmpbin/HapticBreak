import Foundation

/// Haptic timbre family (one of the three axes: timbre).
///
/// Confirmed both by single-variable on-device testing and reverse-engineered palette: the perceivable
/// timbres are really **three families** — tap (no harmonics) / crisp (strong click + harmonics) /
/// low buzz (pure low-frequency buzz); multiple `actuationID`s within a family feel equivalent.
/// One representative ID per family; the concrete ID can be changed in the "Haptic Lab" and persisted
/// by `HapticProfile` (machine-tunable).
enum HapticTimbre: String, Codable, CaseIterable, Identifiable {
    case soft   // Tap: default ID1, pure pulse, softest
    case crisp  // Crisp: default ID6, strong click + timbre, highest ceiling
    case buzz   // Low buzz: default ID16, pure low frequency, dull and long

    var id: String { rawValue }

    /// Factory representative `actuationID` (default when `HapticProfile` has no customization).
    var defaultActuationID: Int32 {
        switch self {
        case .soft:  return 1
        case .crisp: return 6
        case .buzz:  return 16
        }
    }

    var labelKey: String {
        switch self {
        case .soft:  return "timbre.soft"
        case .crisp: return "timbre.crisp"
        case .buzz:  return "timbre.buzz"
        }
    }

    var displayName: String { L.t(labelKey) }

    var symbol: String {
        switch self {
        case .soft:  return "hand.tap"
        case .crisp: return "waveform.path"
        case .buzz:  return "dot.radiowaves.left.and.right"
        }
    }
}

/// A resolved single-actuation parameter set: fed directly to `MTActuatorActuate(ref, actuationID, 0, float0, float1)` (`flags` is always 0).
/// Computed by `HapticProfile.resolve` from "timbre × strength × dullness × global gain".
struct ResolvedTone: Equatable {
    let actuationID: Int32
    let float0: Float   // Main scale (strength)
    let float1: Float   // Pulse width / timbre timing (dullness)
}

/// Haptic backend abstraction: driven by the **resolved concrete parameters** `ResolvedTone`.
protocol HapticEngine: AnyObject {
    var isAvailable: Bool { get }
    var backendName: String { get }
    /// Trigger one resolved actuation.
    func actuate(_ tone: ResolvedTone)
}

enum HapticBackend: String, Codable, CaseIterable {
    case auto    // Auto: prefer the private API, fall back to the public API on failure
    case `private`
    case `public`

    var displayName: String {
        switch self {
        case .auto:     return L.t("backend.auto")
        case .private:  return L.t("backend.private")
        case .public:   return L.t("backend.public")
        }
    }
}

enum HapticEngineFactory {
    /// Build the haptic engine from preferences. For `.auto`, prefer the private API and fall back to
    /// the public API if unavailable.
    static func make(_ backend: HapticBackend, debug: Bool = false) -> HapticEngine {
        switch backend {
        case .public:
            return PublicHapticEngine()
        case .private:
            return PrivateHapticEngine(debug: debug)
        case .auto:
            let priv = PrivateHapticEngine(debug: debug)
            return priv.isAvailable ? priv : PublicHapticEngine()
        }
    }
}
