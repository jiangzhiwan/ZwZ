# Task 9 Report: Streaming Multithreaded Compressor

## Final Status

DONE

## Changed Files

- `Sources/ZwzCore/ZWZV2/ZwzV2Compressor.swift`
- `Tests/ZwzCoreTests/ZWZV2/ZwzV2CompressorTests.swift`
- `Sources/ZwzCore/ZWZV2/ZwzV2BinaryCodec.swift`
- `Sources/ZwzCore/ZWZV2/ZwzV2IndexCodec.swift`
- `.superpowers/sdd/reports/task-9-report.md`

## Implementation

- Added `ZwzV2Compressor` with the required async `compress(sourceURLs:to:)` API.
- Enumerates sources deterministically, records directory and hidden-file metadata in the index, and normalizes filesystem timestamps to whole seconds so they satisfy the index codec's exact-millisecond contract.
- Uses a `withThrowingTaskGroup` with no more than `options.maxInFlightBlocks` active compression/encryption jobs. A single ordered writer emits block-record header, payload, and authentication tag in sequence order.
- Added `ZwzV2OrderedBlockWindow` so out-of-order completed jobs apply backpressure when the missing earlier block has not arrived; the compressor now pauses new reads instead of letting the reorder buffer grow with archive size.
- Writes encrypted and split header flags as applicable, uses a 16-byte KDF salt with 210,000 PBKDF2 iterations for password archives, encrypts block payloads and the index, and writes the encrypted index tag before the footer.
- Each block descriptor records the logical offset of its block-record header, stored/original lengths, codec, checksum, and authentication tag.

## Minimal Existing-Interface Fix

- Normalized `Data` slice inputs in the binary record decoders and index reader. The required compressor test passes footer and index slices; before this repair, decoders assumed zero-based `Data` indices and trapped on valid nonzero-based slices. No format layout changed.

## TDD Evidence

- Added compressor integration tests before implementation and confirmed the red run failed because `ZwzV2Compressor` did not exist.
- The first green attempt exposed a Swift 6 sendability error from capturing mutable `fileOffset`; the task closure now captures an immutable block offset.
- The next run exposed fractional filesystem timestamps rejected by the pre-existing index codec; the compressor now normalizes source timestamps before index creation.
- Debugging then identified the existing `Data` slice index assumption in footer/index decoding; the compatibility repair made the required slice-based test pass.

## Commands Run

| Command | Result |
| --- | --- |
| `swift test --filter ZwzV2CompressorTests` | PASS: 4 tests, 0 failures |
| `swift test --filter ZwzV2IndexCodecTests` | PASS: 10 tests, 0 failures |
| `swift test` | PASS: 64 tests, 0 failures |

Checkpoint recorded: Task 9 verified with `swift test --filter ZwzV2CompressorTests`.

## Self-Review

- Verified header fields and flags are written before block data, with archive ID and block size shared by the index.
- Verified all block record headers precede their payload/tag bytes and descriptors point to those headers.
- Verified task scheduling is bounded, results apply backpressure when sequence reordering reaches the configured window, and volume writes remain deterministic.
- Verified plain and encrypted indexes decode from the archive stream and hidden-file metadata is retained.
- Known follow-up: the current index model and encoder still materialize index metadata before writing. That matches the current Task 7 API, but a fully memory-bounded metadata path would require a streaming or paged index format/encryption update.
