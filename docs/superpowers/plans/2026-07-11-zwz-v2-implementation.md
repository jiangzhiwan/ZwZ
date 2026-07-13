# ZWZ v2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the current `.zwz` archive algorithm with a streaming ZWZ v2 format that is stable on very large inputs, supports password privacy, split volumes, fast preview, individual extraction, recovery mode, and multithreaded compression/decompression.

**Architecture:** Add a focused v2 core under `Sources/ZwzCore/ZWZV2`, then route the existing public API through it. The format is header + independently encoded block records + encrypted index + footer, with bounded queues and worker pools for both writing and reading.

**Tech Stack:** Swift Package Manager, Swift concurrency/actors, SWCompression LZ4/Deflate, CryptoSwift AES-GCM/PBKDF2, XCTest, existing SwiftUI GUI.

## Global Constraints

- Old ZWZ archives are intentionally unsupported and must return a clear unsupported-version error.
- Compression and encryption dependencies must be implemented entirely in Swift.
- Existing LZ4 and Deflate implementations from SWCompression may be reused.
- Add only a mature pure Swift cryptography package for AES-256-GCM and PBKDF2-HMAC-SHA256.
- Archive metadata is limited to normalized relative paths, directories, file sizes, modification times, and hidden-file flags.
- Symbolic links, permissions, extended attributes, and macOS resource forks are not archived.
- Memory use must be bounded by configured block and queue sizes, not input size.
- Preview and individual extraction must not scan or decompress unrelated file data.
- Default block size is 4 MiB.
- Compression levels map to store, LZ4, adaptive LZ4/Deflate/store, and Deflate/store.
- Password archives encrypt and authenticate both blocks and index; names and directory structure are hidden without a password.
- Split volumes must be written directly while streaming.
- Strict mode is default; recovery mode may output only independently verified complete or explicitly partial files.
- Compression and extraction must retain multithreaded processing.
- This folder is not a Git repository, so commit steps are replaced by local checkpoint notes and verification commands.

---

## File Structure

- Modify `Package.swift`: add CryptoSwift and make macOS GUI targets conditionally available while keeping `ZwzCore` portable.
- Create `Sources/ZwzCore/ZWZV2/ZwzV2Types.swift`: shared enums, constants, errors, option structs, and index models.
- Create `Sources/ZwzCore/ZWZV2/ZwzV2BinaryCodec.swift`: little-endian binary reader/writer, fixed header, block record header, footer, and split-volume envelope encoding.
- Create `Sources/ZwzCore/ZWZV2/ZwzV2PathValidator.swift`: relative path normalization, hidden-file detection, traversal rejection, and duplicate-path checks.
- Create `Sources/ZwzCore/ZWZV2/ZwzV2Crypto.swift`: PBKDF2 key derivation, AES-256-GCM block/index sealing, nonce derivation, and authentication errors.
- Create `Sources/ZwzCore/ZWZV2/ZwzV2BlockCodec.swift`: block-level store/LZ4/Deflate/adaptive compression and decompression.
- Create `Sources/ZwzCore/ZWZV2/ZwzV2IndexCodec.swift`: compact binary index serialization/deserialization, encrypted index wrapper, and bounds validation.
- Create `Sources/ZwzCore/ZWZV2/ZwzV2VolumeIO.swift`: logical archive stream writer/reader over normal and split archives.
- Create `Sources/ZwzCore/ZWZV2/ZwzV2SourceEnumerator.swift`: streaming source enumeration for files/directories while skipping symlinks and unsupported metadata.
- Create `Sources/ZwzCore/ZWZV2/ZwzV2Compressor.swift`: bounded multithreaded compression pipeline and ordered writer.
- Create `Sources/ZwzCore/ZWZV2/ZwzV2Extractor.swift`: preview, single-entry extraction, full extraction, strict/recovery policies, and multithreaded decoding.
- Create `Sources/ZwzCore/ZWZV2/ZwzV2RecoveryReport.swift`: machine-readable and user-readable recovery summaries.
- Modify `Sources/ZwzCore/ZwzCompressor.swift`, `Sources/ZwzCore/ZwzExtractor.swift`, `Sources/ZwzCore/ArchivePreviewer.swift`, `Sources/ZwzCore/ZwzAPI.swift`, and `Sources/ZwzCore/Types.swift`: route existing app-facing calls through v2 and map new errors to localized messages.
- Modify `Sources/ZwzGUI/ArchiveViewModel.swift` and `Sources/ZwzGUI/Localization.swift`: expose strict/recovery messages, password-required preview, and unsupported v1 message.
- Add tests under `Tests/ZwzCoreTests/ZWZV2/` for every new component.

---

### Task 1: Package and Portable Core Boundary

**Files:**
- Modify: `Package.swift`
- Test: `Tests/ZwzCoreTests/ZWZV2/PackageBoundaryTests.swift`

**Interfaces:**
- Produces dependency availability for `import CryptoSwift` in `ZwzCore`.
- Produces a core target that can be built without AppKit/SwiftUI imports.

- [ ] **Step 1: Write the failing dependency boundary test**

Create `Tests/ZwzCoreTests/ZWZV2/PackageBoundaryTests.swift`:

```swift
import XCTest
@testable import ZwzCore

final class PackageBoundaryTests: XCTestCase {
    func testCoreTargetExportsV2NamespaceMarker() {
        XCTAssertEqual(ZwzV2Format.version, 2)
        XCTAssertEqual(ZwzV2Format.defaultBlockSize, 4 * 1024 * 1024)
    }
}
```

