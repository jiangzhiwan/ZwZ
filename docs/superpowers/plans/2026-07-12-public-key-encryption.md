# ZWZ Public-Key Encryption Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add multi-recipient X25519 encryption, optional Ed25519 signatures, protected identity management, and consistent ZwzCore/CLI/GUI workflows while preserving all existing ZWZ archives.

**Architecture:** Introduce a version-3 ZWZ codec beside the existing version-1 reader and the ignored experimental version-2 sources. Version 3 encrypts blocks and the index with a random AES-256-GCM content key, wraps that key once per X25519 recipient, and optionally signs the complete canonical archive with Ed25519. ZwzCore owns the format, crypto, key-file, and Keychain abstractions; CLI and GUI only orchestrate those APIs.

**Tech Stack:** Swift 6.3, macOS 15+, Foundation, CryptoKit, Security, LocalAuthentication, CryptoSwift, XCTest, SwiftUI.

## Global Constraints

- Continue using the `.zwz` extension and identify version 3 from the file header.
- Preserve existing unencrypted and password-encrypted ZWZ preview/extraction without conversion.
- Encryption modes are exactly `.none`, `.password`, and `.publicKey`; password and recipients cannot coexist.
- Use X25519 for recipient agreement, HKDF-SHA-256 for wrapping-key derivation, AES-256-GCM for content and key wrapping, and Ed25519 for optional signatures.
- A public-key archive has one or more recipients and zero or one signer.
- Private-key unwrap and signing must require Touch ID or Mac login password on every production use.
- Private keys may only be exported in an AES-256-GCM backup protected by scrypt N=65,536, r=8, p=1 and a random 16-byte salt.
- Do not log passwords, private keys, content keys, shared secrets, or derived keys.
- Existing unrelated worktree changes must not be staged or committed.

---

## File Structure

Create focused version-3 files under `Sources/ZwzCore/ZWZV3/`:

- `ZwzV3Types.swift`: public encryption modes, identities, recipient records, signature results, and errors.
- `ZwzV3Crypto.swift`: fingerprinting, key agreement, HKDF, AES-GCM sealing, signing, and verification.
- `ZwzV3BinaryCodec.swift`: canonical version-3 header, recipient envelope, signature trailer, and bounds-checked parsing.
- `ZwzV3ArchiveCodec.swift`: block/index serialization and authenticated-data construction.
- `ZwzV3Compressor.swift`: atomic archive creation, splitting, progress, and cancellation.
- `ZwzV3Extractor.swift`: list, full extraction, and single-entry extraction.
- `ZwzKeyFileCodec.swift`: public-key files and password-protected private backups.
- `ZwzIdentityStore.swift`: identity/contact protocols and in-memory test store.
- `MacKeychainIdentityStore.swift`: Security/LocalAuthentication production store.

Modify existing routing and product files rather than duplicating them:

- `Sources/ZwzCore/Types.swift`, `ZwzAPI.swift`, `ZwzCompressor.swift`, `ZwzExtractor.swift`, `ArchiveExtractor.swift`, and `ArchivePreviewer.swift` route explicit modes and version 3.
- `Sources/zwz/main.swift` parses key-management, recipient, and signer commands.
- `Sources/ZwzGUI/ArchiveViewModel.swift`, `ZwzApp.swift`, `Localization.swift`, `VirtualDiskManager.swift`, `ArchiveEditSession.swift`, and preview support expose the same workflows.

Tests mirror each responsibility under `Tests/ZwzCoreTests/ZWZV3/` plus focused CLI/GUI-facing parser and view-model tests.

---

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

### Task 3: Canonical Version-3 Binary Envelope

**Files:**
- Create: `Sources/ZwzCore/ZWZV3/ZwzV3BinaryCodec.swift`
- Create: `Sources/ZwzCore/ZWZV3/ZwzV3ArchiveCodec.swift`
- Create: `Tests/ZwzCoreTests/ZWZV3/ZwzV3BinaryCodecTests.swift`
- Create: `Tests/ZwzCoreTests/ZWZV3/ZwzV3BinaryCodecTestSupport.swift`

