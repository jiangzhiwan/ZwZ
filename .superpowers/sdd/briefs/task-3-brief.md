### Task 3: Binary Header, Block Record, Footer, and Split Envelope

**Files:**
- Create: `Sources/ZwzCore/ZWZV2/ZwzV2BinaryCodec.swift`
- Test: `Tests/ZwzCoreTests/ZWZV2/ZwzV2BinaryCodecTests.swift`

**Interfaces:**
- Consumes `ZwzV2Format` and `ZwzV2Error`.
- Produces:
  - `public struct ZwzV2Header: Equatable`
  - `public struct ZwzV2BlockRecordHeader: Equatable`
  - `public struct ZwzV2Footer: Equatable`
  - `public struct ZwzV2SplitEnvelope: Equatable`
  - `public enum ZwzV2BinaryCodec` with `encodeHeader`, `decodeHeader`, `encodeBlockRecordHeader`, `decodeBlockRecordHeader`, `encodeFooter`, `decodeFooter`, `encodeSplitEnvelope`, `decodeSplitEnvelope`.

- [ ] **Step 1: Write binary round-trip and rejection tests**

Create `Tests/ZwzCoreTests/ZWZV2/ZwzV2BinaryCodecTests.swift` with tests:

```swift
import XCTest
@testable import ZwzCore

final class ZwzV2BinaryCodecTests: XCTestCase {
    func testHeaderRoundTrip() throws {
        let header = ZwzV2Header(
            archiveID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            flags: [.encrypted],
            blockSize: 4 * 1024 * 1024,
            kdfSalt: Data([1, 2, 3, 4]),
            kdfIterations: 210_000
        )

        let data = try ZwzV2BinaryCodec.encodeHeader(header)
        XCTAssertEqual(data.count, ZwzV2Header.encodedLength)
        XCTAssertEqual(try ZwzV2BinaryCodec.decodeHeader(data), header)
    }

    func testOldV1HeaderIsRejectedAsUnsupported() {
        var bytes = Data(repeating: 0, count: ZwzV2Header.encodedLength)
        bytes.replaceSubrange(0..<4, with: Data([0x5A, 0x57, 0x5A, 0x31]))

        XCTAssertThrowsError(try ZwzV2BinaryCodec.decodeHeader(bytes)) { error in
            XCTAssertEqual(error as? ZwzV2Error, .unsupportedVersion(1))
        }
    }

    func testFooterRoundTrip() throws {
        let footer = ZwzV2Footer(
            archiveID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            indexOffset: 123,
            indexLength: 456,
            indexChecksum: 789
        )

        let data = try ZwzV2BinaryCodec.encodeFooter(footer)
        XCTAssertEqual(try ZwzV2BinaryCodec.decodeFooter(data), footer)
    }
}
```

- [ ] **Step 2: Run tests to verify failure**

Run: `swift test --filter ZwzV2BinaryCodecTests`

Expected: fails because binary codec types do not exist.

- [ ] **Step 3: Implement exact binary encoding**

Create `Sources/ZwzCore/ZWZV2/ZwzV2BinaryCodec.swift`. Use fixed little-endian fields and explicit length checks. Constants:

```swift
public struct ZwzV2Header: Equatable {
    public static let encodedLength = 128
    public var archiveID: UUID
    public var flags: ZwzV2HeaderFlags
    public var blockSize: UInt32
    public var kdfSalt: Data
    public var kdfIterations: UInt32
}

public struct ZwzV2HeaderFlags: OptionSet, Equatable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public static let encrypted = ZwzV2HeaderFlags(rawValue: 1 << 0)
    public static let split = ZwzV2HeaderFlags(rawValue: 1 << 1)
}

public struct ZwzV2BlockRecordHeader: Equatable {
    public static let encodedLength = 40
    public var sequence: UInt64
    public var codec: ZwzV2Codec
    public var storedLength: UInt32
    public var originalLength: UInt32
    public var checksum: UInt32
    public var tagLength: UInt8
}

public struct ZwzV2Footer: Equatable {
    public static let encodedLength = 64
    public var archiveID: UUID
    public var indexOffset: UInt64
    public var indexLength: UInt64
    public var indexChecksum: UInt32
}

public struct ZwzV2SplitEnvelope: Equatable {
    public static let encodedLength = 80
    public var archiveID: UUID
    public var volumeNumber: UInt32
    public var isFinal: Bool
    public var logicalOffset: UInt64
    public var payloadLength: UInt64
    public var payloadChecksum: UInt32
}
```

Add helper methods that reject unsupported flags, impossible salt length, short input, bad magic, bad version, and unknown codecs with `ZwzV2Error.malformedArchive`.

- [ ] **Step 4: Run tests**

Run: `swift test --filter ZwzV2BinaryCodecTests`

Expected: pass.

- [ ] **Step 5: Checkpoint**

Record: "Task 3 verified with `swift test --filter ZwzV2BinaryCodecTests`."
