### Task 10: Full Regression, Packaging, Compatibility Fixtures, and Documentation

Read Task 10 in `docs/superpowers/plans/2026-07-12-public-key-encryption.md`, the V3
design, the completed Task 1-9 code, `.superpowers/sdd/progress.md`, and the desktop V3
handoff. Use TDD and do not modify or commit `.superpowers/sdd/*`, the repository copy of
the handoff, or unrelated user files.

## Compatibility correction

The repository contains only a V1 structural codec and no historical V1 reader/writer or
authentic V1 fixture. Existing public behavior deliberately returns `unsupportedVersion(1)`.
Do not invent a V1 archive or claim V1 extraction compatibility. Add a small committed V1
header fixture only if it truthfully locks safe detection/rejection; otherwise use an explicit
test-generated header. README must accurately state V1 is detected but unsupported. Commit
real deterministic V2 and V3 fixtures generated from the current canonical codecs.

## Fixtures and tests

Create `Tests/ZwzCoreTests/ZWZV3/ZwzV3CompatibilityTests.swift` and small fixtures under
`Tests/ZwzCoreTests/Fixtures/`. Cover at minimum:

- fixed V2 unencrypted and password fixtures: detect, list, extract, and wrong-password failure;
- fixed V3 unsigned multi-recipient and signed multi-recipient fixtures: detect, inspect, list,
  extract by each intended test recipient, known/unknown signer classification;
- one-byte mutations of signed canonical bytes and authenticated encrypted data are refused;
- fixture generation is deterministic/reproducible as far as the format permits; if random
  cryptographic material prevents byte-for-byte regeneration, commit the fixture plus explicitly
  labeled test-only public/private key material under the test target and lock SHA-256 digests;
- no production private key, password, content key, or real user identity is committed.

Keep fixtures small. Test-only passwords and private keys must be conspicuously labeled and used
only by the compatibility test target.

## Documentation and bundle checks

Update README with exact GUI/Core/CLI public-key behavior and these working CLI shapes, adjusted
only if the actual parser requires different option placement:

```
zwz key create "My Mac"
zwz key export-public "My Mac" recipient.zwzpub
zwz compress -f zwz --recipient recipient.zwzpub --sign "My Mac" source
zwz extract archive.zwz output
zwz key backup "My Mac" identity.zwzkey
zwz key restore identity.zwzkey
```

State password/public-key exclusivity, visible untrusted recipient labels, valid-known versus
valid-unknown signatures, invalid-signature refusal, Keychain user-presence behavior, private-key
backup requirements, irreversible loss if every private-key copy is lost, V2 compatibility, and
truthful V1 unsupported status.

Extend `scripts/check-app-bundle.sh` so packaged app validation covers the executable, Info.plist,
icon/resource readability, resource bundle presence when expected, and code-signature validity
after signing without depending on user Keychain identities.

## Verification and commit

Run the entire suite before documentation changes, then after all changes run at least:

- `swift build`
- `swift test`
- `./scripts/package-app.sh`
- `./scripts/check-app-bundle.sh dist/ZwZ.app`
- package installer if feasible in this environment, reporting any platform/manual limitation
- `git diff --check` and exact staged-scope review

Generate `.superpowers/sdd/v3-task-10-review.diff`, request an independent final review, close all
Critical/Important findings, rerun affected full verification, and commit only README, bundle
check, compatibility tests, and fixtures as:

`docs: document ZWZ public-key encryption`

After the product commit, update repository and desktop progress documents with results and stop.
