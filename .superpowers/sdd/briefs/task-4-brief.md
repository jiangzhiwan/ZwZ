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