- [ ] **Step 2: Run the focused test to verify it fails**

Run: `swift test --filter PackageBoundaryTests`

Expected: fails because `ZwzV2Format` is not defined.

- [ ] **Step 3: Add CryptoSwift dependency and a minimal marker**

Modify `Package.swift`:

```swift
.package(url: "https://github.com/krzyzanowskim/CryptoSwift.git", from: "1.8.0"),
```

Add `CryptoSwift` to the `ZwzCore` target dependencies. Keep SWCompression and ZIPFoundation dependencies unchanged.

Create `Sources/ZwzCore/ZWZV2/ZwzV2Types.swift`:

```swift
import Foundation

public enum ZwzV2Format {
    public static let magic = [UInt8](arrayLiteral: 0x5A, 0x57, 0x5A, 0x32)
    public static let splitMagic = [UInt8](arrayLiteral: 0x5A, 0x57, 0x5A, 0x53)
    public static let version: UInt16 = 2
    public static let defaultBlockSize: Int = 4 * 1024 * 1024
}
```

- [ ] **Step 4: Resolve and verify**

Run: `swift package resolve`

Expected: resolves CryptoSwift without replacing existing dependencies.

Run: `swift test --filter PackageBoundaryTests`

Expected: pass.

- [ ] **Step 5: Checkpoint**

Record in the plan: "Task 1 verified with `swift test --filter PackageBoundaryTests`." Do not run git commands because this folder is not a Git repository.

---

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

---

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

---

### Task 4: Path Validation and Source Enumeration

**Files:**
- Create: `Sources/ZwzCore/ZWZV2/ZwzV2PathValidator.swift`
- Create: `Sources/ZwzCore/ZWZV2/ZwzV2SourceEnumerator.swift`
- Test: `Tests/ZwzCoreTests/ZWZV2/ZwzV2PathTests.swift`

**Interfaces:**
- Produces:
  - `public enum ZwzV2PathValidator`
  - `public static func normalizedArchivePath(root: URL, item: URL) throws -> String`
  - `public static func validateExtractionPath(_ archivePath: String, destination: URL) throws -> URL`
  - `public static func validateNoDuplicatePaths(_ entries: [ZwzV2Entry]) throws`
  - `public struct ZwzV2SourceItem: Equatable`
  - `public struct ZwzV2SourceEnumerator { public func enumerate(root: URL) throws -> [ZwzV2SourceItem] }`

- [ ] **Step 1: Write path safety tests**

Create `Tests/ZwzCoreTests/ZWZV2/ZwzV2PathTests.swift` with tests:

```swift
import XCTest
@testable import ZwzCore

final class ZwzV2PathTests: XCTestCase {
    func testRejectsTraversalAndAbsoluteExtractionPaths() throws {
        let destination = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)

        XCTAssertThrowsError(try ZwzV2PathValidator.validateExtractionPath("../escape.txt", destination: destination))
        XCTAssertThrowsError(try ZwzV2PathValidator.validateExtractionPath("/tmp/escape.txt", destination: destination))
        XCTAssertThrowsError(try ZwzV2PathValidator.validateExtractionPath("safe/\u{0}bad.txt", destination: destination))
    }

    func testDetectsCaseInsensitiveDuplicatePaths() throws {
        let date = Date(timeIntervalSince1970: 1)
        let entries = [
            ZwzV2Entry(path: "Folder/File.txt", type: .file, originalSize: 1, modificationTime: date, isHidden: false, blocks: []),
            ZwzV2Entry(path: "folder/file.txt", type: .file, originalSize: 1, modificationTime: date, isHidden: false, blocks: [])
        ]

        XCTAssertThrowsError(try ZwzV2PathValidator.validateNoDuplicatePaths(entries))
    }
}
```

- [ ] **Step 2: Run tests to verify failure**

Run: `swift test --filter ZwzV2PathTests`

Expected: fails because path validator does not exist.

- [ ] **Step 3: Implement validator and enumerator**

Implement path normalization using `URL.standardizedFileURL`, `pathComponents`, and UTF-8 strings. Rules:

```swift
public enum ZwzV2PathValidator {
    public static func normalizedArchivePath(root: URL, item: URL) throws -> String
    public static func validateExtractionPath(_ archivePath: String, destination: URL) throws -> URL
    public static func validateNoDuplicatePaths(_ entries: [ZwzV2Entry]) throws
}

public struct ZwzV2SourceItem: Equatable {
    public var url: URL
    public var archivePath: String
    public var type: ZwzV2EntryType
    public var size: UInt64
    public var modificationTime: Date
    public var isHidden: Bool
}

public struct ZwzV2SourceEnumerator {
    public init() {}
    public func enumerate(root: URL) throws -> [ZwzV2SourceItem]
}
```

Enumerator requirements: include explicit directories, include hidden files, skip symbolic links, use resource values for size/date/hidden, and sort by `archivePath` for deterministic output.

- [ ] **Step 4: Run tests**

Run: `swift test --filter ZwzV2PathTests`

Expected: pass.

- [ ] **Step 5: Checkpoint**

Record: "Task 4 verified with `swift test --filter ZwzV2PathTests`."

---

### Task 5: Block Codec Selection

**Files:**
- Create: `Sources/ZwzCore/ZWZV2/ZwzV2BlockCodec.swift`
- Test: `Tests/ZwzCoreTests/ZWZV2/ZwzV2BlockCodecTests.swift`

