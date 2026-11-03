// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "xpnd",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1"),
        .package(url: "https://github.com/jpsim/Yams", exact: "6.2.2"),
    ],
    targets: [
        .executableTarget(
            name: "xpnd",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "Yams", package: "Yams"),
            ],
            // Sparkle.framework goes in the app's Contents/Frameworks.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
    ]
)
