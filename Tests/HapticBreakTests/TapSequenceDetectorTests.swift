import XCTest
@testable import HapticBreak

/// Three-finger triple-tap recognition — pure logic driven with synthetic contact frames.
/// The load-bearing scenarios are the resting-contact ones: the previous "all fingers up" episode
/// model could not recognize the gesture at all while a thumb or palm stayed on the trackpad.
final class TapSequenceDetectorTests: HBTestCase {

    private var detector = TapSequenceDetector()
    private var fired = 0

    /// Feed one contact frame at an absolute time.
    private func frame(_ count: Int, at time: Double) {
        if detector.handleFrame(fingerCount: count, timestamp: time) { fired += 1 }
    }

    /// One quick tap: rise to `peak` at `start`, release back to `resting` 0.1 s later.
    private func tap(peak: Int, resting: Int = 0, at start: Double) {
        frame(peak, at: start)
        frame(resting, at: start + 0.1)
    }

    func testCleanTripleTapFires() {
        tap(peak: 3, at: 0.0)
        tap(peak: 3, at: 0.4)
        tap(peak: 3, at: 0.8)
        XCTAssertEqual(fired, 1)
    }

    func testRestingThumbNoLongerBlocksTheGesture() {
        // A thumb parked on the trackpad: the count never returns to zero, which made the old
        // "first finger down → all fingers up" model completely blind to the taps on top.
        frame(1, at: 0.0)              // thumb lands…
        frame(1, at: 0.7)              // …lingers past tap length → absorbed as the baseline
        tap(peak: 4, resting: 1, at: 1.0)
        tap(peak: 4, resting: 1, at: 1.4)
        tap(peak: 4, resting: 1, at: 1.8)
        XCTAssertEqual(fired, 1, "three-finger taps on top of a resting thumb must fire")
    }

    func testTapsOnTopOfRestingFingersFire() {
        // Two fingers resting to feel the buzz (the product's own posture), tapping with three more.
        frame(2, at: 0.0)
        frame(2, at: 0.7)
        tap(peak: 5, resting: 2, at: 1.0)
        tap(peak: 5, resting: 2, at: 1.45)
        tap(peak: 5, resting: 2, at: 1.9)
        XCTAssertEqual(fired, 1)
    }

    func testPreexistingRestIsAbsorbedThenLiftAndTapFires() {
        frame(3, at: 0.0)              // monitor starts while three fingers already rest on the pad
        frame(3, at: 0.7)              // absorbed as baseline
        frame(0, at: 1.0)              // hand lifts to begin tapping — baseline follows down
        tap(peak: 3, at: 1.2)
        tap(peak: 3, at: 1.6)
        tap(peak: 3, at: 2.0)
        XCTAssertEqual(fired, 1)
    }

    func testSmallBlipBetweenTapsDoesNotReset() {
        tap(peak: 3, at: 0.0)
        tap(peak: 1, at: 0.35)         // single-finger blip (palm flicker) — noise, not a reset
        tap(peak: 3, at: 0.6)
        tap(peak: 3, at: 1.0)
        XCTAssertEqual(fired, 1)
    }

    func testSlowPressResetsTheSequenceButAFreshOneStillFires() {
        tap(peak: 3, at: 0.0)
        tap(peak: 3, at: 0.4)
        frame(3, at: 0.8)              // three fingers pressed and held — a failed tap attempt
        frame(3, at: 1.5)              // held past tap length → sequence resets
        frame(0, at: 1.6)
        tap(peak: 3, at: 1.8)
        XCTAssertEqual(fired, 0, "a held press must not complete the sequence")
        tap(peak: 3, at: 2.2)
        tap(peak: 3, at: 2.6)
        XCTAssertEqual(fired, 1, "a fresh full sequence after the reset still fires")
    }

    func testStaleSequenceExpires() {
        tap(peak: 3, at: 0.0)
        tap(peak: 3, at: 0.4)
        tap(peak: 3, at: 2.5)          // a 2 s pause — the sequence expired, this starts a new one
        XCTAssertEqual(fired, 0)
    }

    func testTwoFingerTapsDoNotFire() {
        tap(peak: 2, at: 0.0)
        tap(peak: 2, at: 0.4)
        tap(peak: 2, at: 0.8)
        XCTAssertEqual(fired, 0)
    }
}
