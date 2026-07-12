# Task 3 Review Package

Workspace: `/Users/jiangzhiwan/Desktop/ZwZ`

Git range: unavailable because this workspace is not a Git repository.

## Implementer-Reported Test Evidence

- `swift test --filter ZwzV2BinaryCodecTests`: passed; 6 tests, 0 failures.
- `swift test --filter ZwzV2TypesTests`: passed; 2 tests, 0 failures.
- `swift test --filter PackageBoundaryTests`: passed; 2 tests, 0 failures.
- `swift test`: passed; 16 tests, 0 failures.

## Files Changed

- `Sources/ZwzCore/ZWZV2/ZwzV2BinaryCodec.swift`
- `Tests/ZwzCoreTests/ZWZV2/ZwzV2BinaryCodecTests.swift`

## Current File Pointers

Review these files directly for exact current contents:

- `Sources/ZwzCore/ZWZV2/ZwzV2BinaryCodec.swift`
- `Tests/ZwzCoreTests/ZWZV2/ZwzV2BinaryCodecTests.swift`

## Implementation Summary

- Added `ZwzV2Header`, `ZwzV2HeaderFlags`, `ZwzV2BlockRecordHeader`, `ZwzV2Footer`, `ZwzV2SplitEnvelope`, and `ZwzV2BinaryCodec`.
- Fixed lengths: header 128 bytes, block record header 40 bytes, footer 64 bytes, split envelope 80 bytes.
- Header layout uses `ZWZ2` magic, version at offset 4, UUID at 8, flags at 24, block size at 28, salt length at 32, iterations at 36, salt bytes at 40, reserved bytes after salt up to 72 and from 72 to 128.
- Block record layout uses sequence at 0, codec at 8, tag length at 9, stored length at 12, original length at 16, checksum at 20, reserved bytes afterward.
- Footer layout uses `ZWZ2` magic, version at 4, UUID at 8, index offset at 24, index length at 32, checksum at 40.
- Split envelope layout uses `ZWZS` magic, version at 4, UUID at 8, volume number at 24, final marker at 28, logical offset at 32, payload length at 40, payload checksum at 48.
- Old v1 magic `[0x5A, 0x57, 0x5A, 0x31]` throws `ZwzV2Error.unsupportedVersion(1)`.
- Unsupported flags, impossible salt length, short input, bad magic, bad version, unknown codecs, and nonzero reserved bytes throw `ZwzV2Error.malformedArchive`.
