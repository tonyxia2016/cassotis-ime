"""Compares two lmtest outputs (A = reference, B = candidate); with --correct,
two lmcorrect outputs."""
import json
import statistics
import sys


def load(path):
    head, rows, tail = {}, [], {}
    for line in open(path, encoding="utf-8"):
        d = json.loads(line)
        if "i" in d:
            rows.append(d)
        elif "open_ms" in d:
            head = d
        else:
            tail = d
    return head, rows, tail


def pct(values, q):
    values = sorted(values)
    if not values:
        return float("nan")
    k = min(len(values) - 1, max(0, int(round(q / 100 * (len(values) - 1)))))
    return values[k]


def argmax(xs):
    return max(range(len(xs)), key=lambda i: (xs[i], -i))


def compare_corrections(path_a, path_b):
    a = [json.loads(line) for line in open(path_a, encoding="utf-8")]
    b = [json.loads(line) for line in open(path_b, encoding="utf-8")]
    final = lambda r: r["text"] if r["result"] == 1 else r["draft"]
    same = sum(final(x) == final(y) for x, y in zip(a, b))
    print(f"cases {len(a)}  same output {same / len(a):.1%}  exact fix A "
          f"{sum(final(x) == x['true'] for x in a) / len(a):.1%}  B {sum(final(y) == y['true'] for y in b) / len(b):.1%}")
    for name, rows in (("A", a), ("B", b)):
        ms = [r["ms"] for r in rows[1:]]
        print(f"{name}: p50 {pct(ms, 50):.1f} p95 {pct(ms, 95):.1f} max {max(ms):.1f} ms; "
              f"errors {sum(r['result'] < 0 for r in rows)}")
    for x, y in zip(a, b):
        if final(x) != final(y):
            print(f"  draft {x['draft']}: A {final(x)} | B {final(y)} | true {x['true']}")


def main():
    if sys.argv[1] == "--correct":
        compare_corrections(sys.argv[2], sys.argv[3])
        return
    ha, a, _ = load(sys.argv[1])
    hb, b, _ = load(sys.argv[2])
    assert len(a) == len(b), (len(a), len(b))
    deltas, case_max = [], []
    agree = first_a = first_b = 0
    next_top1 = next_overlap = cont_same = errors = 0
    for x, y in zip(a, b):
        if x["scored"] < 0 or y["scored"] < 0:
            errors += 1
            continue
        d = [abs(p - q) for p, q in zip(x["logp"], y["logp"])]
        deltas += d
        case_max.append(max(d))
        ia, ib = argmax(x["logp"]), argmax(y["logp"])
        agree += ia == ib
        first_a += ia == 0
        first_b += ib == 0
        na = [c for c, _ in x["next"] if c]
        nb = [c for c, _ in y["next"] if c]
        next_top1 += bool(na and nb and na[0] == nb[0])
        next_overlap += len(set(na) & set(nb)) / max(1, len(na))
        cont_same += x["cont"] == y["cont"]
    n = len(a) - errors
    print(f"cases {len(a)}  errors {errors}")
    print(f"open ms: A {ha.get('open_ms')}  B {hb.get('open_ms')}")
    print(f"|dlogp| mean {statistics.mean(deltas):.4f}  p95 {pct(deltas, 95):.4f}  max {max(deltas):.4f}")
    print(f"argmax agreement {agree / n:.1%}   first-choice A {first_a / n:.1%}  B {first_b / n:.1%}")
    print(f"next top1 same {next_top1 / n:.1%}  top-k overlap {next_overlap / n:.1%}  continuation same {cont_same / n:.1%}")
    for key in ("score_ms", "cont_ms"):
        va = [r[key] for r in a[1:]]
        vb = [r[key] for r in b[1:]]
        print(f"{key}: A p50 {pct(va, 50):.1f} p95 {pct(va, 95):.1f} max {max(va):.1f} | "
              f"B p50 {pct(vb, 50):.1f} p95 {pct(vb, 95):.1f} max {max(vb):.1f}")


main()