**Interfaces:**
- Consumes: recipient envelopes and signer records from Task 2.
- Produces: `ZwzV3Header`, `ZwzV3ParsedArchive`, `ZwzV3BinaryCodec.encodeHeader`, `parse`, and `canonicalSignedBytes`.

- [ ] **Step 1: Write round-trip, bounds, and canonicalization tests**

```swift
func testHeaderRoundTripPreservesAlgorithmsAndOffsets() throws {
    let header = ZwzV3Header.fixture(recipientCount: 2, signed: true)
    XCTAssertEqual(try ZwzV3BinaryCodec.decodeHeader(ZwzV3BinaryCodec.encodeHeader(header)), header)
}

func testParserRejectsTruncatedAndOverlappingRegions() {
    XCTAssertThrowsError(try ZwzV3BinaryCodec.parse(Data([0x5A, 0x57, 0x5A, 0x33])))
    XCTAssertThrowsError(try ZwzV3BinaryCodec.parse(.fixtureWithOverlappingIndex()))
}

func testCanonicalBytesExcludeOnlySignatureValue() throws {
    let first = try ZwzV3BinaryCodec.parse(.signedFixture(signature: Data(repeating: 1, count: 64)))
    let second = try ZwzV3BinaryCodec.parse(.signedFixture(signature: Data(repeating: 2, count: 64)))
    XCTAssertEqual(first.canonicalSignedBytes, second.canonicalSignedBytes)
}
```

- [ ] **Step 2: Run and observe failure**

Run: `swift test --filter ZwzV3BinaryCodecTests`

Expected: missing codec types.

- [ ] **Step 3: Implement a bounds-checked codec**

Use magic `ZWZ3`, little-endian fixed-width integers, explicit algorithm IDs, counted UTF-8 strings, and checked `UInt64` arithmetic before every slice. Encode recipient and signer records in one canonical order. `canonicalSignedBytes` must concatenate the header with its signature offset/length fixed, recipient region, data region, and encrypted index, excluding only the 64-byte signature value.

Define `.fixture`, `.fixtureWithOverlappingIndex`, and `.signedFixture(signature:)` in `ZwzV3BinaryCodecTestSupport.swift`. Build valid fixtures with the production encoder; hand-build only the deliberately invalid overlapping-offset input.

```swift
struct ZwzV3ParsedArchive: Sendable {
    let header: ZwzV3Header
    let recipients: [ZwzV3RecipientEnvelope]
    let signer: ZwzV3SignerRecord?
    let encryptedIndex: Data
    let canonicalSignedBytes: Data
}
```

- [ ] **Step 4: Run codec tests and format fuzz corpus**

Run: `swift test --filter ZwzV3BinaryCodecTests`

Expected: round trips pass; truncation at every byte boundary and corrupt lengths return `.malformedArchive` without crashes.

- [ ] **Step 5: Commit**

```bash
git add Sources/ZwzCore/ZWZV3/ZwzV3BinaryCodec.swift Sources/ZwzCore/ZWZV3/ZwzV3ArchiveCodec.swift Tests/ZwzCoreTests/ZWZV3/ZwzV3BinaryCodecTests.swift
git commit -m "feat: define canonical ZWZ version 3 format"
```

### Task 4: Version-3 Compression, Preview, and Extraction

**Files:**
- Create: `Sources/ZwzCore/ZWZV3/ZwzV3Compressor.swift`
- Create: `Sources/ZwzCore/ZWZV3/ZwzV3Extractor.swift`
- Create: `Tests/ZwzCoreTests/ZWZV3/ZwzV3RoundTripTests.swift`
- Create: `Tests/ZwzCoreTests/ZWZV3/ZwzV3SecurityTests.swift`
- Create: `Tests/ZwzCoreTests/ZWZV3/ZwzV3TestSupport.swift`

**Interfaces:**
- Consumes: `ZwzEncryptionMode.publicKey`, `ZwzPrivateKeyProvider`, version-3 crypto and binary codecs.
- Produces: async-neutral synchronous methods matching current core call sites: `compress`, `listEntries`, `extractAll`, and `extractEntryToTemp`.

