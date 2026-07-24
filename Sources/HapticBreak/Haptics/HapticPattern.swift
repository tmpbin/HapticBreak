import Foundation

/// A **single beat** in a haptic sequence (the atomic unit): a self-contained "note".
/// = timbre family + design strength (1…10) + dullness (0…1) + the gap after this beat.
/// Final strength = design strength × global gain (see `HapticProfile`).
struct HapticStep: Codable, Hashable, Identifiable {
    var id = UUID()
    var timbre: HapticTimbre   // Timbre family
    var strength: Int          // 1…10 (design-time absolute strength)
    var dullness: Double       // 0…1 (crisp ↔ dull)
    var gapMsAfter: Int        // Gap from this beat to the next (ms; ignored on the last beat)

    init(id: UUID = UUID(), timbre: HapticTimbre = .crisp, strength: Int, dullness: Double = 0.3, gapMsAfter: Int) {
        self.id = id
        self.timbre = timbre
        self.strength = max(1, min(HapticProfile.strengthLevels, strength))
        self.dullness = max(0, min(1, dullness))
        self.gapMsAfter = max(0, gapMsAfter)
    }

    // MARK: - Codable (compatible with the old schema: `{level 0…5, delayMsAfter}` → auto-migrated to the new beat)

    enum CodingKeys: String, CodingKey {
        case id, timbre, strength, dullness, gapMsAfter
        case level, delayMsAfter   // Legacy fields, only used for decode migration
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        self.gapMsAfter = max(0, (try? c.decode(Int.self, forKey: .gapMsAfter))
                                  ?? (try? c.decode(Int.self, forKey: .delayMsAfter)) ?? 0)
        if let s = try? c.decode(Int.self, forKey: .strength) {
            self.timbre = (try? c.decode(HapticTimbre.self, forKey: .timbre)) ?? .crisp
            self.strength = max(1, min(HapticProfile.strengthLevels, s))
            self.dullness = max(0, min(1, (try? c.decode(Double.self, forKey: .dullness)) ?? 0.3))
        } else if let level = try? c.decode(Int.self, forKey: .level) {
            // Legacy schema migration: level 0…5 → strength 1…10, timbre defaults to crisp.
            self.timbre = .crisp
            self.strength = max(1, min(10, Int((Double(level) / 5.0 * 9.0).rounded()) + 1))
            self.dullness = 0.3
        } else {
            self.timbre = .crisp; self.strength = 5; self.dullness = 0.3
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(timbre, forKey: .timbre)
        try c.encode(strength, forKey: .strength)
        try c.encode(dullness, forKey: .dullness)
        try c.encode(gapMsAfter, forKey: .gapMsAfter)
    }
}

/// Built-in pattern category (UI grouping only; custom patterns fall under `custom`).
enum HapticPatternCategory: String, CaseIterable, Identifiable {
    case basic, nature, rhythm, custom
    var id: String { rawValue }
    var displayName: String { L.t("patcat." + rawValue) }
}

/// A nameable, arrangeable haptic pattern = a sequence of beats.
struct HapticPattern: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var symbol: String        // SF Symbol name, for UI display
    var steps: [HapticStep]
    var isBuiltin: Bool