**Interfaces:**
- Produces:
  - `public struct ZwzV2EncodedBlock: Equatable`
  - `public enum ZwzV2BlockCodec`
  - `public static func encode(_ data: Data, level: ZwzV2CompressionLevel) throws -> ZwzV2EncodedBlock`
  - `public static func decode(_ block: ZwzV2EncodedBlock) throws -> Data`
  - `public static func decode(codec: ZwzV2Codec, payload: Data, originalLength: Int, sequence: UInt64) throws -> Data`

- [ ] **Step 1: Write codec tests**

Create `Tests/ZwzCoreTests/ZWZV2/ZwzV2BlockCodecTests.swift`:

```swift
import XCTest
@testable import ZwzCore

final class ZwzV2BlockCodecTests: XCTestCase {
    func testNoneStoresVerbatim() throws {
        let input = Data("hello".utf8)
        let block = try ZwzV2BlockCodec.encode(input, level: .none)
        XCTAssertEqual(block.codec, .store)
        XCTAssertEqual(try ZwzV2BlockCodec.decode(block), input)
    }

    func testNormalRoundTripsCompressibleData() throws {
        let input = Data(String(repeating: "abc123\n", count: 20_000).utf8)
        let block = try ZwzV2BlockCodec.encode(input, level: .normal)
        XCTAssertLessThan(block.payload.count, input.count)
        XCTAssertEqual(try ZwzV2BlockCodec.decode(block), input)
    }

    func testNormalStoresIncompressibleData() throws {
        var bytes = [UInt8]()
        for value in 0..<65_536 {
            bytes.append(UInt8((value * 31) % 251))
        }
        let input = Data(bytes)
        let block = try ZwzV2BlockCodec.encode(input, level: .normal)
        XCTAssertEqual(try ZwzV2BlockCodec.decode(block), input)
    }
}
```

- [ ] **Step 2: Run tests to verify failure**

Run: `swift test --filter ZwzV2BlockCodecTests`

Expected: fails because block codec does not exist.

- [ ] **Step 3: Implement block codec**

Use `SWCompression` for LZ4 and Deflate. Selection rules:

```swift
public struct ZwzV2EncodedBlock: Equatable {
    public var codec: ZwzV2Codec
    public var payload: Data
    public var originalLength: Int
    public var checksum: UInt32
}
```

Rules:
- `.none`: always `.store`.
- `.fastest`: try LZ4, store if `compressed.count + 40 >= input.count`.
- `.normal`: try LZ4 first; if LZ4 saves at least 12%, use it. If the first 64 KiB has a repeated-byte or repeated-token score above the threshold, try Deflate and use it when it beats LZ4 by at least 8%. Store if neither saves at least 1%.
- `.max`: try Deflate, store if `compressed.count + 40 >= input.count`.

Checksum uses a fast deterministic UInt32 function in this file; use the same function during extraction.

- [ ] **Step 4: Run tests**

Run: `swift test --filter ZwzV2BlockCodecTests`

Expected: pass.

- [ ] **Step 5: Checkpoint**

Record: "Task 5 verified with `swift test --filter ZwzV2BlockCodecTests`."

---

### Task 6: Pure Swift Encryption and Nonce Discipline

**Files:**
- Create: `Sources/ZwzCore/ZWZV2/ZwzV2Crypto.swift`
- Test: `Tests/ZwzCoreTests/ZWZV2/ZwzV2CryptoTests.swift`

**Interfaces:**
- Consumes CryptoSwift.
- Produces:
  - `public struct ZwzV2CryptoContext`
  - `public enum ZwzV2Crypto`
  - `public static func makeSalt() -> Data`
  - `public static func deriveContext(password: String, salt: Data, iterations: UInt32, archiveID: UUID) throws -> ZwzV2CryptoContext`
  - `public static func sealBlock(_ plaintext: Data, sequence: UInt64, context: ZwzV2CryptoContext) throws -> (ciphertext: Data, tag: Data)`
  - `public static func openBlock(_ ciphertext: Data, tag: Data, sequence: UInt64, context: ZwzV2CryptoContext) throws -> Data`
  - `public static func sealIndex(_ plaintext: Data, context: ZwzV2CryptoContext) throws -> (ciphertext: Data, tag: Data)`
  - `public static func openIndex(_ ciphertext: Data, tag: Data, context: ZwzV2CryptoContext) throws -> Data`

- [ ] **Step 1: Write encryption tests**

Create `Tests/ZwzCoreTests/ZWZV2/ZwzV2CryptoTests.swift`:

```swift
import XCTest
@testable import ZwzCore

final class ZwzV2CryptoTests: XCTestCase {
    func testBlockEncryptionRoundTripsAndRejectsWrongPassword() throws {
        let archiveID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let salt = Data(repeating: 7, count: 16)
        let good = try ZwzV2Crypto.deriveContext(password: "secret", salt: salt, iterations: 1_000, archiveID: archiveID)
        let bad = try ZwzV2Crypto.deriveContext(password: "wrong", salt: salt, iterations: 1_000, archiveID: archiveID)
        let sealed = try ZwzV2Crypto.sealBlock(Data("hidden".utf8), sequence: 42, context: good)

        XCTAssertEqual(try ZwzV2Crypto.openBlock(sealed.ciphertext, tag: sealed.tag, sequence: 42, context: good), Data("hidden".utf8))
        XCTAssertThrowsError(try ZwzV2Crypto.openBlock(sealed.ciphertext, tag: sealed.tag, sequence: 42, context: bad))
    }

    func testIndexUsesDifferentNonceDomainThanBlock() throws {
        let archiveID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let context = try ZwzV2Crypto.deriveContext(password: "secret", salt: Data(repeating: 8, count: 16), iterations: 1_000, archiveID: archiveID)
        let block = try ZwzV2Crypto.sealBlock(Data("payload".utf8), sequence: 0, context: context)
        let index = try ZwzV2Crypto.sealIndex(Data("payload".utf8), context: context)
        XCTAssertNotEqual(block.ciphertext + block.tag, index.ciphertext + index.tag)
    }
}
```

