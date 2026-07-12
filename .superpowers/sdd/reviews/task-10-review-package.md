# Task 10 Review Package

Workspace: `/Users/jiangzhiwan/Desktop/ZwZ`

Git range: unavailable because this workspace is not a Git repository.

## Test Evidence

- Main agent: `swift test --filter ZwzV2ExtractorTests`: passed; 7 tests, 0 failures.
- Main agent: `swift test`: passed; 71 tests, 0 failures.

## Files Changed

- `Sources/ZwzCore/ZWZV2/ZwzV2Extractor.swift`
- `Sources/ZwzCore/ZWZV2/ZwzV2VolumeIO.swift`
- `Tests/ZwzCoreTests/ZWZV2/ZwzV2ExtractorTests.swift`

## Current File Pointers

Read these files directly for exact current contents:

- `Sources/ZwzCore/ZWZV2/ZwzV2Extractor.swift`
- `Sources/ZwzCore/ZWZV2/ZwzV2VolumeIO.swift`
- `Tests/ZwzCoreTests/ZWZV2/ZwzV2ExtractorTests.swift`
- Related dependencies:
  - `Sources/ZwzCore/ZWZV2/ZwzV2Compressor.swift`
  - `Sources/ZwzCore/ZWZV2/ZwzV2IndexCodec.swift`
  - `Sources/ZwzCore/ZWZV2/ZwzV2BlockCodec.swift`
  - `Sources/ZwzCore/ZWZV2/ZwzV2PathValidator.swift`

## Implementation Summary

- Added `ZwzV2Extractor` and `ZwzV2RecoveryReport`.
- Preview reads header/footer/index only and validates encrypted password requirements.
- Extraction supports all entries or one requested entry.
- File blocks are decoded concurrently with a bounded task group and written at declared file offsets.
- Block-record headers, authentication tags, decompressed lengths, and checksums are verified before writing decoded data.
- Extraction paths use `ZwzV2PathValidator.validateExtractionPath(_:destination:)`.
- Existing symlink components under the destination are rejected before output creation/opening.
- Decoded index layouts are validated before preview/extraction returns: directories have no blocks; file blocks are unique, contiguous, non-empty, within `originalSize`, and exactly cover file size.
- Existing regular output files are explicitly removed before creating the restored file, preventing stale trailing bytes.
- `ZwzV2VolumeReader` is marked `@unchecked Sendable`; it is immutable and opens a fresh `FileHandle` for each read.

## Follow-up Fixes Since First Review

- First review found destination symlink traversal and insufficient file/block layout validation.
- Added tests for both cases in `ZwzV2ExtractorTests`.
- Fixed both in `ZwzV2Extractor`.
- Second review found a static risk around extracting over existing longer regular files. Added an exact-byte test and changed `ZwzV2Extractor` to remove existing regular files before creating output.

## Known Limitation for Review

- Recovery mode partial-file suffix/report semantics are intentionally minimal in this task and expected to be expanded by Task 11 recovery tests.
