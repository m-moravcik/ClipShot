#!/usr/bin/env python3
"""For every final-name file in a spikewatch log: time from its first appearance under the
final name to the first poll that sees kMDItemIsScreenCapture (or, for .mov, the type xattr),
plus mtime-birth. Usage: marker_latency.py <log>"""
import re, sys
pat = re.compile(r'^(\d+) POLL (NEW|CHANGED) (.*?) birth=(\d+) mtime=(\d+) ctime=\d+ size=\d+ isCap=(\d) capType=(\d) ')
first, marked, bm = {}, {}, {}
for line in open(sys.argv[1], errors='replace'):
    m = pat.match(line)
    if not m: continue
    ts, _, path, birth, mtime, isc, ct = m.groups()
    name = path.rsplit('/', 1)[1]
    if name.startswith('.') or '/clipshot-spike/' not in path and '/Desktop/' not in path: continue
    first.setdefault(path, int(ts)); bm[path] = (int(mtime) - int(birth)) / 1e6
    ok = isc == '1' or (path.endswith('.mov') and ct == '1')
    if ok and path not in marked: marked[path] = int(ts)
print(f"{'marker_after_final_name_ms':>27} {'mtime-birth_ms':>14}  file")
for p in sorted(first, key=first.get):
    lat = (marked[p] - first[p]) / 1e6 if p in marked else float('nan')
    print(f"{lat:27.1f} {bm[p]:14.1f}  {p.split('/clipshot-spike/')[-1]}")
