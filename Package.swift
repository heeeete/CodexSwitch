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
    dependencies: [
        // 업데이트 설치와 검증을 담당하는 프레임워크 버전을 고정한다.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.6")
    ],
    targets: [
        .executableTarget(
            name: "CodexSwitch",
            dependencies: ["Sparkle"],
            path: "Sources/CodexSwitch",
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])
            ]
        ),
        .testTarget(
            name: "CodexSwitchTests",
            dependencies: ["CodexSwitch"],
            path: "Tests/CodexSwitchTests"
        )
    ]
)
