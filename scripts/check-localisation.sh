#!/usr/bin/env bash
#
# Localisation gate for ClipShot.
#   1. Every language in L10N_LANGS (default: en sk cs de es fr) must translate every key.
#   2. Every key with %lld must carry plural variations covering the CLDR
#      categories of each language (en/de/es/fr need one+other, es/fr also many,
#      sk/cs need one+few+many+other).
#   3. Every literal the compiler extracted (.stringsdata) must exist in the catalog.
#
# Usage: scripts/check-localisation.sh [derived-data-path]

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

DERIVED="${1:-$REPO_ROOT/build-localisation}"
CATALOG="ClipShot/Resources/Localizable.xcstrings"
export L10N_LANGS="${L10N_LANGS:-en sk cs de es fr}"

die() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

[ -f "$CATALOG" ] || die "no catalog at $CATALOG"
command -v xcodegen >/dev/null || die "xcodegen not found"
xcodegen generate >/dev/null

xcodebuild build \
  -project ClipShot.xcodeproj \
  -scheme ClipShot \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED" \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_REQUIRED=NO >/dev/null

python3 - "$DERIVED" "$CATALOG" <<'PY'
import glob, json, os, re, sys

derived, catalog = sys.argv[1], sys.argv[2]
langs = os.environ['L10N_LANGS'].split()
cldr = {
    'en': {'one', 'other'}, 'de': {'one', 'other'},
    'es': {'one', 'many', 'other'}, 'fr': {'one', 'many', 'other'},
    'sk': {'one', 'few', 'many', 'other'}, 'cs': {'one', 'few', 'many', 'other'},
}

strings = json.load(open(catalog))['strings']
errors = []

for key, entry in strings.items():
    if not key.strip() or entry.get('shouldTranslate') is False:
        continue
    locs = entry.get('localizations', {})
    for lang in langs:
        loc = locs.get(lang)
        if loc is None:
            errors.append(f"{key!r}: missing {lang}")
            continue
        if '%lld' in key:
            plural = None
            if 'variations' in loc:
                plural = loc['variations'].get('plural')
            else:
                # %lld may sit inside a substitution
                for sub in loc.get('substitutions', {}).values():
                    plural = sub.get('variations', {}).get('plural')
            need = cldr.get(lang, {'one', 'other'})
            have = set(plural or {})
            if not need <= have:
                errors.append(f"{key!r}: {lang} plural categories {sorted(need - have)} missing")

files = glob.glob(derived + '/**/*.stringsdata', recursive=True)
if not files:
    sys.exit("error: no .stringsdata produced - is SWIFT_EMIT_LOC_STRINGS still YES?")
emitted = set()
for path in files:
    for entries in json.load(open(path)).get('tables', {}).values():
        for e in entries:
            if e.get('key', '').strip():
                emitted.add(e['key'])
ignorable = re.compile(r'^(%lld|%@|·)$')
for k in sorted(emitted - set(strings)):
    if not ignorable.match(k):
        errors.append(f"{k!r}: emitted by the code but not in the catalog")

print(f"emitted {len(emitted)} keys, catalog has {len(strings)}, languages: {' '.join(langs)}")
if errors:
    print('\n'.join('  ' + e for e in errors))
    sys.exit(f"error: {len(errors)} localisation problem(s)")
print("localisation: OK")
PY
