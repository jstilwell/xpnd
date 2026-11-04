// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "xpnd",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1"),
        .package(url: "https://github.com/jpsim/Yams", exact: "6.2.2"),
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", exact: "1.99.2"),
    ],
    targets: [
        .executableTarget(
            name: "xpnd",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "Yams", package: "Yams"),
                .product(name: "SwiftTerm", package: "SwiftTerm"),
                "xpndRDP",
            ],
            // Sparkle.framework goes in the app's Contents/Frameworks.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        // Static FreeRDP and OpenSSL, built by `make freerdp` (bin/build-freerdp.sh); git-ignored.
        .binaryTarget(name: "FreeRDP", path: "vendor/FreeRDP.xcframework"),
        // The only target that includes FreeRDP's headers.
        .target(
            name: "xpndRDP",
            dependencies: ["FreeRDP"],
            linkerSettings: [
                .linkedFramework("Cocoa"), .linkedFramework("IOKit"),
                .linkedFramework("CoreAudio"), .linkedFramework("AudioToolbox"),
                // FreeRDP decodes H.264 with VideoToolbox (WITH_APPLE_VIDEOTOOLBOX, on by default).
                .linkedFramework("VideoToolbox"),
            ]
        ),
        .testTarget(name: "xpndTests", dependencies: ["xpnd"]),
    ]
)
