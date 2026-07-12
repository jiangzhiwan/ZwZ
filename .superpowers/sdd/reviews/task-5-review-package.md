# Task 5 Review Package

Workspace: `/Users/jiangzhiwan/Desktop/ZwZ`

Git range: unavailable because this workspace is not a Git repository.

## Test Evidence

- Implementer: `swift test --filter ZwzV2BlockCodecTests`: passed; 3 tests, 0 failures.
- Implementer: `swift test --filter ZwzV2PathTests`: passed; 6 tests, 0 failures.
- Implementer: `swift test`: passed; 35 tests, 0 failures.
- Fix report: `swift test --filter ZwzV2BlockCodecTests`: passed; 6 tests, 0 failures.
- Fix report: `swift test`: passed; 38 tests, 0 failures.
- Coverage fix: `swift test --filter ZwzV2BlockCodecTests`: passed; 6 tests, 0 failures.
- Coverage fix: `swift test`: passed; 38 tests, 0 failures.
- Warnings during full build are existing Swift 6/AppKit warnings in `Sources/ZwzGUI`.

## Files Changed

- `Sources/ZwzCore/ZWZV2/ZwzV2BlockCodec.swift`
- `Tests/ZwzCoreTests/ZWZV2/ZwzV2BlockCodecTests.swift`

## Current File Pointers

Read these files directly for exact current contents:

- `Sources/ZwzCore/ZWZV2/ZwzV2BlockCodec.swift`
- `Tests/ZwzCoreTests/ZWZV2/ZwzV2BlockCodecTests.swift`

## Implementation Summary

- Added `ZwzV2EncodedBlock` with public initializer.
- Added `ZwzV2BlockCodec.encode(_:level:)`.
- Added `ZwzV2BlockCodec.decode(_:)`.
- Added `ZwzV2BlockCodec.decode(codec:payload:originalLength:sequence:)`.
- Uses `SWCompression.LZ4` and `SWCompression.Deflate`.
- Uses a private deterministic FNV-1a UInt32 checksum over original data.
- `.none` stores verbatim.
- `.fastest` tries LZ4 and stores if `compressed.count + 40 >= input.count`.
- `.normal` tries LZ4, optionally Deflate on repeated data, and stores when not beneficial.
- `.normal` Deflate selection is gated on both beating LZ4 by at least 8% and saving at least 1% versus the original input.
- Production `.normal` selection is routed through an internal `selectNormalCodec` seam used only for focused threshold tests.
- `.max` tries Deflate and stores if `compressed.count + 40 >= input.count`.
- Raw decode validates original length and maps decompression failures to `ZwzV2Error.decompressionFailed(sequence:)`.
- Encoded-block decode additionally verifies checksum and throws `ZwzV2Error.checksumMismatch(sequence: 0)`.
- Tests include checksum mismatch, malformed raw compressed payload error mapping, and normal-level store fallback.
- Tests include the exact decision boundary where Deflate beats LZ4 by at least 8% but does not save at least 1% versus input, asserting `.store`.
