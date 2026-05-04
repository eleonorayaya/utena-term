// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "utena-term",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "utena-term", dependencies: ["GhosttyVt"], path: "Sources/UtenaTerm"),
        .binaryTarget(name: "GhosttyVt", path: "Frameworks/ghostty-vt.xcframework"),
    ]
)
