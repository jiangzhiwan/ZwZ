# One-Click Packaging Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add two executable Finder entry scripts for building ZwZ app/DMG artifacts and the ZwZ installer package.

**Architecture:** Root-level `.command` files are thin wrappers over the existing packaging scripts. They resolve paths relative to themselves, preserve the underlying exit status, show user-readable completion output, and reveal successful artifacts in Finder.

**Tech Stack:** Bash, Swift Package Manager, macOS `open`, existing `scripts/package-app.sh` and `scripts/package-pkg.sh`

## Global Constraints

- `build-app.command` produces both `dist/ZwZ.app` and `dist/ZwZ.dmg` through the existing app packaging script.
- `build-installer.command` produces `dist/ZwZ-Installer.pkg` through the existing installer packaging script.
- No packaging implementation is duplicated.
- Both files must be executable and safe for project paths containing spaces.
- Interactive runs pause before Terminal closes; non-interactive runs do not pause.

---

### Task 1: Finder Packaging Entry Scripts

**Files:**
- Create: `build-app.command`
- Create: `build-installer.command`

**Interfaces:**
- Consumes: `scripts/package-app.sh`, `scripts/package-pkg.sh`, and the existing `dist` artifact layout.
- Produces: two executable double-click entry scripts with the wrapped command's exit status.

- [ ] **Step 1: Confirm entry scripts are absent**

Run: `test ! -e build-app.command && test ! -e build-installer.command`

Expected: exit status 0 before creation.

- [ ] **Step 2: Create both thin wrappers**

Each script must use `#!/bin/bash`, `set -euo pipefail`, derive `ROOT` using `dirname "$0"`, invoke its matching script inside an `if` statement, print success or failure, call `/usr/bin/open` only after successful packaging, pause only when `[[ -t 0 ]]`, and exit with the captured packaging status.

- [ ] **Step 3: Make both scripts executable**

Run: `chmod 755 build-app.command build-installer.command`

Expected: both files have executable permission for owner, group, and others.

- [ ] **Step 4: Verify syntax and static contract**

Run: `bash -n build-app.command build-installer.command`

Expected: exit status 0 with no output.

Run permission and content checks confirming both files are executable, point to the correct `scripts/package-*.sh`, mention their expected artifacts, use interactive terminal detection, and contain no trailing whitespace.

- [ ] **Step 5: Report packaging execution boundary**

Do not execute release packaging automatically. Report that double-clicking `build-app.command` creates the app and DMG, while double-clicking `build-installer.command` creates the installer package.