- [ ] **Step 1: Write end-to-end failing tests**

```swift
func testTwoRecipientsRoundTripHiddenEmptyUnicodeAndLargeFiles() throws {
    let fixture = try ZwzV3TestSupport.makeTwoRecipientArchive()
    try ZwzV3TestSupport.assertExtraction(fixture.archive, with: fixture.alice, equals: fixture.source)
    try ZwzV3TestSupport.assertExtraction(fixture.archive, with: fixture.bob, equals: fixture.source)
}
func testUnknownRecipientCannotListEncryptedIndex() throws {
    let fixture = try ZwzV3TestSupport.makeTwoRecipientArchive()
    XCTAssertThrowsError(try ZwzV3Extractor().listEntries(archivePath: fixture.archive.path,
                                                          keyProvider: fixture.mallory))
}
func testSignedArchiveReportsKnownAndUnknownSigner() throws {
    XCTAssertEqual(try ZwzV3TestSupport.signatureStatus(known: true).isKnown, true)
    XCTAssertEqual(try ZwzV3TestSupport.signatureStatus(known: false).isKnown, false)
}
func testMutationOfHeaderRecipientBlockIndexOrSignatureIsRejected() throws {
    for region in ZwzV3TestSupport.authenticatedRegions {
        XCTAssertThrowsError(try ZwzV3TestSupport.openArchiveMutated(in: region))
    }
}
func testCancellationLeavesNoFinalArchive() throws {
    let result = try ZwzV3TestSupport.cancelCompressionAfterFirstProgress()
    XCTAssertFalse(FileManager.default.fileExists(atPath: result.final.path))
    XCTAssertTrue(result.partialFiles.isEmpty)
}
```

- [ ] **Step 2: Run and observe failure**

Run: `swift test --filter ZwzV3RoundTripTests && swift test --filter ZwzV3SecurityTests`

Expected: missing compressor/extractor types.

- [ ] **Step 3: Implement atomic compressor and extractor**

```swift
public protocol ZwzPrivateKeyProvider: Sendable {
    func agreementPrivateKey(fingerprint: String, reason: String) throws -> Data
    func signingPrivateKey(fingerprint: String, reason: String) throws -> Data
    func isKnownSigningKey(fingerprint: String) -> Bool
}

public final class ZwzV3Compressor {
    public func compress(sourcePath: String, destinationPath: String, options: CompressionOptions,
                         keyProvider: ZwzPrivateKeyProvider?, progress: ProgressHandler?,
                         cancellationToken: CancellationToken?) throws
}

public final class ZwzV3Extractor {
    public func listEntries(archivePath: String, keyProvider: ZwzPrivateKeyProvider) throws -> ZwzArchiveListing
    public func extractAll(archivePath: String, destinationPath: String, keyProvider: ZwzPrivateKeyProvider,
                           progress: ProgressHandler?, cancellationToken: CancellationToken?) throws -> ZwzArchiveSecurityInfo
}
```

Write to `destinationPath + ".partial-<UUID>"`, close and verify the completed archive, then atomically move it into place. Derive unique nonces from a random archive nonce prefix plus block sequence; reject sequence overflow. Verify a signature before opening the index or writing extracted files. Reuse existing path validation and cancellation conventions.

Implement every `ZwzV3TestSupport` fixture and tree comparison in the listed support file under a unique temporary directory, with teardown that removes the directory.

- [ ] **Step 4: Run round-trip, security, cancellation, and split-volume tests**

Run: `swift test --filter ZwzV3`

Expected: all version-3 tests pass; no `.partial-*` artifacts remain.

- [ ] **Step 5: Commit**

```bash
git add Sources/ZwzCore/ZWZV3/ZwzV3Compressor.swift Sources/ZwzCore/ZWZV3/ZwzV3Extractor.swift Tests/ZwzCoreTests/ZWZV3
git commit -m "feat: add ZWZ version 3 archive workflows"
```

### Task 5: Key Files, Password-Protected Backups, and Stores

