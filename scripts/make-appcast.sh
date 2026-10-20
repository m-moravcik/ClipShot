#!/usr/bin/env bash
#
# Builds and signs the Sparkle appcast for a release. Ported from VibeRes's
# scripts/make-appcast.sh, with the release notes read from
# release-notes/<version>.md as Eject Guard does.
#
# Usage: scripts/make-appcast.sh <notarized-zip> [output]
#
# Pass the archive as GitHub serves it (scripts/release.sh downloads the asset
# first), so the length and the signature in the feed are those of the bytes
# users fetch.
#
# The feed lives at a stable path in the repo, `appcast.xml` on `main`, served by
# raw.githubusercontent.com, rather than as a release asset: a
# `releases/latest/download/appcast.xml` URL 404s for every client the moment
# one release is published without that asset.
#
# The archive and the feed are signed with the EdDSA key in the login keychain,
# the key VibeRes and Eject Guard share (DEVELOPMENT.md, Updates). That key is
# the one thing that cannot be recreated: lose it and no existing install can be
# updated again. The first signature asks for keychain access; allow it on the
# Mac. Back the key up with Sparkle's `generate_keys -x`.
#
# Environment:
#   SPARKLE_EDDSA_PRIVATE_KEY_PATH  file holding the base64 Ed25519 seed. Falls
#                                   back to the keychain when unset, which only
#                                   works interactively.
#   DERIVED_DATA                    where SwiftPM put Sparkle's tools (./build,
#                                   as scripts/release-signed.sh builds there).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

ZIP="${1:?usage: make-appcast.sh <notarized-zip> [output]}"
OUT="${2:-$REPO_ROOT/appcast.xml}"
DERIVED_DATA="${DERIVED_DATA:-$REPO_ROOT/build}"
REPO="m-moravcik/ClipShot"

die() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# shellcheck source=scripts/sparkle-tools.sh
. "$REPO_ROOT/scripts/sparkle-tools.sh"

[ -f "$ZIP" ] || die "no such archive: $ZIP"
# sign_update recognises a feed by its extension.
case "$OUT" in *.xml) : ;; *) die "the output must end in .xml: $OUT" ;; esac

# Sparkle ships its tools inside the SwiftPM artifact bundle; each must match its
# pinned hash (scripts/sparkle-tools.sh) before it sees the key. Build the app
# first (scripts/release-signed.sh) so the artifact is there.
SIGN_UPDATE="$(sparkle_tool sign_update "$DERIVED_DATA")"
GENERATE_KEYS="$(sparkle_tool generate_keys "$DERIVED_DATA")"

# Empty when the key comes from the keychain. Always expanded as
# ${SIGN_ARGS[@]+"${SIGN_ARGS[@]}"}: macOS's /bin/bash is 3.2, where "${SIGN_ARGS[@]}"
# on an empty array is an unbound-variable error under `set -u`.
SIGN_ARGS=()
if [ -n "${SPARKLE_EDDSA_PRIVATE_KEY_PATH:-}" ]; then
  [ -f "$SPARKLE_EDDSA_PRIVATE_KEY_PATH" ] || die "key file missing: $SPARKLE_EDDSA_PRIVATE_KEY_PATH"
  SIGN_ARGS=(--ed-key-file "$SPARKLE_EDDSA_PRIVATE_KEY_PATH")
fi

# Nothing is signed with a key installed copies would reject.
check_signing_key

VERSION="$(awk -F'"' '/MARKETING_VERSION:/ {print $2; exit}' project.yml)"
BUILD="$(awk -F'"' '/CURRENT_PROJECT_VERSION:/ {print $2; exit}' project.yml)"
MIN_OS="$(awk -F'"' '/MACOSX_DEPLOYMENT_TARGET:/ {print $2; exit}' project.yml)"
[ -n "$VERSION" ] && [ -n "$BUILD" ] && [ -n "$MIN_OS" ] || die "could not read version numbers from project.yml"

[ "$(basename "$ZIP")" = "ClipShot-$VERSION.zip" ] \
  || die "archive is $(basename "$ZIP"), expected ClipShot-$VERSION.zip for version $VERSION"

NOTES="release-notes/$VERSION.md"
[ -s "$NOTES" ] || die "no release notes at $NOTES"

