### Task 8: GUI Key Management

Read the Task 8 plan, Task 5 store contracts, current settings implementation around
`ZWZSettingsView`, and the current unstaged `ZwzApp.swift`/`Localization.swift` diffs. Use
TDD. Preserve preview/sidebar changes and do not include them in Task 8 commits.

## View-model contract

Create an `@MainActor` `IdentityManagerViewModel: ObservableObject` with published read-only
identities/contacts, selection, busy state, pending deletion, non-sensitive pending conflict,
error/success messages, and the injected `ZwzIdentityStore`. Never publish/cache private key
bytes, backup passwords, decrypted backup records, or authenticated `LAContext` objects.

Expose create, refresh, rename, request/cancel/confirm delete, public import/export data,
private backup data, and restore operations. Validate non-blank names and password confirmation
before store access. Default import/restore uses `.requireConfirmation`; on
`.identityConflict(fingerprint)` set a conflict state containing only operation kind and
fingerprint. An explicit retry from the view passes `.replaceExisting` and reuses password
only from the view's `@State` secure field. Clear password fields on success, cancel, view
dismissal, and failed authentication.

Store calls that may invoke Keychain authentication or scrypt must execute off the main
actor; only state publication returns to `MainActor`. Prevent concurrent mutating operations
with `isBusy`, while refresh/list must not cause private-key prompts. Propagate
`.userAuthenticationCancelled`, Keychain errors, invalid backup, and conflicts into clear
localized UI state without mapping them to generic password errors.

Deletion is two-phase: `requestDelete` does not touch the store; confirmation performs the
delete. The pending state and UI warning must distinguish a local identity (deleting the last
private copy may make archives permanently unrecoverable) from a public-only contact.

Accept an optional restore callback used by a future pending archive action. Invoke it exactly
once after a successful private restore, never on conflict, cancellation, wrong password, or
public import.

## Settings UI

Create `IdentityManagerView.swift` and add a `keys` destination to the existing settings
sidebar. Use the current restrained settings style and `SettingsStrings.text` bilingual
helper; do not require edits to dirty `Localization.swift` unless unavoidable. Use SF Symbols
for commands and tooltips/accessibility labels for icon-only controls.

The page must provide:

- toolbar commands: create identity, import public key, restore private backup;
- separate local identities and contacts sections with name and grouped fingerprint;
- selected-item actions: rename, copy fingerprint, export public key, delete;
- local-only encrypted private backup action;
- empty/loading/busy/error/success states;
- create/rename sheets with validated names;
- delete confirmation with the permanent-loss warning for local identities;
- backup sheet with two `SecureField`s and disabled confirmation until non-empty/matching;
- restore sheet with one `SecureField`;
- explicit conflict alert offering cancel or replace;
- `NSOpenPanel` filters for `.zwzpub`/`.zwzkey` and `NSSavePanel` default extensions;
- atomic `Data.write(options: .atomic)` only after the panel confirms the target.

Do not display raw public-key bytes or any private material. Fingerprints may wrap and use a
monospaced font; all text must fit at the existing settings minimum width. No nested cards.

The production page creates `MacKeychainIdentityStore` once via `@StateObject` view-model
ownership. Merely opening settings/keys or refreshing must not trigger user authentication.
Actual Touch ID/login-password prompts remain a signed-app manual integration check.

## Required tests

Use `InMemoryZwzIdentityStore` or a controlled Sendable fake; never instantiate the real
Keychain store in tests. Cover:

- initial refresh, manual nonblank create, selection and local/contact separation;
- rename preserves fingerprint/public keys;
- request delete leaves data intact, cancel leaves intact, confirm deletes;
- public import/export and conflict state/default-vs-explicit replacement;
- backup rejects empty/mismatched password before store access and contains no raw keys;
- restore wrong password/conflict/cancel do not invoke resume callback;
- successful restore invokes callback exactly once and refreshes identities;
- user authentication cancellation and Keychain errors remain distinguishable messages;
- busy state rejects overlapping mutations and scrypt/store work does not run on main thread;
- error and sensitive view state are cleared at the defined boundaries.

Run `swift test --filter IdentityManagerViewModelTests`, existing settings tests, and a GUI
target build. Commit only the two new GUI files, two new test files, and precise Task 8 hunks
in `ZwzApp.swift` (and localization only if actually needed) as
`feat: add ZWZ key management interface`.
