import os

/// Unified runtime logging. Inspect with:
/// `log stream --predicate 'subsystem == "com.aremind.hapticbreak"'`
///
/// Scope: runtime errors/notices that matter for field diagnosis. CLI diagnostic paths
/// (`--selftest` / `--hapticscan` with `debug: true`) intentionally keep printing to the terminal
/// instead — their output must be visible in the invoking shell.
enum Log {
    private static let subsystem = "com.aremind.hapticbreak"
    static let haptics = Logger(subsystem: subsystem, category: "haptics")
    static let hotkeys = Logger(subsystem: subsystem, category: "hotkeys")
    static let system  = Logger(subsystem: subsystem, category: "system")
    static let updates = Logger(subsystem: subsystem, category: "updates")
}