- [ ] **Step 2: Run tests to verify failure**

Run: `swift test --filter ZwzV2CryptoTests`

Expected: fails because crypto wrapper does not exist.

- [ ] **Step 3: Implement crypto wrapper**

Implement PBKDF2-HMAC-SHA256 and AES-GCM using CryptoSwift. Nonces are 12 bytes:

```swift
nonce[0] = domainByte // 0x42 for block, 0x49 for index
nonce[1...8] = sequence little-endian for blocks, zeros for index
nonce[9...11] = first three bytes of archiveID.uuid
```

`ZwzV2CryptoContext` contains `archiveID`, `salt`, `iterations`, and `key`. Throw `ZwzV2Error.wrongPasswordOrTamperedData` for authentication failures.

- [ ] **Step 4: Run tests**

Run: `swift test --filter ZwzV2CryptoTests`

Expected: pass.

- [ ] **Step 5: Checkpoint**

Record: "Task 6 verified with `swift test --filter ZwzV2CryptoTests`."

---

### Task 7: Index Codec and Metadata Privacy

**Files:**
- Create: `Sources/ZwzCore/ZWZV2/ZwzV2IndexCodec.swift`
- Test: `Tests/ZwzCoreTests/ZWZV2/ZwzV2IndexCodecTests.swift`

**Interfaces:**
- Consumes `ZwzV2Index`, `ZwzV2Entry`, `ZwzV2BlockDescriptor`, and `ZwzV2Crypto`.
- Produces:
  - `public enum ZwzV2IndexCodec`
  - `public static func encodePlain(_ index: ZwzV2Index) throws -> Data`
  - `public static func decodePlain(_ data: Data) throws -> ZwzV2Index`
  - `public static func encodeForArchive(_ index: ZwzV2Index, context: ZwzV2CryptoContext?) throws -> (payload: Data, tag: Data)`
  - `public static func decodeFromArchive(payload: Data, tag: Data, context: ZwzV2CryptoContext?) throws -> ZwzV2Index`

- [ ] **Step 1: Write index tests**

Create `Tests/ZwzCoreTests/ZWZV2/ZwzV2IndexCodecTests.swift`:

```swift
import XCTest
@testable import ZwzCore

final class ZwzV2IndexCodecTests: XCTestCase {
    func testPlainIndexRoundTrips() throws {
        let index = sampleIndex()
        let data = try ZwzV2IndexCodec.encodePlain(index)
        XCTAssertEqual(try ZwzV2IndexCodec.decodePlain(data), index)
    }

    func testEncryptedIndexDoesNotExposeFilenames() throws {
        let index = sampleIndex()
        let context = try ZwzV2Crypto.deriveContext(password: "secret", salt: Data(repeating: 9, count: 16), iterations: 1_000, archiveID: index.archiveID)
        let sealed = try ZwzV2IndexCodec.encodeForArchive(index, context: context)
        XCTAssertNil(String(data: sealed.payload, encoding: .utf8)?.contains("hidden.txt") == true ? "leaked" : nil)
        XCTAssertEqual(try ZwzV2IndexCodec.decodeFromArchive(payload: sealed.payload, tag: sealed.tag, context: context), index)
    }

    private func sampleIndex() -> ZwzV2Index {
        let block = ZwzV2BlockDescriptor(sequence: 0, fileOffset: 0, archiveOffset: 128, storedLength: 5, originalLength: 5, codec: .store, checksum: 1, authenticationTag: [])
        let entry = ZwzV2Entry(path: ".secret/hidden.txt", type: .file, originalSize: 5, modificationTime: Date(timeIntervalSince1970: 10), isHidden: true, blocks: [block])
        return ZwzV2Index(archiveID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!, blockSize: 4 * 1024 * 1024, entries: [entry])
    }
}
```

- [ ] **Step 2: Run tests to verify failure**

Run: `swift test --filter ZwzV2IndexCodecTests`

Expected: fails because index codec does not exist.

- [ ] **Step 3: Implement compact index serialization**

Use a binary index, not JSON. Layout:
- magic `ZWZI`, version `2`, archiveID, blockSize, entry count.
- For each entry: path byte length, UTF-8 path, type, size, mtime milliseconds since 1970, hidden flag, block count.
- For each block: sequence, fileOffset, archiveOffset, storedLength, originalLength, codec, checksum, tag length, tag.

Reject oversized path lengths, invalid UTF-8, unknown entry types, unknown codecs, impossible block counts, and trailing bytes.

- [ ] **Step 4: Run tests**

Run: `swift test --filter ZwzV2IndexCodecTests`

Expected: pass.

- [ ] **Step 5: Checkpoint**

Record: "Task 7 verified with `swift test --filter ZwzV2IndexCodecTests`."

---

