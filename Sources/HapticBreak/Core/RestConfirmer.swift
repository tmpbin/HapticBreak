import Foundation

/// "Honest rest" decision: a real break is counted only when, after a reminder fires, you **actually
/// step away briefly** (no input for a while) — not "as soon as the reminder sounds it counts as rest".
/// This makes streak / statistics reflect real behavior.
///
/// Pure logic; `now` is injectable for deterministic testing.
struct RestConfirmer {
    /// Time window to wait for "stepping away" after a reminder: beyond it, this one didn't truly rest.
    var window: TimeInterval = 120
    /// No-input seconds threshold considered "truly stepped away".
    var idleThreshold: TimeInterval = 30

    private var pendingSince: Date?

    var isPending: Bool { pendingSince != nil }

    /// Reminder fired: start waiting for "stepped away" confirmation.
    mutating func didFire(at now: Date = Date()) {
        pendingSince = now
    }

    /// The reminder was abandoned without resting (skip / postpone / auto-postpone / quiet scene):
    /// void the pending window, so a later idle spell can't count a rest the user explicitly declined.
    mutating func cancel() {
        pendingSince = nil
    }

    /// Call every second. Returns `true` when "a real rest is confirmed", at which point the caller
    /// should record a break.
    mutating func tick(idleSeconds: TimeInterval, now: Date = Date()) -> Bool {
        guard let since = pendingSince else { return false }
        if now.timeIntervalSince(since) > window {
            pendingSince = nil          // Never stepped away within the window → this one isn't a real rest
            return false
        }
        if idleSeconds >= idleThreshold {
            pendingSince = nil          // Actually stepped away after the reminder → count a real rest
            return true
        }
        return false
    }
}
