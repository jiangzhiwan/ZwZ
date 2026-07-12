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
