// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NexVoice",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "NexVoice", targets: ["NexVoice"])
    ],
    targets: [
        .executableTarget(
            name: "NexVoice",
            path: "Sources/NexVoice",
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "NexVoiceTests",
            dependencies: ["NexVoice"],
            path: "Tests/NexVoiceTests"
        )
    ]
)
