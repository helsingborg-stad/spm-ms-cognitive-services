// swift-tools-version:5.5
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "MSCognitiveServices",
    platforms: [.macOS(.v10_15), .iOS(.v13), .tvOS(.v13)],
    products: [
        .library(
            name: "MSCognitiveServices",
            targets: ["MSCognitiveServices"]),
        .library(
            name: "MicrosoftCognitiveServicesSpeech",
            targets: ["MicrosoftCognitiveServicesSpeech"])
    ],
    dependencies: [
        .package(name: "Shout", url: "https://github.com/helsingborg-stad/spm-shout.git", from: "0.1.3"),
        .package(name: "TextTranslator", url: "https://github.com/helsingborg-stad/spm-text-translator", from: "0.2.1"),
        .package(name: "TTS", url: "https://github.com/helsingborg-stad/spm-tts.git", from: "0.2.2"),
        .package(name: "STT", url: "https://github.com/helsingborg-stad/spm-stt.git", from: "0.2.3"),
        .package(name: "FFTPublisher", url: "https://github.com/helsingborg-stad/spm-fft-publisher.git", from: "0.1.2"),
        .package(name: "AudioSwitchboard", url: "https://github.com/helsingborg-stad/spm-audio-switchboard.git", from: "0.1.3")
    ],
    targets: [
        .target(
            name: "MSCognitiveServices",
            dependencies: ["TTS", "FFTPublisher", "MicrosoftCognitiveServicesSpeech", "AudioSwitchboard","Shout", "TextTranslator","STT"]),
        .testTarget(
            name: "MSCognitiveServicesTests",
            dependencies: ["MSCognitiveServices"]),
        .binaryTarget(
            name: "MicrosoftCognitiveServicesSpeech",
            url: "https://csspeechstorage.blob.core.windows.net/drop/1.19.0/MicrosoftCognitiveServicesSpeech-XCFramework-1.19.0.zip",
            checksum: "077cf2c2ff5d70c62d4ada90b80c0fc3b8bc59818b4eeaae5b1b28c48e4ddab4"
        )
    ]
)
