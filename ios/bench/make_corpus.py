#!/usr/bin/env python3
"""Build the replay corpus: Chinese clauses from the project's own documents and
their full pinyin, read from the dictionary itself so polyphones follow words.

    make_corpus.py <macos directory> <dict_sc.db> <out.tsv> [min_keys]

Output is deterministic. Each line: target<TAB>pinyin letters.
"""
import math, random, re, sqlite3, sys, pathlib

repo, db_path, out = pathlib.Path(sys.argv[1]), sys.argv[2], pathlib.Path(sys.argv[3])
min_keys = int(sys.argv[4]) if len(sys.argv) > 4 else 12000
DOCS = ["README.zh-Hans.md", "CONFIGURATION.md", "BENCHMARK.md", "BUILD.md", "QUICK_INPUT.md"]

db = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
words = {}
for pinyin, text, weight in db.execute("SELECT pinyin, text, weight FROM dict_base"):
    if len(text) <= 8 and (text not in words or weight > words[text][1]):
        words[text] = (pinyin, weight)

def to_pinyin(clause):
    n = len(clause)
    best = [(-math.inf, None)] * (n + 1)
    best[0] = (0.0, None)
    for end in range(1, n + 1):
        for start in range(max(0, end - 8), end):
            word = clause[start:end]
            entry = words.get(word)
            if entry is None or best[start][0] == -math.inf:
                continue
            # A longer word beats its parts unless the parts are far more common.
            score = best[start][0] + math.log1p(max(entry[1], 0)) + 4.0 * (len(word) - 1)
            if score > best[end][0]:
                best[end] = (score, start)
    if best[n][1] is None:
        return None
    parts, end = [], n
    while end > 0:
        start = best[end][1]
        parts.append(words[clause[start:end]][0])
        end = start
    return "".join(reversed(parts))

clauses, seen = [], set()
for name in DOCS:
    text = (repo / name).read_text(encoding="utf-8")
    text = re.sub(r"`[^`]*`", " ", text)           # no inline code
    for clause in re.split(r"[^一-鿿]+", text):
        if 4 <= len(clause) <= 24 and clause not in seen:
            seen.add(clause)
            clauses.append(clause)

random.Random(20261107).shuffle(clauses)
rows, keys = [], 0
for clause in clauses:
    pinyin = to_pinyin(clause)
    if not pinyin or not re.fullmatch(r"[a-z]+", pinyin):
        continue
    rows.append((clause, pinyin))
    keys += len(pinyin) + 1  # the space that commits
    if keys >= min_keys:
        break
out.write_text("".join(f"{t}\t{p}\n" for t, p in rows), encoding="utf-8")
first = rows[:300]
print(f"{len(clauses)} clauses available, wrote {len(rows)} ({keys} keys); "
      f"first 300 = {sum(len(p) + 1 for _, p in first)} keys")
