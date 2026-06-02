#!/usr/bin/env bash
#
# Build a release .dmg of Carafe and drop it into the repo root.
#
# This script is the canonical entry point both for local releases
# (run by hand on the maintainer's machine) and for the GitHub
# Actions release workflow (.github/workflows/release.yml). Keep it
# environment-agnostic — no machine-specific paths, no inferred
# secrets.
#
# Usage:
#
#     ./Tools/build-dmg.sh                # builds Carafe-0.1.7.dmg
#     CARAFE_VERSION=0.2.0 ./Tools/build-dmg.sh
#
# What it does, in order:
#   1. Ensures `create-dmg` is available (installs via Homebrew if
#      not, so a fresh CI runner doesn't need extra setup steps).
#   2. Regenerates the procedural DMG background.
#   3. Builds Carafe in Release configuration into an isolated
#      DerivedData under /tmp by default (does not interfere with the
#      developer's interactive Xcode session, and avoids File Provider
#      xattrs when the repo lives in Documents/iCloud).
#   4. Copies the built .app out of DerivedData into the staging dir.
#   5. Runs `create-dmg` with the canonical layout
#      (660×400 window, 128 px icons, volume "Carafe <version>").
#   6. Leaves Carafe-<version>.dmg in the repo root.
#
# CODE-SIGNING POLICY (v0.1.x)
# ----------------------------
# We sign ad-hoc only — `Sign to Run Locally` (the implicit Xcode
# default when no `DEVELOPMENT_TEAM` is set). The resulting .dmg
# works on the user's machine *with* the "right-click → Open"
# Gatekeeper bypass on first launch. Notarization needs a $99 Apple
# Developer ID account; when that lands, override at invocation
# time:
#
#     DEVELOPMENT_TEAM=ABCD123456 \
#     CODE_SIGN_IDENTITY="Developer ID Application: …" \
#     ./Tools/build-dmg.sh
#
# Both vars are forwarded into xcodebuild verbatim. No script edits
# needed to upgrade.
#
# FRAGILITY
# ---------
# * `create-dmg` drives Finder via AppleScript to position the .app
#   and Applications icons in the window. On a fresh machine you may
#   get an "Accessibility / Automation" permission prompt the FIRST
#   time it runs; allow it. CI runners don't show the prompt — they
#   run with permissions pre-granted.
# * The window size (660×400) MUST match the background image
#   dimensions in Tools/generate-dmg-background.swift (1320×800 = 2×
#   for retina). Changing one without the other will produce a
#   stretched or off-position background.

set -euo pipefail

# ---- Configuration ----

VERSION="${CARAFE_VERSION:-0.1.7}"
APP_NAME="Carafe"
DMG_NAME="${APP_NAME}-${VERSION}.dmg"
VOLUME_NAME="${APP_NAME} ${VERSION}"
WINDOW_WIDTH=660
WINDOW_HEIGHT=400
ICON_SIZE=128

# ---- Paths ----

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# Keep build products outside Documents/iCloud-style File Provider
# locations. Those can attach com.apple.fileprovider.fpfs / FinderInfo
# xattrs to Sparkle's nested apps, which makes installed copies fail
# deep codesign verification.
BUILD_DIR="${CARAFE_BUILD_DIR:-${TMPDIR:-/tmp}/carafe-release-build}"
DERIVED_DATA="${BUILD_DIR}/DerivedData"
STAGING_APP="${BUILD_DIR}/${APP_NAME}.app"
BACKGROUND="${BUILD_DIR}/dmg-background.png"
DMG_PATH="${REPO_ROOT}/${DMG_NAME}"

mkdir -p "${BUILD_DIR}"

# ---- 1. create-dmg ----

if ! command -v create-dmg &>/dev/null; then
    echo "→ Installing create-dmg via Homebrew (one-time)…"
    brew install create-dmg
fi
echo "✓ create-dmg: $(command -v create-dmg)"

# ---- 2. Background image ----

echo "→ Generating DMG background…"
( cd "${REPO_ROOT}" && CARAFE_VERSION="${VERSION}" CARAFE_BUILD_DIR="${BUILD_DIR}" swift Tools/generate-dmg-background.swift )
if [[ ! -f "${BACKGROUND}" ]]; then
    echo "✗ Background image was not produced at ${BACKGROUND}" >&2
    exit 1
fi

# ---- 3. Build .app in Release ----

if [[ ! -d "${REPO_ROOT}/Carafe.xcodeproj" ]]; then
    echo "✗ Carafe.xcodeproj missing. Run 'xcodegen generate' first." >&2
    exit 1
fi

# Defensive: clear xattrs on the source tree. Some generator outputs
# (notably AppIcon.icns from the Swift script) pick up
# `com.apple.provenance`. Strictly speaking we strip in-bundle later
# too, but doing it here avoids the situation where a stale xattr
# trips up other tools that don't have our workaround.
echo "→ Clearing source-tree xattrs (provenance, etc.)…"
xattr -cr "${REPO_ROOT}/Carafe" || true

# Build the app WITHOUT codesigning. macOS 14+ (and especially 15/26)
# unconditionally tags every file the toolchain writes with
# `com.apple.provenance`, and codesign then refuses to operate on
# them ("resource fork, Finder information, or similar detritus not
# allowed"). We work around it by deferring the codesign step:
#   1. xcodebuild builds + links + copies frameworks → leaves an
#      unsigned .app with all the provenance xattrs.
#   2. We `xattr -cr` the bundle to strip them.
#   3. We sign the bundle manually with codesign, innermost-out.
#
# This is a known gotcha and the conventional fix; Apple has been
# aware since the macOS 14 release notes.
echo "→ Building ${APP_NAME} (Release, unsigned)…"
xcodebuild \
    -project "${REPO_ROOT}/Carafe.xcodeproj" \
    -scheme "${APP_NAME}" \
    -configuration Release \
    -derivedDataPath "${DERIVED_DATA}" \
    -destination 'platform=macOS,arch=arm64' \
    CODE_SIGN_IDENTITY="" \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGNING_ALLOWED=NO \
    ALWAYS_EMBED_SWIFT_STANDARD_LIBRARIES=NO \
    build \
    | tail -20