**Files:**
- Create: `Sources/ZwzCore/ZWZV3/ZwzKeyFileCodec.swift`
- Create: `Sources/ZwzCore/ZWZV3/ZwzIdentityStore.swift`
- Create: `Sources/ZwzCore/ZWZV3/MacKeychainIdentityStore.swift`
- Create: `Tests/ZwzCoreTests/ZWZV3/ZwzKeyFileCodecTests.swift`
- Create: `Tests/ZwzCoreTests/ZWZV3/ZwzIdentityStoreTests.swift`
- Create: `Tests/ZwzCoreTests/ZWZV3/ZwzKeyFileTestSupport.swift`

**Interfaces:**
- Produces: `ZwzPublicIdentity`, `ZwzIdentityMetadata`, `ZwzIdentityStore`, `InMemoryZwzIdentityStore`, and `MacKeychainIdentityStore`.
- Conforms: production and in-memory stores to `ZwzPrivateKeyProvider`.

- [ ] **Step 1: Write key lifecycle and backup tests**

```swift
func testPublicKeyExportImportKeepsFingerprint() throws {
    let identity = ZwzKeyFileTestSupport.identity()
    XCTAssertEqual(try ZwzKeyFileCodec.decodePublic(ZwzKeyFileCodec.encodePublic(identity)).fingerprint,
                   identity.fingerprint)
}
func testBackupContainsNeitherRawPrivateKey() throws {
    let fixture = try ZwzKeyFileTestSupport.backup(password: "correct horse battery staple")
    XCTAssertNil(fixture.encoded.range(of: fixture.agreementPrivateKey))
    XCTAssertNil(fixture.encoded.range(of: fixture.signingPrivateKey))
}
func testWrongPasswordAndEveryRegionMutationFailImport() throws {
    for data in try ZwzKeyFileTestSupport.wrongPasswordAndMutatedBackups() {
        XCTAssertThrowsError(try ZwzKeyFileCodec.decodeBackup(data, password: "wrong"))
    }
}
func testRestoredIdentityDecryptsAndSigns() throws {
    XCTAssertTrue(try ZwzKeyFileTestSupport.restoreThenDecryptAndSign())
}
func testDuplicateFingerprintRequiresExplicitConflictResolution() throws {
    XCTAssertThrowsError(try ZwzKeyFileTestSupport.importDuplicate(policy: .requireConfirmation))
}
```

- [ ] **Step 2: Run and observe failure**

Run: `swift test --filter 'ZwzKeyFileCodecTests|ZwzIdentityStoreTests'`

Expected: missing key-file/store types.

- [ ] **Step 3: Implement exact file and store contracts**

```swift
public protocol ZwzIdentityStore: ZwzPrivateKeyProvider {
    func createIdentity(named name: String) throws -> ZwzIdentityMetadata
    func identities() throws -> [ZwzIdentityMetadata]
    func contacts() throws -> [ZwzPublicIdentity]
    func importPublicIdentity(_ data: Data, conflict: ZwzIdentityConflictPolicy) throws -> ZwzPublicIdentity
    func exportPublicIdentity(fingerprint: String) throws -> Data
    func exportPrivateBackup(fingerprint: String, password: String) throws -> Data
    func importPrivateBackup(_ data: Data, password: String, conflict: ZwzIdentityConflictPolicy) throws -> ZwzIdentityMetadata
    func rename(fingerprint: String, to name: String) throws
    func delete(fingerprint: String) throws
}
```

Use CryptoSwift `Scrypt(password:salt:dkLen:N:r:p:)` with N=65,536, r=8, p=1 and AES-GCM from CryptoKit. Store algorithm IDs and parameters in the authenticated backup header. For Keychain private items create `SecAccessControl` with `.userPresence`; query private bytes with an `LAContext` and an operation-specific prompt every time. Store public metadata separately so listing never prompts.

Implement `ZwzKeyFileTestSupport` with fixed test-only keys, mutation offsets reported by the production parser, and `InMemoryZwzIdentityStore`; it must never query the real Keychain.

- [ ] **Step 4: Run isolated tests and a signed macOS Keychain integration test**

Run: `swift test --filter 'ZwzKeyFileCodecTests|ZwzIdentityStoreTests'`

