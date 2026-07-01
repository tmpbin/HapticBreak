import XCTest
@testable import HapticBreak

/// Preference persistence and migration — each test case injects an isolated UserDefaults suite, cleared on exit.
final class SettingsTests: HBTestCase {

    func testFactoryDefaultsOnEmptySuite() {
        let s = makeSettings()
        XCTAssertEqual(s.breakIntervalMinutes, 25)
        XCTAssertEqual(s.strength, 6)
        XCTAssertFalse(s.pomodoroEnabled)
        XCTAssertTrue(s.idleEnabled)
        XCTAssertTrue(s.typingAwareDefer)
        XCTAssertTrue(s.autoUpdateCheck)
        XCTAssertEqual(s.selectedPatternID, HapticPattern.urgent.id)
    }

    func testPersistenceRoundTrip() {
        let d = makeDefaults()
        let s1 = Settings(defaults: d)
        s1.breakIntervalMinutes = 45
        s1.strength = 9
        s1.pomodoroEnabled = true
        let s2 = Settings(defaults: d)
        XCTAssertEqual(s2.breakIntervalMinutes, 45)
        XCTAssertEqual(s2.strength, 9)
        XCTAssertTrue(s2.pomodoroEnabled)
    }

    func testStrengthMigratesFromLegacyIntensity() {
        let d = makeDefaults()
        d.set(3, forKey: "hb.intensity")  // legacy 1…5 strength
        let s = Settings(defaults: d)
        XCTAssertEqual(s.strength, 6, "legacy 3 → ×2 = 6")
        XCTAssertEqual(d.object(forKey: "hb.strength") as? Int, 6, "migration result persisted to the new key")
    }

    func testNewStrengthKeyWinsOverLegacy() {
        let d = makeDefaults()
        d.set(8, forKey: "hb.strength")
        d.set(3, forKey: "hb.intensity")
        let s = Settings(defaults: d)
        XCTAssertEqual(s.strength, 8, "when the new key exists, the legacy key is ignored")
    }

    func testCustomPatternUpsertDeletePersist() {
        let d = makeDefaults()
        let s1 = Settings(defaults: d)
        let p = HapticPattern(id: "custom.unit", name: "Unit", symbol: "waveform",
                              steps: [HapticStep(strength: 6, gapMsAfter: 0)], isBuiltin: false)
        s1.upsertCustomPattern(p)
        XCTAssertEqual(Settings(defaults: d).customPatterns.map(\.id), ["custom.unit"],
                       "custom pattern is persisted and reads back")
        s1.deleteCustomPattern(id: "custom.unit")
        XCTAssertTrue(Settings(defaults: d).customPatterns.isEmpty, "no longer present after deletion")
    }

    func testDeletingSelectedCustomFallsBackToDefault() {
        let s = makeSettings()
        let p = HapticPattern(id: "custom.sel", name: "Sel", symbol: "waveform",
                              steps: [HapticStep(strength: 6, gapMsAfter: 0)], isBuiltin: false)
        s.upsertCustomPattern(p)
        s.selectedPatternID = "custom.sel"
        s.deleteCustomPattern(id: "custom.sel")
        XCTAssertEqual(s.selectedPatternID, HapticPattern.urgent.id,
                       "deleting the currently selected custom pattern → falls back to default")
    }

    func testResetToDefaultsKeepsCustomPatterns() {
        let s = makeSettings()
        s.breakIntervalMinutes = 45
        s.strength = 10
        s.pomodoroEnabled = true
        let p = HapticPattern(id: "custom.keep", name: "Keep", symbol: "waveform",
                              steps: [HapticStep(strength: 6, gapMsAfter: 0)], isBuiltin: false)
        s.upsertCustomPattern(p)

        s.resetToDefaults()

        XCTAssertEqual(s.breakIntervalMinutes, 25)
        XCTAssertEqual(s.strength, 6)
        XCTAssertFalse(s.pomodoroEnabled)
        XCTAssertEqual(s.customPatterns.map(\.id), ["custom.keep"], "restoring defaults does not clear custom patterns")
    }
}
