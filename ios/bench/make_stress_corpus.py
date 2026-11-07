#!/usr/bin/env python3
"""A long corpus of distinct queries, to push caches harder than real typing does.
Phrases are word salads sampled from the dictionary by weight. They mean nothing,
which is the point: a person repeats themselves, this does not.

    make_stress_corpus.py <dict_sc.db> <out.tsv> [keys] [seed]
"""
import bisect, itertools, random, re, sqlite3, sys, pathlib

db_path, out = sys.argv[1], pathlib.Path(sys.argv[2])
goal = int(sys.argv[3]) if len(sys.argv) > 3 else 120000
rng = random.Random(int(sys.argv[4]) if len(sys.argv) > 4 else 7)
db = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
rows = db.execute("SELECT pinyin, text, weight FROM dict_base WHERE weight >= 300 AND length(text) BETWEEN 1 AND 4").fetchall()
rows = [(p, t, w) for p, t, w in rows if re.fullmatch(r"[a-z]+", p) and re.fullmatch(r"[一-鿿]+", t)]
cumulative = list(itertools.accumulate(w for _, _, w in rows))
def draw():
    return rows[bisect.bisect_left(cumulative, rng.uniform(0, cumulative[-1]))]
keys, lines = 0, []
while keys < goal:
    words = [draw() for _ in range(rng.randint(2, 7))]
    pinyin = "".join(w[0] for w in words)
    text = "".join(w[1] for w in words)
    lines.append(f"{text}\t{pinyin}\n")
    keys += len(pinyin) + 1
out.write_text("".join(lines), encoding="utf-8")
print(len(rows), "words,", len(lines), "phrases,", keys, "keys")
