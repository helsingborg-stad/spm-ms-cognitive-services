// swift-tools-version:5.5
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "MSCognitiveServices",
    platforms: [.macOS(.v10_15), .iOS(.v13), .tvOS(.v13)],
    products: [
        // Products define the executables and libraries a package produces, and make them visible to other packages.
        .library(
            name: "MSCognitiveServices",
            targets: ["MSCognitiveServices"]),
        .library(
            name: "MicrosoftCognitiveServicesSpeech",
            targets: ["MicrosoftCognitiveServicesSpeech"])
    ],
    dependencies: [
        .package(name: "Shout", url: "https://github.com/helsingborg-stad/spm-shout.git", from: "0.1.0"),
        .package(name: "TextTranslator", url: "https://github.com/helsingborg-stad/spm-text-translator", from: "0.2.0"),
        .package(name: "TTS", url: "https://github.com/helsingborg-stad/spm-tts.git", from: "0.2.0"),
        .package(name: "STT", url: "https://github.com/helsingborg-stad/spm-stt.git", from: "0.2.1"),
        .package(name: "FFTPublisher", url: "https://github.com/helsingborg-stad/spm-fft-publisher.git", from: "0.1.1"),
        .package(name: "AudioSwitchboard", url: "https://github.com/helsingborg-stad/spm-audio-switchboard.git", from: "0.1.2")
    ],
    targets: [
        // Targets are the basic building blocks of a package. A target can define a module or a test suite.
        // Targets can depend on other targets in this package, and on products in packages this package depends on.
        .target(
            name: "MSCognitiveServices",
            dependencies: ["TTS", "FFTPublisher", "MicrosoftCognitiveServicesSpeech", "AudioSwitchboard","Shout", "TextTranslator","STT"]),
        .testTarget(
            name: "MSCognitiveServicesTests",
            dependencies: ["MSCognitiveServices"]),
        .binaryTarget(
            name: "MicrosoftCognitiveServicesSpeech",
            url: "https://github.com/tomasgreen/MSSpeechServiceXCFramework/blob/versoon-1.18.0/MicrosoftCognitiveServicesSpeech.xcframework.zip?raw=true",
            checksum: "5e4aca1600fdd5dc79e9facb1c7a40d0262606ac20b51e3eec069b2f78dd8d04"
        )
    ]
)
