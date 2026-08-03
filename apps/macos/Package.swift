// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Ampersand",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "AmpersandCore", targets: ["Protocol", "AndroidBridge", "InputCapture", "EdgeSwitch"]),
        .executable(name: "AmpersandApp", targets: ["App"]),
        .executable(name: "cxi-smoke", targets: ["SmokeMain"])
    ],
    targets: [
        .target(name: "App", dependencies: ["Protocol", "AndroidBridge", "InputCapture", "EdgeSwitch", "AppSettings"]),
        .executableTarget(name: "SmokeMain", dependencies: ["Protocol", "AndroidBridge"], path: "Tools/SmokeMain"),
        .target(name: "Protocol", dependencies: []),
        .target(name: "AndroidBridge", dependencies: ["Protocol"]),
        .target(name: "InputCapture", dependencies: ["EdgeSwitch", "Diagnostics"]),
        .target(name: "EdgeSwitch", dependencies: ["AndroidBridge"]),
        .target(name: "Diagnostics", dependencies: []),
        .target(name: "AppSettings", dependencies: []),
        .testTarget(name: "ProtocolTests", dependencies: ["Protocol"])
    ]
)
