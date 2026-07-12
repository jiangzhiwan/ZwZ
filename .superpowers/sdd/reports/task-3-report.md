# Task 3 Report

Status: DONE_WITH_CONCERNS

## Changed Files

- `Sources/ZwzCore/ZWZV2/ZwzV2BinaryCodec.swift`
- `Tests/ZwzCoreTests/ZWZV2/ZwzV2BinaryCodecTests.swift`

## Work Completed

- Added public, `Equatable`, and `Sendable` v2 binary record types with public initializers:
  `ZwzV2Header`, `ZwzV2HeaderFlags`, `ZwzV2BlockRecordHeader`, `ZwzV2Footer`, and `ZwzV2SplitEnvelope`.
- Added the public `ZwzV2BinaryCodec` encode/decode APIs for each fixed-length record.
- Used fixed little-endian integer fields, fixed record lengths, UUID byte fields, and zeroed reserved bytes.
- Enforced strict decode validation for record length, magic, version, flags, KDF salt capacity, reserved bytes, final-volume marker, and block codec. Old v1 magic throws `.unsupportedVersion(1)`; other invalid data throws `.malformedArchive`.
- Added round-trip tests for header, footer, block record header, and split envelope, plus v1 and malformed-length rejection coverage.

## Commands Run

- `swift test --filter ZwzV2BinaryCodecTests` before implementation: FAIL as expected because the requested codec types did not exist. The initial sandboxed invocation was blocked before compilation by Swift module-cache permissions; the permitted rerun reached the expected missing-symbol failures.
- `swift test --filter ZwzV2BinaryCodecTests`: PASS, 6 tests, 0 failures.
- `swift test --filter ZwzV2TypesTests`: PASS, 2 tests, 0 failures.
- `swift test --filter PackageBoundaryTests`: PASS, 2 tests, 0 failures.
- `swift test`: PASS, 16 tests, 0 failures.

## Self-Review

- Kept changes within Task 3 ownership and did not modify `ZwzV2Types.swift`.
- Preserved Task 1 and Task 2 public API and package-boundary tests.
- Confirmed all fixed record types expose the required public initializers and exact encoded-length constants.
- Confirmed integers are written and decoded explicitly in little-endian order rather than using platform-dependent memory loads.

## Concerns

- The full package build still emits pre-existing Swift 6 concurrency/actor-isolation and AppKit deprecation warnings in `Sources/ZwzGUI`; these files are outside Task 3 ownership and the test suite passes.

## Review Fixes

- Added checked-add overflow rejection for footer `indexOffset + indexLength` and split-envelope `logicalOffset + payloadLength`; both decode paths now throw `ZwzV2Error.malformedArchive` on overflow.
- Added `ZwzV2Format.splitEnvelopeVersion` and used it for split-envelope encoding and validation.
- Added deterministic decode regressions for overflow, unsupported header flags, unknown block codec, bad magic, bad version, malformed salt length, and reserved-byte corruption.

## Review Fix Verification

- TDD red: `swift test --filter ZwzV2BinaryCodecTests/testFooterDecodeRejectsOverflowingIndexRange` failed before the footer range guard because decode did not throw.
- TDD red: `swift test --filter ZwzV2BinaryCodecTests` failed before the split-envelope range guard because decode did not throw.
- `swift test --filter ZwzV2BinaryCodecTests`: PASS, 14 tests, 0 failures.
- `swift test --filter ZwzV2TypesTests`: PASS, 2 tests, 0 failures.
- `swift test`: PASS, 24 tests, 0 failures.

## Remaining Finding Fix

- Added checked-add guards to `encodeFooter` and `encodeSplitEnvelope`; overflowing ranges now throw `ZwzV2Error.malformedArchive` before serialization.
- Added encoder regression tests for overflowing footer index and split-envelope payload ranges.
- Updated decode overflow fixtures to construct malformed bytes without calling encoders that now correctly reject those values.

## Final Verification

- `swift test --filter ZwzV2BinaryCodecTests`: PASS, 16 tests, 0 failures.
- `swift test`: PASS, 26 tests, 0 failures.

## Final Concerns

- Existing Swift 6 concurrency/actor-isolation and AppKit deprecation warnings in `Sources/ZwzGUI` remain; they are outside Task 3 ownership and do not affect the passing test suites.
