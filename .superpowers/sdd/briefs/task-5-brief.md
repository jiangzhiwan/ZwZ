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
