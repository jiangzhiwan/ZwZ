### Task 9: GUI Public-Key Archive Workflows

Read Task 9 in `docs/superpowers/plans/2026-07-12-public-key-encryption.md`, the V3
design, Task 5 identity-store contracts, Task 6 structured archive APIs, Task 8 restore
callback semantics, and the current archive preview/edit/virtual-disk implementations. Use
TDD. The archive-entry preview sidebar is a separate prerequisite commit; do not mix its
baseline changes into the Task 9 commit.

## Application identity ownership

Create one application-level `ZwzGUIIdentityStore.shared` production owner backed by one
`MacKeychainIdentityStore`. Inject a `ZwzIdentityStore` into testable workflows. Key settings,
compression, listing, extraction, entry preview/open, editing, and virtual-disk mount/save must
all receive that same store instance. Tests must use an in-memory or controlled fake and must
never invoke Keychain, Touch ID, `hdiutil`, or file panels.

`ArchiveViewModel` should receive a small injected archive-workflow client plus edit-session and
mount adapters. Keep production defaults so existing views remain source-compatible. Do not
cache private key bytes, authenticated contexts, restore passwords, or decrypted content in
published state or persisted virtual-disk session data.

## Read-only archive inspection

Add the minimum Core inspection API needed to parse a V3 archive, expose public recipient
labels/fingerprints, and verify an optional Ed25519 signature before any private-key lookup or
content-key unwrap. It must return `ZwzArchiveSecurityInfo` for unsigned, valid-known,
valid-unknown, and invalid signatures without decrypting the index. `invalid` is observable
metadata from inspection, while list/extract/entry operations must still reject content with
`ZwzV3Error.invalidSignature`.

Inspection must preserve the existing split-volume, size-limit, canonical signature, signer
fingerprint/public-key binding, and malformed-input rules. Known-signer classification uses the
injected provider's public trust lookup only and must not request private keys. Add focused Core
tests for unsigned, known, unknown, invalid, missing-key, renamed V3, and split archives.

## Compression state and UI

Add `.none`, `.password`, and `.publicKey` GUI selection. Public-key mode is valid only for ZWZ
and requires at least one selected recipient. Recipient choices are the de-duplicated union of
local identities and public contacts. Signer choices contain only local identities. Sort selected
fingerprints before constructing recipients so output and tests are deterministic.

Switching away from public-key mode clears recipient and signer selections. Switching to ZIP
must leave public-key mode and must never silently reinterpret it as password encryption. Build
`CompressionOptions.encryption` explicitly and pass the shared store to `ZwzAPI.compress`.
Show a dense recipient checklist and optional signer menu in the existing compression sheet;
disable confirmation until the state is valid and show a concise validation/error state.

## Listing, extraction, and recovery

Use the structured `ZwzAPI.list` and `ZwzAPI.extract` paths for ZWZ so the model publishes
`archiveSecurityInfo`. Preview inspection should publish signature status even when no matching
private key exists. Show four distinct badge states: valid known signer, valid unknown signer,
unsigned, and invalid. Recipient names/fingerprints displayed before unlock are untrusted labels.

On `noMatchingPrivateKey`, inspect public `recipientInfo`, publish a restore prompt, and capture a
non-sensitive pending operation snapshot. A successful private-backup restore callback must take
and clear that snapshot before retrying exactly once. A second missing-key result must not create
another automatic retry loop. Cancellation, source changes, tab/preview clearing, and prompt
dismissal clear pending state. Authentication cancellation and Keychain failures must remain
distinct from missing-key recovery.

If inspection or an attempted operation reports an invalid signature, publish `.invalid` and
reject all content-opening methods at their entry points: preview/list retry, normal extract,
smart extract, entry preview/open/drag, archive edit, and virtual-disk mount. UI disabling is
additional defense, not the enforcement boundary.

## Entry preview, editing, and virtual disk

Inject the same store and a typed missing-key callback into `ArchiveEntryPreviewModel`; preserve
its cancellation, extraction-budget, cleanup-root, and generation behavior from the prerequisite
preview commit. `retry()` must retain injected dependencies. Do not reintroduce whole-archive
fallbacks or duplicate extraction triggers.

When opening an edit session or virtual disk, retain the original archive security configuration
without persisting secrets. Public-key save/rebuild must resolve every original recipient public
key from the current identity/contact store. If any recipient is unavailable, refuse the save;
never drop a recipient or downgrade encryption. Preserve signing only when the original signer is
still a local identity with matching public keys and an available signing private key. Otherwise
refuse overwrite/save with an explicit error; do not silently emit unsigned output. Password and
unencrypted V2 behavior must remain unchanged.

## Required tests

Create `PublicKeyArchiveWorkflowTests.swift` and focused test support. Cover at minimum:

- public-key compression requires a ZWZ format and at least one valid recipient;
- changing to password/none/ZIP clears recipient and signer state;
- compression passes sorted recipients, a local-only signer, and the exact shared store;
- preview/list/extract/smart extract/entry/edit/mount receive the exact shared store;
- missing-key prompt shows public recipient labels, successful restore retries once, and a second
  missing-key failure cannot loop;
- authentication cancellation and Keychain errors do not open the restore flow;
- all four signature badges map correctly, and invalid signature leaves every downstream spy
  count at zero;
- edit and virtual-disk public-key saves preserve every recipient/signature or fail explicitly
  when a recipient/signer cannot be resolved;
- no persisted session contains private-key bytes, restore passwords, or authenticated state.

Run the focused Core inspection tests, `swift test --filter PublicKeyArchiveWorkflowTests`, all
`ZwzGUITests`, V2/V3 public API regression tests, and `swift build --target ZwzGUI`. Generate an
independent review diff, close every Critical/Important finding, and commit only Task 9 product
and test files as `feat: integrate public-key archives in GUI`. Update repository and desktop
V3 progress documents after the commit, then pause before Task 10.
