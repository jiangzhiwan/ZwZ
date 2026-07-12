# Task 8 Report: Logical Volume I/O

## Final Status

DONE

## Changed Files

- `Sources/ZwzCore/ZWZV2/ZwzV2VolumeIO.swift`
- `Tests/ZwzCoreTests/ZWZV2/ZwzV2VolumeIOTests.swift`
- `.superpowers/sdd/reports/task-8-report.md`

## Implementation

- Added `ZwzV2VolumeWriter`, `ZwzV2VolumeSet`, and `ZwzV2VolumeReader`.
- Unsplit archives are written directly without split envelopes.
- Split archives use deterministic `archive.z01`, `archive.z02`, ..., `archive.zwz` naming, 80-byte split envelopes, and a local streaming FNV-1a `UInt32` checksum.
- The reader validates split envelope magic/version, archive IDs, contiguous sequence and logical offsets, final markers, on-disk payload lengths, and checksums in bounded chunks. Requested logical reads only load the needed payload spans.

## TDD Evidence

- Added the required cross-volume round-trip test and confirmed the initial failure because `ZwzV2VolumeWriter` and `ZwzV2VolumeReader` did not exist.
- Added single-file and empty-single-file regression tests before their corresponding fixes; each failed before the implementation adjustment and passed afterward.

## Commands Run

| Command | Result |
| --- | --- |
| `swift test --filter ZwzV2VolumeIOTests` | PASS: 3 tests |
| `swift test --filter ZwzV2BinaryCodecTests` | PASS: 16 tests |
| `swift test` | PASS: 53 tests |

Checkpoint recorded: Task 8 verified with `swift test --filter ZwzV2VolumeIOTests`.

## Review Fixes (2026-07-11)

### Changes

- Updated split writer metadata to start volume numbering at `0`.
- Updated reader validation to require the supplied URL order, rejecting reordered lists with `malformedArchive("reordered split volume URLs")` instead of sorting them.
- Reader now reports absent zero-based sequence entries with `.missingVolume(Int)` and retains clear malformed-archive errors for duplicate numbers, mixed archive IDs, invalid checksums, final markers, and logical ranges.

### Test Coverage

- Added coverage for zero-based metadata, reordered URLs, missing volumes, duplicate volumes, mixed archives, invalid checksums, final markers, and non-contiguous logical ranges.
- TDD red evidence: before the implementation update, the volume suite failed for first volume `1` rather than `0`, accepted reordered URLs, and reported missing volume `2` instead of `1`.

### Verification

| Command | Result |
| --- | --- |
| `swift test --filter ZwzV2VolumeIOTests` | PASS: 10 tests |
| `swift test --filter ZwzV2BinaryCodecTests` | PASS: 16 tests |
| `swift test` | PASS: 60 tests |

## Self-Review

- Verified split writes return logical offsets and split a write across payload budgets.
- Verified final split volume is renamed to the requested `.zwz` output and earlier volumes retain numbered extensions.
- Verified reader range reads cross volume boundaries without materializing all volumes at once.
- Verified unsplit and empty unsplit files do not receive or expect split envelopes.
- No concerns identified.
