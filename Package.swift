// swift-tools-version: 5.9
import PackageDescription

// Test the production stores and safety helpers without launching the app.
let package = Package(
    name: "CleanupSafety",
    platforms: [.macOS(.v14)],
    products: [.library(name: "CleanupCore", targets: ["CleanupCore"])],
    targets: [
        .target(name: "CleanupCore", path: "Sources", exclude: ["CleanUpForMacOSApp.swift"]),
        .testTarget(name: "CleanupCoreTests", dependencies: ["CleanupCore"], path: "Tests")
    ]
)
