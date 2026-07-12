# Task 9 Review Package

Workspace: `/Users/jiangzhiwan/Desktop/ZwZ`

Git range: unavailable because this workspace is not a Git repository.

## Test Evidence

- Implementer: `swift test --filter ZwzV2CompressorTests`: passed; 4 tests, 0 failures.
- Implementer: `swift test --filter ZwzV2IndexCodecTests`: passed; 10 tests, 0 failures.
- Implementer: `swift test`: passed; 64 tests, 0 failures.
- Main follow-up after first review: `swift test --filter ZwzV2CompressorTests`: passed; 4 tests, 0 failures.

## Files Changed

- `Sources/ZwzCore/ZWZV2/ZwzV2Compressor.swift`
- `Tests/ZwzCoreTests/ZWZV2/ZwzV2CompressorTests.swift`
- `Sources/ZwzCore/ZWZV2/ZwzV2BinaryCodec.swift`
- `Sources/ZwzCore/ZWZV2/ZwzV2IndexCodec.swift`

## Current File Pointers

Read these files directly for exact current contents:

- `Sources/ZwzCore/ZWZV2/ZwzV2Compressor.swift`
- `Tests/ZwzCoreTests/ZWZV2/ZwzV2CompressorTests.swift`
- `Sources/ZwzCore/ZWZV2/ZwzV2BinaryCodec.swift`
- `Sources/ZwzCore/ZWZV2/ZwzV2IndexCodec.swift`

## Implementation Summary

- Added `ZwzV2Compressor` with `compress(sourceURLs:to:) async throws -> [URL]`.
- Writes header, block record headers, payloads, tags, index payload/tag, footer.
- Uses `ZwzV2SourceEnumerator`, `ZwzV2BlockCodec`, `ZwzV2Crypto`, `ZwzV2VolumeWriter`, and `ZwzV2IndexCodec`.
- Uses `withThrowingTaskGroup` with `options.maxInFlightBlocks` cap.
- Ordered writer uses `ZwzV2OrderedBlockWindow` to buffer completed blocks by sequence, write in sequence order, and apply backpressure when earlier missing blocks would otherwise let the reorder buffer grow.
- Password archives derive one CryptoSwift context with 210,000 PBKDF2 iterations and encrypt block payloads plus index.
- Header flags include encrypted and split flags where applicable.
- Block descriptors point to block record header logical offsets and include payload tag bytes.
- Tests verify plain archive readable index/hidden metadata, encrypted archive block/index tags, fixed reorder-window backpressure, descriptor-offset block-record boundaries, and split-volume logical reads.
- Binary/index decoders were adjusted to copy `Data` slices before indexed reads.

## Known Limitation for Review

- The first review correctly noted that index metadata is still materialized by the current `ZwzV2Index` / `ZwzV2IndexCodec.encodeForArchive` API before writing. This patch fixes the unbounded completed-block reorder buffer and adds Task 10-facing block-boundary tests, but fully streaming or paged index metadata would require a follow-up format/API change touching Task 7 and encrypted-index handling.
