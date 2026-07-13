### Task 2: Crypto Primitives and Recipient Key Wrapping

**Files:**
- Create: `Sources/ZwzCore/ZWZV3/ZwzV3Crypto.swift`
- Create: `Tests/ZwzCoreTests/ZWZV3/ZwzV3CryptoTests.swift`
- Create: `Tests/ZwzCoreTests/ZWZV3/ZwzV3CryptoTestSupport.swift`

**Interfaces:**
- Consumes: `ZwzRecipient`, `ZwzSigningIdentity`, `ZwzV3Error`.
- Produces: `ZwzV3RecipientEnvelope`, `ZwzV3SignerRecord`, and static methods on `ZwzV3Crypto`.

- [ ] **Step 1: Write known-behavior crypto tests**

```swift
func testAnyRecipientCanUnwrapSameContentKey() throws {
    let alice = Curve25519.KeyAgreement.PrivateKey()
    let bob = Curve25519.KeyAgreement.PrivateKey()
    let contentKey = SymmetricKey(size: .bits256)
    let archiveID = UUID()
    let envelopes = try ZwzV3Crypto.wrap(contentKey: contentKey, recipients: [
        .init(name: "Alice", publicKey: alice.publicKey.rawRepresentation),
        .init(name: "Bob", publicKey: bob.publicKey.rawRepresentation)
    ], archiveID: archiveID)
    XCTAssertEqual(try ZwzV3Crypto.unwrap(envelopes[0], privateKey: alice, archiveID: archiveID).bytes,
                   contentKey.bytes)
    XCTAssertEqual(try ZwzV3Crypto.unwrap(envelopes[1], privateKey: bob, archiveID: archiveID).bytes,
                   contentKey.bytes)
}

func testWrongRecipientAndTamperedEnvelopeFailAuthentication() throws {
    var envelope = try XCTUnwrap(makeWrappedFixture().envelopes.first)
    envelope.ciphertext[0] ^= 0x01
    XCTAssertThrowsError(try ZwzV3Crypto.unwrap(envelope, privateKey: makeWrappedFixture().wrongKey,
                                                archiveID: makeWrappedFixture().archiveID))
}

func testEd25519SignatureRejectsChangedCanonicalBytes() throws {
    let key = Curve25519.Signing.PrivateKey()
    let original = Data("archive".utf8)
    let signature = try ZwzV3Crypto.sign(original, privateKey: key)
    XCTAssertFalse(ZwzV3Crypto.verify(signature, bytes: Data("Archive".utf8),
                                      publicKey: key.publicKey.rawRepresentation))
}
```

- [ ] **Step 2: Run and observe failure**

Run: `swift test --filter ZwzV3CryptoTests`

Expected: compilation fails for missing `ZwzV3Crypto`.

- [ ] **Step 3: Implement the minimal primitive API**

```swift
enum ZwzV3Crypto {
    static func fingerprint(agreement: Data, signing: Data?) -> String
    static func wrap(contentKey: SymmetricKey, recipients: [ZwzRecipientPublicMaterial], archiveID: UUID) throws -> [ZwzV3RecipientEnvelope]
    static func unwrap(_ envelope: ZwzV3RecipientEnvelope, privateKey: Curve25519.KeyAgreement.PrivateKey, archiveID: UUID) throws -> SymmetricKey
    static func seal(_ plaintext: Data, key: SymmetricKey, nonce: AES.GCM.Nonce, aad: Data) throws -> Data
    static func open(_ combined: Data, key: SymmetricKey, aad: Data) throws -> Data
    static func sign(_ bytes: Data, privateKey: Curve25519.Signing.PrivateKey) throws -> Data
    static func verify(_ signature: Data, bytes: Data, publicKey: Data) -> Bool
}
```

Generate one ephemeral X25519 key per `wrap` call. Derive each wrapping key with `sharedSecret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: archiveID.bytes, sharedInfo: Data("ZWZ3 key wrap".utf8), outputByteCount: 32)`. Bind archive ID, recipient fingerprint, and ephemeral public key as AES-GCM authenticated data. Convert all CryptoKit failures to `ZwzV3Error.keyUnwrapFailed` or `.authenticationFailed` without exposing key material.

Define `makeWrappedFixture()` in `ZwzV3CryptoTestSupport.swift`. Add internal UUID-to-bytes and `SymmetricKey`-to-test-bytes helpers; do not expose content-key bytes in the public API.

- [ ] **Step 4: Run crypto and mutation tests**

Run: `swift test --filter ZwzV3CryptoTests`

Expected: all tests pass, including wrong key and every single-byte mutation case.

- [ ] **Step 5: Commit**

```bash
git add Sources/ZwzCore/ZWZV3/ZwzV3Crypto.swift Tests/ZwzCoreTests/ZWZV3/ZwzV3CryptoTests.swift
git commit -m "feat: add ZWZ recipient wrapping and signatures"
```

