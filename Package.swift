// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "QuickVoiceInput",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "QuickVoice", targets: ["QuickVoice"]),
    ],
    targets: [
        .target(name: "QuickVoiceCore"),
        .executableTarget(
            name: "QuickVoice",
            dependencies: ["QuickVoiceCore"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("Carbon"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("SwiftUI"),
            ]
        ),
        .testTarget(name: "QuickVoiceCoreTests", dependencies: ["QuickVoiceCore"]),
    ]
)
