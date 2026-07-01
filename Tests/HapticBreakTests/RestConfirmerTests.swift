import XCTest
@testable import HapticBreak

/// CR-04 "honest rest": only count one real rest if you "actually leave" after a reminder (idle reaches the threshold, within the window).
final class RestConfirmerTests: XCTestCase {

    func testLeavingWithoutFireDoesNotCount() {
        var rc = RestConfirmer()
        let t0 = Date()
        XCTAssertFalse(rc.tick(idleSeconds: 100, now: t0), "leaving without a reminder isn't counted as a rest")
    }

    func testCountsOnceWhenTrulyAway() {
        var rc = RestConfirmer()
        let t0 = Date()
        rc.didFire(at: t0)
        XCTAssertFalse(rc.tick(idleSeconds: 0, now: t0.addingTimeInterval(5)),
                       "still active after a reminder → not counted")
        XCTAssertTrue(rc.tick(idleSeconds: 30, now: t0.addingTimeInterval(20)),
                      "actually left after a reminder → count one real rest")
        XCTAssertFalse(rc.tick(idleSeconds: 60, now: t0.addingTimeInterval(25)),
                       "only counted once per reminder")
    }

    func testWindowExpiryVoidsThisFire() {
        var rc = RestConfirmer()
        let t0 = Date()
        rc.didFire(at: t0)
        XCTAssertFalse(rc.tick(idleSeconds: 0, now: t0.addingTimeInterval(121)),
                       "still not left past the window → this one is void")
        XCTAssertFalse(rc.tick(idleSeconds: 60, now: t0.addingTimeInterval(130)),
                       "leaving after voiding doesn't back-fill a count")
    }
}
