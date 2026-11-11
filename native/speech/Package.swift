// swift-tools-version: 6.2
// mb-speech: meetingbox's speech helper. Built by `meetingbox setup` with `swift build`, every
// SwiftPM cache and clone in setup's temporary folder. FluidAudio is pinned exactly, with only
// the Diarizer trait (ASR is always built): no text to speech, no downloaded text normaliser.
import PackageDescription

let package = Package(
    name: "mb-speech",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.18.3", traits: ["Diarizer"]),
    ],
    targets: [
        .executableTarget(
            name: "mb-speech",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
            path: "Sources/mb-speech",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