Expected: unit tests pass. Run the manual integration fixture from an app-signed build and confirm one system prompt per unwrap/sign operation, password fallback, and distinct user-cancel error.

- [ ] **Step 5: Commit**

```bash
git add Sources/ZwzCore/ZWZV3/ZwzKeyFileCodec.swift Sources/ZwzCore/ZWZV3/ZwzIdentityStore.swift Sources/ZwzCore/ZWZV3/MacKeychainIdentityStore.swift Tests/ZwzCoreTests/ZWZV3
git commit -m "feat: add protected ZWZ identity management"
```

### Task 6: Route Version 3 Through Existing Core APIs

**Files:**
- Modify: `Sources/ZwzCore/ZwzAPI.swift`
- Modify: `Sources/ZwzCore/ZwzCompressor.swift`
- Modify: `Sources/ZwzCore/ZwzExtractor.swift`
- Modify: `Sources/ZwzCore/ArchiveExtractor.swift`
- Modify: `Sources/ZwzCore/ArchivePreviewer.swift`
- Create: `Tests/ZwzCoreTests/ZWZV3/ZwzV3APITests.swift`
- Create: `Tests/ZwzCoreTests/ZWZV3/ZwzV3APITestSupport.swift`

**Interfaces:**
- Consumes: Task 4 archive workflows and Task 5 key provider.
- Produces: overloads of `ZwzAPI.compress`, `extract`, `list`, and `extractEntryToTemp` accepting `keyProvider`, while preserving legacy signatures.

- [ ] **Step 1: Write API routing and backward-compatibility tests**

```swift
func testAPIWritesV3OnlyForPublicKeyMode() throws {
    XCTAssertEqual(try ZwzV3APITestSupport.createdArchiveVersion(encryption: .publicKeyFixture), 3)
}
func testAPIAutoDetectsV1AndV3() throws {
    XCTAssertEqual(try ZwzV3APITestSupport.list(version: 1).map(\.path), ["file.txt"])
    XCTAssertEqual(try ZwzV3APITestSupport.list(version: 3).map(\.path), ["file.txt"])
}
func testLegacyPasswordInitializerStillRoundTripsV1() throws {
    XCTAssertTrue(try ZwzV3APITestSupport.legacyPasswordRoundTrip())
}
func testPasswordAndZIPRoutesAreUnchanged() throws {
    XCTAssertTrue(try ZwzV3APITestSupport.existingNonV3RoutesPass())
}
```

- [ ] **Step 2: Run and observe routing failure**

Run: `swift test --filter ZwzV3APITests`

Expected: public-key overloads or version routing are missing.

- [ ] **Step 3: Add magic/version dispatch and structured results**

```swift
public func list(archivePath: String, password: String? = nil,
                 keyProvider: ZwzPrivateKeyProvider? = nil) throws -> ZwzArchiveListing

public func extract(archivePath: String, destinationPath: String? = nil,
                    password: String? = nil, keyProvider: ZwzPrivateKeyProvider? = nil,
                    progress: ProgressHandler? = nil,
                    cancellationToken: CancellationToken? = nil) throws -> ZwzExtractionResult
```

Read only the magic/version prefix before selecting `ZwzExtractor` or `ZwzV3Extractor`. Map the old `[ArchiveEntry]` list API to `listing.entries` and the old string-returning extract API to `result.destinationPath` so source compatibility is retained.

Implement `ZwzV3APITestSupport` with temporary version-1, version-3, and ZIP archives created through the corresponding public compressors.

- [ ] **Step 4: Run API and legacy regression suites**

Run: `swift test --filter ZwzV3APITests && swift test --filter ZwzCoreTests`

Expected: version 1 and version 3 pass; ZIP/RAR/7Z/TAR/GZ tests remain green.

- [ ] **Step 5: Commit**

```bash
git add Sources/ZwzCore/ZwzAPI.swift Sources/ZwzCore/ZwzCompressor.swift Sources/ZwzCore/ZwzExtractor.swift Sources/ZwzCore/ArchiveExtractor.swift Sources/ZwzCore/ArchivePreviewer.swift Tests/ZwzCoreTests/ZWZV3/ZwzV3APITests.swift
git commit -m "feat: route public-key archives through ZwzCore"
```

