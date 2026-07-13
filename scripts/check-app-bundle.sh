#!/bin/bash
set -euo pipefail

APP_BUNDLE="${1:?Usage: check-app-bundle.sh /path/to/ZwZ.app}"
INFO_PLIST="$APP_BUNDLE/Contents/Info.plist"
RESOURCES="$APP_BUNDLE/Contents/Resources"

require_mode_bits_for_all() {
  local path="$1"
  local required="$2"
  local description="$3"
  local mode
  mode="$(/usr/bin/stat -f '%Lp' "$path")"
  local owner=$(( (mode / 100) % 10 ))
  local group=$(( (mode / 10) % 10 ))
  local other=$(( mode % 10 ))
  (( (owner & required) == required &&
     (group & required) == required &&
     (other & required) == required )) || {
    printf '%s must be available to owner, group, and other users: %s (mode %s)\n' \
      "$description" "$path" "$mode" >&2
    exit 1
  }
}

require_readable_by_all() { require_mode_bits_for_all "$1" 4 "Resource"; }
require_traversable_by_all() { require_mode_bits_for_all "$1" 5 "Directory"; }
require_executable_by_all() { require_mode_bits_for_all "$1" 5 "Executable"; }

[[ -d "$APP_BUNDLE" && -r "$APP_BUNDLE" ]] || {
  printf 'App bundle is not readable: %s\n' "$APP_BUNDLE" >&2
  exit 1
}
require_traversable_by_all "$APP_BUNDLE"
require_traversable_by_all "$APP_BUNDLE/Contents"

[[ -r "$INFO_PLIST" ]] || {
  printf 'Info.plist is not readable: %s\n' "$INFO_PLIST" >&2
  exit 1
}

/usr/bin/plutil -lint "$INFO_PLIST" >/dev/null
require_readable_by_all "$INFO_PLIST"

EXECUTABLE_NAME="$(/usr/bin/plutil -extract CFBundleExecutable raw -o - "$INFO_PLIST")"
[[ -n "$EXECUTABLE_NAME" && "$EXECUTABLE_NAME" != */* ]] || {
  printf 'Invalid CFBundleExecutable in: %s\n' "$INFO_PLIST" >&2
  exit 1
}
EXECUTABLE="$APP_BUNDLE/Contents/MacOS/$EXECUTABLE_NAME"
require_traversable_by_all "$APP_BUNDLE/Contents/MacOS"
[[ -f "$EXECUTABLE" && -r "$EXECUTABLE" && -x "$EXECUTABLE" ]] || {
  printf 'App executable is not readable and executable: %s\n' "$EXECUTABLE" >&2
  exit 1
}
require_executable_by_all "$EXECUTABLE"

ICON_NAME="$(/usr/bin/plutil -extract CFBundleIconFile raw -o - "$INFO_PLIST")"
[[ -n "$ICON_NAME" && "$ICON_NAME" != */* ]] || {
  printf 'Invalid CFBundleIconFile in: %s\n' "$INFO_PLIST" >&2
  exit 1
}
[[ "$ICON_NAME" == *.* ]] || ICON_NAME="$ICON_NAME.icns"
ICON_FILE="$RESOURCES/$ICON_NAME"
require_traversable_by_all "$RESOURCES"
[[ -f "$ICON_FILE" && -r "$ICON_FILE" ]] || {
  printf 'App icon is not readable: %s\n' "$ICON_FILE" >&2
  exit 1
}
require_readable_by_all "$ICON_FILE"

LOGO_FILE="$RESOURCES/ZwZLogo.png"
[[ -f "$LOGO_FILE" && -r "$LOGO_FILE" ]] || {
  printf 'App logo resource is not readable: %s\n' "$LOGO_FILE" >&2
  exit 1
}
require_readable_by_all "$LOGO_FILE"

RESOURCE_BUNDLE="$RESOURCES/zwz_ZwzGUI.bundle"
[[ -d "$RESOURCE_BUNDLE" && -r "$RESOURCE_BUNDLE" ]] || {
  printf 'Expected SwiftPM resource bundle is missing: %s\n' "$RESOURCE_BUNDLE" >&2
  exit 1
}
require_traversable_by_all "$RESOURCE_BUNDLE"
RESOURCE_LOGO="$RESOURCE_BUNDLE/ZwZLogo.png"
[[ -f "$RESOURCE_LOGO" && -r "$RESOURCE_LOGO" ]] || {
  printf 'Bundled logo resource is not readable: %s\n' "$RESOURCE_LOGO" >&2
  exit 1
}
require_readable_by_all "$RESOURCE_LOGO"

SIGNATURE_DETAILS="$(/usr/bin/codesign --display --verbose=2 "$APP_BUNDLE" 2>&1 || true)"
if [[ "$SIGNATURE_DETAILS" != *"Info.plist=not bound"* &&
      "$SIGNATURE_DETAILS" != *"Sealed Resources=none"* ]]; then
  /usr/bin/codesign --verify --deep --strict "$APP_BUNDLE"
  printf 'App bundle code signature is valid: %s\n' "$APP_BUNDLE"
else
  # package-app.sh performs this preflight before applying its ad-hoc bundle signature.
  # Verify a copy outside the unfinished bundle so codesign does not expect sealed resources yet.
  TEMP_EXECUTABLE="$(/usr/bin/mktemp "${TMPDIR:-/tmp}/zwz-signature-check.XXXXXX")"
  cleanup_signature_copy() { /bin/rm -f "$TEMP_EXECUTABLE"; }
  trap cleanup_signature_copy EXIT
  /bin/cp "$EXECUTABLE" "$TEMP_EXECUTABLE"
  /bin/chmod 755 "$TEMP_EXECUTABLE"
  /usr/bin/codesign --verify --strict "$TEMP_EXECUTABLE"
  cleanup_signature_copy
  trap - EXIT
  printf 'Unsigned bundle preflight passed; executable signature is valid: %s\n' "$EXECUTABLE"
fi

printf 'App bundle structure and resources are valid: %s\n' "$APP_BUNDLE"
