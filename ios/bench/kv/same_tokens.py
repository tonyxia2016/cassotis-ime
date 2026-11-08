# The same trie in two function lengths: are the log-probabilities the same bits?
import numpy as np, coremltools as ct, sys
MASKED = -30000.0
vocab = 12017
rng = np.random.default_rng(3)
def feed(length, ids, parent):
    n = len(ids)
    i = np.zeros((1, length), np.int32); p = np.zeros((1, length), np.int32)
    m = np.full((1, 1, length, length), MASKED, np.float16)
    for t in range(n):
        i[0, t] = ids[t]
        depth = 0; j = t
        while j >= 0:
            m[0, 0, t, j] = 0; j = parent[j]; depth += 1
        p[0, t] = depth - 1
    for t in range(n, length):
        m[0, 0, t, t] = 0
    return {"ids": i, "positions": p, "mask": m}
n = 60
ids = rng.integers(2, vocab, n).astype(np.int32); ids[0] = 0
parent = [-1] + list(range(0, 19)) + [(19 if k % 4 == 0 else 20 + k - 1) for k in range(40)]
results = {}
for length in (64, 128, 256):
    model = ct.models.MLModel(sys.argv[1], compute_units=ct.ComputeUnit.CPU_AND_NE, function_name=f"len{length}")
    a = model.predict(feed(length, ids, parent))["logp_all"][0, :n].copy()
    b = model.predict(feed(length, ids, parent))["logp_all"][0, :n].copy()
    print(f"len{length}: repeat identical {np.array_equal(a, b)}", flush=True)
    results[length] = a
for x, y in ((64, 128), (64, 256), (128, 256)):
    d = np.abs(results[x].astype(np.float64) - results[y].astype(np.float64))
    print(f"len{x} vs len{y}: identical {np.array_equal(results[x], results[y])}; |d| mean {d.mean():.6f} max {d.max():.6f}; "
          f"differing values {(d > 0).mean() * 100:.2f}%; argmax agree {(results[x].argmax(-1) == results[y].argmax(-1)).mean():.4f}", flush=True)
