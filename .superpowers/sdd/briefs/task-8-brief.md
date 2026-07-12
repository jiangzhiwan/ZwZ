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