# Sparkle compares sparkle:version, which is CFBundleVersion: the build number,
# not the marketing version. Getting this wrong makes every client see "no
# update" with nothing logged anywhere.
LENGTH="$(stat -f%z "$ZIP")"
SIGNATURE="$("$SIGN_UPDATE" ${SIGN_ARGS[@]+"${SIGN_ARGS[@]}"} -p "$ZIP")" || die "sign_update failed"
[ -n "$SIGNATURE" ] || die "sign_update produced no signature"

# The notes as HTML, so the update window shows bullets rather than raw
# markdown. Escaping comes first, so a note can never inject markup into the
# page Sparkle renders. Wrapped lines are joined first, or every wrapped line
# would become its own paragraph.
# shellcheck disable=SC2016  # Python source: the $ and backticks are its own.
HTML="$(python3 -I -c '
import html, re, sys

blocks, current = [], None
for line in open(sys.argv[1], encoding="utf-8").read().splitlines():
    stripped = line.strip()
    if not stripped:
        if current: blocks.append(current); current = None
        continue
    if stripped.startswith(("- ", "### ", "## ", "> ")):
        if current: blocks.append(current)
        current = stripped
    elif current is not None:
        current += " " + stripped
    else:
        current = stripped
if current: blocks.append(current)

def inline(text):
    text = html.escape(text)
    text = re.sub(r"\*\*(.+?)\*\*", r"<strong>\1</strong>", text)
    text = re.sub(r"`(.+?)`", r"<code>\1</code>", text)
    return text

out, in_list = [], False
for block in blocks:
    if block.startswith("### ") or block.startswith("## "):
        if in_list: out.append("</ul>"); in_list = False
        out.append("<h3>" + inline(block.lstrip("# ").strip()) + "</h3>")
    elif block.startswith("- "):
        if not in_list: out.append("<ul>"); in_list = True
        out.append("<li>" + inline(block[2:]) + "</li>")
    else:
        if in_list: out.append("</ul>"); in_list = False
        out.append("<p>" + inline(block.lstrip("> ")) + "</p>")
if in_list: out.append("</ul>")
print("\n".join(out))
' "$NOTES")"
case "$HTML" in *"]]>"*) die "release notes must not contain ]]>" ;; esac

URL="https://github.com/${REPO}/releases/download/v${VERSION}/ClipShot-${VERSION}.zip"
DATE="$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')"

cat > "$OUT" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>ClipShot</title>
    <link>https://raw.githubusercontent.com/${REPO}/main/appcast.xml</link>
    <description>Updates for ClipShot</description>
    <language>en</language>
    <item>
      <title>Version ${VERSION}</title>
      <pubDate>${DATE}</pubDate>
      <sparkle:version>${BUILD}</sparkle:version>
      <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>${MIN_OS}</sparkle:minimumSystemVersion>
      <description><![CDATA[
${HTML}
      ]]></description>
      <sparkle:fullReleaseNotesLink>https://github.com/${REPO}/releases</sparkle:fullReleaseNotesLink>
      <enclosure url="${URL}"
                 sparkle:edSignature="${SIGNATURE}"
                 length="${LENGTH}"
                 type="application/octet-stream" />
    </item>
  </channel>
</rss>
XML

# Sign the feed itself. SURequireSignedFeed is on in Info.plist, so clients
# refuse an unsigned feed. Without this, someone able to substitute the feed
# cannot ship a malicious build (the enclosure signature stops that) but could
# pin every client to an older, validly signed release.
"$SIGN_UPDATE" ${SIGN_ARGS[@]+"${SIGN_ARGS[@]}"} --disable-signing-warning "$OUT" >/dev/null \
  || die "failed to sign the appcast feed"

# Check both signatures as a client would, before anyone relies on them: the
# enclosure against the archive, and the feed's own embedded signature.
"$SIGN_UPDATE" ${SIGN_ARGS[@]+"${SIGN_ARGS[@]}"} --verify "$ZIP" "$SIGNATURE" \
  || die "the enclosure signature does not verify against $ZIP"
"$SIGN_UPDATE" ${SIGN_ARGS[@]+"${SIGN_ARGS[@]}"} --verify "$OUT" \
  || die "the feed signature in $OUT does not verify"

grep -q 'sparkle:edSignature' "$OUT" || die "appcast has no enclosure signature"
echo "appcast: $OUT"
echo "  version ${VERSION} (build ${BUILD}), ${LENGTH} bytes"
echo "  signature: ${SIGNATURE:0:16}..."
echo "  enclosure and feed signatures verified; SURequireSignedFeed makes clients demand both"
