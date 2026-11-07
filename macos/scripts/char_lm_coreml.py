#!/usr/bin/env python3
"""Convert the shared character LM (data/models/char_lm, ONNX) to Core ML.

The ONNX graph is an 11-layer character GPT with int8 weights (symmetric, one
scale per output channel) and int8 activations at fixed ranges, plus a custom
attention operator (cassotis:TrieAttention). Everything but the attention is a
standard operation, and the attention is plain masked softmax attention over the
tokens a mask names, so the model rebuilds exactly in MIL:

- the int8 weights are kept as they are (constexpr_blockwise_shift_scale with the
  ONNX scales), so no weight is quantized a second time;
- `--activations fake` keeps the fixed int8 activation ranges as quantize /
  dequantize pairs, `--activations fp16` drops them;
- the TrieAttention mask becomes an additive float mask over the tokens of the
  run. Earlier runs' keys and values are not inputs: the caller runs a token's
  whole chain (see nc_char_lm_coreml.mm), which Core ML can place on the Neural
  Engine because every shape is fixed.

One function per sequence length shares a single copy of the weights
(multifunction model, iOS 18 / macOS 15). The engine's runs stay within 256
tokens (the model's context is 256 positions; a long-sentence trie has at most
176 nodes), and the runtime splits a longer one into runs of whole chains, so
the default lengths stop at 256: a function's output buffer is length x 12017
float16 values, which the keyboard extension pays for every function it loads.

The model records the SHA-256 of the ONNX graph it was made from
(cassotis_source_sha256); the hosts compare it with runtime_manifest.json.

    char_lm_coreml.py --onnx char_lm.onnx --out char_lm.mlpackage --compile DIR
    char_lm_coreml.py --onnx char_lm.onnx --check char_lm.mlpackage   # compare with numpy

Needs numpy, onnx and coremltools (tested with 9.0); --compile needs Xcode.
"""
import argparse
import hashlib
import pathlib
import shutil
import subprocess
import sys
import tempfile

import numpy as np

LAYERS, HEADS, HEAD_DIM, EMBED = 11, 16, 64, 1024
MASKED = -30000.0  # additive mask; fp16 safe, exp() of it is exactly zero
NORM_PRESCALE = 16.0


def load_weights(path):
    import onnx
    from onnx import numpy_helper
    model = onnx.load(str(path))
    weights = {t.name: numpy_helper.to_array(t) for t in model.graph.initializer}
    vocab = weights["wte_half"].shape[0]
    for name, value in weights.items():
        if name.endswith("_zero_point") and value.dtype == np.int8 and np.any(value != 0):
            sys.exit(f"{name}: asymmetric int8 weights are not supported")
    return weights, vocab


# ---------------------------------------------------------------- reference

def fake_quant(x, weights, name):
    scale = float(weights[name + "_scale"])
    zero = float(weights[name + "_zero_point"])
    q = np.clip(np.rint(x / scale) + zero, 0, 255)
    return ((q - zero) * scale).astype(np.float32)


def dequant(weights, name):
    return weights[name + "_quantized"].astype(np.float32) * weights[name + "_scale"].astype(np.float32)


def layer_norm(x, gamma):
    mean = x.mean(-1, keepdims=True)
    var = ((x - mean) ** 2).mean(-1, keepdims=True)
    return (x - mean) / np.sqrt(var + 1e-5) * gamma


def gelu_tanh(x):
    return 0.5 * x * (1.0 + np.tanh(np.sqrt(2.0 / np.pi) * (x + 0.044715 * x ** 3)))


