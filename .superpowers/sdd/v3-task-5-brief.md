### Task 5: Key Files, Password-Protected Backups, and Stores

Read the Task 5 plan and public-key design first. This brief is normative where the plan is
not byte-exact. Use TDD. Do not touch unrelated GUI/preview changes or `.superpowers/sdd`
when committing.

## Public identity file (`ZWZP`)

All integers are unsigned little-endian. The fixed header is 32 bytes:

| Offset | Size | Field |
|---:|---:|---|
| 0 | 4 | ASCII `ZWZP` |
| 4 | 2 | version = 1 |
| 6 | 2 | header size = 32 |
| 8 | 1 | agreement algorithm = 1 (X25519) |
| 9 | 1 | signing algorithm = 1 (Ed25519) |
| 10 | 1 | fingerprint algorithm = 1 (ZWZ3/SHA-256 canonical fingerprint) |
| 11 | 1 | reserved zero |
| 12 | 4 | non-empty UTF-8 name length |
| 16 | 4 | fingerprint UTF-8 length |
| 20 | 4 | agreement public-key length = 32 |
| 24 | 4 | signing public-key length = 32 |
| 28 | 4 | reserved zero |

Body order is name, fingerprint, agreement public key, signing public key, with no padding or
trailing bytes. Fingerprint is exactly 64 lowercase ASCII hex characters and must equal
`ZwzV3Crypto.fingerprint(agreement:signing:)`; encode never trusts a caller-supplied mismatch.
Unknown versions/algorithms, non-zero reserved bytes, invalid UTF-8, overflow, truncation,
wrong key lengths, and trailing bytes return `.invalidKeyFile`.

## Private backup file (`ZWZB`)

The fixed authenticated header is 64 bytes:

| Offset | Size | Field |
|---:|---:|---|
| 0 | 4 | ASCII `ZWZB` |
| 4 | 2 | version = 1 |
| 6 | 2 | header size = 64 |
| 8 | 1 | KDF = 1 (scrypt) |
| 9 | 1 | cipher = 1 (AES-256-GCM) |
| 10 | 1 | agreement algorithm = 1 (X25519) |
| 11 | 1 | signing algorithm = 1 (Ed25519) |
| 12 | 4 | N = 65,536 |
| 16 | 4 | r = 8 |
| 20 | 4 | p = 1 |
| 24 | 2 | salt length = 16 |
| 26 | 2 | nonce length = 12 |
| 28 | 8 | ciphertext length |
| 36 | 28 | reserved zero |

File order is fixed header, 16-byte random salt, 12-byte random nonce, ciphertext, 16-byte
GCM tag, and EOF. AES-GCM AAD is exact header + salt + nonce. Before invoking CryptoSwift,
decode requires the exact supported IDs/parameters and checked total length; never allocate
from an untrusted KDF parameter. Password must be non-empty. Derive exactly 32 bytes with
`Scrypt(password:Array(password.utf8), salt:Array(salt), dkLen:32, N:65536, r:8, p:1)`.
All password/KDF/GCM/body errors map to `.invalidBackup` without distinguishing wrong password
from corruption. Do not expose derived keys or private bytes in errors/logs.

The encrypted plaintext is:

1. ASCII `ZWZI` (4 bytes), version UInt16 = 1, reserved UInt16 = 0;
2. name length UInt32, fingerprint length UInt32;
3. agreement private-key length UInt32 = 32, signing private-key length UInt32 = 32;
4. non-empty UTF-8 name, 64-byte lowercase fingerprint, 32-byte X25519 private key,
   32-byte Ed25519 private key, and EOF.

On decode, construct both CryptoKit private keys, derive their public keys, recompute the
fingerprint, and reject any mismatch. Public keys are not duplicated in encrypted plaintext.
Tests may inject deterministic salt/nonce through an internal-only encoder seam; production
uses `SecRandomCopyBytes` for salt and CryptoKit `AES.GCM.Nonce()`.

## Store contracts

`ZwzPublicIdentity` contains name, fingerprint, agreementPublicKey, signingPublicKey.
`ZwzIdentityMetadata` contains the same public fields and creation date; it never contains
private bytes. `ZwzIdentityConflictPolicy` has `.requireConfirmation` and
`.replaceExisting`; replacement happens only when explicitly requested. Fingerprints always
bind both actual public keys. Rename cannot change fingerprint or keys.

`InMemoryZwzIdentityStore` keeps private material only for tests/non-production injection and
conforms to `ZwzPrivateKeyProvider`. `isKnownSigningKey` returns true only for a stored identity
or contact whose fingerprint and signing public key both match. Provider cancellation/errors
remain distinct.

`MacKeychainIdentityStore` stores public identity/contact metadata in separately queryable
generic-password items without user-presence ACL, so `identities()` and `contacts()` never
prompt. Store each agreement/signing private key in a separate generic-password item created
with `SecAccessControlCreateWithFlags(..., kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
.userPresence, ...)`. Every private-key lookup creates a fresh `LAContext` and query with
`kSecUseAuthenticationContext` plus the operation-specific reason. Never cache private bytes
or an authenticated context. Map `errSecUserCanceled` to `.userAuthenticationCancelled`, item
missing to `.noMatchingPrivateKey([fingerprint])`, and other statuses to
`.keychainFailure(status)`.

Creation/import is transactional at store level: if any private/metadata item write fails,
remove items written for that fingerprint. Delete removes metadata and both private items.
Public contacts never acquire private-key provider capability. Backup restore validates the
complete container before writing any item.

Unit tests must never query the real Keychain. Cover public golden bytes/round trip, every
header field/truncation/trailing mutation, backup no plaintext key/name leakage, wrong
password/header/salt/nonce/cipher/tag mutations, KDF parameter rejection before derivation,
restored decrypt/sign, conflict policies, rename/delete/contact trust binding, provider error
semantics, and transactional in-memory behavior. The real Keychain user-presence prompt is a
manual signed-app integration check and must be documented as not runnable in `swift test`.

Run `swift test --filter 'ZwzKeyFileCodecTests|ZwzIdentityStoreTests'`, then
`swift test --filter ZwzV3`. Commit only Task 5 source/tests and minimal V3 error additions as
`feat: add protected ZWZ identity management`.
