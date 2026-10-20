#!/usr/bin/env python3
"""Condense a spikewatch log: keep KQ/FSE lines, NEW/GONE, and CHANGED lines whose
xattr set or birth/mtime changed; collapse size-only growth into one line per path.
Usage: summarize.py <log> [<from_ns> [<to_ns>]] [--grep SUBSTR]"""
import re, sys
args = [a for a in sys.argv[1:]]
needle = None
if '--grep' in args:
    i = args.index('--grep'); needle = args[i + 1]; del args[i:i + 2]
log = args[0]
lo = int(args[1]) if len(args) > 1 else 0
hi = int(args[2]) if len(args) > 2 else 1 << 63
pat = re.compile(r'^(\d+) POLL (NEW|CHANGED) (.*?) birth=(\d+) mtime=(\d+) ctime=(\d+) size=(\d+) isCap=(\d) capType=(\d) xattrs=(.*)$')
last = {}
t0 = None
growing = {}
def short(x): return x.replace('com.apple.metadata:', 'md:').replace('com.apple.', '')
def rel(t):
    return f"{(t - t0) / 1e6:9.1f}ms"
for raw in open(log, errors='replace'):
    raw = raw.rstrip('\n')
    if '.DS_Store' in raw: continue
    if needle and needle not in raw and ' KQ ' not in raw: continue
    ts = int(raw.split(' ', 1)[0]) if raw[:1].isdigit() else 0
    if ts < lo or ts > hi: continue
    if t0 is None: t0 = ts
    m = pat.match(raw)
    if not m:
        print(rel(ts), raw.split(' ', 1)[1]); continue
    _, st, path, birth, mtime, ctime, size, isc, ct, xa = m.groups()
    name = path.rsplit('/', 1)[1]
    key = (birth, mtime, xa)
    if st == 'CHANGED' and last.get(path) == key:
        growing[path] = (ts, size); continue
    if path in growing:
        gts, gsize = growing.pop(path); print(rel(gts), f"  ..size grew to {gsize} {name}")
    last[path] = key
    print(rel(ts), f"{st:7} {name} birth={rel(int(birth))} mtime={rel(int(mtime))} size={size} isCap={isc} capType={ct} xattrs={short(xa)}")
for path, (gts, gsize) in growing.items():
    print(rel(gts), f"  ..size grew to {gsize} {path.rsplit('/', 1)[1]}")
