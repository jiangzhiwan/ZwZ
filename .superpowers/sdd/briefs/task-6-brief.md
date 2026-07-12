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
