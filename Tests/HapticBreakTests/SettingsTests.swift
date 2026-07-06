import XCTest
@testable import HapticBreak

/// Preference persistence and migration — each test case injects an isolated UserDefaults suite, cleared on exit.
final class SettingsTests: HBTestCase {

    func testFactoryDefaultsOnEmptySuite() {
        let s = makeSettings()
        XCTAssertEqual(s.breakIntervalMinutes, 25)
        XCTAssertEqual(s.restMinutes, 0, "default is reminder-only (no timed rest segment)")
        XCTAssertEqual(s.strength, 6)
        XCTAssertEqual(s.remindPulseSeconds, 20)
        XCTAssertEqual(s.remindPulseMax, 4)
        XCTAssertTrue(s.ackGestureEnabled)
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
        s1.restMinutes = 5
        s1.ackGestureEnabled = false
        let s2 = Settings(defaults: d)
        XCTAssertEqual(s2.breakIntervalMinutes, 45)
        XCTAssertEqual(s2.strength, 9)
        XCTAssertEqual(s2.restMinutes, 5)
        XCTAssertFalse(s2.ackGestureEnabled)
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

    func testLegacyPomodoroOnMigratesToUnifiedCycle() {
        let d = makeDefaults()
        d.set(true, forKey: "hb.pomodoro")
        d.set(52, forKey: "hb.pomoWork")
        d.set(17, forKey: "hb.pomoBreak")
        let s = Settings(defaults: d)
        XCTAssertEqual(s.breakIntervalMinutes, 45, "old work length snaps to the nearest selectable interval")
        XCTAssertEqual(s.restMinutes, 17, "old break length becomes the rest segment")
        XCTAssertNil(d.object(forKey: "hb.pomodoro"), "legacy keys removed after migration")
        XCTAssertNil(d.object(forKey: "hb.pomoWork"))
        XCTAssertNil(d.object(forKey: "hb.pomoBreak"))
    }

    func testLegacyPomodoroOffMigratesToReminderOnly() {
        let d = makeDefaults()
        d.set(false, forKey: "hb.pomodoro")
        d.set(25, forKey: "hb.pomoWork")
        let s = Settings(defaults: d)
        XCTAssertEqual(s.restMinutes, 0, "pomodoro off → pure reminder (no rest segment)")
        XCTAssertNil(d.object(forKey: "hb.pomodoro"))
    }

    func testMigrationDoesNotOverrideExistingRestMinutes() {
        let d = makeDefaults()
        d.set(10, forKey: "hb.restMinutes")
        d.set(true, forKey: "hb.pomodoro")
        d.set(50, forKey: "hb.pomoWork")
        let s = Settings(defaults: d)
        XCTAssertEqual(s.restMinutes, 10, "an already-migrated suite is left untouched")
        XCTAssertEqual(s.breakIntervalMinutes, 25, "interval keeps its default; migration ran once before")
        XCTAssertNil(d.object(forKey: "hb.pomodoro"), "leftover legacy keys are still cleaned up")
    }

    func testRetiredKeysAreCleanedUp() {
        let d = makeDefaults()
        d.set(3, forKey: "hb.reminderRepeat")
        d.set(true, forKey: "hb.escalation")
        _ = Settings(defaults: d)
        XCTAssertNil(d.object(forKey: "hb.reminderRepeat"), "retired repeat-count key removed")
        XCTAssertNil(d.object(forKey: "hb.escalation"), "retired escalation key removed")
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

    func testStoredIDForRemovedBuiltinFallsBackToDefault() {
        let d = makeDefaults()
        d.set("builtin.waltz", forKey: "hb.pattern")           // removed in the preset lineup rework
        d.set("builtin.breathe", forKey: "hb.finishPattern")   // removed in the preset lineup rework
        d.set(HapticPattern.gentle.id, forKey: "hb.headsUpPattern")  // still exists → kept
        let s = Settings(defaults: d)
        XCTAssertEqual(s.selectedPatternID, HapticPattern.urgent.id)
        XCTAssertEqual(s.finishPatternID, HapticPattern.ramp.id)
        XCTAssertEqual(s.headsUpPatternID, HapticPattern.gentle.id)
    }

    func testResetToDefaultsKeepsCustomPatterns() {
        let s = makeSettings()
        s.breakIntervalMinutes = 45
        s.strength = 10
        s.restMinutes = 5
        s.remindPulseMax = 8
        let p = HapticPattern(id: "custom.keep", name: "Keep", symbol: "waveform",
                              steps: [HapticStep(strength: 6, gapMsAfter: 0)], isBuiltin: false)
        s.upsertCustomPattern(p)

        s.resetToDefaults()

        XCTAssertEqual(s.breakIntervalMinutes, 25)
        XCTAssertEqual(s.strength, 6)
        XCTAssertEqual(s.restMinutes, 0)
        XCTAssertEqual(s.remindPulseMax, 4)
        XCTAssertEqual(s.customPatterns.map(\.id), ["custom.keep"], "restoring defaults does not clear custom patterns")
    }
}
