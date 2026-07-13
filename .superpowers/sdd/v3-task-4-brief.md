### Task 4: Version-3 Compression, Preview, and Extraction

Read the Task 4 section in `docs/superpowers/plans/2026-07-12-public-key-encryption.md` and
the authoritative Task 3 brief first. Use TDD and preserve unrelated workspace changes.

## Normative archive payload format

All integers are unsigned little-endian. V3 reuses `ZwzV2BlockCodec`, `ZwzV2Index`,
`ZwzV2Entry`, `ZwzV2BlockDescriptor`, `ZwzV2IndexCodec.encodePlain/decodePlain`, source
enumeration, and path validation. The V2 index bytes are never public in V3: the complete
plain index is AES-256-GCM encrypted.

The Task 3 opaque data region is a concatenation of exactly `header.dataBlockCount` records:

1. `recordLength: UInt32`, bytes following this field;
2. `sequence: UInt64`, canonical zero-based strictly increasing sequence;
3. `codec: UInt8` (`ZwzV2Codec` raw value);
4. 3 reserved zero bytes;
5. `originalLength: UInt32`, greater than zero;
6. `sealedLength: UInt32`, at least 28;
7. `sealedLength` bytes of CryptoKit AES-GCM combined form: 12-byte nonce, ciphertext, and
   16-byte tag.

`recordLength` must equal 20 + sealedLength. No padding or trailing bytes are allowed. The
index block descriptor `archiveOffset` points to the record's absolute file offset,
`storedLength` equals sealedLength, and `authenticationTag` is empty because the combined
sealed box already carries its tag. Index descriptors must exactly match parsed record
sequence/codec/original length/offset/sealed length. File offsets, block coverage, duplicate
sequence, directory blocks, paths, and total block count receive the existing strict V2
layout validation.

Block AAD is the exact concatenation of ASCII `ZWZ3 data block v1`, the 16 RFC-4122 archive
UUID bytes, sequence UInt64 LE, codec UInt8, and originalLength UInt32 LE. Every block uses a
fresh random CryptoKit AES-GCM nonce; do not derive or reuse nonces.

The encrypted-index field is CryptoKit AES-GCM combined form. Its AAD is ASCII
`ZWZ3 encrypted index v1`, archive UUID bytes, the seven algorithm raw bytes from header
offsets 12...18, recipient count UInt32 LE, the exact canonical encoded recipient region,
dataBlockCount UInt64 LE, and SHA-256(dataRegion). This makes unsigned archives reject
mutations of algorithm identity, recipient names/envelopes, or any block before exposing
paths. Header offsets/lengths are canonical consequences of region sizes and are checked by
Task 3 parsing. Signed archives additionally sign Task 3 `canonicalSignedBytes`.

## Public API contract

Add the Task 4 plan's `ZwzPrivateKeyProvider`. Raw provider bytes must be validated by
CryptoKit. A provider lookup failure may be tried against another matching envelope; after
all records fail, return `.noMatchingPrivateKey(public fingerprints)` unless at least one
matching key was obtained but unwrap/authentication failed, in which case return
`.keyUnwrapFailed`. Do not suppress `.userAuthenticationCancelled`.

Define `ZwzV3ArchiveListing` with public `entries: [ZwzV2Entry]` and
`securityInfo: ZwzArchiveSecurityInfo`. `listEntries` and extraction must: parse; verify an
embedded Ed25519 signature before unwrap/index open; unwrap; authenticate the index AAD;
decode and validate index; then return/write data. Invalid signatures always throw
`.invalidSignature`. Known/unknown signer status comes from `isKnownSigningKey`.

Compression requires `.zwz` plus `.publicKey` with at least one recipient. The signing
private key is loaded only when a signer is requested; derive its Ed25519 public key from the
private bytes, verify its fingerprint equals the selected identity fingerprint, assemble
with a 64-zero signature placeholder, sign Task 3 canonical bytes, then replace exactly the
signature value. Verify the completed archive before publishing it.

Use a sibling temporary staging directory. On cancellation/error remove every staged file.
For a single archive, atomically replace the destination only after verification. For
`options.splitVolume`, reuse the existing ZWZ split envelope reader/writer over the completed
logical V3 bytes, stage every volume, then publish the entire set; discovery orders `.z00`,
`.z01`, ... and final `.zwz`. Cancellation is checked during source/block work and before
publishing. Existing destination files must not be destroyed until the new archive verifies.

`extractEntryToTemp` extracts one selected file or directory subtree using the same path and
symlink protections as V2. Full extraction removes a partially written current file on any
error/cancellation. Progress is monotonic from 0 to 1.

## Required tests

- two recipients independently list/extract hidden, empty, Unicode, nested, and multi-block files;
- wrong recipient and cancelled private-key authentication remain distinct;
- unsigned mutation of header algorithm, recipient name/envelope, block header/cipher/tag,
  and encrypted index fails before paths are returned;
- signed known/unknown status, signature mutation, signer metadata mutation, and signing-key
  mismatch;
- malicious record lengths/counts/offset mismatches never trap;
- single-entry extraction, path traversal/symlink defense, cancellation cleanup, replacement
  safety, and split-volume round trip/missing/reordered volume behavior.

Run `swift test --filter ZwzV3` and commit only Task 4 source/tests plus any minimal V3 codec
changes as `feat: add ZWZ version 3 archive workflows`. Do not stage `.superpowers/sdd`.
