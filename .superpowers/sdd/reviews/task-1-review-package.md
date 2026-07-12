# Task 1 Review Package

Workspace: `/Users/jiangzhiwan/Desktop/ZwZ`

Git range: unavailable because this workspace is not a Git repository.

## Implementer-Reported Test Evidence

- `swift package resolve`: passed; CryptoSwift resolved at `1.10.0`.
- Initial `swift test --filter PackageBoundaryTests`: passed; 1 test, 0 failures.
- After review fixes, `swift test --filter PackageBoundaryTests`: passed; 2 tests, 0 failures.
- After review fixes, `swift test`: passed; 7 tests, 0 failures.
- Initial red test attempt was blocked by sandbox cache permissions before missing-symbol compilation could be observed.

## Files Changed

- `Package.swift`
- `Package.resolved`
- `Sources/ZwzCore/ZWZV2/ZwzV2Types.swift`
- `Tests/ZwzCoreTests/ZWZV2/PackageBoundaryTests.swift`

## Current `Package.swift`

```swift
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
            path: "Sources/ZwzGUI"
        ),
        .testTarget(
            name: "ZwzCoreTests",
            dependencies: ["ZwzCore"],
            path: "Tests/ZwzCoreTests"
        ),
    ],
    swiftLanguageModes: [.v6]
)
```

## Current `Package.resolved`

```json
{
  "originHash" : "c0e673a9e03462e56e3cf91367f1a985dbba778eab9f53ada29f906a423ba876",
  "pins" : [
    {
      "identity" : "bitbytedata",
      "kind" : "remoteSourceControl",
      "location" : "https://github.com/tsolomko/BitByteData",
      "state" : {
        "revision" : "e1a5443be67daf0833cbb5f4fa3a06a265ca3105",
        "version" : "2.1.0"
      }
    },
    {
      "identity" : "cryptoswift",
      "kind" : "remoteSourceControl",
      "location" : "https://github.com/krzyzanowskim/CryptoSwift.git",
      "state" : {
        "revision" : "f2a627b84c1ff96f21ac2fcb623ab36142dd5512",
        "version" : "1.10.0"
      }
    },
    {
      "identity" : "swcompression",
      "kind" : "remoteSourceControl",
      "location" : "https://github.com/tsolomko/SWCompression.git",
      "state" : {
        "branch" : "develop",
        "revision" : "83689e0a8b06e81b333ab72f92a28da53e671940"
      }
    },
    {
      "identity" : "zipfoundation",
      "kind" : "remoteSourceControl",
      "location" : "https://github.com/weichsel/ZIPFoundation.git",
      "state" : {
        "revision" : "22787ffb59de99e5dc1fbfe80b19c97a904ad48d",
        "version" : "0.9.20"
      }
    }
  ],
  "version" : 3
}
```

## Current `Sources/ZwzCore/ZWZV2/ZwzV2Types.swift`

```swift
import Foundation
import CryptoSwift

public enum ZwzV2Format {
    public static let magic = [UInt8](arrayLiteral: 0x5A, 0x57, 0x5A, 0x32)
    public static let splitMagic = [UInt8](arrayLiteral: 0x5A, 0x57, 0x5A, 0x53)
    public static let version: UInt16 = 2
    public static let defaultBlockSize: Int = 4 * 1024 * 1024

    internal static func cryptoSwiftProbe() -> [UInt8] {
        [UInt8]().sha256()
    }
}
```

## Current `Tests/ZwzCoreTests/ZWZV2/PackageBoundaryTests.swift`

```swift
import XCTest
@testable import ZwzCore

final class PackageBoundaryTests: XCTestCase {
    func testCoreTargetExportsV2NamespaceMarker() {
        XCTAssertEqual(ZwzV2Format.magic, [0x5A, 0x57, 0x5A, 0x32])
        XCTAssertEqual(ZwzV2Format.splitMagic, [0x5A, 0x57, 0x5A, 0x53])
        XCTAssertEqual(ZwzV2Format.version, 2)
        XCTAssertEqual(ZwzV2Format.defaultBlockSize, 4 * 1024 * 1024)
    }

    func testCoreCanUseCryptoSwift() {
        XCTAssertEqual(
            ZwzV2Format.cryptoSwiftProbe(),
            [0xE3, 0xB0, 0xC4, 0x42, 0x98, 0xFC, 0x1C, 0x14,
             0x9A, 0xFB, 0xF4, 0xC8, 0x99, 0x6F, 0xB9, 0x24,
             0x27, 0xAE, 0x41, 0xE4, 0x64, 0x9B, 0x93, 0x4C,
             0xA4, 0x95, 0x99, 0x1B, 0x78, 0x52, 0xB8, 0x55]
        )
    }
}
```
