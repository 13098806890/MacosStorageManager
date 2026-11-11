// swift-tools-version: 5.9
import PackageDescription

// Test the production stores and safety helpers without launching the app.
let package = Package(
    name: "CleanupSafety",
    platforms: [.macOS(.v14)],
    products: [.library(name: "CleanupCore", targets: ["CleanupCore"])],
    targets: [
        .target(name: "CleanupCore", path: "Sources", exclude: ["App/CleanUpForMacOSApp.swift", "Features/Cleanup/CleanupViews.swift", "Features/Homebrew/HomebrewManagerView.swift", "Features/Simulator/SimulatorManagerViews.swift"]),
        .testTarget(name: "CleanupCoreTests", dependencies: ["CleanupCore"], path: "Tests")
    ]
)