### Task 8: Logical Volume I/O

**Files:**
- Create: `Sources/ZwzCore/ZWZV2/ZwzV2VolumeIO.swift`
- Test: `Tests/ZwzCoreTests/ZWZV2/ZwzV2VolumeIOTests.swift`

**Interfaces:**
- Produces:
  - `public final class ZwzV2VolumeWriter`
  - `public struct ZwzV2VolumeSet`
  - `public final class ZwzV2VolumeReader`
  - `public func write(_ data: Data) throws -> UInt64`
  - `public func finalize() throws -> [URL]`
  - `public func read(offset: UInt64, length: Int) throws -> Data`

- [ ] **Step 1: Write volume tests**

Create `Tests/ZwzCoreTests/ZWZV2/ZwzV2VolumeIOTests.swift`:

```swift
import XCTest
@testable import ZwzCore

final class ZwzV2VolumeIOTests: XCTestCase {
    func testSplitWriterAndReaderRoundTripAcrossBoundaries() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let output = dir.appendingPathComponent("archive.zwz")
        let archiveID = UUID(uuidString: "99999999-2222-3333-4444-555555555555")!

        let writer = try ZwzV2VolumeWriter(outputURL: output, archiveID: archiveID, splitVolumeSize: 64)
        let offset = try writer.write(Data((0..<200).map { UInt8($0 % 251) }))
        let urls = try writer.finalize()
        let reader = try ZwzV2VolumeReader(urls: urls)

        XCTAssertEqual(offset, 0)
        XCTAssertEqual(try reader.read(offset: 50, length: 100), Data((50..<150).map { UInt8($0 % 251) }))
    }
}
```

- [ ] **Step 2: Run tests to verify failure**

Run: `swift test --filter ZwzV2VolumeIOTests`

Expected: fails because volume I/O does not exist.

- [ ] **Step 3: Implement logical stream reader/writer**

Writer behavior:
- If `splitVolumeSize == nil`, write to one file directly.
- If split is enabled, write payload envelopes and rotate before the next write would exceed the requested payload budget.
- Return logical offsets for every write.
- `finalize()` marks final volume and returns all URLs.

Reader behavior:
- Accept single archive or split volume URLs.
- Validate split magic, archiveID consistency, volume sequence, logical ranges, and payload checksum.
- Resolve `read(offset:length:)` across volume boundaries without loading all volumes.

- [ ] **Step 4: Run tests**

Run: `swift test --filter ZwzV2VolumeIOTests`

Expected: pass.

- [ ] **Step 5: Checkpoint**

Record: "Task 8 verified with `swift test --filter ZwzV2VolumeIOTests`."

---

### Task 9: Streaming Multithreaded Compressor

**Files:**
- Create: `Sources/ZwzCore/ZWZV2/ZwzV2Compressor.swift`
- Test: `Tests/ZwzCoreTests/ZWZV2/ZwzV2CompressorTests.swift`

**Interfaces:**
- Consumes source enumerator, block codec, crypto, volume writer, index codec.
- Produces:
  - `public final class ZwzV2Compressor`
  - `public init(options: ZwzV2Options = ZwzV2Options())`
  - `public func compress(sourceURLs: [URL], to outputURL: URL) async throws -> [URL]`

- [ ] **Step 1: Write compressor integration tests**

Create `Tests/ZwzCoreTests/ZWZV2/ZwzV2CompressorTests.swift`:

```swift
import XCTest
@testable import ZwzCore

final class ZwzV2CompressorTests: XCTestCase {
    func testCompressesHiddenFileAndWritesReadableEncryptedOrPlainIndex() async throws {
        let fixture = try makeFixture()
        let output = fixture.dir.appendingPathComponent("out.zwz")
        let compressor = ZwzV2Compressor(options: ZwzV2Options(blockSize: 32 * 1024, compressionLevel: .normal, threadCount: 2))

        let urls = try await compressor.compress(sourceURLs: [fixture.root], to: output)

        XCTAssertEqual(urls.count, 1)
        let archive = try Data(contentsOf: urls[0])
        let header = try ZwzV2BinaryCodec.decodeHeader(archive.prefix(ZwzV2Header.encodedLength))
        let footerStart = archive.count - ZwzV2Footer.encodedLength
        let footer = try ZwzV2BinaryCodec.decodeFooter(archive[footerStart..<archive.count])
        let indexStart = Int(footer.indexOffset)
        let indexEnd = indexStart + Int(footer.indexLength)
        let index = try ZwzV2IndexCodec.decodeFromArchive(
            payload: archive[indexStart..<indexEnd],
            tag: Data(),
            context: nil
        )

        XCTAssertEqual(header.archiveID, index.archiveID)
        XCTAssertTrue(index.entries.contains { $0.path == ".hidden.txt" && $0.isHidden })
    }

    private func makeFixture() throws -> (dir: URL, root: URL) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        let root = dir.appendingPathComponent("root")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(String(repeating: "hello\n", count: 10_000).utf8).write(to: root.appendingPathComponent("visible.txt"))
        try Data("secret".utf8).write(to: root.appendingPathComponent(".hidden.txt"))
        return (dir, root)
    }
}
```

- [ ] **Step 2: Run tests to verify failure**

Run: `swift test --filter ZwzV2CompressorTests`

Expected: fails because compressor is not implemented.

- [ ] **Step 3: Implement bounded compression pipeline**

