# Task 6 Review Package

Workspace: `/Users/jiangzhiwan/Desktop/ZwZ`

Git range: unavailable because this workspace is not a Git repository.

## Test Evidence

- Implementer: `swift test --filter ZwzV2CryptoTests`: passed; 2 tests, 0 failures.
- Implementer: `swift test --filter ZwzV2BlockCodecTests`: passed; 6 tests, 0 failures.
- Implementer: `swift test`: passed; 40 tests, 0 failures.
- Warnings during full build are existing Swift 6/AppKit warnings in `Sources/ZwzGUI`.

## Files Changed

- `Sources/ZwzCore/ZWZV2/ZwzV2Crypto.swift`
- `Tests/ZwzCoreTests/ZWZV2/ZwzV2CryptoTests.swift`

## Current File Pointers

Read these files directly for exact current contents:

- `Sources/ZwzCore/ZWZV2/ZwzV2Crypto.swift`
- `Tests/ZwzCoreTests/ZWZV2/ZwzV2CryptoTests.swift`

## Implementation Summary

- Added `ZwzV2CryptoContext` with public `archiveID`, `salt`, `iterations`, and fileprivate key.
- Added `ZwzV2Crypto.makeSalt()`.
- Added `deriveContext(password:salt:iterations:archiveID:)` using CryptoSwift PBKDF2-HMAC-SHA256 with a 32-byte key.
- Added AES-GCM detached tag sealing/opening for blocks and index.
- Nonce layout is 12 bytes: domain byte, 8-byte little-endian sequence, first three bytes of archive UUID.
- Block domain is `0x42`; index domain is `0x49`.
- Authenticated open failures map to `ZwzV2Error.wrongPasswordOrTamperedData`.
