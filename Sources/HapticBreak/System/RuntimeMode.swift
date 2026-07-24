import Foundation

/// Runtime mode decision: centrally decides whether shared singletons (`Settings.shared` /
/// `StatisticsStore.shared`) should use "real storage" or "ephemeral storage".
///
/// Motivation: some headless/demo entry points write state to disk — `--demo` invokes the full app
/// (writing statistics, preferences like `hasLaunchedBefore`, etc.). Those processes should not pollute
/// the user's real preferences and statistics. This decides it in one place, so singletons land on
/// in-process-isolated, discard-on-exit temporary storage in ephemeral runs.
///
/// Notes:
/// - `--logictest` doesn't rely on this; instead it injects an isolated `Settings` directly in `runLogicTests()`.
/// - `--checkenv` is a read-only entry (no disk writes), so it uses real storage for an honest environment check.
/// - Unit tests don't go through `shared`; they inject an `InMemoryKeyValueStore` / temp file path directly.
enum RuntimeMode {

    /// Whether this is an "ephemeral run" — shared singletons should use temporary, in-process-isolated,
    /// discard-on-exit storage.
    /// `--rendershots` is included because it overwrites `Settings.shared` with representative
    /// "fresh install" values before rendering — run against the packaged .app, that would clobber
    /// the user's real preferences without this isolation.
    static let isEphemeral: Bool = {
        CommandLine.arguments.contains("--demo")
            || CommandLine.arguments.contains("--rendershots")
    }()

    /// The single shared preference store behind every preference singleton (`Settings` /
    /// `HapticProfile` / `L10n`, plus the quiet-scene state persisted via `Settings`): normally
    /// `.standard`, one shared in-memory instance for ephemeral runs. No preference persistence may
    /// bypass this to `UserDefaults.standard` directly — that would silently punch a hole in the
    /// ephemeral isolation.
    static let preferenceStore: KeyValueStore =
        isEphemeral ? InMemoryKeyValueStore() : UserDefaults.standard

    /// Preference storage choice for the preference singletons (see `preferenceStore`).
    static func settingsDefaults() -> KeyValueStore { preferenceStore }

    /// Statistics file choice for `StatisticsStore.shared`: normally App Support, ephemeral runs use a temp directory.
    static func statsFileURL() -> URL {
        guard isEphemeral else { return StatisticsStore.defaultFileURL() }
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("HapticBreak-ephemeral-\(ProcessInfo.processInfo.processIdentifier)",
                                    isDirectory: true)
            .appendingPathComponent("statistics.json")
    }
}
