// swift-tools-version:5.6
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
        .package(url: "https://github.com/helsingborg-stad/spm-daisy", from: "1.0.0"),
        .package(url: "https://github.com/tomasgreen/AsyncPublisher", from: "0.1.1")
    ],
    targets: [
        .target(
            name: "MSCognitiveServices",
            dependencies: [
                .product(
                    name: "TTS",
                    package: "spm-daisy"
                ),
                .product(
                    name: "STT",
                    package: "spm-daisy"
                ),
                .product(
                    name: "TextTranslator",
                    package: "spm-daisy"
                ),
                .product(
                    name: "AudioSwitchboard",
                    package: "spm-daisy"
                ),
                .product(
                    name: "Shout",
                    package: "spm-daisy"
                ),
                .product(
                    name: "AsyncPublisher",
                    package: "AsyncPublisher"
                ),
                .product(
                    name: "FFTPublisher",
                    package: "spm-daisy"
                ),
                .byName(name: "MicrosoftCognitiveServicesSpeech")
            ]),
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
