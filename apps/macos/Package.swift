// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Ampersand",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "AmpersandCore", targets: ["Protocol", "AndroidBridge", "InputCapture", "EdgeSwitch"]),
        .executable(name: "AmpersandApp", targets: ["App"])
    ],
    targets: [
        .target(name: "App", dependencies: ["Protocol", "AndroidBridge", "InputCapture", "EdgeSwitch"]),
        .target(name: "Protocol", dependencies: []),
        .target(name: "AndroidBridge", dependencies: ["Protocol"]),
        .target(name: "InputCapture", dependencies: []),
        .target(name: "EdgeSwitch", dependencies: ["AndroidBridge"]),
        .target(name: "Diagnostics", dependencies: []),
        .target(name: "Settings", dependencies: []),
        .testTarget(name: "ProtocolTests", dependencies: ["Protocol"])
    ]
)
