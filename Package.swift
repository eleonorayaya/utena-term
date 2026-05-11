// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "utena-term",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "utena-term",
            dependencies: ["GhosttyVt"],
            path: "Sources/UtenaTerm",
            linkerSettings: [
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("ImageIO"),
            ]
        ),
        .binaryTarget(name: "GhosttyVt", path: "Frameworks/ghostty-vt.xcframework"),
        .testTarget(
            name: "UtenaTermTests",
            dependencies: ["utena-term"],
            path: "Tests/UtenaTermTests"
        ),
    ]
)
