#!/bin/bash
set -euo pipefail

APP_BUNDLE="${1:?Usage: check-app-bundle.sh /path/to/ZwZ.app}"
INFO_PLIST="$APP_BUNDLE/Contents/Info.plist"
ICON_FILE="$APP_BUNDLE/Contents/Resources/ZwZ.icns"

[[ -r "$INFO_PLIST" ]] || {
  printf 'Info.plist is not readable: %s\n' "$INFO_PLIST" >&2
  exit 1
}

[[ -r "$ICON_FILE" ]] || {
  printf 'App icon is not readable: %s\n' "$ICON_FILE" >&2
  exit 1
}

/usr/bin/plutil -lint "$INFO_PLIST" >/dev/null
[[ "$(/usr/bin/stat -f '%A' "$INFO_PLIST")" =~ [4-7][0-7][4-7]$ ]] || {
  printf 'Info.plist must be readable by all users: %s\n' "$INFO_PLIST" >&2
  exit 1
}

[[ "$(/usr/bin/stat -f '%A' "$ICON_FILE")" =~ [4-7][0-7][4-7]$ ]] || {
  printf 'App icon must be readable by all users: %s\n' "$ICON_FILE" >&2
  exit 1
}

printf 'App bundle resources are readable: %s\n' "$APP_BUNDLE"
