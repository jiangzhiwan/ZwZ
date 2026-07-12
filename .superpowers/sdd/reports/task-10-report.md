# Task 10 Report: Preview and Multithreaded Extractor

## Final Status

READY FOR FOLLOW-UP REVIEW

## Changed Files

- `Sources/ZwzCore/ZWZV2/ZwzV2Extractor.swift`
- `Sources/ZwzCore/ZWZV2/ZwzV2VolumeIO.swift`
- `Tests/ZwzCoreTests/ZWZV2/ZwzV2ExtractorTests.swift`
- `.superpowers/sdd/reports/task-10-report.md`

## Implementation

- Added `ZwzV2Extractor` with async `preview`, `extractAll`, and `extractEntry` APIs.
- Added `ZwzV2RecoveryReport` for extracted entries, failed entries, and failed block sequences.
- Preview opens the logical volume reader, validates header/footer agreement, derives crypto context when encrypted, validates index checksum, reads only index payload/tag, and decodes paths through `ZwzV2IndexCodec`.
- Extraction filters all entries or one requested entry, creates directories, decodes requested file blocks concurrently up to `options.maxInFlightBlocks`, verifies block-record headers against index descriptors, decrypts/authenticates encrypted blocks, verifies decompressed lengths and checksums, and writes blocks at declared file offsets.
- Strict mode removes the failed output file and throws on the first file extraction failure.
- Extraction rejects existing symbolic-link components under the destination before creating or opening an output path.
- Extraction explicitly removes an existing regular output file before creating the restored file, so stale bytes cannot survive when restoring a shorter archived file.
- Preview validates decoded index layout before returning it: directory entries cannot contain blocks, file blocks must be unique, contiguous, non-empty, and exactly cover `originalSize`.
- Marked `ZwzV2VolumeReader` as `@unchecked Sendable`; it is immutable after initialization and each read opens its own local `FileHandle`.

## TDD Evidence

- Added `ZwzV2ExtractorTests` before implementation. The red run failed because `ZwzV2Extractor` did not exist.
- First implementation compile surfaced existing API mismatches in path validation and block decode; fixed by using `validateExtractionPath(_:destination:)` and adding extractor-side checksum verification.
- Swift 6 concurrency then required a sendability boundary for `ZwzV2VolumeReader`; added a narrow `@unchecked Sendable` conformance after checking it has no shared mutable read state.
- Follow-up review found two important gaps: destination symlink traversal and trusted sparse/oversized index block layouts. Added failing tests for both and fixed them in `ZwzV2Extractor`.

## Commands Run

| Command | Result |
| --- | --- |
| `swift test --filter ZwzV2ExtractorTests` | PASS: 7 tests, 0 failures |
| `swift test` | PASS: 71 tests, 0 failures |

## Self-Review

- Verified preview does not create extraction output.
- Verified single-entry extraction does not materialize an unrequested sibling.
- Verified extract-all restores directories, hidden files, and file bytes.
- Verified encrypted preview fails without password and succeeds with the correct password.
- Verified extraction rejects existing symlink components inside the destination.
- Verified malformed index block layouts that would write past `originalSize` are rejected before output remains.
- Verified extracting over an existing longer file restores exact bytes without stale trailing data.
- Known follow-up: recovery mode currently records failed entries but does not yet emit partial-file suffixes; broader recovery behavior is planned for Task 11.
