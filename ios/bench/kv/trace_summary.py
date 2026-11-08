"""Summarizes a record of every model run: where the time goes, the first run of a
burst against later ones, what other functions would give. One line per prediction:
rows union length ms kept kind thread start_ms, from a temporary fprintf around
predictionFromFeatures in CharLmPredict (nc_char_lm_coreml.mm); kind says which
algorithm ran it. See REPORT-MODEL.md, section 10."""
import collections
import statistics as st
import sys

rows = []
for line in open(sys.argv[1]):
    p = line.split()
    rows.append(dict(rows=int(p[0]), union=int(p[1]), length=int(p[2]), ms=float(p[3]), kept=int(p[4]),
                     kind=p[5], thread=p[6], start=float(p[7])))
total = sum(r['ms'] for r in rows)
span = rows[-1]['start'] - rows[0]['start']
print(f"runs {len(rows)}, model time {total/1000:.1f} s, of {span/1000:.0f} s of replay; {len(rows)/1519:.2f} runs a key, {total/1519:.1f} ms a key")

threads = collections.Counter(r['thread'] for r in rows)
names = {t: f"thread{i}" for i, (t, _) in enumerate(threads.most_common())}
print('by thread and kind (runs, seconds, median ms, median rows, median union):')
groups = collections.defaultdict(list)
for r in rows:
    groups[(names[r['thread']], r['kind'])].append(r)
for key in sorted(groups, key=lambda k: -sum(r['ms'] for r in groups[k])):
    g = groups[key]
    print(f"  {key[0]:8s} {key[1]:3s} runs {len(g):5d}  {sum(r['ms'] for r in g)/1000:6.2f} s ({100*sum(r['ms'] for r in g)/total:4.1f}%)  "
          f"median {st.median(r['ms'] for r in g):6.2f} ms  rows {st.median(r['rows'] for r in g):5.0f}  union {st.median(r['union'] for r in g):5.0f}")

# Bursts: runs with less than 50 ms between them belong to one key.
bursts = []
for r in rows:
    if bursts and r['start'] - (bursts[-1][-1]['start'] + bursts[-1][-1]['ms']) < 50:
        bursts[-1].append(r)
    else:
        bursts.append([r])
sizes = sorted(len(b) for b in bursts)
print(f"bursts {len(bursts)}: runs in a burst median {st.median(sizes)}, p90 {sizes[int(len(sizes)*.9)]}, max {sizes[-1]}")
times = sorted(b[-1]['start'] + b[-1]['ms'] - b[0]['start'] for b in bursts)
print(f"burst duration median {st.median(times):.1f} ms, p90 {times[int(len(times)*.9)]:.1f}, p95 {times[int(len(times)*.95)]:.1f}, max {times[-1]:.1f}")

print('first run of a burst against later runs, by function length (median ms):')
for length in (64, 128, 256):
    first = [b[0]['ms'] for b in bursts if b[0]['length'] == length]
    later = [r['ms'] for b in bursts for r in b[1:] if r['length'] == length]
    print(f"  len{length}: first {st.median(first) if first else 0:6.2f} ms (n={len(first)}), later {st.median(later) if later else 0:6.2f} ms (n={len(later)})")
extra = sum(b[0]['ms'] - {64: 4.9, 128: 6.0, 256: 15.1}[b[0]['length']] for b in bursts)
print(f"time above the hot run time in first runs: {extra/1000:.1f} s")
later_extra = sum(r['ms'] - {64: 4.9, 128: 6.0, 256: 15.1}[r['length']] for b in bursts for r in b[1:])
print(f"time above the hot run time in later runs: {later_extra/1000:.1f} s")

# What different functions would give, at the hot times measured with real shapes.
def bucket(n, table):
    for k in sorted(table):
        if n <= k:
            return table[k]
    return table[max(table)]
now = {64: 4.94, 128: 5.96, 256: 15.11}
short = {16: 4.03, 32: 4.38, 64: 4.94, 128: 5.96, 256: 15.11}
print(f"at hot times: now {sum(bucket(r['union'], now) for r in rows)/1000:.1f} s, with len16 and len32 {sum(bucket(r['union'], short) for r in rows)/1000:.1f} s")
kv = {16: 4.17, 32: 4.65}
best = sum(min(bucket(r['union'], short), kv[16] if r['rows'] <= 16 else kv[32] if r['rows'] <= 32 else 1e9) for r in rows)
print(f"  and K/V where it wins {best/1000:.1f} s")
dup = collections.Counter(r['union'] for r in rows)
print('union <= 16:', sum(1 for r in rows if r['union'] <= 16), ' <= 32:', sum(1 for r in rows if 16 < r['union'] <= 32),
      ' <= 64:', sum(1 for r in rows if 32 < r['union'] <= 64), ' <= 128:', sum(1 for r in rows if 64 < r['union'] <= 128),
      ' > 128:', sum(1 for r in rows if r['union'] > 128))
