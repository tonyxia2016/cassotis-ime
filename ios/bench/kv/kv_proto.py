#!/usr/bin/env python3
"""Prototype: the character LM with keys and values as inputs and outputs.

One function per (new tokens N, kept slots P), all shapes fixed:
  ids, positions  [1, N] int32
  mask            [1, 1, N, P + N] fp16, additive, as in char_lm_coreml.py
  past            [1, 22, P, 1024] fp16: layer l's keys in block 2l, values in 2l + 1
  -> logp_all     [1, N, vocab]
  -> present      [1, 22, N, 1024]
Run against the numpy reference with --check; compile and time with kv_bench.
"""
import argparse
import importlib.util
import pathlib
import shutil
import subprocess
import sys
import tempfile
import time

import numpy as np

repo = pathlib.Path(__file__).resolve().parents[3] / 'macos'
spec = importlib.util.spec_from_file_location('char_lm_coreml', repo / 'scripts/char_lm_coreml.py')
base = importlib.util.module_from_spec(spec)
spec.loader.exec_module(base)
LAYERS, HEADS, HEAD_DIM, EMBED, MASKED, NORM_PRESCALE = (
    base.LAYERS, base.HEADS, base.HEAD_DIM, base.EMBED, base.MASKED, base.NORM_PRESCALE)


def build_kv(weights, new, slots):
    import coremltools as ct
    from coremltools.converters.mil import Builder as mb
    from coremltools.converters.mil.mil import types
    fp16 = np.float16

    def linear(x, name):
        quantized = np.ascontiguousarray(weights[name + "_quantized"].T)
        scale = weights[name + "_scale"].astype(fp16).reshape(-1, 1)
        weight = mb.constexpr_blockwise_shift_scale(data=quantized, scale=scale, name=name + "_w")
        return mb.linear(x=x, weight=weight)

    def norm(x, name):
        scaled = mb.mul(x=x, y=fp16(1.0 / NORM_PRESCALE))
        return mb.layer_norm(x=scaled, axes=[-1], gamma=weights[name].astype(fp16),
                             epsilon=fp16(1e-5 / NORM_PRESCALE ** 2))

    def heads(x, count):
        x = mb.reshape(x=x, shape=[1, count, HEADS, HEAD_DIM])
        return mb.transpose(x=x, perm=[0, 2, 1, 3])

    specs = [mb.TensorSpec(shape=(1, new), dtype=types.int32),
             mb.TensorSpec(shape=(1, new), dtype=types.int32),
             mb.TensorSpec(shape=(1, 1, new, slots + new), dtype=types.fp16),
             mb.TensorSpec(shape=(1, 2 * LAYERS, slots, EMBED), dtype=types.fp16)]

    @mb.program(input_specs=specs, opset_version=ct.target.iOS18)
    def program(ids, positions, mask, past):
        tokens = mb.gather(x=weights["wte_half"].astype(fp16), indices=ids, axis=0)
        places = mb.gather(x=weights["wpe"].astype(fp16), indices=positions, axis=0)
        h = mb.add(x=tokens, y=places)
        kept = mb.split(x=past, num_splits=2 * LAYERS, axis=1)
        presents = []
        for layer in range(LAYERS):
            a = norm(h, f"ln1_{layer}")
            qkv = linear(a, f"qkv_{layer}")
            q, k, v = mb.split(x=qkv, num_splits=3, axis=-1)
            presents += [k, v]
            old_k = mb.reshape(x=kept[2 * layer], shape=[1, slots, EMBED])
            old_v = mb.reshape(x=kept[2 * layer + 1], shape=[1, slots, EMBED])
            all_k = heads(mb.concat(values=[old_k, k], axis=1), slots + new)
            all_v = heads(mb.concat(values=[old_v, v], axis=1), slots + new)
            scores = mb.matmul(x=heads(q, new), y=all_k, transpose_y=True)
            scores = mb.add(x=mb.mul(x=scores, y=fp16(1.0 / np.sqrt(HEAD_DIM))), y=mask)
            att = mb.matmul(x=mb.softmax(x=scores, axis=-1), y=all_v)
            att = mb.reshape(x=mb.transpose(x=att, perm=[0, 2, 1, 3]), shape=[1, new, EMBED])
            r1 = mb.add(x=h, y=linear(att, f"attn_proj_{layer}"))
            m = norm(r1, f"ln2_{layer}")
            g = mb.gelu(x=linear(m, f"fc_{layer}"), mode="TANH_APPROXIMATION")
            g = mb.mul(x=g, y=weights[f"mlp_out_inv_scale_{layer}"].astype(fp16))
            h = mb.add(x=r1, y=linear(g, f"fc_out_{layer}"))
        logits = linear(norm(h, "lnf"), "wte_t")
        top = mb.reduce_max(x=logits, axes=[-1], keep_dims=True)
        shifted = mb.sub(x=logits, y=top)
        total = mb.reduce_sum(x=mb.exp(x=shifted), axes=[-1], keep_dims=True)
        logp = mb.sub(x=shifted, y=mb.log(x=total), name="logp_all")
        stacked = mb.stack(values=presents, axis=1)
        return logp, mb.identity(x=stacked, name="present")

    return program


