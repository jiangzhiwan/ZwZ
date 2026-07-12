# One-Click Packaging Design

## Goal

Add two Finder-double-clickable entry scripts to the ZwZ project root: one for producing the application bundle and disk image, and one for producing the macOS installer package.

## Entry Scripts

### `build-app.command`

- Resolve the project root from the script's own location.
- Invoke `scripts/package-app.sh` without duplicating packaging logic.
- Produce `dist/ZwZ.app` and `dist/ZwZ.dmg` through the existing packaging script.
- On success, print both artifact paths and reveal the `dist` directory in Finder.

### `build-installer.command`

- Resolve the project root from the script's own location.
- Invoke `scripts/package-pkg.sh` without duplicating packaging logic.
- Produce `dist/ZwZ-Installer.pkg`, containing the app and command-line tool through the existing packaging script.
- On success, print the installer path and reveal it in Finder.

## Terminal Behavior

- Both entry scripts use Bash strict mode.
- Both print a clear title before starting.
- Failure from an underlying packaging script is preserved as a nonzero exit status.
- When launched interactively from Finder, success and failure both display a final prompt so the user can read the result before closing the terminal window.
- When standard input is not a terminal, the scripts do not wait for input, which keeps automated verification usable.

## Permissions and Compatibility

- Both `.command` files are executable.
- Paths are quoted so the project can live in a directory containing spaces.
- No new dependencies or signing identities are introduced.
- Existing ad-hoc code signing and package contents remain unchanged.

## Verification

- Run Bash syntax checks on both entry scripts.
- Verify both files are executable.
- Verify each entry references the correct existing packaging script and expected output paths.
- Do not run the full packaging processes during routine script verification because they create release artifacts and invoke macOS signing, disk-image, and installer tools; the user can run either entry explicitly when desired.
