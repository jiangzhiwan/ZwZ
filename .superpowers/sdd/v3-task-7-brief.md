### Task 7: CLI Key Management and Public-Key Workflows

Read the Task 7 plan, current `Sources/zwz/main.swift`, Task 5 stores, and Task 6 structured
APIs. Use TDD. Complete this task, update tests, and stop before GUI work.

## Architecture

Move parsing/value types to `CLIArguments.swift`. Put command execution behind
`ZwzCLI.run(arguments:dependencies:) -> Int32`; `main.swift` must only call the runner and
`exit`. Dependencies expose output/error sinks, password/confirmation readers, an
`ZwzIdentityStore`, and the archive operations needed by CLI tests. Production dependencies
use `MacKeychainIdentityStore` and `ZwzAPI`; tests use in-memory/fakes and never query the real
Keychain. No command handler may call `exit`.

Add a `ZwzCLITests` test target depending on `zwz` and `ZwzCore`. Keep legacy aliases and
syntax (`c/x/l/h`, existing compress/extract options) source/behavior compatible.

## Commands and parsing

Commands:

- `key create <name>`
- `key list`
- `key rename <identity-or-fingerprint> <new-name>`
- `key delete [--yes] <identity-or-fingerprint>`
- `key export-public <identity-or-fingerprint> <output.zwzpub>`
- `key import-public [--replace] <input.zwzpub>`
- `key backup <identity-or-fingerprint> <output.zwzkey>`
- `key restore [--replace] <input.zwzkey>`
- existing `compress`, `extract`, `list`, `help` and aliases.

Compression adds repeatable `--recipient <name-or-fingerprint>` and optional
`--sign <local-identity-or-fingerprint>`. Password and recipient/sign modes are mutually
exclusive. Recipients/sign require `-f zwz`; sign requires at least one recipient. Reject
missing option values, duplicate singleton options, extra positional arguments, invalid split
sizes, non-positive split sizes, negative threads, and unknown flags before filesystem or
Keychain access. Preserve repeatable recipient order while removing exact duplicate resolved
fingerprints.

List/extract continue accepting archive `-p/--password` and automatically use the injected
identity store for V3. Key backup/restore must reject all password/password-file/environment
options; there is no CLI/environment password transport.

## Identity resolution and safety

Resolve a 64-lowercase-hex exact fingerprint first. Otherwise match names case-insensitively
and exactly. Recipients search local identities plus contacts; signer, backup, rename of local
identity, and private operations search local identities as appropriate. Rename/delete may
also address contacts, but backup/sign cannot. Zero matches is a command error. Multiple name
matches are an error that prints every matching fingerprint; never pick the first silently.

`key delete` prints the permanent-loss warning and requires interactive `y/yes` unless
`--yes` was explicitly parsed. `--replace` is the only route to
`.replaceExisting`; default import/restore uses `.requireConfirmation`. Public/backup output
uses a sibling temporary file plus atomic replace and removes partial files on error. Do not
overwrite an existing output unless the command contract explicitly confirms it; export and
backup should fail if output exists.

Backup password input is requested twice for export and once for restore. When stdin is a
TTY, disable echo with Darwin `termios`, restore terminal state with `defer` on every path,
then print a newline. When stdin is not a TTY, read one line without echo manipulation so a
caller may pipe input. Reject empty passwords and mismatched confirmation. Never print, log,
store in arguments, or read backup passwords from environment variables.

## Archive execution and output

Build `ZwzRecipient` from resolved public materials. Build `ZwzSigningIdentity` only from a
local identity and pass the store as `keyProvider`. Unsigned public-key compression may still
use the store dependency without prompting; the core only requests a private key for signing.

Use Task 6 detailed list/extract APIs and print signature state:

- unsigned;
- valid known signer with name/fingerprint;
- valid unknown signer with embedded name/fingerprint.

Invalid signatures already throw and must exit nonzero. Preserve concrete errors in stderr:
missing private key, user-cancelled system authentication, Keychain failure, invalid signature,
and archive authentication failure must not become “wrong password”. On
`.noMatchingPrivateKey(fingerprints)`, print all recipient fingerprints and exactly the
actionable template `zwz key restore <backup.zwzkey>`.

To show public recipient names as well, add a minimal read-only Core API only if needed:
`ZwzV3Extractor.recipientInfo(archivePath:) -> [ZwzRecipientInfo]`, using its existing
single/split validated loader and Task 3 parser without decrypting the index. Do not duplicate
archive parsing in the CLI. If added, names/fingerprints are untrusted public labels and must
be described only as archive recipients, never as verified identities.

Help output must list all key commands and public-key flags without printing implementation
instructions. Avoid decorative output dependence in parser/handler tests; assert semantic
lines and exit codes.

## Required tests

- Parser covers all key subcommands, aliases, repeated recipients/sign, legacy syntax, and
  every invalid mixed/duplicate/missing-value/extra-position case.
- Name/fingerprint resolution, ambiguous names with candidate fingerprints, local-only signer,
  duplicate recipient collapse, and contact recipients.
- Key create/list/rename/delete confirmation, public import/export conflict, backup/restore
  password confirmation, no plaintext password in output/errors/parsed values, atomic output
  cleanup, and no real Keychain access.
- End-to-end CLI unsigned/signed multi-recipient V3 compress, list, extract, and signature
  output using an in-memory store.
- Missing key restore guidance includes archive recipient names/fingerprints when the Core
  recipient-info API is present; cancellation/keychain/signature/authentication errors remain
  distinct and nonzero.
- Existing ZIP and V2 CLI commands still parse and run; help contains new commands.
- Password reader terminal-state restoration is isolated behind a system-call abstraction or
  a small deterministic unit-testable helper; do not manipulate the test runner's TTY.

Run `swift test --filter ZwzCLITests`, `swift run zwz help`, and relevant Core API tests.
Commit only Task 7 CLI/Package/test files and any minimal recipient-info Core additions as
`feat: expose ZWZ identities and recipients in CLI`.
