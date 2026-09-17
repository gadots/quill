// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "quill",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.7.0"),
    ],
    targets: [
        // Pure-Foundation logic: transcript model and rendering, session
        // metadata, segment grouping, config. Split out from the executable so
        // it can be imported by tests — an executable target can't be. Nothing
        // here touches AVFoundation, Core Audio or AppKit, so it builds and
        // tests anywhere, in seconds.
        .target(name: "QuillCore"),
        .executableTarget(
            name: "quill",
            dependencies: [
                "QuillCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            exclude: ["Info.plist"],
            linkerSettings: [
                // Embed Info.plist into the binary so TCC can attribute the
                // system-audio-capture permission to quill itself when it
                // runs as a LaunchAgent (no .app bundle to carry a plist).
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/quill/Info.plist",
                ]),
            ]
        ),
        .testTarget(name: "QuillCoreTests", dependencies: ["QuillCore"]),
    ]
)
