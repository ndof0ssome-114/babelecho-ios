// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "BabelEchoCoreChecks",
    platforms: [.macOS(.v13)],
    products: [.library(name: "BabelEchoCoreChecks", targets: ["BabelEchoCoreChecks"])],
    targets: [
        .target(name: "BabelEchoCoreChecks", path: "BabelEcho",
            exclude: ["AppModel.swift", "AudioRecorder.swift", "BabelEchoApp.swift", "ContentView.swift", "DisplayCapture.swift", "Info.plist", "MeetingStore.swift", "Assets.xcassets"],
            sources: ["Models.swift", "CloudClient.swift", "WAVWriter.swift", "MediaImporter.swift"]),
        .testTarget(name: "BabelEchoCoreChecksTests", dependencies: ["BabelEchoCoreChecks"], path: "Tests")
    ]
)
