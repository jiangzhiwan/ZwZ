// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "zwz",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "zwz", targets: ["zwz"]),
        .library(name: "ZwzCore", targets: ["ZwzCore"]),
        .executable(name: "ZwzGUI", targets: ["ZwzGUI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/krzyzanowskim/CryptoSwift.git", from: "1.8.0"),
        // Pure Swift ZIP read/write with AES encryption support
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.4.0"),
        // Pure Swift TAR, GZIP, BZIP2, LZMA, 7Z decompression
        .package(url: "https://github.com/tsolomko/SWCompression.git", branch: "develop"),
    ],
    targets: [
        .target(
            name: "ZwzCore",
            dependencies: [
                .product(name: "CryptoSwift", package: "CryptoSwift"),
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
                .product(name: "SWCompression", package: "SWCompression"),
            ],
            path: "Sources/ZwzCore"
        ),
        .executableTarget(
            name: "zwz",
            dependencies: ["ZwzCore"],
            path: "Sources/zwz"
        ),
        .executableTarget(
            name: "ZwzGUI",
            dependencies: ["ZwzCore"],
            path: "Sources/ZwzGUI",
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "ZwzCoreTests",
            dependencies: ["ZwzCore"],
            path: "Tests/ZwzCoreTests",
            resources: [
                .copy("Fixtures")
            ]
        ),
        .testTarget(
            name: "ZwzGUITests",
            dependencies: ["ZwzGUI"],
            path: "Tests/ZwzGUITests"
        ),
        .testTarget(
            name: "ZwzCLITests",
            dependencies: ["zwz", "ZwzCore"],
            path: "Tests/ZwzCLITests"
        ),
    ],
    swiftLanguageModes: [.v6]
)