### Task 7: CLI Key Management and Public-Key Workflows

**Files:**
- Modify: `Sources/zwz/main.swift`
- Create: `Sources/zwz/CLIArguments.swift`
- Modify: `Package.swift`
- Create: `Tests/ZwzCLITests/CLIArgumentsTests.swift`

**Interfaces:**
- Consumes: `MacKeychainIdentityStore`, explicit encryption modes, structured signature results.
- Produces CLI commands `key create|list|rename|delete|export-public|import-public|backup|restore`, repeatable `--recipient`, and optional `--sign`.

- [ ] **Step 1: Extract parsing and write failing parser tests**

```swift
func testCompressParsesMultipleRecipientsAndSigner() throws {
    let command = try CLIArguments.parse(["compress", "-f", "zwz", "--recipient", "Alice", "--recipient", "Bob", "--sign", "Me", "input"])
    XCTAssertEqual(command, .compress(.init(recipients: ["Alice", "Bob"], signer: "Me", source: "input")))
}

func testParserRejectsPasswordWithRecipient() {
    XCTAssertThrowsError(try CLIArguments.parse(["compress", "-p", "x", "--recipient", "Alice", "input"]))
}
```

- [ ] **Step 2: Run and observe failure**

Run: `swift test --filter ZwzCLITests`

Expected: `CLIArguments` does not exist.

- [ ] **Step 3: Implement parser and command handlers**

Resolve recipient names or fingerprints uniquely through `ZwzIdentityStore`; ambiguous names print matching fingerprints and exit nonzero. Key backup/restore passwords must be read with terminal echo disabled when attached to a TTY, never accepted as an environment variable, and never printed. Print signature status after list/extract. If no matching key exists, print recipient names/fingerprints and the exact `zwz key restore <backup>` command.

Move command dispatch behind `ZwzCLI.run(arguments:)` so parsing is importable in tests. Add `.testTarget(name: "ZwzCLITests", dependencies: ["zwz"], path: "Tests/ZwzCLITests")` to `Package.swift`.

- [ ] **Step 4: Run parser tests and CLI smoke tests**

Run: `swift test --filter ZwzCLITests && swift run zwz help`

Expected: help lists all new commands; invalid mixed modes fail before reading input; version-1 commands retain syntax.

- [ ] **Step 5: Commit**

```bash
git add Package.swift Sources/zwz/main.swift Sources/zwz/CLIArguments.swift Tests/ZwzCLITests/CLIArgumentsTests.swift
git commit -m "feat: expose ZWZ identities and recipients in CLI"
```

### Task 8: GUI Key Management

**Files:**
- Create: `Sources/ZwzGUI/IdentityManagerViewModel.swift`
- Create: `Sources/ZwzGUI/IdentityManagerView.swift`
- Modify: `Sources/ZwzGUI/ZwzApp.swift`
- Modify: `Sources/ZwzGUI/Localization.swift`
- Create: `Tests/ZwzGUITests/IdentityManagerViewModelTests.swift`
- Create: `Tests/ZwzGUITests/IdentityManagerTestSupport.swift`

**Interfaces:**
- Consumes: `ZwzIdentityStore` from Task 5.
- Produces: observable identities/contacts, create/rename/delete, public import/export, backup/restore, conflict prompts, and destructive-delete warning.

- [ ] **Step 1: Write failing view-model tests with an in-memory store**

```swift
@MainActor func testIdentityMustBeNamedAndCreatedManually() throws {
    let model = IdentityManagerViewModel(store: InMemoryZwzIdentityStore())
    XCTAssertThrowsError(try model.createIdentity(named: "   "))
    XCTAssertTrue(model.identities.isEmpty)
}
@MainActor func testDeleteRequiresExplicitConfirmation() throws {
    let model = try IdentityManagerTestSupport.modelWithIdentity()
    model.requestDelete(model.identities[0])
    XCTAssertNotNil(model.pendingDeletion)
    XCTAssertEqual(model.identities.count, 1)
}
@MainActor func testSuccessfulRestoreResumesPendingArchiveAction() throws {
    XCTAssertEqual(try IdentityManagerTestSupport.restoreAndCountResumeCallbacks(), 1)
}
```

