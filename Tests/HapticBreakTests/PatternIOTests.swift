import XCTest
@testable import HapticBreak

/// Import/export of custom patterns and clamping of out-of-range fields (human/AI-friendly compact JSON).
final class PatternIOTests: XCTestCase {

    func testExportParseRoundTrip() {
        let p = HapticPattern(
            id: "custom.x", name: "Test", symbol: "waveform",
            steps: [
                HapticStep(timbre: .buzz, strength: 9, dullness: 0.8, gapMsAfter: 120),
                HapticStep(timbre: .crisp, strength: 3, dullness: 0.2, gapMsAfter: 0),
            ],
            isBuiltin: false)
        let back = PatternIO.parse(PatternIO.exportText([p]))
        XCTAssertEqual(back?.count, 1)
        XCTAssertEqual(back?[0].steps.map(\.timbre), [.buzz, .crisp])
        XCTAssertEqual(back?[0].steps.map(\.strength), [9, 3])
        XCTAssertEqual(back?[0].steps.map(\.gapMsAfter), [120, 0])
        XCTAssertEqual(back?[0].steps[0].dullness ?? 0, 0.8, accuracy: 0.001)
    }

    func testParseClampsOutOfRangeFields() {
        let json = #"[{"name":"X","steps":[{"timbre":"crisp","strength":99,"dullness":5,"gapMs":-10}]}]"#
        let step = PatternIO.parse(json)?.first?.steps.first
        XCTAssertEqual(step?.strength, HapticProfile.strengthLevels, "strength clamped to the upper bound")
        XCTAssertEqual(step?.dullness ?? -1, 1.0, accuracy: 0.001, "dullness clamped to 1.0")
        XCTAssertEqual(step?.gapMsAfter, 0, "negative gap clamped to 0")
    }

    func testParseAcceptsSingleObject() {
        let json = #"{"name":"Solo","steps":[{"timbre":"soft","strength":4,"dullness":0.3,"gapMs":80}]}"#
        XCTAssertEqual(PatternIO.parse(json)?.count, 1, "a single object parses too")
    }

    func testParseInvalidReturnsNil() {
        XCTAssertNil(PatternIO.parse("not json at all"))
        XCTAssertNil(PatternIO.parse(""))
    }

    func testEmptyStepsGetsDefaultStep() {
        let json = #"[{"name":"Empty","steps":[]}]"#
        XCTAssertEqual(PatternIO.parse(json)?.first?.steps.count, 1, "an empty step sequence gets one default step")
    }

    func testUnknownTimbreFallsBackToCrisp() {
        let json = #"[{"name":"Weird","steps":[{"timbre":"nope","strength":5,"dullness":0.3,"gapMs":0}]}]"#
        XCTAssertEqual(PatternIO.parse(json)?.first?.steps.first?.timbre, .crisp)
    }
}
