# Task 7 Report: Index Codec and Metadata Privacy

## Final Status

DONE

## Changed Files

- `Sources/ZwzCore/ZWZV2/ZwzV2IndexCodec.swift`
- `Tests/ZwzCoreTests/ZWZV2/ZwzV2IndexCodecTests.swift`
- `.superpowers/sdd/reports/task-7-report.md`

## Implementation

- Added `ZwzV2IndexCodec` with a compact little-endian binary index format: `ZWZI` magic, version `2`, archive UUID, block size, entries, and block descriptors.
- Encoded paths as length-prefixed UTF-8 and modification times as signed, little-endian milliseconds since the Unix epoch.
- Added guarded decoding for truncated data, invalid lengths/counts, invalid UTF-8, unknown entry types/codecs, invalid hidden flags, invalid block sizes, and trailing bytes.
- Validated archive paths and duplicate/file-descendant conflicts during both encoding and decoding through `ZwzV2PathValidator`.
- Added archive wrappers that leave plaintext untagged when no crypto context is supplied and otherwise use `ZwzV2Crypto.sealIndex/openIndex`, preserving detached authentication tags and tamper/wrong-password behavior.

## Test-Driven Development Record

1. Added index codec tests before implementation.
2. Ran `swift test --filter ZwzV2IndexCodecTests`; after Swift compiler-cache access was granted, it failed because `ZwzV2IndexCodec` did not exist.
3. Implemented the codec and reran the focused suite successfully.
4. Added the integral-milliseconds wire-format test; it failed against the original floating-point timestamp encoding.
5. Changed the timestamp field to signed little-endian milliseconds and reran the focused suite successfully.

## Commands Run

| Command | Result |
| --- | --- |
| `swift test --filter ZwzV2IndexCodecTests` | PASS: 6 tests, 0 failures |
| `swift test --filter ZwzV2CryptoTests` | PASS: 2 tests, 0 failures |
| `swift test` | PASS: 46 tests, 0 failures |

## Self-Review

- Confirmed the public API exactly matches the task brief.
- Confirmed binary data is used throughout; no JSON serialization is involved.
- Confirmed fields are written and read in the documented order with little-endian fixed-width integers.
- Confirmed count/length checks are bounded by remaining bytes and every read is range-checked; the decoder rejects trailing bytes.
- Confirmed paths are validated and duplicate conflicts rejected after decoding.
- Confirmed encrypted payloads are produced only by `sealIndex`; the filename privacy and wrong-context tests pass.
- No changes to `ZwzV2Types.swift` were needed.

## Concerns

None for Task 7. The package still emits unrelated Swift concurrency and deprecation warnings from existing GUI code during builds; all tests pass.

## Review Fixes

- `encodePlain` now rejects modification times that are not whole milliseconds. It converts the rounded millisecond value with `Int64(exactly:)`, preventing the `Double(Int64.max)` upper-bound trap while preserving exact round-trip behavior for accepted values.
- Decoder count checks now compare through `UInt64`, avoiding a narrowing conversion from `reader.remaining`, and no longer reserve arrays directly from untrusted counts.
- Filename privacy verification now searches encrypted bytes directly for `Data("hidden.txt".utf8)`.
- Added regression tests for fractional timestamps, the unrepresentable upper timestamp bound, encrypted payload tampering, and encrypted tag tampering.

## Review Verification

| Command | Result |
| --- | --- |
| `swift test --filter ZwzV2IndexCodecTests` | PASS: 10 tests, 0 failures |
| `swift test --filter ZwzV2CryptoTests` | PASS: 2 tests, 0 failures |
| `swift test` | PASS: 50 tests, 0 failures |

## Review Concerns

None.
