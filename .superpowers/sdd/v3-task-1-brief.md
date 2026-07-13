### Task 1: Public Types and Encryption-Mode Compatibility

**Files:**
- Create: `Sources/ZwzCore/ZWZV3/ZwzV3Types.swift`
- Modify: `Sources/ZwzCore/Types.swift`
- Create: `Tests/ZwzCoreTests/ZWZV3/ZwzV3TypesTests.swift`

**Interfaces:**
- Produces: `ZwzEncryptionMode`, `ZwzRecipient`, `ZwzSigningIdentity`, `ZwzSignatureVerification`, `ZwzArchiveSecurityInfo`, and `ZwzV3Error`.
- Preserves: `CompressionOptions(password:)` by mapping it to `.password` or `.none`.

- [ ] **Step 1: Write failing construction and exclusivity tests**

```swift
func testCompressionOptionsMapsLegacyPassword() {
    XCTAssertEqual(CompressionOptions(password: "secret", format: .zwz).encryption, .password("secret"))
    XCTAssertEqual(CompressionOptions(format: .zwz).encryption, .none)
}

func testPublicKeyModeRequiresRecipient() {
    XCTAssertThrowsError(try ZwzEncryptionMode.publicKey(recipients: [], signer: nil).validated()) {
        XCTAssertEqual($0 as? ZwzV3Error, .recipientRequired)
    }
}
```

- [ ] **Step 2: Run the new test and verify it fails**

Run: `swift test --filter ZwzV3TypesTests`

Expected: compilation fails because the version-3 types do not exist.

- [ ] **Step 3: Add exact public type shapes and legacy mapping**

```swift
public enum ZwzEncryptionMode: Equatable, Sendable {
    case none
    case password(String)
    case publicKey(recipients: [ZwzRecipient], signer: ZwzSigningIdentity?)

    public func validated() throws -> Self {
        if case .publicKey(let recipients, _) = self, recipients.isEmpty {
            throw ZwzV3Error.recipientRequired
        }
        return self
    }
}

public struct ZwzRecipient: Equatable, Sendable {
    public let name: String
    public let fingerprint: String
    public let agreementPublicKey: Data
}

public struct ZwzSigningIdentity: Equatable, Sendable {
    public let name: String
    public let fingerprint: String
}

public enum ZwzSignatureVerification: Equatable, Sendable {
    case unsigned
    case validKnownSigner(name: String, fingerprint: String)
    case validUnknownSigner(name: String, fingerprint: String)
    case invalid
}
```

Add `encryption: ZwzEncryptionMode` to `CompressionOptions`. Keep the existing initializer and assign `encryption = password.map(ZwzEncryptionMode.password) ?? .none`; add a new initializer that accepts `encryption` directly so public-key callers cannot also pass `password`.

- [ ] **Step 4: Run compatibility tests**

Run: `swift test --filter ZwzV3TypesTests && swift test --filter ZwzCoreTests`

Expected: new tests pass; existing core tests remain green.

- [ ] **Step 5: Commit**

```bash
git add Sources/ZwzCore/Types.swift Sources/ZwzCore/ZWZV3/ZwzV3Types.swift Tests/ZwzCoreTests/ZWZV3/ZwzV3TypesTests.swift
git commit -m "feat: add explicit ZWZ encryption modes"
```