def reference(weights, ids, positions, allowed, activations="fake"):
    """The ONNX graph in numpy, float32. allowed[i, j]: token i sees token j."""
    fq = (lambda x, n: fake_quant(x, weights, n)) if activations == "fake" else (lambda x, n: x)
    h = weights["wte_half"][ids].astype(np.float32) + weights["wpe"][positions]
    n = len(ids)
    bias = np.where(allowed, 0.0, -np.inf).astype(np.float32)
    for layer in range(LAYERS):
        a = fq(layer_norm(h, weights[f"ln1_{layer}"]), f"a_in_{layer}")
        qkv = a @ dequant(weights, f"qkv_{layer}")
        q, k, v = (qkv[:, i * EMBED:(i + 1) * EMBED].reshape(n, HEADS, HEAD_DIM).transpose(1, 0, 2) for i in range(3))
        scores = q @ k.transpose(0, 2, 1) / np.sqrt(HEAD_DIM) + bias
        scores -= scores.max(-1, keepdims=True)
        p = np.exp(scores)
        p /= p.sum(-1, keepdims=True)
        att = (p @ v).transpose(1, 0, 2).reshape(n, EMBED)
        r1 = h + fq(att, f"a_{layer}") @ dequant(weights, f"attn_proj_{layer}")
        m = fq(layer_norm(r1, weights[f"ln2_{layer}"]), f"m_in_{layer}")
        g = gelu_tanh(m @ dequant(weights, f"fc_{layer}")) * weights[f"mlp_out_inv_scale_{layer}"]
        h = r1 + fq(g, f"gs_{layer}") @ dequant(weights, f"fc_out_{layer}")
    logits = fq(layer_norm(h, weights["lnf"]), "hf") @ dequant(weights, "wte_t")
    logits -= logits.max(-1, keepdims=True)
    return logits - np.log(np.exp(logits).sum(-1, keepdims=True))


# ---------------------------------------------------------------- Core ML

def build_program(weights, vocab, length, activations, layers=LAYERS, probe=None, attention="manual",
                  weight_format="int8"):
    import coremltools as ct
    from coremltools.converters.mil import Builder as mb
    from coremltools.converters.mil.mil import types

    fp16 = np.float16

    def linear(x, name):
        quantized = np.ascontiguousarray(weights[name + "_quantized"].T)          # [out, in] int8
        if weight_format == "fp16":                                                # debugging aid
            return mb.linear(x=x, weight=(quantized.astype(np.float32) *
                             weights[name + "_scale"].reshape(-1, 1)).astype(fp16))
        scale = weights[name + "_scale"].astype(fp16).reshape(-1, 1)               # [out, 1]
        weight = mb.constexpr_blockwise_shift_scale(data=quantized, scale=scale, name=name + "_w")
        return mb.linear(x=x, weight=weight)

    def attend(q, k, v, mask):
        # iOS 18's fused scaled_dot_product_attention returns wrong numbers on the
        # Neural Engine with an additive mask (macOS 27, M1 Pro); matmul and
        # softmax spelled out are right on every compute unit.
        if attention == "sdpa":
            return mb.scaled_dot_product_attention(query=q, key=k, value=v, attn_mask=mask)
        scores = mb.matmul(x=q, y=k, transpose_y=True)
        scores = mb.add(x=mb.mul(x=scores, y=fp16(1.0 / np.sqrt(HEAD_DIM))), y=mask)
        return mb.matmul(x=mb.softmax(x=scores, axis=-1), y=v)

    def fq(x, name):
        if activations != "fake":
            return x
        scale = fp16(weights[name + "_scale"])
        zero = np.uint8(weights[name + "_zero_point"])
        q = mb.quantize(input=x, scale=scale, zero_point=zero, output_dtype="uint8")
        return mb.dequantize(input=q, scale=scale, zero_point=zero)

    def norm(x, name):
        # The residual stream reaches about 700 in layers 3 to 8, so a sum of
        # squares passes 500,000 and overflows float16 on the Neural Engine.
        # Layer normalization ignores a common factor: normalize x / 16 with
        # epsilon / 256, the same thing in a range float16 holds.
        scaled = mb.mul(x=x, y=fp16(1.0 / NORM_PRESCALE))
        return mb.layer_norm(x=scaled, axes=[-1], gamma=weights[name].astype(fp16),
                             epsilon=fp16(1e-5 / NORM_PRESCALE ** 2))

    def heads(x):
        x = mb.reshape(x=x, shape=[1, length, HEADS, HEAD_DIM])
        return mb.transpose(x=x, perm=[0, 2, 1, 3])

    @mb.program(input_specs=[mb.TensorSpec(shape=(1, length), dtype=types.int32),
                             mb.TensorSpec(shape=(1, length), dtype=types.int32),
                             mb.TensorSpec(shape=(1, 1, length, length), dtype=types.fp16)],
                opset_version=ct.target.iOS18)
    def program(ids, positions, mask):
        tokens = mb.gather(x=weights["wte_half"].astype(fp16), indices=ids, axis=0)
        places = mb.gather(x=weights["wpe"].astype(fp16), indices=positions, axis=0)
        h = mb.add(x=tokens, y=places)
        if probe == "embed":
            return mb.identity(x=h, name="logp_all")
        for layer in range(layers):
            a = fq(norm(h, f"ln1_{layer}"), f"a_in_{layer}")
            if probe == "norm" and layer == layers - 1:
                return mb.identity(x=a, name="logp_all")
            qkv = linear(a, f"qkv_{layer}")
            q, k, v = mb.split(x=qkv, num_splits=3, axis=-1)
            if probe == "qkv" and layer == layers - 1:
                return mb.identity(x=qkv, name="logp_all")
            att = attend(heads(q), heads(k), heads(v), mask)
            att = mb.reshape(x=mb.transpose(x=att, perm=[0, 2, 1, 3]), shape=[1, length, EMBED])
            if probe == "attention" and layer == layers - 1:
                return mb.identity(x=att, name="logp_all")
            r1 = mb.add(x=h, y=linear(fq(att, f"a_{layer}"), f"attn_proj_{layer}"))
            m = fq(norm(r1, f"ln2_{layer}"), f"m_in_{layer}")
            g = mb.gelu(x=linear(m, f"fc_{layer}"), mode="TANH_APPROXIMATION")
            g = mb.mul(x=g, y=weights[f"mlp_out_inv_scale_{layer}"].astype(fp16))
            h = mb.add(x=r1, y=linear(fq(g, f"gs_{layer}"), f"fc_out_{layer}"))
        if probe == "hidden":
            return mb.identity(x=h, name="logp_all")
        logits = linear(fq(norm(h, "lnf"), "hf"), "wte_t")
        top = mb.reduce_max(x=logits, axes=[-1], keep_dims=True)
        shifted = mb.sub(x=logits, y=top)
        total = mb.reduce_sum(x=mb.exp(x=shifted), axes=[-1], keep_dims=True)
        return mb.sub(x=shifted, y=mb.log(x=total), name="logp_all")

    return program


def sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as stream:
        for block in iter(lambda: stream.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def convert(weights, vocab, lengths, activations, out, source):
    import coremltools as ct
    out = pathlib.Path(out)
    with tempfile.TemporaryDirectory() as folder:
        parts = []
        for length in lengths:
            model = ct.convert(build_program(weights, vocab, length, activations),
                               convert_to="mlprogram", minimum_deployment_target=ct.target.iOS18,
                               compute_precision=ct.precision.FLOAT16)
            path = pathlib.Path(folder) / f"len{length}.mlpackage"
            model.save(str(path))
            parts.append((path, length))
            print(f"[coreml] length {length} converted", flush=True)
        if out.exists():
            shutil.rmtree(out)
        if len(parts) == 1:
            shutil.copytree(parts[0][0], out)
        else:
            descriptor = ct.utils.MultiFunctionDescriptor()
            for path, length in parts:
                descriptor.add_function(str(path), src_function_name="main", target_function_name=f"len{length}")
            descriptor.default_function_name = f"len{parts[0][1]}"
            ct.utils.save_multifunction(descriptor, str(out))
    model = ct.models.MLModel(str(out), skip_model_load=True)
    model.user_defined_metadata["cassotis_source_sha256"] = sha256(source)
    model.user_defined_metadata["cassotis_lengths"] = " ".join(str(length) for length in lengths)
    staged = out.with_name(out.stem + ".staging.mlpackage")  # save() wants the extension
    if staged.exists():
        shutil.rmtree(staged)
    model.save(str(staged))
    shutil.rmtree(out)
    staged.rename(out)
    print(f"[coreml] wrote {out}")


def compile_model(package, folder):
    """xcrun coremlcompiler: package -> folder/char_lm.mlmodelc."""
    folder = pathlib.Path(folder)
    folder.mkdir(parents=True, exist_ok=True)
    target = folder / "char_lm.mlmodelc"
    if target.exists():
        shutil.rmtree(target)
    with tempfile.TemporaryDirectory(dir=folder) as staging:
        subprocess.check_call(["xcrun", "coremlcompiler", "compile", str(package), staging])
        compiled = pathlib.Path(staging) / (pathlib.Path(package).stem + ".mlmodelc")
        compiled.rename(target)
    print(f"[coreml] compiled {target}")


def check(weights, vocab, package, length, activations, units):
    """Score a small trie with Core ML and with the numpy reference."""
    import coremltools as ct
    rng = np.random.default_rng(7)
    n = min(length, 40)
    ids = np.zeros(length, np.int32)
    positions = np.zeros(length, np.int32)
    allowed = np.zeros((length, length), bool)
    # BOS, a 10-token context chain, then two branches of 15 tokens each.
    parent = [-1] + list(range(10)) + [10] + list(range(11, 25)) + [10] + list(range(26, 39))
    parent = parent[:n]
    ids[:n] = rng.integers(2, vocab, n)
    ids[0] = 0
    for i in range(n):
        j = i
        while j >= 0:
            allowed[i, j] = True
            j = parent[j]
        positions[i] = allowed[i, :i].sum()
    for i in range(n, length):          # padding: each sees itself
        allowed[i, i] = True
    mask = np.where(allowed, 0.0, MASKED).astype(np.float16)[None, None]
    unit = {"all": ct.ComputeUnit.ALL, "ne": ct.ComputeUnit.CPU_AND_NE, "cpu": ct.ComputeUnit.CPU_ONLY,
            "gpu": ct.ComputeUnit.CPU_AND_GPU}[units]
    import time
    started = time.perf_counter()
    try:
        model = ct.models.MLModel(str(package), compute_units=unit, function_name=f"len{length}")
    except ValueError:               # a single-function package
        model = ct.models.MLModel(str(package), compute_units=unit)
    loaded = time.perf_counter() - started
    feed = {"ids": ids[None], "positions": positions[None], "mask": mask}
    got = model.predict(feed)["logp_all"][0, :n]
    runs = []
    for _ in range(8):
        started = time.perf_counter()
        model.predict(feed)
        runs.append(time.perf_counter() - started)
    print(f"[check] len{length} {units}: load {loaded:.2f}s, predict median {np.median(runs) * 1000:.1f} ms")
    want = reference(weights, ids[:n], positions[:n], allowed[:n, :n], activations)
    targets = np.r_[ids[1:n], 0]        # log-probability each token gives the next one
    got_t = got[np.arange(n), targets].astype(np.float64)
    want_t = want[np.arange(n), targets].astype(np.float64)
    diff = np.abs(got_t - want_t)
    top1 = np.mean(got.argmax(-1) == want.argmax(-1))
    print(f"[check] len{length} {units}: |Δlogp| mean {diff.mean():.4f} max {diff.max():.4f}; "
          f"argmax agreement {top1:.3f}")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--onnx", required=True, type=pathlib.Path)
    parser.add_argument("--out", type=pathlib.Path)
    parser.add_argument("--check", type=pathlib.Path)
    parser.add_argument("--compile", type=pathlib.Path, metavar="DIR",
                        help="also compile --out to DIR/char_lm.mlmodelc")
    parser.add_argument("--lengths", type=int, nargs="+", default=[64, 128, 256])
    parser.add_argument("--activations", choices=["fake", "fp16"], default="fp16")
    parser.add_argument("--units", choices=["all", "ne", "cpu", "gpu"], default="all")
    args = parser.parse_args()
    weights, vocab = load_weights(args.onnx)
    if args.out:
        convert(weights, vocab, args.lengths, args.activations, args.out, args.onnx)
        if args.compile:
            compile_model(args.out, args.compile)
    if args.check:
        for length in args.lengths:
            check(weights, vocab, args.check, length, args.activations, args.units)


if __name__ == "__main__":
    main()
