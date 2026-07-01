import AppKit
import UniformTypeIdentifiers

/// Import / export of custom haptic patterns. Uses a compact JSON that's friendly to humans and AI
/// (no internal UUIDs):
/// ```json
/// [ { "name": "...", "steps": [ { "timbre": "crisp", "strength": 6, "dullness": 0.3, "gapMs": 120 } ] } ]
/// ```
/// - `timbre`: `soft` | `crisp` | `buzz`
/// - `strength`: 1…10 (design strength, multiplied by global strength at runtime)
/// - `dullness`: 0…1 (0 crisp → 1 dull)
/// - `gapMs`: gap in ms from this beat to the next (0 for the last beat)
enum PatternIO {

    struct StepDTO: Codable { var timbre: String; var strength: Int; var dullness: Double; var gapMs: Int }
    struct PatternDTO: Codable { var name: String; var steps: [StepDTO] }

    // MARK: - Conversion

    static func dto(from p: HapticPattern) -> PatternDTO {
        PatternDTO(name: p.displayName, steps: p.steps.map {
            StepDTO(timbre: $0.timbre.rawValue, strength: $0.strength,
                    dullness: (($0.dullness * 100).rounded()) / 100, gapMs: $0.gapMsAfter)
        })
    }

    static func pattern(from dto: PatternDTO) -> HapticPattern {
        let steps = dto.steps.map { d in
            HapticStep(timbre: HapticTimbre(rawValue: d.timbre.lowercased()) ?? .crisp,
                       strength: d.strength, dullness: d.dullness, gapMsAfter: d.gapMs)
        }
        let name = dto.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return HapticPattern(
            id: "custom.\(UUID().uuidString)",
            name: name.isEmpty ? L.t("editor.newPatternName") : name,
            symbol: "waveform",
            steps: steps.isEmpty ? [HapticStep(strength: 6, gapMsAfter: 0)] : steps,
            isBuiltin: false)
    }

    // MARK: - Text encode/decode

    private static func encoder() -> JSONEncoder {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return enc
    }

    static func exportText(_ patterns: [HapticPattern]) -> String {
        guard let data = try? encoder().encode(patterns.map(dto(from:))),
              let s = String(data: data, encoding: .utf8) else { return "[]" }
        return s
    }

    /// Parse: accepts a `[PatternDTO]` array or a single `PatternDTO`; out-of-range fields are clamped by `HapticStep` itself.
    static func parse(_ text: String) -> [HapticPattern]? {
        guard let data = text.data(using: .utf8) else { return nil }
        let dec = JSONDecoder()
        if let arr = try? dec.decode([PatternDTO].self, from: data), !arr.isEmpty { return arr.map(pattern(from:)) }
        if let one = try? dec.decode(PatternDTO.self, from: data) { return [pattern(from: one)] }
        return nil
    }

    static func exampleJSON() -> String {
        let example = [
            PatternDTO(name: "My Pattern", steps: [
                StepDTO(timbre: "crisp", strength: 6, dullness: 0.3, gapMs: 120),
                StepDTO(timbre: "buzz",  strength: 9, dullness: 0.8, gapMs: 0),
            ])
        ]
        return (try? encoder().encode(example)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
    }

    // MARK: - File / clipboard

    @MainActor static func exportToFile(_ patterns: [HapticPattern]) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "HapticBreak-patterns.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? exportText(patterns).data(using: .utf8)?.write(to: url)
    }

    @MainActor static func importFromFile() -> [HapticPattern]? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url,
              let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return parse(text)
    }

    static func copyToClipboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    static func clipboardText() -> String? { NSPasteboard.general.string(forType: .string) }
}
