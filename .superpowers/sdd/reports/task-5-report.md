# Task 5 Report

Status: DONE

## Changed Files

- `Sources/ZwzCore/ZWZV2/ZwzV2BlockCodec.swift`
- `Tests/ZwzCoreTests/ZWZV2/ZwzV2BlockCodecTests.swift`
- `.superpowers/sdd/reports/task-5-report.md`

## Work Completed

- Added public `ZwzV2EncodedBlock` with a public initializer and the required block codec API.
- Implemented store, LZ4, Deflate, and adaptive codec selection using SWCompression.
- Added deterministic FNV-1a checksums and enforced decoded original length and checksum validation.
- Decode reports malformed compressed payloads and incorrect original lengths as `ZwzV2Error.decompressionFailed(sequence:)`; checksum mismatches report `ZwzV2Error.checksumMismatch(sequence:)`.
- Added the required tests for verbatim storage and normal-level round trips for compressible and incompressible inputs.

## Commands Run

- `swift test --filter ZwzV2BlockCodecTests`: FAIL before implementation, as expected. The compiler reported `cannot find 'ZwzV2BlockCodec' in scope`.
- `swift test --filter ZwzV2BlockCodecTests`: PASS. 3 tests executed, 0 failures.
- `swift test --filter ZwzV2PathTests`: PASS. 6 tests executed, 0 failures.
- `swift test`: PASS. 35 tests executed, 0 failures.

Task 5 verified with `swift test --filter ZwzV2BlockCodecTests`.

## Self-Review

- Kept production and test edits within the Task 5 ownership paths; `ZwzV2Types.swift` did not require modification.
- Confirmed the public encoded-block initializer supports use from package consumers.
- Confirmed `.none`, `.fastest`, `.normal`, and `.max` follow the required codec-selection rules, including the 40-byte overhead guard for fastest and max modes.
- Confirmed the raw decoder validates original length for every codec and converts decompression failures to the required v2 error.
- Confirmed encoded-block decoding verifies the checksum after decoding.

## Concerns

- The full build emits existing Swift concurrency and deprecation warnings from `Sources/ZwzGUI`; no warnings were emitted from the new Task 5 files.

## Review Fix Addendum

Status: FIXED

- Gated `.normal` Deflate selection on both beating LZ4 by at least 8% and saving at least 1% versus the original input. When either condition fails, the existing LZ4-if-saves-1% / store fallback applies.
- Added focused coverage for checksum mismatch from `decode(_:)`, malformed raw compressed payload mapping to `ZwzV2Error.decompressionFailed(sequence:)`, and the normal-level store fallback.

## Review Fix Verification

- `swift test --filter ZwzV2BlockCodecTests`: PASS. 6 tests executed, 0 failures.
- `swift test`: PASS. 38 tests executed, 0 failures.

## Review Fix Concerns

- SwiftPM required access to the system module cache in this environment; verification completed successfully with that access.

## Remaining Coverage Fix

Status: FIXED

- Added focused coverage for the exact `.normal` decision boundary where Deflate beats LZ4 by at least 8% but does not save at least 1% versus the input; the selected codec is asserted to be `.store`.
- Added a small internal `selectNormalCodec` seam and routed production `.normal` selection through it, keeping the public API unchanged.

## Remaining Coverage Verification

- `swift test --filter ZwzV2BlockCodecTests`: PASS. 6 tests executed, 0 failures.
- `swift test`: PASS. 38 tests executed, 0 failures.

## Remaining Coverage Concerns

- The first sandboxed SwiftPM run was blocked by system module-cache permissions; the required commands passed after granting cache access.
