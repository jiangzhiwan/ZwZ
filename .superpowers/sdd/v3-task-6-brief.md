### Task 6: Route Version 3 Through Existing Core APIs

Read the Task 6 plan, Task 3/4 APIs, current public adapters, and the existing unstaged diffs
in `ZwzExtractor.swift` and `ArchiveExtractor.swift`. Preserve those cleanup changes exactly.
Use TDD and do not stage unrelated workspace work.

## Compatibility truth

The current repository's public baseline writes and reads V2. It contains a V1 structural
codec but no V1 compressor/extractor or compatibility fixture, and existing
`ZwzV2APITests.testPublicAPIRejectsV1ArchiveAsUnsupported` deliberately returns
`.unsupportedVersion(1)`. Task 6 must preserve that tested behavior rather than invent an
unverifiable V1 decompressor. Record V1 read support as requiring a historical fixture or
implementation in the final compatibility ledger. V2 no-password/password/split and all
ZIP/other-format behavior must remain unchanged.

## Dispatch

Read only enough bytes to select a codec. Single files use `ZWZ3` for V3,
`ZwzV2Format.magic` for V2, and V1 magic remains explicitly unsupported. V2 and V3 split
archives both use the existing 80-byte `ZWZS` envelope: discover and order the full volume
set by envelope volume number, validate it with existing volume rules, then inspect the first
four logical payload bytes of volume zero. Never decide V2 versus V3 from extension alone.
Unknown/truncated logical magic is a structured malformed/unsupported error, never a trap.

`ZwzCompressor.compress` selects V3 only for `.publicKey`; `.none` and `.password` continue
through V2. An unsigned public-key archive may use a nil provider. A requested signer with a
nil provider fails through the existing V3 error. ZIP never sees a key provider.

## Public result/API contract

Add public Sendable/Equatable results:

- `ZwzArchiveListing`: `entries: [ArchiveEntry]`, `version: UInt16?`, and optional
  `securityInfo`; non-ZWZ formats use nil version/security.
- `ZwzExtractionResult`: `destinationPath: String`, `version: UInt16?`, and optional
  `securityInfo`.

Keep every existing signature source-compatible. Add unambiguous detailed overloads where a
`keyProvider` argument is explicitly present (do not overload on return type alone):

- `ZwzAPI.compress(..., keyProvider: ZwzPrivateKeyProvider?, ...) -> String`;
- `ZwzAPI.list(archivePath:password:keyProvider:) -> ZwzArchiveListing` while the existing
  `list(archivePath:) -> [ArchiveEntry]` maps `.entries`;
- `ZwzAPI.extract(..., keyProvider: ZwzPrivateKeyProvider?, ...) -> ZwzExtractionResult`
  while the existing overload maps `.destinationPath`;
- `ZwzAPI.extractEntryToTemp(..., keyProvider:)` plus the legacy overload.

Mirror routing in `ZwzCompressor` and `ZwzExtractor`. `ArchiveExtractor` and
`ArchivePreviewer` receive source-compatible optional `keyProvider` parameters and pass them
only to ZWZ. Preserve the existing temporary-directory cleanup diff on single-entry failure.

For V3, map `ZwzV2Entry` to `ArchiveEntry` with the existing directory-size presentation and
return the exact V3 security info. For V2, return version 2; security info is `.password` when
the actual decoded V2 header encrypted flag is set, otherwise `.none`, and signature is
`.unsigned`. Do not infer encryption from whether a caller supplied a password. Legacy list
and extract discard structured security metadata only at their compatibility boundary.

V3 full extraction returns its security info and single-entry extraction uses the provider.
All V3 missing-key, user-cancel, keychain, invalid-signature, and authentication errors pass
through unchanged. Do not map them to password errors or generic strings.

## Required tests

- Public API `.publicKey` writes `ZWZ3`; `.none` and `.password` still write V2; ZIP unchanged.
- Single and split V3 are detected from logical magic, listed/extracted by either recipient,
  and report exact signed/unsigned security info.
- V2 no-password/password/split list/extract and security metadata remain correct.
- V1 retains the current explicit unsupported error; unknown/truncated inputs are safe.
- Missing provider, wrong provider, user cancellation, invalid signature, and keychain failure
  survive all adapter layers with the same concrete error.
- Legacy signatures still compile and return their old `[ArchiveEntry]`, `String`, and `URL`
  shapes.
- V3 single-entry failure cleans its temporary directory, preserving the user's unstaged fix.
- ArchivePreviewer/ArchiveExtractor route V3 without affecting ZIP/TAR/GZ/RAR/7Z dispatch.

Run `swift test --filter ZwzV3APITests`, `swift test --filter ZwzV2APITests`, and focused
preview/cleanup tests. Commit only Task 6 product/test files as
`feat: route public-key archives through ZwzCore`.