- [ ] **Step 2: Run and observe failure**

Run: `swift test --filter IdentityManagerViewModelTests`

Expected: identity manager types are missing.

- [ ] **Step 3: Implement the focused view model and settings page**

```swift
@MainActor final class IdentityManagerViewModel: ObservableObject {
    @Published private(set) var identities: [ZwzIdentityMetadata] = []
    @Published private(set) var contacts: [ZwzPublicIdentity] = []
    @Published var pendingDeletion: ZwzIdentityMetadata?
    @Published var errorMessage: String?
    let store: ZwzIdentityStore
}
```

Add a “Keys” settings destination. Use `NSSavePanel`/`NSOpenPanel` for `.zwzpub` and `.zwzkey` files. Require password plus confirmation for backup, a password for restore, and explicit conflict choice. Show grouped fingerprints and state that deleting the final private copy can make archives unrecoverable.

Implement the in-memory identity fixtures and resume-callback counter in `IdentityManagerTestSupport.swift`.

- [ ] **Step 4: Run GUI unit tests**

Run: `swift test --filter IdentityManagerViewModelTests`

Expected: all state transitions pass without opening real panels or Keychain prompts.

- [ ] **Step 5: Commit**

```bash
git add Sources/ZwzGUI/IdentityManagerViewModel.swift Sources/ZwzGUI/IdentityManagerView.swift Sources/ZwzGUI/ZwzApp.swift Sources/ZwzGUI/Localization.swift Tests/ZwzGUITests/IdentityManagerViewModelTests.swift
git commit -m "feat: add ZWZ key management interface"
```

### Task 9: GUI Compression, Preview, Extraction, and Signature Status

**Files:**
- Modify: `Sources/ZwzGUI/ArchiveViewModel.swift`
- Modify: `Sources/ZwzGUI/ZwzApp.swift`
- Modify: `Sources/ZwzGUI/ArchiveEntryPreviewModel.swift`
- Modify: `Sources/ZwzGUI/ArchiveEditSession.swift`
- Modify: `Sources/ZwzGUI/VirtualDiskManager.swift`
- Modify: `Sources/ZwzGUI/Localization.swift`
- Create: `Tests/ZwzGUITests/PublicKeyArchiveWorkflowTests.swift`
- Create: `Tests/ZwzGUITests/ArchiveViewModelTestSupport.swift`

**Interfaces:**
- Consumes: core structured encryption and signature APIs, Keychain store, identity-manager resume callback.
- Produces: three-way encryption selection, multi-recipient picker, optional signer picker, missing-key recovery prompt, and signature badge.

- [ ] **Step 1: Write failing GUI workflow tests**

```swift
@MainActor func testPublicKeyModeRequiresAtLeastOneRecipient() throws {
    let model = ArchiveViewModelTestSupport.publicKeyModel()
    XCTAssertFalse(model.canStartCompression)
    model.selectedRecipientFingerprints.insert("AA:BB")
    XCTAssertTrue(model.canStartCompression)
}
@MainActor func testChangingToPasswordClearsRecipientsAndSigner() throws {
    let model = ArchiveViewModelTestSupport.selectedPublicKeyModel()
    model.selectEncryptionMode(.password)
    XCTAssertTrue(model.selectedRecipientFingerprints.isEmpty)
    XCTAssertNil(model.selectedSignerFingerprint)
}
@MainActor func testMissingPrivateKeyOffersRestoreAndRetriesOnce() throws {
    XCTAssertEqual(try ArchiveViewModelTestSupport.restoreAndRetryCount(), 1)
}
@MainActor func testInvalidSignatureBlocksPreviewExtractAndMount() throws {
    XCTAssertEqual(try ArchiveViewModelTestSupport.blockedActionCount(for: .invalid), 3)
}
```

- [ ] **Step 2: Run and observe failure**

Run: `swift test --filter PublicKeyArchiveWorkflowTests`

Expected: new archive security state is missing.

