import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {

    private let controller = AppController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller.start()
        // Start in-app auto-update (Sparkle). Safely self-disables internally when no public key is configured.
        _ = UpdaterController.shared
        if CommandLine.arguments.contains("--demo") {
            controller.runDemo()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.applicationWillTerminate()
    }
}
