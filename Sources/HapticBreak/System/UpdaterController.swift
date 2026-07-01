import AppKit
import Sparkle

/// In-app automatic updates (Sparkle 2).
///
/// Instantiated by `AppDelegate` only during a normal run — CLI paths like `--logictest` exit before
/// `NSApp.run()`, and offscreen rendering doesn't go through `AppDelegate`, so neither touches Sparkle,
/// eliminating background-check side effects.
///
/// When the EdDSA public key (`SUPublicEDKey`) is missing, the updater **does not start**: this avoids a
/// "missing configuration" warning on first launch and hides the "Check for Updates" entry. Once the
/// public key is configured (see `packaging/autoupdate/setup-keys.sh`), it becomes available automatically.
final class UpdaterController: NSObject {

    static let shared = UpdaterController()

    private let controller: SPUStandardUpdaterController?

    /// Whether it's configured and available (a valid public key is embedded). The UI uses this to decide
    /// whether to show the update entry.
    var isConfigured: Bool { controller != nil }

    private override init() {
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String
        if let key, !key.isEmpty {
            controller = SPUStandardUpdaterController(
                startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        } else {
            controller = nil
            NSLog("HapticBreak: update public key (SUPublicEDKey) not configured; in-app updates disabled. "
                + "Run packaging/autoupdate/setup-keys.sh to generate keys, then repackage to enable.")
        }
        super.init()
        applyAutoCheck()
        NotificationCenter.default.addObserver(
            self, selector: #selector(applyAutoCheck), name: .hbSettingsChanged, object: nil)
    }

    /// Sync the "automatically check for updates" preference to Sparkle (Sparkle also persists this state itself).
    @objc private func applyAutoCheck() {
        controller?.updater.automaticallyChecksForUpdates = Settings.shared.autoUpdateCheck
    }

    /// Manually check for updates (triggered by the menu / settings button).
    @objc func checkForUpdates(_ sender: Any?) {
        controller?.checkForUpdates(sender)
    }
}
