// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "HapticBreak",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "HapticBreak", targets: ["HapticBreak"])
    ],
    dependencies: [
        // 应用内自动升级（EdDSA 签名 appcast + GitHub Releases）。
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0")
    ],
    targets: [
        .executableTarget(
            name: "HapticBreak",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources/HapticBreak"
        ),
        .testTarget(
            name: "HapticBreakTests",
            dependencies: ["HapticBreak"],
            path: "Tests/HapticBreakTests"
        )
    ]
)