Implementation shape:
- Enumerate source items deterministically.
- Emit directory entries immediately into the pending index.
- For files, read chunks of `options.blockSize`.
- Use `withThrowingTaskGroup` with at most `options.maxInFlightBlocks` outstanding block jobs.
- Each job returns `ZwzV2EncodedArchiveBlock(sequence, entryPath, fileOffset, originalLength, codec, checksum, ciphertextOrPayload, tag)`.
- A single ordered writer buffers completed results in `[UInt64: ZwzV2EncodedArchiveBlock]` and writes only the next expected sequence.
- The writer records `archiveOffset`, stored length, tag, checksum, and codec in `ZwzV2BlockDescriptor`.
- After all blocks, encode and optionally encrypt index, write footer, finalize volumes.

Keep these private structs inside `ZwzV2Compressor.swift`:

```swift
private struct ZwzV2EncodedArchiveBlock {
    var sequence: UInt64
    var entryPath: String
    var fileOffset: UInt64
    var originalLength: UInt32
    var codec: ZwzV2Codec
    var checksum: UInt32
    var payload: Data
    var tag: Data
}
```

- [ ] **Step 4: Run tests**

Run: `swift test --filter ZwzV2CompressorTests`

Expected: pass.

- [ ] **Step 5: Checkpoint**

Record: "Task 9 verified with `swift test --filter ZwzV2CompressorTests`."

---

### Task 10: Preview and Multithreaded Extractor

**Files:**
- Create: `Sources/ZwzCore/ZWZV2/ZwzV2Extractor.swift`
- Create: `Sources/ZwzCore/ZWZV2/ZwzV2RecoveryReport.swift`
- Test: `Tests/ZwzCoreTests/ZWZV2/ZwzV2ExtractorTests.swift`

**Interfaces:**
- Produces:
  - `public final class ZwzV2Extractor`
  - `public func preview(archiveURLs: [URL], password: String?) async throws -> ZwzV2Index`
  - `public func extractAll(archiveURLs: [URL], to destination: URL, password: String?) async throws -> ZwzV2RecoveryReport`
  - `public func extractEntry(path: String, archiveURLs: [URL], to destination: URL, password: String?) async throws -> ZwzV2RecoveryReport`
  - `public struct ZwzV2RecoveryReport: Equatable`

- [ ] **Step 1: Write extractor tests**

Create `Tests/ZwzCoreTests/ZWZV2/ZwzV2ExtractorTests.swift`:

```swift
import XCTest
@testable import ZwzCore

final class ZwzV2ExtractorTests: XCTestCase {
    func testExtractsSingleEntryWithoutExtractingUnrequestedSibling() async throws {
        let fixture = try makeFixture()
        let archive = fixture.dir.appendingPathComponent("out.zwz")
        let urls = try await ZwzV2Compressor(options: ZwzV2Options(blockSize: 16 * 1024, threadCount: 2)).compress(sourceURLs: [fixture.root], to: archive)
        let destination = fixture.dir.appendingPathComponent("extract")

        let report = try await ZwzV2Extractor(options: ZwzV2Options(threadCount: 2)).extractEntry(path: "a.txt", archiveURLs: urls, to: destination, password: nil)

        XCTAssertTrue(report.failedEntries.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("a.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("b.txt").path))
    }

    private func makeFixture() throws -> (dir: URL, root: URL) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        let root = dir.appendingPathComponent("root")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(String(repeating: "a", count: 100_000).utf8).write(to: root.appendingPathComponent("a.txt"))
        try Data(String(repeating: "b", count: 100_000).utf8).write(to: root.appendingPathComponent("b.txt"))
        return (dir, root)
    }
}
```

- [ ] **Step 2: Run tests to verify failure**

Run: `swift test --filter ZwzV2ExtractorTests`

Expected: fails until extractor reads footer/index and materializes requested blocks.

- [ ] **Step 3: Implement preview**

Preview steps:
- Open logical reader.
- Read header from offset `0`.
- Read footer from logical end minus `ZwzV2Footer.encodedLength`.
- Validate matching archiveID and version.
- Derive crypto context when encrypted; throw `wrongPasswordOrTamperedData` when password is missing or wrong.
- Read and decode index only; do not read block payloads.
- Validate paths and duplicate conflicts.

- [ ] **Step 4: Implement extraction**

Extraction steps:
- Use preview path to get verified index.
- Filter entries for all or selected path.
- Create directories first.
- Schedule block jobs with at most `options.maxInFlightBlocks`.
- Each job reads the block record at `archiveOffset`, authenticates/decrypts when needed, decompresses, verifies checksum and length, then returns `(path, fileOffset, data)`.
- A per-file writer actor serializes `seek + write` calls while decode work stays parallel.
- Strict mode deletes unfinished outputs on first failure.
- Recovery mode writes incomplete files with `.partial.zwz-recovered` suffix and records failed block sequences.

- [ ] **Step 5: Run tests**

Run: `swift test --filter ZwzV2ExtractorTests`

Expected: pass.

- [ ] **Step 6: Checkpoint**

Record: "Task 10 verified with `swift test --filter ZwzV2ExtractorTests`."

---

### Task 11: Security, Split, Recovery, and Large-Data Regression Tests

**Files:**
- Test: `Tests/ZwzCoreTests/ZWZV2/ZwzV2RoundTripTests.swift`
- Test: `Tests/ZwzCoreTests/ZWZV2/ZwzV2SecurityTests.swift`
- Test: `Tests/ZwzCoreTests/ZWZV2/ZwzV2RecoveryTests.swift`

