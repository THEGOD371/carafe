#!/usr/bin/env bash
#
# Generate a Sparkle 2 appcast.xml from a release's metadata.
#
# Usage:
#
#     ./Tools/generate-appcast.sh \
#         VERSION DMG_PATH ED_SIGNATURE \
#         > appcast.xml
#
# Where:
#     VERSION       = "0.1.0" (matches the git tag, without the v)
#     DMG_PATH      = local path to Carafe-VERSION.dmg
#     ED_SIGNATURE  = base64 ed25519 signature produced by Sparkle's
#                     `sign_update` tool. Pass empty string ("")
#                     during dry runs; Sparkle will refuse to install
#                     anything with an empty signature, which is the
#                     right behaviour for unsigned artifacts.
#
# Output: an appcast.xml document on stdout. Redirect to a file as
# needed.
#
# The download URL is the canonical GitHub-Releases-by-tag form:
#
#     https://github.com/<REPO>/releases/download/v<VERSION>/Carafe-<VERSION>.dmg
#
# `REPO` defaults to the placeholder `carafe-app/carafe` — override
# via env when calling. This will be set explicitly in the CI
# workflow before the first real release.
#
# DESIGN NOTES
# ------------
# For v0.1.x this script emits a feed containing ONLY the release
# being built right now. That works because Sparkle ranks items by
# `sparkle:version` and shows the highest one ≥ the user's current
# version. As soon as we ship v0.2.0 we'll need to either:
#   (a) Maintain appcast.xml in the repo with every release appended,
#       or
#   (b) Rebuild it from the GitHub Releases API at release time
#       (`gh api repos/$REPO/releases`).
# Option (b) is cleaner — no commit churn — but means the script grows
# a GitHub API call. We'll cross that bridge at v0.2.0.

set -euo pipefail

if [[ $# -lt 3 ]]; then
    echo "Usage: $0 VERSION DMG_PATH ED_SIGNATURE" >&2
    exit 64
fi

VERSION="$1"
DMG_PATH="$2"
ED_SIGNATURE="$3"
REPO="${CARAFE_REPO:-carafe-app/carafe}"
MINIMUM_MACOS="${CARAFE_MIN_MACOS:-14.0}"

if [[ ! -f "${DMG_PATH}" ]]; then
    echo "✗ DMG not found at ${DMG_PATH}" >&2
    exit 1
fi

DMG_SIZE=$(stat -f %z "${DMG_PATH}")
DMG_BASENAME=$(basename "${DMG_PATH}")
# RFC 822 date in UTC (Sparkle's parser is strict about this).
PUB_DATE=$(LC_ALL=C TZ=UTC date "+%a, %d %b %Y %H:%M:%S +0000")

# The `sparkle:edSignature` attribute is only added if a signature
# was supplied — Sparkle treats both "missing" and "empty" as
# "unsigned, refuse install", but missing is the spec-correct form.
SIG_ATTR=""
if [[ -n "${ED_SIGNATURE}" ]]; then
    SIG_ATTR=$'\n        sparkle:edSignature="'"${ED_SIGNATURE}"$'"'
fi

cat <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0"
     xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"
     xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>Carafe</title>
    <link>https://github.com/${REPO}</link>
    <description>Carafe — Windows games on Apple Silicon. Update feed.</description>
    <language>en</language>
    <item>
      <title>Version ${VERSION}</title>
      <pubDate>${PUB_DATE}</pubDate>
      <sparkle:version>${VERSION}</sparkle:version>
      <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>${MINIMUM_MACOS}</sparkle:minimumSystemVersion>
      <description><![CDATA[
        <p>See the <a href="https://github.com/${REPO}/releases/tag/v${VERSION}">v${VERSION} release notes</a> on GitHub.</p>
      ]]></description>
      <enclosure
        url="https://github.com/${REPO}/releases/download/v${VERSION}/${DMG_BASENAME}"
        length="${DMG_SIZE}"
        type="application/octet-stream"${SIG_ATTR}/>
    </item>
  </channel>
</rss>
EOF
