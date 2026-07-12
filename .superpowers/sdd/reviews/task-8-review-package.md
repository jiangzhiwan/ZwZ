# Task 8 Review Package

Workspace: `/Users/jiangzhiwan/Desktop/ZwZ`

Git range: unavailable because this workspace is not a Git repository.

## Test Evidence

- Implementer: `swift test --filter ZwzV2VolumeIOTests`: passed; 3 tests.
- Implementer: `swift test --filter ZwzV2BinaryCodecTests`: passed; 16 tests.
- Implementer: `swift test`: passed; 53 tests.
- Fix report: `swift test --filter ZwzV2VolumeIOTests`: passed; 10 tests.
- Fix report: `swift test --filter ZwzV2BinaryCodecTests`: passed; 16 tests.
- Fix report: `swift test`: passed; 60 tests.

## Files Changed

- `Sources/ZwzCore/ZWZV2/ZwzV2VolumeIO.swift`
- `Tests/ZwzCoreTests/ZWZV2/ZwzV2VolumeIOTests.swift`

## Current File Pointers

Read these files directly for exact current contents:

- `Sources/ZwzCore/ZWZV2/ZwzV2VolumeIO.swift`
- `Tests/ZwzCoreTests/ZWZV2/ZwzV2VolumeIOTests.swift`

## Implementation Summary

- Added `ZwzV2VolumeSet`, `ZwzV2VolumeWriter`, and `ZwzV2VolumeReader`.
- Unsplit archives write directly to the requested output URL without split envelopes.
- Split archives write payload envelopes with `ZwzV2BinaryCodec.encodeSplitEnvelope`.
- Split volume numbering is zero-based.
- Split naming: numbered nonfinal volumes use `output.deletingPathExtension().appendingPathExtension("z%02u")`; final volume is moved to requested output URL.
- Reader detects split archives by split magic in first URL.
- Reader validates supplied URL order, envelope magic/version through `ZwzV2BinaryCodec`, archive ID consistency, duplicate/missing numbers, contiguous logical offsets, sequence, final marker, file size, and payload checksum.
- Reader reads requested logical spans from only intersecting volume payload ranges.
- Local volume checksum is FNV-1a `UInt32`.

## Review Fix Summary

- Changed writer first volume number from `1` to `0`.
- Removed sorting behavior from reader; reordered URL lists now fail.
- Added tests for zero-based metadata, reordered URLs, missing volumes, duplicate volumes, mixed archive IDs, checksum invalidity, final-marker errors, and non-contiguous logical ranges.
