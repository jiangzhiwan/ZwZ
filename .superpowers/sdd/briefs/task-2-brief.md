### Task 2: Shared Types and Error Model

**Files:**
- Modify: `Sources/ZwzCore/ZWZV2/ZwzV2Types.swift`
- Test: `Tests/ZwzCoreTests/ZWZV2/ZwzV2TypesTests.swift`

**Interfaces:**
- Produces:
  - `public enum ZwzV2CompressionLevel: Equatable { case none, fastest, normal, max }`
  - `public enum ZwzV2Codec: UInt8, Equatable { case store = 0, lz4 = 1, deflate = 2 }`
  - `public enum ZwzV2EntryType: UInt8, Equatable { case directory = 1, file = 2 }`
  - `public enum ZwzV2RecoveryPolicy: Equatable { case strict, recover }`
  - `public struct ZwzV2Options: Equatable`
  - `public struct ZwzV2Index: Equatable`
  - `public struct ZwzV2Entry: Equatable`
  - `public struct ZwzV2BlockDescriptor: Equatable`
  - `public enum ZwzV2Error: LocalizedError, Equatable`

- [ ] **Step 1: Write type behavior tests**

Create `Tests/ZwzCoreTests/ZWZV2/ZwzV2TypesTests.swift`:

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

- [ ] **Step 2: Run tests to verify failure**

Run: `swift test --filter ZwzV2TypesTests`

Expected: fails because the types do not exist.

- [ ] **Step 3: Implement shared types**

Extend `Sources/ZwzCore/ZWZV2/ZwzV2Types.swift`:

```swift
public enum ZwzV2CompressionLevel: Equatable {
    case none
    case fastest
    case normal
    case max
}

public enum ZwzV2Codec: UInt8, Equatable {
    case store = 0
    case lz4 = 1
    case deflate = 2
}

public enum ZwzV2EntryType: UInt8, Equatable {
    case directory = 1
    case file = 2
}

public enum ZwzV2RecoveryPolicy: Equatable {
    case strict
    case recover
}

public struct ZwzV2Options: Equatable {
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

public struct ZwzV2Index: Equatable {
    public var archiveID: UUID
    public var blockSize: Int
    public var entries: [ZwzV2Entry]
}

public struct ZwzV2Entry: Equatable {
    public var path: String
    public var type: ZwzV2EntryType
    public var originalSize: UInt64
    public var modificationTime: Date
    public var isHidden: Bool
    public var blocks: [ZwzV2BlockDescriptor]
}

public struct ZwzV2BlockDescriptor: Equatable {
    public var sequence: UInt64
    public var fileOffset: UInt64
    public var archiveOffset: UInt64
    public var storedLength: UInt32
    public var originalLength: UInt32
    public var codec: ZwzV2Codec
    public var checksum: UInt32
    public var authenticationTag: [UInt8]
}

public enum ZwzV2Error: LocalizedError, Equatable {
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

- [ ] **Step 4: Run tests**

Run: `swift test --filter ZwzV2TypesTests`

Expected: pass.

- [ ] **Step 5: Checkpoint**

Record: "Task 2 verified with `swift test --filter ZwzV2TypesTests`."
