#!/usr/bin/env python3
"""One-screen summary of a keyboard report."""
import json, sys
j = json.load(open(sys.argv[1]))
if "run" not in j:
    print(json.dumps(j, ensure_ascii=False)); sys.exit()
r = j["run"]
if "functions" in r:
    print(r["label"], j["device"], "units", r["units"], "before", r["before_mb"], "end", r["end_mb"], "peak", r["peak_mb"], "available", r["available_mb"])
    for f in r["functions"]: print("  ", f)
    sys.exit()
if "idle_samples" in r:
    print(r["label"], j["device"], "marks", [(m["name"], m["mb"], m["available_mb"]) for m in j["marks"]])
    print(" idle", r["idle_samples"])
    sys.exit()
if "document" in r:  # mode=type
    print(f"{r['label']}  {j['device']} iOS {j['os']}  keys {r['keys']}  model {r.get('model_state')}  user_dict {r['user_dict_bytes']} bytes")
    print(f"  document {r['document']!r}")
    shown = r["candidates"]
    print(f"  preedit {r['preedit']!r}  {len(shown)} candidates of {r.get('pages', '?')} pages: {shown[:12]}{' …' if len(shown) > 12 else ''}")
    if r.get("completion"):
        print(f"  completion {r['completion']!r}{' (predicted)' if r.get('completion_predicted') else ''}")
    if "debug_context" in r:
        print(f"  context {r['debug_context']!r} reported={r['debug_context_reported']}")
    if "settings" in r:
        print(f"  mode {r.get('mode')}  settings {r['settings']}")
    if "release_ms" in r:
        m = r["release_ms"]
        print(f"  key-down compute {r.get('speculates')}  release->drawn n {m['count']} p50 {m['p50']:.1f} p95 {m['p95']:.1f} max {m['max']:.1f} ms  polls applied {r.get('polls_applied')} dropped {r.get('polls_dropped')}")
    sys.exit()
print(f"{r['label']}  {j['device']} iOS {j['os']} full_access={j['full_access']}")
print("  marks  " + "  ".join(f"{m['name']}={m['mb']}MB(avail {m['available_mb']})" for m in j["marks"]))
print(f"  keys {r['keys']} in {r['seconds']:.0f}s  first {r['first_rate']:.3f}  digest {r['digest']}  err={r['error']!r}")
if r.get("model_state", -2) != -2:
    print(f"  model state {r['model_state']} after {r['model_seconds']:.1f}s  open {r['open_seconds']:.2f}s  deferred {r['deferred']}")
print(f"  engine p50 {r['p50_ms']:.1f} p95 {r['p95_ms']:.1f} p99 {r['p99_ms']:.1f} worst {r['worst_ms']:.0f}   with UI p50 {r['ui_p50_ms']:.1f} p95 {r['ui_p95_ms']:.1f} p99 {r['ui_p99_ms']:.1f} worst {r['ui_worst_ms']:.0f}")
print(f"  end {r['end_mb']:.1f}MB  peak {r['peak_mb']:.1f}MB  available end {r['available_end_mb']:.1f} min {r['available_min_mb']:.1f}")
