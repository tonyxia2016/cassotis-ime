"""Correction cases like nc_lm_repair_host builds them: prefix SEP syllables DRAFT draft SEP,
then the draft; one or two characters of the true text replaced by homophones."""
import json, os, random, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from cases import SENTENCES
readings = json.load(open(sys.argv[1], encoding="utf-8"))
syllables = {s: i for i, s in enumerate(readings["syllables"])}
tok = readings["tokens"]
random.seed(11)
def cp(c): return chr(c)
for s in SENTENCES:
    for start in (0, 4):
        true = s[start:start + 10]
        if len(true) < 6: continue
        prefix = s[:start]
        sy = [readings["readings"].get(c, [None])[0] for c in true]
        if None in sy or any(x not in syllables for x in sy): continue
        draft = list(true)
        for k in random.sample(range(len(true)), 2 if len(true) > 7 else 1):
            pool = [c for c in readings["homophones"][sy[k]][:6] if c != true[k]]
            if pool: draft[k] = random.choice(pool)
        draft = "".join(draft)
        context = prefix + cp(tok["sep"]) + "".join(cp(tok["syllable_base"] + syllables[x]) for x in sy) \
            + cp(tok["draft"]) + draft + cp(tok["sep"])
        allowed = []
        for k, x in enumerate(sy):
            pts = [ord(c) for c in readings["homophones"][x]]
            if ord(draft[k]) not in pts: pts.append(ord(draft[k]))
            allowed.append(",".join(map(str, pts)))
        print("\t".join([context, draft, true, ";".join(allowed)]))
