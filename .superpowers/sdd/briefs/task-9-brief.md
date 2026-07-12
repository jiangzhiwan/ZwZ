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
