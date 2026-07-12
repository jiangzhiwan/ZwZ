# Task 7 Review Package

Workspace: `/Users/jiangzhiwan/Desktop/ZwZ`

Git range: unavailable because this workspace is not a Git repository.

## Test Evidence

- Implementer: `swift test --filter ZwzV2IndexCodecTests`: passed; 6 tests, 0 failures.
- Implementer: `swift test --filter ZwzV2CryptoTests`: passed; 2 tests, 0 failures.
- Implementer: `swift test`: passed; 46 tests, 0 failures.
- Fix report: `swift test --filter ZwzV2IndexCodecTests`: passed; 10 tests, 0 failures.
- Fix report: `swift test --filter ZwzV2CryptoTests`: passed; 2 tests, 0 failures.
- Fix report: `swift test`: passed; 50 tests, 0 failures.
- Warnings during full build are existing Swift 6/AppKit warnings in `Sources/ZwzGUI`.

## Files Changed

- `Sources/ZwzCore/ZWZV2/ZwzV2IndexCodec.swift`
- `Tests/ZwzCoreTests/ZWZV2/ZwzV2IndexCodecTests.swift`

## Current File Pointers

Read these files directly for exact current contents:

- `Sources/ZwzCore/ZWZV2/ZwzV2IndexCodec.swift`
- `Tests/ZwzCoreTests/ZWZV2/ZwzV2IndexCodecTests.swift`

## Implementation Summary

- Binary index format with `ZWZI` magic, version `2`, UUID, block size, entry count, entries, and block descriptors.
- Entry fields: path byte length, UTF-8 path, entry type, original size, signed mtime milliseconds encoded as `UInt64(bitPattern:)`, hidden flag, block count.
- Block fields: sequence, fileOffset, archiveOffset, storedLength, originalLength, codec, checksum, tag length, tag.
- Encode validates block size, entry count, path length, block count, mtime range, auth tag length, and duplicate/unsafe paths.
- Encode rejects modification times that are not exact whole milliseconds and uses `Int64(exactly:)` after rounding to avoid upper-bound traps.
- Decode validates magic, version, block size, possible entry/block counts based on remaining bytes, UTF-8, entry type, hidden flag, block codec, trailing bytes, and duplicate/unsafe paths.
- Decode count checks compare through `UInt64` and avoid reserve capacity from untrusted counts.
- Archive wrapper encrypts/decrypts index through `ZwzV2Crypto.sealIndex/openIndex` when context is present; plaintext indexes use empty tag.
- Tests search encrypted payload bytes directly for filename leakage and cover payload/tag tampering.
