### Task 3: Canonical Version-3 Binary Envelope

**Files:**
- Create: `Sources/ZwzCore/ZWZV3/ZwzV3BinaryCodec.swift`
- Create: `Sources/ZwzCore/ZWZV3/ZwzV3ArchiveCodec.swift`
- Create: `Tests/ZwzCoreTests/ZWZV3/ZwzV3BinaryCodecTests.swift`
- Create: `Tests/ZwzCoreTests/ZWZV3/ZwzV3BinaryCodecTestSupport.swift`

**Interfaces:**
- Consumes: recipient envelopes and signer records from Task 2.
- Produces: `ZwzV3Header`, `ZwzV3ParsedArchive`, `ZwzV3BinaryCodec.encodeHeader`, `parse`, and `canonicalSignedBytes`.

## Authoritative V3 Envelope Layout

This section is normative. Reject unknown flags/algorithm IDs, non-zero reserved bytes,
non-canonical layouts, invalid UTF-8, overflow, truncation, overlap, gaps, and trailing bytes
with `ZwzV3Error.malformedArchive`. All integers are unsigned little-endian. All offsets are
absolute from byte zero of the logical, joined archive.

### Fixed header (160 bytes)

| Offset | Size | Field |
|---:|---:|---|
| 0 | 4 | ASCII magic `ZWZ3` |
| 4 | 2 | version = 3 |
| 6 | 2 | header size = 160 |
| 8 | 4 | flags: bit 0 = signed; all other bits zero |
| 12 | 1 | encryption = 2 (`publicKey`) |
| 13 | 1 | content cipher = 1 (`aes256GCM`) |
| 14 | 1 | key agreement = 1 (`x25519`) |
| 15 | 1 | KDF = 1 (`hkdfSHA256`) |
| 16 | 1 | key wrap cipher = 1 (`aes256GCM`) |
| 17 | 1 | signature = 0 (`none`) or 1 (`ed25519`) |
| 18 | 1 | index cipher = 1 (`aes256GCM`) |
| 19 | 1 | reserved = 0 |
| 20 | 16 | archive UUID, RFC 4122 byte order (same order as `UUID.uuid`) |
| 36 | 4 | recipient count, at least 1 |
| 40 | 8 | recipient region offset |
| 48 | 8 | recipient region length |
| 56 | 8 | data region offset |
| 64 | 8 | data region length |
| 72 | 8 | encrypted index offset |
| 80 | 8 | encrypted index length |
| 88 | 8 | signer region offset, or zero when unsigned |
| 96 | 8 | signer region length, or zero when unsigned |
| 104 | 8 | signature value offset, or zero when unsigned |
| 112 | 8 | signature value length: 64 when signed, otherwise zero |
| 120 | 8 | data block count (may be zero) |
| 128 | 32 | reserved, all zero |

Signed flag and signature algorithm must agree. Signed archives have exactly one signer.
Unsigned archives have no signer region and all four signer/signature offset/length fields
are zero.

### Canonical regions

Regions are exactly `header -> recipients -> data -> encrypted index -> optional signer`.
Thus recipient offset is 160, and every following offset equals the checked end of its
predecessor. The final region must end at EOF. Recipient and index regions must be non-empty;
the data region may be empty only when data block count is zero. `parse` returns the opaque
data region as well as the encrypted index so callers never need to reslice unchecked bytes.

Each recipient record is:

1. `recordLength: UInt32`, counting all bytes after this field;
2. `nameLength: UInt32`, followed by non-empty UTF-8 name bytes;
3. `fingerprintLength: UInt32`, followed by non-empty UTF-8 fingerprint bytes;
4. 32-byte X25519 ephemeral public key;
5. 12-byte AES-GCM nonce;
6. 32-byte encrypted content key;
7. 16-byte AES-GCM authentication tag.

The recipient region is exactly `recipientCount` concatenated records with no region-level
count and no padding. Records remain in caller-supplied order. A record length must exactly
match the consumed record bytes.

The signed signer record is:

1. `recordLength: UInt32`, counting all bytes after this field;
2. `nameLength: UInt32`, followed by non-empty UTF-8 name bytes;
3. `fingerprintLength: UInt32`, followed by non-empty UTF-8 fingerprint bytes;
4. 32-byte Ed25519 public key;
5. 64-byte Ed25519 signature value.

The signer region contains exactly this one record. Its signature value must be the final 64
bytes of both the record and the file. Header `signatureOffset` points at that value and
`signatureLength` is 64.

### Canonical signing and encoder contract

For a signed archive, `canonicalSignedBytes` is the complete encoded archive with the byte
range `[signatureOffset, signatureOffset + 64)` removed. This excludes only the signature
value: the fixed header (including signature offset/length), recipient region, data region,
encrypted index, signer lengths/name/fingerprint/public key are signed. For an unsigned
archive it is the complete archive.

`ZwzV3ArchiveCodec` owns whole-envelope assembly. Its encoder accepts recipient records,
opaque `dataRegion`, opaque `encryptedIndex`, optional signer, archive UUID, and data block
count; it computes every offset/length and does not accept caller-provided offsets. A
lower-level `encodeHeader`/`decodeHeader` exists for header round-trip tests, while `parse`
performs full-file canonical validation. Encoding rejects wrong fixed crypto field sizes and
inconsistent signed/unsigned state.

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