def convert(weights, vocab, plain, pairs, out, source):
    import coremltools as ct
    out = pathlib.Path(out)
    with tempfile.TemporaryDirectory(dir=out.parent) as folder:
        descriptor = ct.utils.MultiFunctionDescriptor()
        first = None
        for length in plain:
            model = ct.convert(base.build_program(weights, vocab, length, "fp16"), convert_to="mlprogram",
                               minimum_deployment_target=ct.target.iOS18, compute_precision=ct.precision.FLOAT16)
            path = pathlib.Path(folder) / f"len{length}.mlpackage"
            model.save(str(path))
            descriptor.add_function(str(path), src_function_name="main", target_function_name=f"len{length}")
            first = first or f"len{length}"
            print(f"[kv] len{length}", flush=True)
        for new, past in pairs:
            model = ct.convert(build_kv(weights, new, past), convert_to="mlprogram",
                               minimum_deployment_target=ct.target.iOS18, compute_precision=ct.precision.FLOAT16)
            path = pathlib.Path(folder) / f"kv{new}_{past}.mlpackage"
            model.save(str(path))
            descriptor.add_function(str(path), src_function_name="main", target_function_name=f"kv{new}_{past}")
            first = first or f"kv{new}_{past}"
            print(f"[kv] kv{new}_{past}", flush=True)
        descriptor.default_function_name = first
        if out.exists():
            shutil.rmtree(out)
        ct.utils.save_multifunction(descriptor, str(out))
    print(f"[kv] wrote {out}", flush=True)


def compile_model(package, folder):
    folder = pathlib.Path(folder)
    folder.mkdir(parents=True, exist_ok=True)
    target = folder / (pathlib.Path(package).stem + ".mlmodelc")
    if target.exists():
        shutil.rmtree(target)
    subprocess.check_call(["xcrun", "coremlcompiler", "compile", str(package), str(folder)])
    print(f"[kv] compiled {target}", flush=True)


def check(weights, vocab, package, new, past, units):
    """A chain and two branches: run the chain, keep its K/V, then run the branches
    against it, and compare with the numpy reference over the whole trie."""
    import coremltools as ct
    unit = {"ne": ct.ComputeUnit.CPU_AND_NE, "cpu": ct.ComputeUnit.CPU_ONLY}[units]
    rng = np.random.default_rng(7)
    chain, branch = min(new, 12), min(new // 2, 8)
    total = chain + 2 * branch
    ids = rng.integers(2, vocab, total).astype(np.int32)
    ids[0] = 0
    parent = list(range(-1, chain - 1)) + [chain - 1] + list(range(chain, chain + branch - 1)) + \
        [chain - 1] + list(range(chain + branch, chain + 2 * branch - 1))
    allowed = np.zeros((total, total), bool)
    positions = np.zeros(total, np.int32)
    for i in range(total):
        j = i
        while j >= 0:
            allowed[i, j] = True
            j = parent[j]
        positions[i] = allowed[i].sum() - 1
    want = base.reference(weights, ids, positions, allowed, "fp16")

    model = ct.models.MLModel(str(package), compute_units=unit, function_name=f"kv{new}_{past}")
    # First the chain, with nothing kept.
    def feed(run):
        n = len(run)
        i = np.zeros((1, new), np.int32)
        p = np.zeros((1, new), np.int32)
        m = np.full((1, 1, new, past + new), MASKED, np.float16)
        for r, node in enumerate(run):
            i[0, r] = ids[node]
            p[0, r] = positions[node]
            j = node
            while j >= 0:
                if j in slots:
                    m[0, 0, r, slots[j]] = 0
                else:
                    m[0, 0, r, past + run.index(j)] = 0
                j = parent[j]
        for r in range(n, new):
            m[0, 0, r, past + r] = 0
        return {"ids": i, "positions": p, "mask": m, "past": store}
    store = np.zeros((1, 2 * LAYERS, past, EMBED), np.float16)
    slots = {}
    got = np.zeros((total, vocab))
    for run in (list(range(chain)), list(range(chain, chain + branch)), list(range(chain + branch, total))):
        out = model.predict(feed(run))
        for r, node in enumerate(run):
            got[node] = out["logp_all"][0, r]
        # Keep them: the next run sees them as past.
        for r, node in enumerate(run):
            slot = len(slots)
            store[0, :, slot, :] = out["present"][0, :, r, :]
            slots[node] = slot
    targets = rng.integers(2, vocab, total)
    diff = np.abs(got[np.arange(total), targets] - want[np.arange(total), targets])
    agree = np.mean(got.argmax(-1) == want.argmax(-1))
    print(f"[check] kv{new}_{past} {units}: |dlogp| mean {diff.mean():.4f} max {diff.max():.4f}; "
          f"argmax agreement {agree:.3f}", flush=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--onnx", type=pathlib.Path, default=repo / "data/models/char_lm/char_lm.onnx")
    parser.add_argument("--out", type=pathlib.Path, required=True)
    parser.add_argument("--plain", type=int, nargs="*", default=[])
    parser.add_argument("--kv", nargs="*", default=[], help="N:P pairs")
    parser.add_argument("--compile", type=pathlib.Path)
    parser.add_argument("--check", nargs="*", default=None, help="N:P pairs to check against numpy")
    parser.add_argument("--units", default="ne")
    args = parser.parse_args()
    weights, vocab = base.load_weights(args.onnx)
    pairs = [tuple(int(x) for x in pair.split(":")) for pair in args.kv]
    if pairs or args.plain:
        started = time.time()
        convert(weights, vocab, args.plain, pairs, args.out, args.onnx)
        print(f"[kv] converted in {time.time() - started:.0f}s", flush=True)
        if args.compile:
            compile_model(args.out, args.compile)
    if args.check is not None:
        for pair in args.check:
            new, past = (int(x) for x in pair.split(":"))
            check(weights, vocab, args.out, new, past, args.units)


if __name__ == "__main__":
    main()
