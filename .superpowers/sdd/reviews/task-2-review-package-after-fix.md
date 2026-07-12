# Task 2 Review Package After Fix

Workspace: `/Users/jiangzhiwan/Desktop/ZwZ`

Git range: unavailable because this workspace is not a Git repository.

## Implementer-Reported Test Evidence

- `swift test --filter PublicAPIBoundaryTests`: passed; 1 test, 0 failures.
- `swift test --filter ZwzV2TypesTests`: passed; 2 tests, 0 failures.
- `swift test --filter PackageBoundaryTests`: passed; 2 tests, 0 failures.
- `swift test`: passed; 10 tests, 0 failures.

## Files Changed

- `Sources/ZwzCore/ZWZV2/ZwzV2Types.swift`
- `Tests/ZwzCoreTests/ZWZV2/ZwzV2TypesTests.swift`
- `Tests/ZwzCoreTests/ZWZV2/PublicAPIBoundaryTests.swift`

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

public enum ZwzV2CompressionLevel: Equatable, Sendable {
    case none
    case fastest
    case normal
    case max
}

public enum ZwzV2Codec: UInt8, Equatable, Sendable {
    case store = 0
    case lz4 = 1
    case deflate = 2
}

public enum ZwzV2EntryType: UInt8, Equatable, Sendable {
    case directory = 1
    case file = 2
}

public enum ZwzV2RecoveryPolicy: Equatable, Sendable {
    case strict
    case recover
}

public struct ZwzV2Options: Equatable, Sendable {
    public var blockSize: Int
    public var compressionLevel: ZwzV2CompressionLevel
    public var password: String?
    public var splitVolumeSize: UInt64?
    public var threadCount: Int
    public var maxInFlightBlocks: Int
    public var recoveryPolicy: ZwzV2RecoveryPolicy

    public init(
        blockSize: Int = ZwzV2Format.defaultBlockSize,
        compressionLevel: ZwzV2CompressionLevel = .normal,
        password: String? = nil,
        splitVolumeSize: UInt64? = nil,
        threadCount: Int = max(1, ProcessInfo.processInfo.activeProcessorCount - 1),
        maxInFlightBlocks: Int? = nil,
        recoveryPolicy: ZwzV2RecoveryPolicy = .strict
    ) {
        self.blockSize = blockSize
        self.compressionLevel = compressionLevel
        self.password = password
        self.splitVolumeSize = splitVolumeSize
        self.threadCount = max(1, threadCount)
        self.maxInFlightBlocks = max(2, maxInFlightBlocks ?? max(2, self.threadCount * 2))
        self.recoveryPolicy = recoveryPolicy
    }
}

public struct ZwzV2Index: Equatable, Sendable {
    public var archiveID: UUID
    public var blockSize: Int
    public var entries: [ZwzV2Entry]

    public init(archiveID: UUID, blockSize: Int, entries: [ZwzV2Entry]) {
        self.archiveID = archiveID
        self.blockSize = blockSize
        self.entries = entries
    }
}

public struct ZwzV2Entry: Equatable, Sendable {
    public var path: String
    public var type: ZwzV2EntryType
    public var originalSize: UInt64
    public var modificationTime: Date
    public var isHidden: Bool
    public var blocks: [ZwzV2BlockDescriptor]

    public init(path: String, type: ZwzV2EntryType, originalSize: UInt64, modificationTime: Date, isHidden: Bool, blocks: [ZwzV2BlockDescriptor]) {
        self.path = path
        self.type = type
        self.originalSize = originalSize
        self.modificationTime = modificationTime
        self.isHidden = isHidden
        self.blocks = blocks
    }
}

public struct ZwzV2BlockDescriptor: Equatable, Sendable {
    public var sequence: UInt64
    public var fileOffset: UInt64
    public var archiveOffset: UInt64
    public var storedLength: UInt32
    public var originalLength: UInt32
    public var codec: ZwzV2Codec
    public var checksum: UInt32
    public var authenticationTag: [UInt8]

    public init(sequence: UInt64, fileOffset: UInt64, archiveOffset: UInt64, storedLength: UInt32, originalLength: UInt32, codec: ZwzV2Codec, checksum: UInt32, authenticationTag: [UInt8]) {
        self.sequence = sequence
        self.fileOffset = fileOffset
        self.archiveOffset = archiveOffset
        self.storedLength = storedLength
        self.originalLength = originalLength
        self.codec = codec
        self.checksum = checksum
        self.authenticationTag = authenticationTag
    }
}

public enum ZwzV2Error: LocalizedError, Equatable, Sendable {
    case unsupportedVersion(UInt16)
    case malformedArchive(String)
    case unsafePath(String)
    case duplicatePath(String)
    case wrongPasswordOrTamperedData
    case missingVolume(Int)
    case checksumMismatch(sequence: UInt64)
    case decompressionFailed(sequence: UInt64)

    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version):
            return "Unsupported ZWZ archive version \(version)."
        case .malformedArchive(let reason):
            return "Malformed ZWZ archive: \(reason)."
        case .unsafePath(let path):
            return "Unsafe archive path: \(path)."
        case .duplicatePath(let path):
            return "Duplicate archive path: \(path)."
        case .wrongPasswordOrTamperedData:
            return "The password is incorrect or the archive data was modified."
        case .missingVolume(let number):
            return "Missing split volume \(number)."
        case .checksumMismatch(let sequence):
            return "Checksum mismatch in block \(sequence)."
        case .decompressionFailed(let sequence):
            return "Could not decompress block \(sequence)."
        }
    }
}
```

## Current `Tests/ZwzCoreTests/ZWZV2/ZwzV2TypesTests.swift`

```swift
import XCTest
@testable import ZwzCore

final class ZwzV2TypesTests: XCTestCase {
    func testDefaultOptionsAreBoundedAndStrict() {
        let options = ZwzV2Options()
        XCTAssertEqual(options.blockSize, ZwzV2Format.defaultBlockSize)
        XCTAssertEqual(options.compressionLevel, .normal)
        XCTAssertEqual(options.recoveryPolicy, .strict)
        XCTAssertGreaterThanOrEqual(options.threadCount, 1)
        XCTAssertLessThanOrEqual(options.maxInFlightBlocks, max(2, options.threadCount * 2))
    }

    func testUnsupportedVersionErrorMessageIsClear() {
        let error = ZwzV2Error.unsupportedVersion(1)
        XCTAssertTrue(error.localizedDescription.localizedCaseInsensitiveContains("unsupported"))
        XCTAssertTrue(error.localizedDescription.contains("1"))
    }
}
```

## Current `Tests/ZwzCoreTests/ZWZV2/PublicAPIBoundaryTests.swift`

```swift
import Foundation
import XCTest
import ZwzCore

final class PublicAPIBoundaryTests: XCTestCase {
    func testPublicV2ValueTypesCanBeConstructedAcrossPackageBoundary() {
        let block = ZwzV2BlockDescriptor(
            sequence: 1,
            fileOffset: 2,
            archiveOffset: 3,
            storedLength: 4,
            originalLength: 5,
            codec: .store,
            checksum: 6,
            authenticationTag: [7, 8]
        )
        let entry = ZwzV2Entry(
            path: "file.txt",
            type: .file,
            originalSize: 9,
            modificationTime: Date(timeIntervalSince1970: 10),
            isHidden: false,
            blocks: [block]
        )
        let index = ZwzV2Index(
            archiveID: UUID(),
            blockSize: 11,
            entries: [entry]
        )

        XCTAssertEqual(index.entries, [entry])
        XCTAssertEqual(index.entries[0].blocks, [block])
    }
}
```
