import XCTest
import Carbon.HIToolbox
@testable import HapticBreak

/// User-editable global shortcuts: display strings, duplicate detection, persistence and
/// tolerant decoding of the bindings blob.
final class HotKeyBindingTests: HBTestCase {

    func testDisplayUsesSystemGlyphOrder() {
        let combo = HotKeyBinding(keyCode: UInt32(kVK_ANSI_S),
                                  modifiers: UInt32(controlKey) | UInt32(optionKey))
        XCTAssertEqual(combo.display, "⌃⌥S")
        let full = HotKeyBinding(keyCode: UInt32(kVK_Space),
                                 modifiers: UInt32(cmdKey) | UInt32(shiftKey) | UInt32(controlKey) | UInt32(optionKey))
        XCTAssertEqual(full.display, "⌃⌥⇧⌘Space", "modifiers render in ⌃⌥⇧⌘ order")
    }

    func testDefaultBindings() {
        let d = HotKeyBindings.defaults
        XCTAssertEqual(d.pause.display, "⌃⌥Space")
        XCTAssertEqual(d.skip.display, "⌃⌥S")
        XCTAssertEqual(d.buzz.display, "⌃⌥B")
        XCTAssertEqual(d.acknowledge.display, "⌃⌥⏎")
        XCTAssertTrue(d.hasNoDuplicates)
    }

    func testDuplicateDetection() {
        var b = HotKeyBindings.defaults
        b.skip = b.pause
        XCTAssertFalse(b.hasNoDuplicates, "two actions on one combo would make one unreachable")
    }

    func testSettingsPersistenceRoundTrip() {
        let d = makeDefaults()
        let s1 = Settings(defaults: d)
        XCTAssertEqual(s1.hotKeys, .defaults, "fresh suite starts at factory bindings")
        s1.hotKeys.acknowledge = HotKeyBinding(keyCode: UInt32(kVK_ANSI_R),
                                               modifiers: UInt32(cmdKey) | UInt32(shiftKey))
        let s2 = Settings(defaults: d)
        XCTAssertEqual(s2.hotKeys.acknowledge.display, "⇧⌘R", "custom binding reads back")
        XCTAssertEqual(s2.hotKeys.pause, HotKeyBindings.defaults.pause, "untouched bindings stay at defaults")
    }

    func testTolerantDecodingOfPartialBlob() throws {
        // A blob from an older build that only knew some of the actions.
        let json = #"{"pause":{"keyCode":49,"modifiers":6144}}"#
        let decoded = try JSONDecoder().decode(HotKeyBindings.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.pause.keyCode, 49)
        XCTAssertEqual(decoded.acknowledge, HotKeyBindings.defaults.acknowledge,
                       "missing fields fall back to factory defaults")
    }

    func testResetToDefaultsRestoresBindings() {
        let s = makeSettings()
        s.hotKeys.buzz = HotKeyBinding(keyCode: UInt32(kVK_ANSI_9), modifiers: UInt32(cmdKey))
        s.resetToDefaults()
        XCTAssertEqual(s.hotKeys, .defaults)
    }
}
