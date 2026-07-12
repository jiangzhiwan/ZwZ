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