**Interfaces:**
- Consumes all v2 public interfaces.
- Produces higher confidence before routing app API to v2.

- [ ] **Step 1: Add round-trip tests**

Create `Tests/ZwzCoreTests/ZWZV2/ZwzV2RoundTripTests.swift` covering:

```swift
func testRoundTripEmptyDirectoryAndEmptyFile() async throws
func testRoundTripUnicodeLongPathsAndHiddenFiles() async throws
func testRoundTripFileSpanningManyBlocks() async throws
func testRoundTripSplitArchiveSpanningVolumes() async throws
```

Each test compresses a temporary fixture, extracts it, and compares relative file list plus file bytes.

- [ ] **Step 2: Add security tests**

Create `Tests/ZwzCoreTests/ZWZV2/ZwzV2SecurityTests.swift` covering:

```swift
func testPasswordArchivePreviewRequiresPassword() async throws
func testPasswordArchiveDoesNotExposeFileNameBytes() async throws
func testWrongPasswordFailsBeforeOutput() async throws
func testTamperedBlockFailsAuthenticationOrChecksum() async throws
func testUnsafeIndexPathIsRejectedBeforeWriting() async throws
```

- [ ] **Step 3: Add recovery tests**

Create `Tests/ZwzCoreTests/ZWZV2/ZwzV2RecoveryTests.swift` covering:

```swift
func testStrictModeRemovesPartialOutputAfterCorruptBlock() async throws
func testRecoveryModeKeepsValidSiblingAndReportsFailedEntry() async throws
func testMissingSplitVolumeReportsSpecificError() async throws
```

- [ ] **Step 4: Run the v2 test suite**

Run: `swift test --filter ZWZV2`

Expected: all v2 tests pass. Memory use should stay stable during `testRoundTripFileSpanningManyBlocks`.

- [ ] **Step 5: Checkpoint**

Record: "Task 11 verified with `swift test --filter ZWZV2`."

---

### Task 12: Route Existing Core API Through ZWZ v2

**Files:**
- Modify: `Sources/ZwzCore/ZwzCompressor.swift`
- Modify: `Sources/ZwzCore/ZwzExtractor.swift`
- Modify: `Sources/ZwzCore/ArchivePreviewer.swift`
- Modify: `Sources/ZwzCore/ZwzAPI.swift`
- Modify: `Sources/ZwzCore/Types.swift`
- Test: `Tests/ZwzCoreTests/ZwzV2APITests.swift`

**Interfaces:**
- Consumes v2 compressor/extractor.
- Produces the same app-facing public API names currently used by GUI and CLI.

- [ ] **Step 1: Write API compatibility tests**

Create `Tests/ZwzCoreTests/ZwzV2APITests.swift`:

```swift
import XCTest
@testable import ZwzCore

final class ZwzV2APITests: XCTestCase {
    func testPublicAPIWritesV2ArchiveAndListIncludesHiddenFileForGuiFiltering() throws {
        let fixture = try makeFixture()
        let archive = fixture.dir.appendingPathComponent("api.zwz")
        let api = ZwzAPI()

        _ = try api.compress(
            sourcePath: fixture.root.path,
            destinationPath: archive.path,
            options: CompressionOptions(format: .zwz)
        )
        let bytes = try Data(contentsOf: archive)
        XCTAssertEqual(Array(bytes.prefix(4)), ZwzV2Format.magic)

        let entries = try api.list(archivePath: archive.path)

        XCTAssertTrue(entries.contains { $0.path == ".hidden.txt" })
    }

    private func makeFixture() throws -> (dir: URL, root: URL) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        let root = dir.appendingPathComponent("root")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("shown".utf8).write(to: root.appendingPathComponent("visible.txt"))
        try Data("hidden".utf8).write(to: root.appendingPathComponent(".hidden.txt"))
        return (dir, root)
    }
}
```

This uses the current public API surface from `ZwzAPI.swift` and `Types.swift`: `ZwzAPI().compress(sourcePath:destinationPath:options:progress:)`, `ZwzAPI().list(archivePath:)`, and `CompressionOptions(format: .zwz)`.

- [ ] **Step 2: Run test to verify current API does not use v2**

Run: `swift test --filter ZwzV2APITests`

Expected: fails until public API routes through v2.

- [ ] **Step 3: Map public options to v2 options**

Mapping:
- Existing compression level -> `ZwzV2CompressionLevel`.
- Existing password -> `ZwzV2Options.password`.
- Existing split volume size -> `ZwzV2Options.splitVolumeSize`.
- Existing automatic/manual thread setting -> `ZwzV2Options.threadCount`.
- Existing hidden-file behavior affects source inclusion and preview filtering, not archive capability.
- Existing preview folder-size display uses index entry sizes, so folder sizes are sum of descendants and no longer `0 KB`.

- [ ] **Step 4: Add old v1 unsupported detection**

When header magic/version indicates the old `.zwz` format, throw `ZwzV2Error.unsupportedVersion(1)` and map it to localized UI text.

- [ ] **Step 5: Run API tests**

Run: `swift test --filter ZwzV2APITests`

Expected: pass.

- [ ] **Step 6: Checkpoint**

Record: "Task 12 verified with `swift test --filter ZwzV2APITests`."

---

### Task 13: GUI Messages and Settings Integration

