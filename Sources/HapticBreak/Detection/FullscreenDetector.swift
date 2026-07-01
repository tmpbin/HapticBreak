import AppKit

/// Detects whether the frontmost app is in fullscreen (presentation / video / game) state.
///
/// Principle: a native fullscreen window fully covers a screen (including the menu-bar area). Using
/// `CGWindowList` to read the frontmost process's window bounds (bounds and ownerPID are available without
/// Screen Recording permission), if its size is approximately equal to a screen's full size, it's judged
/// fullscreen.
enum FullscreenDetector {

    static func isFrontmostFullscreen() -> Bool {
        guard let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier else {
            return false
        }
        // Ignore Finder (desktop) and ourselves.
        let ourPID = ProcessInfo.processInfo.processIdentifier
        if frontPID == ourPID { return false }

        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let infoList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return false
        }

        let screenSizes = NSScreen.screens.map { $0.frame.size }

        for window in infoList {
            guard let owner = window[kCGWindowOwnerPID as String] as? pid_t, owner == frontPID,
                  let layer = window[kCGWindowLayer as String] as? Int, layer == 0,
                  let boundsDict = window[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
            else { continue }

            for size in screenSizes where coversFull(bounds.size, screen: size) {
                return true
            }
        }
        return false
    }

    private static func coversFull(_ windowSize: CGSize, screen: CGSize, tolerance: CGFloat = 2) -> Bool {
        abs(windowSize.width - screen.width) <= tolerance &&
        abs(windowSize.height - screen.height) <= tolerance
    }
}
