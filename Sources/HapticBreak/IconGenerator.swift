import AppKit

/// Programmatically draw the app icon with Core Graphics (no external assets needed).
/// Generate the 1024×1024 primary artwork via `HapticBreak --makeicon <out.png>`, then build.sh converts it to .icns.
func makeAppIcon(to path: String) -> Int32 {
    let size: CGFloat = 1024
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()

    // Background: rounded square (squircle approximation) + indigo→blue gradient
    let margin: CGFloat = 86
    let rect = CGRect(x: margin, y: margin, width: size - 2 * margin, height: size - 2 * margin)
    let radius = rect.width * 0.2237
    let squircle = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    let gradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.46, green: 0.40, blue: 0.96, alpha: 1.0),
        NSColor(calibratedRed: 0.28, green: 0.62, blue: 0.98, alpha: 1.0)
    ])!
    gradient.draw(in: squircle, angle: -90)

    // Primary visual: white "hand.tap.fill" (a finger tap + ripples above, matching "trackpad haptic reminder")
    let config = NSImage.SymbolConfiguration(pointSize: 470, weight: .semibold)
    if let symbol = NSImage(systemSymbolName: "hand.tap.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(config) {
        let tinted = tint(symbol, with: .white)
        let s = tinted.size
        let origin = CGPoint(x: (size - s.width) / 2, y: (size - s.height) / 2 - 12)
        tinted.draw(in: CGRect(origin: origin, size: s))
    }

    image.unlockFocus()

    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else {
        FileHandle.standardError.write("makeAppIcon: failed to generate PNG data\n".data(using: .utf8)!)
        return 1
    }
    do {
        try png.write(to: URL(fileURLWithPath: path))
        print("icon written: \(path)")
        return 0
    } catch {
        FileHandle.standardError.write("makeAppIcon: write failed \(error)\n".data(using: .utf8)!)
        return 1
    }
}

private func tint(_ image: NSImage, with color: NSColor) -> NSImage {
    let result = NSImage(size: image.size)
    result.lockFocus()
    color.set()
    let bounds = NSRect(origin: .zero, size: image.size)
    image.draw(in: bounds)
    bounds.fill(using: .sourceAtop)
    result.unlockFocus()
    return result
}