**Files:**
- Modify: `Sources/ZwzGUI/ArchiveViewModel.swift`
- Modify: `Sources/ZwzGUI/Localization.swift`
- Test: `Tests/ZwzCoreTests/ZwzHiddenFilePreviewTests.swift`
- Test: `Tests/ZwzCoreTests/ArchiveEntryPresentationTests.swift`

**Interfaces:**
- Consumes existing GUI settings for preview hidden-file toggle.
- Produces clear user-facing messages for password-required preview, unsupported v1, recovery results, and failed compression.

- [ ] **Step 1: Extend existing tests**

Update `Tests/ZwzCoreTests/ZwzHiddenFilePreviewTests.swift` to assert:

```swift
XCTAssertFalse(defaultPreviewEntries.contains { $0.path.hasPrefix(".") || $0.path.contains("/.") })
XCTAssertTrue(showHiddenPreviewEntries.contains { $0.path == ".hidden.txt" })
```

Update `Tests/ZwzCoreTests/ArchiveEntryPresentationTests.swift` to assert folder display size is the sum of descendant file sizes.

- [ ] **Step 2: Run existing presentation tests**

Run: `swift test --filter ZwzHiddenFilePreviewTests`

Expected: pass after v2 preview filtering is connected.

Run: `swift test --filter ArchiveEntryPresentationTests`

Expected: pass after folder-size calculation uses descendant sizes.

- [ ] **Step 3: Update GUI localization**

Add localized strings:
- English: `Unsupported ZWZ archive version. Please recompress this folder with the current app.`
- Chinese: `不支持旧版 ZWZ 压缩包，请使用当前版本重新压缩。`
- English: `Password required to preview this encrypted archive.`
- Chinese: `预览此加密压缩包需要密码。`
- English: `Recovery completed with partial files.`
- Chinese: `恢复完成，部分文件已作为不完整文件输出。`

- [ ] **Step 4: Update view model error mapping**

Map `ZwzV2Error.unsupportedVersion`, `wrongPasswordOrTamperedData`, `missingVolume`, and recovery report failures into existing alert state. Keep the hidden-file preview setting in settings and default it to off.

- [ ] **Step 5: Run GUI-related test subset**

Run: `swift test --filter ZwzHiddenFilePreviewTests`

Expected: pass.

Run: `swift test --filter ArchiveEntryPresentationTests`

Expected: pass.

- [ ] **Step 6: Checkpoint**

Record: "Task 13 verified with hidden-preview and presentation tests."

---

### Task 14: Final Verification and Benchmark Smoke Test

**Files:**
- Modify: `README.md`
- Test: full test suite

**Interfaces:**
- Produces a verified user-facing implementation.

- [x] **Step 1: Update README format note**

Add a short note that `.zwz` archives are v2-only, old archives are not supported, and password archives hide filenames until a password is provided.

- [x] **Step 2: Run all tests**

Run: `swift test`

Expected: all tests pass.

- [x] **Step 3: Run app build**

Run: `swift build`

Expected: build succeeds.

- [x] **Step 4: Manual smoke scenario**

Use the app or CLI to run:
- Compress a folder containing `visible.txt`, `.hidden.txt`, an empty directory, and a 20 MiB text file.
- Preview with hidden files off: `.hidden.txt` is not shown.
- Preview with hidden files on: `.hidden.txt` is shown.
- Extract only `visible.txt`: no other file appears.
- Compress with password: preview asks for password and names are not visible without it.
- Compress with split size: output volumes are created and preview/extraction works with all volumes present.

- [x] **Step 5: Record verification results**

Record exact outcomes in this plan file under a `Verification Results` section. Do not claim completion if any command fails.

## Verification Results

Verified on 2026-07-11:

- `swift build` succeeded for all products.
- Final `swift test` executed 88 tests with 0 failures in 192.565 seconds.
- A CLI smoke fixture containing `visible.txt`, `.hidden.txt`, an empty directory, and a 20,018,271-byte text file compressed to ZWZ v2, listed all four entries, extracted successfully, and retained hidden and empty entries.
- Hidden-path filtering, single-entry extraction without siblings, encrypted filename privacy, and password-required preview were re-run as a focused five-test subset with 0 failures.
- Password-protected CLI compression succeeded; passwordless preview failed before exposing index entries, as designed.
- A 2 MiB incompressible payload produced nine split files (`multi.z00` through `multi.z07`, plus final `multi.zwz`). Preview and extraction from the final volume succeeded, and `cmp` confirmed byte-identical output.
- The split-volume smoke test exposed a public API volume-discovery defect for `.zNN` files. The compatibility adapter now identifies `.zNN` names and orders volumes by the encoded envelope `volumeNumber`; a public API regression test covers listing and extraction from the final volume.

---

## Self-Review

- Spec coverage: The tasks cover v2-only format, unsupported v1 errors, bounded block compression, adaptive codec choice, password-encrypted index and blocks, split volumes, preview, individual extraction, hidden files, strict/recovery policies, and multithreaded compression/decompression.
- Placeholder scan: The plan contains no banned marker words, no unresolved future step, and no vague error-handling step without concrete expected behavior.
- Type consistency: Later tasks consume `ZwzV2Options`, `ZwzV2Index`, `ZwzV2Entry`, `ZwzV2BlockDescriptor`, `ZwzV2CryptoContext`, `ZwzV2Compressor`, and `ZwzV2Extractor` exactly as introduced earlier.
- Local repository state: `/Users/jiangzhiwan/Desktop/ZwZ` is not a Git repository, so this plan uses checkpoint notes instead of commits.