RELEASE_APP="${DERIVED_DATA}/Build/Products/Release/${APP_NAME}.app"
if [[ ! -d "${RELEASE_APP}" ]]; then
    echo "✗ Build succeeded but ${RELEASE_APP} doesn't exist" >&2
    exit 1
fi

# ---- 4. Strip provenance xattrs and codesign manually ----

echo "→ Stripping xattrs from the unsigned bundle…"
xattr -cr "${RELEASE_APP}"

# Pick signing identity. If the caller set CODE_SIGN_IDENTITY (e.g.
# a Developer ID Application cert for a future notarized release),
# use it; otherwise sign ad-hoc with `-`.
SIGN_ID="${CODE_SIGN_IDENTITY:--}"
ENTITLEMENTS="${REPO_ROOT}/Carafe/App/Carafe.entitlements"

echo "→ Codesigning (identity: ${SIGN_ID}, innermost-out)…"

# Each call to codesign writes new CodeResources / xattr metadata,
# and the OS *re-tags* the new files with `com.apple.provenance` —
# which the NEXT codesign call then refuses on. So we have to strip
# xattrs between each level of nesting. The codesign signatures
# themselves live in CodeResources XML + embedded Mach-O headers,
# not in xattrs, so stripping is safe and doesn't invalidate.
sign_with_strip() {
    local target="$1"
    shift  # remaining args go to codesign
    # `xattr -cr` is a no-op when the target has none; cheap.
    xattr -cr "${target}"
    codesign --force --options runtime "$@" --sign "${SIGN_ID}" "${target}"
}

# Sign Sparkle's nested executables and XPC services first, then the
# framework itself. Order matters — codesign requires nested code to
# already have a valid signature before it will sign the container.
SPARKLE_VER="${RELEASE_APP}/Contents/Frameworks/Sparkle.framework/Versions/B"
if [[ -d "${SPARKLE_VER}" ]]; then
    for helper in "${SPARKLE_VER}/Autoupdate" "${SPARKLE_VER}/Updater.app"; do
        if [[ -e "${helper}" ]]; then
            sign_with_strip "${helper}"
        fi
    done
    for xpc in "${SPARKLE_VER}/XPCServices/"*.xpc; do
        if [[ -d "${xpc}" ]]; then
            sign_with_strip "${xpc}"
        fi
    done
    sign_with_strip "${RELEASE_APP}/Contents/Frameworks/Sparkle.framework"
fi

# Strip xattrs across the whole bundle one final time before signing
# the umbrella. Signing the framework above re-tagged its
# CodeResources with provenance, and the umbrella sign walks every
# nested file looking for that exact xattr.
xattr -cr "${RELEASE_APP}"

# Sign the umbrella app — with our entitlements (Wine/GPTK needs
# JIT, library-validation off, etc; see Carafe.entitlements).
codesign --force --options runtime \
    --entitlements "${ENTITLEMENTS}" \
    --sign "${SIGN_ID}" \
    "${RELEASE_APP}"

# Final strip after signing. Sparkle's nested updater can retain
# FinderInfo / FileProvider xattrs on recent macOS builds; those make
# a copied app fail deep codesign verification even though the top
# level app looks fine. Stripping xattrs does not invalidate the
# signature because the signature data lives in CodeResources and
# Mach-O headers, not in extended attributes.
xattr -cr "${RELEASE_APP}"

# Sanity check. Use deep+strict here because the normal verifier can
# miss nested Sparkle updater metadata that breaks installed copies.
echo "→ Verifying signature…"
codesign --verify --deep --strict --verbose=2 "${RELEASE_APP}" 2>&1 | sed 's/^/    /'

# ---- 5. Stage the .app ----

echo "→ Staging ${APP_NAME}.app at ${STAGING_APP}…"
rm -rf "${STAGING_APP}"
cp -R "${RELEASE_APP}" "${STAGING_APP}"

# Belt-and-braces: clear any xattrs the cp might re-introduce
# (Finder-driven copies sometimes do; cp -R doesn't, but cheap to
# be sure).
xattr -cr "${STAGING_APP}" || true

echo "→ Verifying staged app…"
codesign --verify --deep --strict --verbose=2 "${STAGING_APP}" 2>&1 | sed 's/^/    /'

# ---- 5. Build the .dmg ----

rm -f "${DMG_PATH}"

echo "→ Running create-dmg…"
# Icons:
#   * App at logical (165, 265)  ← bottom-half left
#   * Applications at (495, 265) ← bottom-half right
# Both y=265 sits cleanly below the brand block in the background
# image (logo + wordmark + version, which all live above y=200).
create-dmg \
    --volname "${VOLUME_NAME}" \
    --background "${BACKGROUND}" \
    --window-pos 200 120 \
    --window-size ${WINDOW_WIDTH} ${WINDOW_HEIGHT} \
    --icon-size ${ICON_SIZE} \
    --icon "${APP_NAME}.app" 165 265 \
    --app-drop-link 495 265 \
    --no-internet-enable \
    --hide-extension "${APP_NAME}.app" \
    "${DMG_PATH}" \
    "${STAGING_APP}"

echo ""
echo "════════════════════════════════════════════════════════"
echo "✓ ${DMG_PATH}"
echo "  Size: $(du -h "${DMG_PATH}" | cut -f1)"
echo "════════════════════════════════════════════════════════"
