// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "CodexSwitch",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "CodexSwitch", targets: ["CodexSwitch"])
    ],
    targets: [
        .executableTarget(
            name: "CodexSwitch",
            path: "Sources/CodexSwitch"
        ),
        .testTarget(
            name: "CodexSwitchTests",
            dependencies: ["CodexSwitch"],
            path: "Tests/CodexSwitchTests"
        )
    ]
)