    init(id: String, name: String, symbol: String, steps: [HapticStep], isBuiltin: Bool) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.steps = steps
        self.isBuiltin = isBuiltin
    }

    /// Estimated total playback duration (seconds), for UI hints.
    var estimatedDuration: TimeInterval {
        let ms = steps.dropLast().reduce(0) { $0 + $1.gapMsAfter }
        return TimeInterval(ms) / 1000.0
    }

    /// Content equality of the beat sequence, ignoring per-beat identity (imports mint fresh UUIDs,
    /// so `steps ==` can never match a re-imported copy).
    func hasSameSteps(as other: HapticPattern) -> Bool {
        steps.count == other.steps.count && zip(steps, other.steps).allSatisfy {
            $0.timbre == $1.timbre && $0.strength == $1.strength
                && $0.dullness == $1.dullness && $0.gapMsAfter == $1.gapMsAfter
        }
    }

    /// UI display name: built-ins resolve a localization key by id convention (`builtin.X` → `pattern.X`);
    /// custom patterns use the user's name.
    var displayName: String {
        guard isBuiltin else { return name }
        let prefix = "builtin."
        if id.hasPrefix(prefix) { return L.t("pattern." + id.dropFirst(prefix.count)) }
        return name
    }

    var category: HapticPatternCategory {
        guard isBuiltin else { return .custom }
        if Self.natureIDs.contains(id) { return .nature }
        if Self.rhythmIDs.contains(id) { return .rhythm }
        return .basic
    }

    // MARK: - Construction helpers

    private static func s(_ t: HapticTimbre, _ strength: Int, _ dullness: Double, _ gap: Int) -> HapticStep {
        HapticStep(timbre: t, strength: strength, dullness: dullness, gapMsAfter: gap)
    }

    // MARK: - Basic (alert prototypes)
    //
    // Perceptibility floor (on-device finding): the `soft` timbre rides the faintest actuation, and
    // design strength ≤3 lands at float0 ≤0.56 — at/below the feeling threshold even at global 10.
    // Soft-dominated presets therefore keep their strength *contour* but sit on a floor of ≥4,
    // so every beat is actually deliverable; deliberate decay tails bottom out at 2, not 1.

    static let gentle = HapticPattern(
        id: "builtin.gentle", name: "Gentle", symbol: "hand.tap",
        steps: [s(.soft, 10, 0.4, 0)], isBuiltin: true)

    static let double = HapticPattern(
        id: "builtin.double", name: "Double Tap", symbol: "hand.tap.fill",
        steps: [s(.crisp, 6, 0.25, 110), s(.crisp, 6, 0.25, 0)], isBuiltin: true)

    static let triple = HapticPattern(
        id: "builtin.triple", name: "Triple Tap", symbol: "ellipsis",
        steps: [s(.crisp, 6, 0.3, 140), s(.crisp, 6, 0.3, 140), s(.crisp, 6, 0.3, 0)], isBuiltin: true)

    static let ramp = HapticPattern(   // 10 beats, silence → full: a gradual "coming back" swell
        id: "builtin.ramp", name: "Ramp Up", symbol: "chart.line.uptrend.xyaxis",
        steps: [s(.crisp, 1, 0.3, 110), s(.crisp, 2, 0.3, 110), s(.crisp, 3, 0.3, 110),
                s(.crisp, 4, 0.3, 110), s(.crisp, 5, 0.3, 110), s(.crisp, 6, 0.3, 110),
                s(.crisp, 7, 0.3, 110), s(.crisp, 8, 0.3, 110), s(.crisp, 9, 0.3, 110),
                s(.crisp, 10, 0.3, 0)], isBuiltin: true)

    static let fade = HapticPattern(   // 10 beats, full → silence: the mirror of Ramp Up
        id: "builtin.fade", name: "Fade Out", symbol: "chart.line.downtrend.xyaxis",
        steps: [s(.crisp, 10, 0.4, 120), s(.crisp, 9, 0.4, 120), s(.crisp, 8, 0.4, 120),
                s(.crisp, 7, 0.4, 120), s(.crisp, 6, 0.4, 120), s(.crisp, 5, 0.4, 120),
                s(.crisp, 4, 0.4, 120), s(.crisp, 3, 0.4, 120), s(.crisp, 2, 0.4, 120),
                s(.crisp, 1, 0.4, 0)], isBuiltin: true)

    static let urgent = HapticPattern(
        id: "builtin.urgent", name: "Urgent", symbol: "exclamationmark.triangle.fill",
        steps: [s(.crisp, 8, 0.3, 90), s(.crisp, 8, 0.3, 90), s(.crisp, 8, 0.3, 90),
                s(.crisp, 8, 0.3, 90), s(.crisp, 8, 0.3, 90), s(.crisp, 8, 0.3, 0)], isBuiltin: true)

    static let sos = HapticPattern(
        id: "builtin.sos", name: "SOS", symbol: "sos",
        steps: [s(.crisp, 6, 0.25, 130), s(.crisp, 6, 0.25, 130), s(.crisp, 6, 0.25, 300),
                s(.crisp, 9, 0.3, 240), s(.crisp, 9, 0.3, 240), s(.crisp, 9, 0.3, 300),
                s(.crisp, 6, 0.25, 130), s(.crisp, 6, 0.25, 130), s(.crisp, 6, 0.25, 0)], isBuiltin: true)

    // MARK: - Nature (inspired by natural sounds/rhythms)

    static let heartbeat = HapticPattern(
        id: "builtin.heartbeat", name: "Heartbeat", symbol: "heart.fill",
        steps: [s(.buzz, 7, 0.8, 140), s(.buzz, 4, 0.8, 560),
                s(.buzz, 7, 0.8, 140), s(.buzz, 4, 0.8, 0)], isBuiltin: true)

    static let ripple = HapticPattern(
        id: "builtin.ripple", name: "Ripple", symbol: "drop.fill",
        steps: [s(.soft, 6, 0.2, 70), s(.soft, 4, 0.2, 70),
                s(.soft, 3, 0.2, 70), s(.soft, 2, 0.2, 0)], isBuiltin: true)

    static let dripping = HapticPattern(
        id: "builtin.dripping", name: "Dripping", symbol: "drop",
        steps: [s(.soft, 6, 0.2, 650), s(.soft, 6, 0.2, 650), s(.soft, 6, 0.2, 0)], isBuiltin: true)

    static let flutter = HapticPattern(
        id: "builtin.flutter", name: "Flutter", symbol: "leaf.fill",
        steps: [s(.soft, 10, 0.4, 85), s(.soft, 10, 0.4, 85), s(.soft, 10, 0.4, 85),
                s(.soft, 10, 0.4, 85), s(.soft, 10, 0.4, 0)], isBuiltin: true)

    static let woodpecker = HapticPattern(
        id: "builtin.woodpecker", name: "Woodpecker", symbol: "bird.fill",
        steps: [s(.crisp, 6, 0.1, 70), s(.crisp, 6, 0.1, 70), s(.crisp, 6, 0.1, 70),
                s(.crisp, 6, 0.1, 70), s(.crisp, 6, 0.1, 0)], isBuiltin: true)

    // MARK: - Rhythm (musical grooves; each spans ≥ 2 full bars). Feel rules learned on-device:
    // taps closer than ~120 ms blur into one buzz, so inter-onset gaps stay above that; meter is carried by
    // ACCENT CONTRAST — low `buzz` = kick / downbeat, bright `crisp` = clap / accent, gentle `soft` = weak
    // offbeat — not by strength alone. Gaps are real inter-onset intervals at a singable tempo.

    static let boomclap = HapticPattern(   // 4/4 four-on-the-floor · ~135 BPM: kick-CLAP alternating (2 bars)
        id: "builtin.boomclap", name: "Boom Clap", symbol: "metronome.fill",
        steps: [s(.buzz, 9, 0.7, 440), s(.crisp, 8, 0.15, 440),
                s(.buzz, 9, 0.7, 440), s(.crisp, 8, 0.15, 440),
                s(.buzz, 9, 0.7, 440), s(.crisp, 8, 0.15, 440),
                s(.buzz, 9, 0.7, 440), s(.crisp, 8, 0.15, 0)], isBuiltin: true)

    static let accelerando = HapticPattern(   // A dropped ball: bounces get faster and softer until they
        // blur into a settle — gaps shrink geometrically (~×0.8), strength decays with the energy.
        id: "builtin.accelerando", name: "Accelerando", symbol: "forward.fill",
        steps: [s(.crisp, 10, 0.4, 500), s(.crisp, 9, 0.4, 400), s(.crisp, 8, 0.4, 320),
                s(.crisp, 7, 0.35, 255), s(.crisp, 6, 0.35, 205), s(.crisp, 6, 0.3, 165),
                s(.crisp, 5, 0.3, 130), s(.crisp, 5, 0.3, 105), s(.crisp, 4, 0.3, 85),
                s(.crisp, 4, 0.3, 70), s(.crisp, 4, 0.3, 60), s(.crisp, 4, 0.3, 0)], isBuiltin: true)

    static let ritardando = HapticPattern(   // The drop played backwards: a rattle gathers energy,
        // spacing out and hardening until the final full-strength blow.
        id: "builtin.ritardando", name: "Ritardando", symbol: "backward.fill",
        steps: [s(.crisp, 4, 0.3, 60), s(.crisp, 4, 0.3, 70), s(.crisp, 4, 0.3, 85),
                s(.crisp, 5, 0.3, 105), s(.crisp, 5, 0.3, 130), s(.crisp, 6, 0.3, 165),
                s(.crisp, 6, 0.35, 205), s(.crisp, 7, 0.35, 255), s(.crisp, 8, 0.4, 320),
                s(.crisp, 9, 0.4, 400), s(.crisp, 10, 0.4, 500), s(.crisp, 10, 0.5, 0)], isBuiltin: true)

    static let triplet = HapticPattern(   // Two bars: four accented triplet groups — ONE-two-three ×4
        id: "builtin.triplet", name: "Triplet", symbol: "music.note.list",
        steps: [s(.crisp, 8, 0.25, 160), s(.soft, 4, 0.3, 160), s(.soft, 4, 0.3, 300),
                s(.crisp, 8, 0.25, 160), s(.soft, 4, 0.3, 160), s(.soft, 4, 0.3, 300),
                s(.crisp, 8, 0.25, 160), s(.soft, 4, 0.3, 160), s(.soft, 4, 0.3, 300),
                s(.crisp, 8, 0.25, 160), s(.soft, 4, 0.3, 160), s(.soft, 4, 0.3, 0)], isBuiltin: true)

    static let echo = HapticPattern(   // Call + fading echoes, twice (two phrases)
        id: "builtin.echo", name: "Echo", symbol: "speaker.wave.3.fill",
        steps: [s(.crisp, 9, 0.3, 180), s(.crisp, 6, 0.35, 230), s(.soft, 4, 0.4, 280), s(.soft, 2, 0.45, 480),
                s(.crisp, 9, 0.3, 180), s(.crisp, 6, 0.35, 230), s(.soft, 4, 0.4, 280), s(.soft, 2, 0.45, 0)], isBuiltin: true)

    static let pulse = HapticPattern(   // Two bars · ~115 BPM: strong driving throb, accent every downbeat (ONE-two ×4)
        id: "builtin.pulse", name: "Pulse", symbol: "waveform.path",
        steps: [s(.buzz, 10, 0.5, 260), s(.buzz, 6, 0.5, 260), s(.buzz, 10, 0.5, 260), s(.buzz, 6, 0.5, 260),
                s(.buzz, 10, 0.5, 260), s(.buzz, 6, 0.5, 260), s(.buzz, 10, 0.5, 260), s(.buzz, 6, 0.5, 0)], isBuiltin: true)

    static let countdown = HapticPattern(   // 3-2-1 ticks then a strong "GO", twice
        id: "builtin.countdown", name: "Countdown", symbol: "timer",
        steps: [s(.soft, 4, 0.3, 450), s(.soft, 4, 0.3, 450), s(.soft, 4, 0.3, 450), s(.buzz, 9, 0.4, 620),
                s(.soft, 4, 0.3, 450), s(.soft, 4, 0.3, 450), s(.soft, 4, 0.3, 450), s(.buzz, 9, 0.4, 0)], isBuiltin: true)

    static let gallop = HapticPattern(   // Two bars · horse gallop: ti-ti-DUM (two soft + accented) ×3
        id: "builtin.gallop", name: "Gallop", symbol: "hare.fill",
        steps: [s(.soft, 4, 0.3, 140), s(.soft, 4, 0.3, 140), s(.buzz, 8, 0.4, 330),
                s(.soft, 4, 0.3, 140), s(.soft, 4, 0.3, 140), s(.buzz, 8, 0.4, 330),
                s(.soft, 4, 0.3, 140), s(.soft, 4, 0.3, 140), s(.buzz, 8, 0.4, 0)], isBuiltin: true)

    // MARK: - Iconic motifs (the rhythm alone evokes the classic; each is two phrases long)

    static let fate = HapticPattern(   // Beethoven's 5th "Fate": three eighths + a held blow, twice — "· · · —  · · · —"
        id: "builtin.fate", name: "Fate", symbol: "bolt.fill",
        steps: [s(.crisp, 7, 0.3, 220), s(.crisp, 7, 0.3, 220), s(.crisp, 7, 0.3, 220), s(.buzz, 10, 0.6, 840),
                s(.crisp, 7, 0.3, 220), s(.crisp, 7, 0.3, 220), s(.crisp, 7, 0.3, 220), s(.buzz, 10, 0.6, 0)], isBuiltin: true)

    static let stomp = HapticPattern(   // "We Will Rock You" stomp-stomp-CLAP (eighths ≈ 360 ms), two bars
        id: "builtin.stomp", name: "Stomp Clap", symbol: "hands.clap.fill",
        steps: [s(.buzz, 9, 0.7, 360), s(.buzz, 9, 0.7, 360), s(.crisp, 9, 0.15, 720),
                s(.buzz, 9, 0.7, 360), s(.buzz, 9, 0.7, 360), s(.crisp, 9, 0.15, 0)], isBuiltin: true)

    static let haircut = HapticPattern(   // "Shave and a Haircut, two bits" — seven-tap couplet
        id: "builtin.haircut", name: "Shave & Haircut", symbol: "scissors",
        steps: [s(.crisp, 8, 0.25, 340), s(.soft, 6, 0.3, 190), s(.soft, 6, 0.3, 340),
                s(.crisp, 8, 0.25, 360), s(.crisp, 7, 0.25, 620),
                s(.soft, 6, 0.3, 300), s(.crisp, 9, 0.2, 0)], isBuiltin: true)

    static let darkMarch = HapticPattern(   // Villain-march cadence: three strong beats + (strong-weak-strong) ×2
        id: "builtin.darkmarch", name: "Dark March", symbol: "flag.fill",
        steps: [s(.buzz, 9, 0.5, 420), s(.buzz, 9, 0.5, 420), s(.buzz, 9, 0.5, 420),
                s(.buzz, 9, 0.5, 360), s(.soft, 5, 0.3, 130), s(.buzz, 9, 0.5, 420),
                s(.buzz, 9, 0.5, 360), s(.soft, 5, 0.3, 130), s(.buzz, 9, 0.5, 0)], isBuiltin: true)

    static let jingle = HapticPattern(   // "Jingle Bells" chorus: ti-ti-TA ×2, then ti-ti-ti-ti WAY (eighth ≈ 200 ms)
        id: "builtin.jingle", name: "Jingle Bells", symbol: "bell.fill",
        steps: [s(.crisp, 6, 0.3, 200), s(.crisp, 6, 0.3, 200), s(.crisp, 9, 0.3, 400),
                s(.crisp, 6, 0.3, 200), s(.crisp, 6, 0.3, 200), s(.crisp, 9, 0.3, 400),
                s(.crisp, 6, 0.3, 200), s(.crisp, 6, 0.3, 200), s(.crisp, 7, 0.3, 200),
                s(.crisp, 6, 0.3, 200), s(.buzz, 10, 0.5, 0)], isBuiltin: true)

    static let birthday = HapticPattern(   // "Happy Birthday": hap-py pickup + BIRTH-day-to-YOU, two phrases (quarter ≈ 450 ms)
        id: "builtin.birthday", name: "Happy Birthday", symbol: "gift.fill",
        steps: [s(.soft, 5, 0.3, 320), s(.soft, 5, 0.3, 130), s(.buzz, 9, 0.5, 450),
                s(.crisp, 7, 0.3, 450), s(.crisp, 7, 0.3, 450), s(.buzz, 10, 0.5, 700),
                s(.soft, 5, 0.3, 320), s(.soft, 5, 0.3, 130), s(.buzz, 9, 0.5, 450),
                s(.crisp, 7, 0.3, 450), s(.crisp, 7, 0.3, 450), s(.buzz, 10, 0.5, 0)], isBuiltin: true)

    static let frere = HapticPattern(   // "Frère Jacques" / 两只老虎: four even quarters ×2, then ti-ti-TAA ×2 (quarter ≈ 320 ms)
        id: "builtin.frere", name: "Frère Jacques", symbol: "pawprint.fill",
        steps: [s(.crisp, 8, 0.3, 320), s(.crisp, 6, 0.3, 320), s(.crisp, 6, 0.3, 320), s(.crisp, 6, 0.3, 320),
                s(.crisp, 8, 0.3, 320), s(.crisp, 6, 0.3, 320), s(.crisp, 6, 0.3, 320), s(.crisp, 6, 0.3, 320),
                s(.crisp, 7, 0.3, 320), s(.crisp, 7, 0.3, 320), s(.buzz, 9, 0.5, 640),
                s(.crisp, 7, 0.3, 320), s(.crisp, 7, 0.3, 320), s(.buzz, 9, 0.5, 0)], isBuiltin: true)

    static let chime = HapticPattern(   // Westminster Quarters — the school-bell chime: four slow bell strokes ×2
        id: "builtin.chime", name: "Westminster", symbol: "graduationcap.fill",
        steps: [s(.buzz, 8, 0.8, 550), s(.buzz, 8, 0.8, 550), s(.buzz, 8, 0.8, 550), s(.buzz, 10, 0.9, 1000),
                s(.buzz, 8, 0.8, 550), s(.buzz, 8, 0.8, 550), s(.buzz, 8, 0.8, 550), s(.buzz, 10, 0.9, 0)], isBuiltin: true)

    static let mission = HapticPattern(   // Spy-theme 5/4 ostinato: DUM… DUM… ba-da, twice
        id: "builtin.mission", name: "Secret Mission", symbol: "figure.run",
        steps: [s(.buzz, 9, 0.6, 700), s(.buzz, 9, 0.6, 700), s(.crisp, 7, 0.25, 180), s(.crisp, 7, 0.25, 420),
                s(.buzz, 9, 0.6, 700), s(.buzz, 9, 0.6, 700), s(.crisp, 7, 0.25, 180), s(.crisp, 7, 0.25, 0)], isBuiltin: true)

    // MARK: - Aggregation / categorization

    static let natureIDs: Set<String> = [
        heartbeat.id, ripple.id, dripping.id, flutter.id, woodpecker.id]

    static let rhythmIDs: Set<String> = [
        boomclap.id, accelerando.id, ritardando.id,
        triplet.id, echo.id, pulse.id, countdown.id, gallop.id,
        fate.id, stomp.id, haircut.id, darkMarch.id,
        jingle.id, birthday.id, frere.id, chime.id, mission.id]

    static let builtins: [HapticPattern] = [
        // Basic
        gentle, double, triple, ramp, fade, urgent, sos,
        // Nature
        heartbeat, ripple, dripping, flutter, woodpecker,
        // Rhythm
        boomclap, accelerando, ritardando, triplet, echo, pulse, countdown, gallop,
        // Iconic motifs
        fate, stomp, haircut, darkMarch, jingle, birthday, frere, chime, mission,
    ]

    static func builtins(in category: HapticPatternCategory) -> [HapticPattern] {
        builtins.filter { $0.category == category }
    }
}
