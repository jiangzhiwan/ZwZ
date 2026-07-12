#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
PACKAGE_SCRIPT="$ROOT/scripts/package-pkg.sh"
INSTALLER="$ROOT/dist/ZwZ-Installer.pkg"
status=0

printf '\n=== ZwZ 安装包一键打包 ===\n\n'

if "$PACKAGE_SCRIPT"; then
    printf '\n打包成功：\n  %s\n' "$INSTALLER"
    /usr/bin/open -R "$INSTALLER" || /usr/bin/open "$ROOT/dist" || true
else
    status=$?
    printf '\n打包失败（退出码：%d）。请查看上方错误信息。\n' "$status" >&2
fi

if [[ -t 0 ]]; then
    printf '\n按回车键关闭窗口…'
    read -r _
fi

exit "$status"
