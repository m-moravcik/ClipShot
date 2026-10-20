#!/usr/bin/env bash
#
# Localisation gate for ClipShot.
#   1. Every language in L10N_LANGS (default: en sk cs de es fr) must translate every key of
#      every catalog in ClipShot/Resources.
#   2. Every plural, top-level or in any substitution (`%#@name@`), must cover the CLDR
#      categories of its language: en/de one+other, es/fr one+many+other,
#      sk/cs one+few+many+other. Each substitution is checked on its own, so one complete
#      substitution cannot hide an incomplete one. A key needs plurals when it has %lld,
#      or when any of its localisations uses a substitution.
#   3. Every `%#@name@` a value uses must be defined in that localisation's substitutions.
#      Every value, plural variant and substitution variant must be non-empty and in state
#      "translated".
#   4. Every literal the compiler extracted (.stringsdata) must exist in Localizable.xcstrings.
#
# Usage:
#   scripts/check-localisation.sh [derived-data-path]   self-test, build, then the full gate
#   scripts/check-localisation.sh --catalog FILE...     checks 1-3 on FILE(s) only, no build
#   scripts/check-localisation.sh --self-test           proves the gate fails on broken fixtures

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

export L10N_LANGS="${L10N_LANGS:-en sk cs de es fr}"
FIXTURES="ClipShotTests/Fixtures/l10n"

die() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# check_catalogs [--stringsdata DIR] CATALOG...
check_catalogs() {
  python3 - "$@" <<'PY'
import glob, json, os, re, sys

args = sys.argv[1:]
derived = None
if args[:1] == ['--stringsdata']:
    derived, args = args[1], args[2:]
catalogs = args
langs = os.environ['L10N_LANGS'].split()
cldr = {
    'en': {'one', 'other'}, 'de': {'one', 'other'},
    'es': {'one', 'many', 'other'}, 'fr': {'one', 'many', 'other'},
    'sk': {'one', 'few', 'many', 'other'}, 'cs': {'one', 'few', 'many', 'other'},
}
token = re.compile(r'%#@([A-Za-z0-9_]+)@')
errors = []

def values(loc):
    """Every stringUnit value of a localisation, including inside variations."""
    out = []
    if 'stringUnit' in loc:
        out.append(loc['stringUnit'].get('value', ''))
    for variation in loc.get('variations', {}).values():
        for case in variation.values():
            out.extend(values(case))
    return out

def units(loc, where=''):
    """(where, stringUnit) for every unit: the value, variations and substitution variants."""
    out = []
    if 'stringUnit' in loc:
        out.append((where, loc['stringUnit']))
    for kind, variation in loc.get('variations', {}).items():
        for case, sub in variation.items():
            out.extend(units(sub, f"{where} {kind}.{case}"))
    for name, sub in loc.get('substitutions', {}).items():
        out.extend(units(sub, f"{where} substitution {name!r}"))
    return out

def plurals(loc):
    """(where, categories) for the top-level plural and for each substitution, separately."""
    found = []
    plural = loc.get('variations', {}).get('plural')
    if plural is not None:
        found.append(('', set(plural)))
    for name, sub in loc.get('substitutions', {}).items():
        found.append((f" substitution {name!r}", set(sub.get('variations', {}).get('plural') or {})))
    return found

for catalog in catalogs:
    strings = json.load(open(catalog))['strings']
    label = os.path.basename(catalog)
    for key, entry in strings.items():
        if not key.strip() or entry.get('shouldTranslate') is False:
            continue
        locs = entry.get('localizations', {})
        needs_plural = '%lld' in key or bool(token.search(key)) or any(
            'substitutions' in loc or any(token.search(v) for v in values(loc)) for loc in locs.values())
        for lang in langs:
            loc = locs.get(lang)
            if loc is None:
                errors.append(f"{label}: {key!r}: missing {lang}")
                continue
            for where, unit in units(loc):
                if not unit.get('value', '').strip():
                    errors.append(f"{label}: {key!r}: {lang}{where} has an empty value")
                if unit.get('state') != 'translated':
                    errors.append(f"{label}: {key!r}: {lang}{where} is in state {unit.get('state')!r}, not 'translated'")
            subs = loc.get('substitutions', {})
            for value in values(loc):
                for name in token.findall(value):
                    if name not in subs:
                        errors.append(f"{label}: {key!r}: {lang} uses %#@{name}@ without a substitution")
            if not needs_plural:
                continue
            need = cldr.get(lang, {'one', 'other'})
            found = plurals(loc)
            if not found:
                errors.append(f"{label}: {key!r}: {lang} has no plural variations")
            for where, have in found:
                if not need <= have:
                    errors.append(f"{label}: {key!r}: {lang}{where} plural categories {sorted(need - have)} missing")

if derived is not None:
    strings = json.load(open(catalogs[0]))['strings']
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
}

# What the gate must report for each broken fixture.
expected_failure() {
  case "$(basename "$1")" in
    sk-missing-few-*) echo "sk.*\['few'\] missing" ;;
    bad-missing-language*) echo "missing sk" ;;
    bad-undefined-substitution*) echo "without a substitution" ;;
    bad-empty-value*) echo "has an empty value" ;;
    bad-state-new*) echo "in state 'new'" ;;
    *) return 1 ;;
  esac
}

# The gate must fail on each broken fixture with the expected message, and pass the valid
# one. Fixtures carry only en and sk.
self_test() {
  local fixture out pattern
  for fixture in "$FIXTURES"/*.xcstrings; do
    [ "$(basename "$fixture")" = "valid.xcstrings" ] && continue
    pattern="$(expected_failure "$fixture")" || die "self-test: no expected failure for $fixture"
    if out="$(L10N_LANGS="en sk" check_catalogs "$fixture" 2>&1)"; then
      die "self-test: $fixture passed, but it is broken"
    fi
    grep -q "$pattern" <<<"$out" || die "self-test: $fixture failed for another reason:
$out"
  done
  out="$(L10N_LANGS="en sk" check_catalogs "$FIXTURES/valid.xcstrings" 2>&1)" \
    || die "self-test: the valid fixture failed:
$out"
  echo "localisation self-test: OK"
}

case "${1:-}" in
  --catalog)
    shift
    [ "$#" -gt 0 ] || die "--catalog needs at least one file"
    check_catalogs "$@"
    exit
    ;;
  --self-test)
    self_test
    exit
    ;;
esac

DERIVED="${1:-$REPO_ROOT/build-localisation}"
CATALOG="ClipShot/Resources/Localizable.xcstrings"

[ -f "$CATALOG" ] || die "no catalog at $CATALOG"
command -v xcodegen >/dev/null || die "xcodegen not found"

self_test

xcodegen generate >/dev/null
xcodebuild build \
  -project ClipShot.xcodeproj \
  -scheme ClipShot \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED" \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_REQUIRED=NO >/dev/null

others=()
for f in ClipShot/Resources/*.xcstrings; do
  [ "$f" = "$CATALOG" ] || others+=("$f")
done
check_catalogs --stringsdata "$DERIVED" "$CATALOG" ${others[@]+"${others[@]}"}
