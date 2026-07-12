# ZWZ V3 Task 2 Report

## Status

Implemented crypto primitives, recipient content-key wrapping, and Ed25519 signing/verification for ZWZ V3.

## Implementation

- Added public recipient-envelope and signer-record value types.
- Added SHA-256 fingerprints using unambiguous length-prefixed canonical input.
- Added one ephemeral X25519 key per `wrap` call and a distinct random AES-GCM nonce per recipient.
- Derived 256-bit wrapping keys with HKDF-SHA-256, the archive UUID bytes as salt, and `ZWZ3 key wrap` shared info.
- Bound `ZWZ3 recipient envelope`, archive UUID bytes, length-prefixed recipient fingerprint, and ephemeral public key into AES-GCM AAD.
- Added AES-256-GCM seal/open and Ed25519 sign/verify primitives.
- Collapsed unwrap/authentication failures to `ZwzV3Error` values without logging or embedding key material.

## Files

- `Sources/ZwzCore/ZWZV3/ZwzV3Crypto.swift`
- `Tests/ZwzCoreTests/ZWZV3/ZwzV3CryptoTests.swift`
- `Tests/ZwzCoreTests/ZWZV3/ZwzV3CryptoTestSupport.swift`

## RED Evidence

`swift test --filter ZwzV3CryptoTests` failed during test compilation because `ZwzV3Crypto` and `ZwzV3RecipientEnvelope` did not exist. The initial sandboxed invocation was blocked by SwiftPM/Clang cache permissions; the approved unsandboxed invocation produced the expected missing-API compiler failures.

## GREEN Evidence

`swift test --filter ZwzV3CryptoTests` completed with 6 tests, 0 failures. Coverage includes multi-recipient unwrap, shared per-package ephemeral key, per-recipient nonce separation, wrong-key failure, every-byte nonce/ciphertext/tag mutation, AAD metadata mutation, generic AES-GCM AAD authentication, and Ed25519 changed-byte rejection.

## Full Test Result

The single final `swift test` invocation completed with exit code 0 and no test failures, covering the full package including existing V1/V2 and GUI suites.

## Self-review

- Confirmed envelope field mutability matches the requested shape.
- Confirmed AAD uses the specified domain and canonical length prefix for the variable-length fingerprint.
- Confirmed all envelopes from one call share exactly one ephemeral public key while using independently generated nonces.
- Confirmed no logging calls or error payloads expose private keys, shared secrets, content keys, or derived keys.
- Confirmed only Task 2 files are staged for the commit; unrelated pre-existing worktree changes remain untouched.

## Concerns

- The full build emits pre-existing Swift concurrency/deprecation warnings in unrelated V1/V2/GUI files; they do not fail the suite and were not modified for this task.
- `wrap` is intentionally callable with an empty array and returns an empty array; the public encryption-mode validator from Task 1 remains responsible for enforcing at least one recipient.

## Review Fix (2026-07-12)

### Changes

- Updated fingerprint canonical input to length-prefix, in exact order, `ZWZ3 fingerprint v1`, `X25519 agreement public key`, agreement bytes, `Ed25519 signing public key`, and signing bytes. A missing signing key is encoded as a zero-length final value. Every length is UInt32 big-endian.
- Added a deterministic fingerprint vector using agreement bytes `00...1f` and signing bytes `20...3f`. The expected lowercase SHA-256 value, calculated independently with `openssl dgst -sha256`, is `20f48b0d432704d6b4240c092cbddb0330149080aba7dd8ec863956805e14836`.
- Added assertions that swapping the agreement/signing fields and omitting the signing field change the fingerprint.
- Split `wrap` error handling so only recipient-key parsing/key agreement maps to `.invalidRecipientPublicKey(name)`; AES-GCM sealing failures map to `.authenticationFailed`.

### RED

Command: `swift test --filter ZwzV3CryptoTests`

Result: 7 tests executed, 1 failure. `testFingerprintUsesVersionedTypedCanonicalFields` observed the old fingerprint `adc1b4fdbc944f3e111387091df3a20a06a68fb6dbffd2e2acfbdd2e6fb23345` instead of the independently calculated expected `20f48b0d432704d6b4240c092cbddb0330149080aba7dd8ec863956805e14836`.

### GREEN

Command: `swift test --filter ZwzV3CryptoTests`

Result: 7 tests executed, 0 failures, 0 unexpected failures. Full suite intentionally not repeated per review instruction.

### Files Changed

- `Sources/ZwzCore/ZWZV3/ZwzV3Crypto.swift`
- `Tests/ZwzCoreTests/ZWZV3/ZwzV3CryptoTests.swift`
- `.superpowers/sdd/v3-task-2-report.md`
