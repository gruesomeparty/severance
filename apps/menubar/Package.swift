// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Severance",
    platforms: [.macOS(.v14)],
    targets: [
        // Pure data + logic (no SwiftUI) so it is unit-testable headlessly.
        .target(
            name: "SeveranceCore",
            path: "Sources/SeveranceCore"
        ),
        // The MenuBarExtra app.
        .executableTarget(
            name: "Severance",
            dependencies: ["SeveranceCore"],
            path: "Sources/Severance"
        ),
        .testTarget(
            name: "SeveranceTests",
            dependencies: ["SeveranceCore"],
            path: "Tests/SeveranceTests"
        ),
    ]
)