- [ ] **Step 3: Add GUI state and route every ZWZ operation**

Add to `ArchiveViewModel`:

```swift
@Published var encryptionModeSelection: EncryptionModeSelection = .none
@Published var selectedRecipientFingerprints: Set<String> = []
@Published var selectedSignerFingerprint: String?
@Published private(set) var archiveSecurityInfo: ZwzArchiveSecurityInfo?
@Published var showMissingPrivateKeyPrompt = false
```

Build `CompressionOptions.encryption` from these fields. Pass the same store into preview, normal extraction, smart extraction, entry preview, archive editing, and virtual-disk mount/save. Display valid-known, valid-unknown, unsigned, and invalid states. Invalid signatures disable all content-opening actions. After successful backup restore, retry the captured operation once and clear it to prevent loops.

Implement `ArchiveViewModelTestSupport` with spy compressor, extractor, and mounter dependencies so tests count downstream calls without mounting disk images or showing authentication UI.

- [ ] **Step 4: Run GUI workflow and existing archive tests**

Run: `swift test --filter PublicKeyArchiveWorkflowTests && swift test --filter ZwzGUITests`

Expected: public-key workflows pass and current password prompt/search/edit/virtual-disk tests remain green.

- [ ] **Step 5: Commit**

```bash
git add Sources/ZwzGUI/ArchiveViewModel.swift Sources/ZwzGUI/ZwzApp.swift Sources/ZwzGUI/ArchiveEntryPreviewModel.swift Sources/ZwzGUI/ArchiveEditSession.swift Sources/ZwzGUI/VirtualDiskManager.swift Sources/ZwzGUI/Localization.swift Tests/ZwzGUITests/PublicKeyArchiveWorkflowTests.swift
git commit -m "feat: integrate public-key archives in GUI"
```

### Task 10: Full Regression, Packaging, and Documentation

**Files:**
- Modify: `README.md`
- Modify: `scripts/check-app-bundle.sh`
- Create: `Tests/ZwzCoreTests/ZWZV3/ZwzV3CompatibilityTests.swift`

**Interfaces:**
- Consumes all previous tasks.
- Produces verified release behavior and user-facing instructions.

- [ ] **Step 1: Add committed compatibility fixtures and tests**

Add small version-1 unencrypted/password fixtures and deterministic version-3 unsigned/signed/multi-recipient fixtures under `Tests/ZwzCoreTests/Fixtures/`. Test detection, listing, extraction, signature status, and refusal after one-byte mutation. Never commit fixture private keys except explicitly labeled test-only keys under the test target.

- [ ] **Step 2: Run the entire suite before documentation changes**

Run: `swift test`

Expected: all core and GUI tests pass with zero failures.

- [ ] **Step 3: Document exact product behavior**

Update README feature, CLI, and security sections with:

```text
zwz key create "My Mac"
zwz key export-public "My Mac" recipient.zwzpub
zwz compress -f zwz --recipient recipient.zwzpub --sign "My Mac" source
zwz extract archive.zwz output
zwz key backup "My Mac" identity.zwzkey
zwz key restore identity.zwzkey
```

State that password/public-key modes are exclusive, recipients are visible, signatures may be unknown-but-valid, and losing all private-key copies makes recovery impossible.

- [ ] **Step 4: Verify build, tests, bundle, and working-tree scope**

Run: `swift build && swift test && ./scripts/package-app.sh && ./scripts/check-app-bundle.sh`

Expected: build and tests succeed; bundle check reports success; `git status --short` contains only intended public-key feature files plus the user’s pre-existing unrelated changes.

- [ ] **Step 5: Commit final fixtures and docs**

```bash
git add README.md scripts/check-app-bundle.sh Tests/ZwzCoreTests/Fixtures Tests/ZwzCoreTests/ZWZV3/ZwzV3CompatibilityTests.swift
git commit -m "docs: document ZWZ public-key encryption"
```

- [ ] **Step 6: Request final code review**

Invoke `superpowers:requesting-code-review`, address only verified findings, rerun `swift test` and bundle checks, then use `superpowers:verification-before-completion` before reporting success.
