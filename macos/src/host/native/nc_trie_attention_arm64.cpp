// Apple Silicon implementation of the Windows AVX2 attention kernel.
// Keep the same eight-lane reductions, explicit fused multiply-adds and
// Cephes exponential. A four-lane reduction or an unfused dot product moves
// int8 activation boundaries and changes model decisions across platforms.
#include <arm_neon.h>
#include <cfloat>
#include <cstddef>
#include <cstdint>

namespace {
constexpr size_t kTogether = 4;
struct Vec8 { float32x4_t low, high; };
inline Vec8 Zero() { return {vdupq_n_f32(0), vdupq_n_f32(0)}; }
inline Vec8 Broadcast(float x) { return {vdupq_n_f32(x), vdupq_n_f32(x)}; }
inline Vec8 BroadcastAt(const float* x) { return Broadcast(*x); }
inline Vec8 Load(const float* x) { return {vld1q_f32(x), vld1q_f32(x + 4)}; }
inline void Store(float* x, Vec8 v) { vst1q_f32(x, v.low); vst1q_f32(x + 4, v.high); }
inline Vec8 Add(Vec8 a, Vec8 b) { return {vaddq_f32(a.low,b.low), vaddq_f32(a.high,b.high)}; }
inline Vec8 Sub(Vec8 a, Vec8 b) { return {vsubq_f32(a.low,b.low), vsubq_f32(a.high,b.high)}; }
inline Vec8 Mul(Vec8 a, Vec8 b) { return {vmulq_f32(a.low,b.low), vmulq_f32(a.high,b.high)}; }
inline Vec8 Fma(Vec8 a, Vec8 b, Vec8 c) {
    return {vfmaq_f32(c.low,a.low,b.low), vfmaq_f32(c.high,a.high,b.high)};
}
inline Vec8 NegativeFma(Vec8 a, Vec8 b, Vec8 c) {
    return {vfmsq_f32(c.low,a.low,b.low), vfmsq_f32(c.high,a.high,b.high)};
}
inline Vec8 And(Vec8 a, Vec8 b) {
    return {vreinterpretq_f32_u32(vandq_u32(vreinterpretq_u32_f32(a.low),vreinterpretq_u32_f32(b.low))),
            vreinterpretq_f32_u32(vandq_u32(vreinterpretq_u32_f32(a.high),vreinterpretq_u32_f32(b.high)))};
}
inline Vec8 FirstLanes(size_t count) {
    const uint32_t indices[8]={0,1,2,3,4,5,6,7};
    const uint32x4_t n=vdupq_n_u32(static_cast<uint32_t>(count));
    return {vreinterpretq_f32_u32(vcltq_u32(vld1q_u32(indices),n)),
            vreinterpretq_f32_u32(vcltq_u32(vld1q_u32(indices+4),n))};
}
inline float HorizontalSum(Vec8 v) {
    const float32x4_t combined=vaddq_f32(v.low,v.high);
    const float32x2_t pairs=vadd_f32(vget_low_f32(combined),vget_high_f32(combined));
    return vget_lane_f32(pairs,0)+vget_lane_f32(pairs,1);
}
inline Vec8 ExpNonPositive(Vec8 x) {
    const float32x4_t minimum=vdupq_n_f32(-87.33654f);
    x={vmaxq_f32(x.low,minimum),vmaxq_f32(x.high,minimum)};
    Vec8 n=Mul(x,Broadcast(1.44269504088896341f));
    n={vrndnq_f32(n.low),vrndnq_f32(n.high)};
    Vec8 r=NegativeFma(n,Broadcast(0.693359375f),x);
    r=NegativeFma(n,Broadcast(-2.12194440e-4f),r);
    Vec8 p=Broadcast(1.9875691500e-4f);
    p=Fma(p,r,Broadcast(1.3981999507e-3f));
    p=Fma(p,r,Broadcast(8.3334519073e-3f));
    p=Fma(p,r,Broadcast(4.1665795894e-2f));
    p=Fma(p,r,Broadcast(1.6666665459e-1f));
    p=Fma(p,r,Broadcast(5.0000001201e-1f));
    const Vec8 y=Add(Fma(p,Mul(r,r),r),Broadcast(1.0f));
    const int32x4_t bias=vdupq_n_s32(127);
    const Vec8 power={
        vreinterpretq_f32_s32(vshlq_n_s32(vaddq_s32(vcvtq_s32_f32(n.low),bias),23)),
        vreinterpretq_f32_s32(vshlq_n_s32(vaddq_s32(vcvtq_s32_f32(n.high),bias),23))};
    return Mul(y,power);
}

struct Rows {
    uintptr_t past;
    uintptr_t fresh;  // moved back by the earlier tokens, so that both are indexed by j
    size_t past_count;
    size_t bytes;     // of one token's numbers

    Rows(const float* past_rows, size_t count, const float* new_rows, size_t dim)
        : past(reinterpret_cast<uintptr_t>(past_rows)),
          fresh(reinterpret_cast<uintptr_t>(new_rows) - count * dim * sizeof(float)),
          past_count(count), bytes(dim * sizeof(float)) {}

    const float* row(uint32_t j) const {
        return reinterpret_cast<const float*>((j < past_count ? past : fresh) + j * bytes);
    }
};


// weights[i] = scale * (q . key of list[i]); returns the largest.
inline float Scores(const float* q, const Rows& keys, const uint32_t* list, size_t count, size_t dim,
    float scale, float* weights) {
    float best = -FLT_MAX;
    for (size_t i = 0; i < count; ++i) {
        const float* key = keys.row(list[i]);
        Vec8 a0 = Zero(), a1 = Zero();
        size_t d = 0;
        for (; d + 16 <= dim; d += 16) {
            a0 = Fma(Load(q + d), Load(key + d), a0);
            a1 = Fma(Load(q + d + 8), Load(key + d + 8), a1);
        }
        if (d < dim) a0 = Fma(Load(q + d), Load(key + d), a0);
        const float score = HorizontalSum(Add(a0, a1)) * scale;
        weights[i] = score;
        if (score > best) best = score;
    }
    return best;
}

// The same for the usual head of sixty-four numbers: the query stays in
// registers and a score is eight multiply-adds in four short chains.
inline float Scores64(const float* q, const Rows& keys, const uint32_t* list, size_t count, float scale,
    float* weights) {
    const Vec8 q0 = Load(q), q1 = Load(q + 8);
    const Vec8 q2 = Load(q + 16), q3 = Load(q + 24);
    const Vec8 q4 = Load(q + 32), q5 = Load(q + 40);
    const Vec8 q6 = Load(q + 48), q7 = Load(q + 56);
    float best = -FLT_MAX;
    for (size_t i = 0; i < count; ++i) {
        const float* key = keys.row(list[i]);
        Vec8 a0 = Mul(q0, Load(key));
        Vec8 a1 = Mul(q1, Load(key + 8));
        Vec8 a2 = Mul(q2, Load(key + 16));
        Vec8 a3 = Mul(q3, Load(key + 24));
        a0 = Fma(q4, Load(key + 32), a0);
        a1 = Fma(q5, Load(key + 40), a1);
        a2 = Fma(q6, Load(key + 48), a2);
        a3 = Fma(q7, Load(key + 56), a3);
        const float score = HorizontalSum(Add(Add(a0, a1), Add(a2, a3))) * scale;
        weights[i] = score;
        if (score > best) best = score;
    }
    return best;
}

// Scores to shares: exp(score - best) over their sum; zero after the list
// (whatever the buffer held there).
inline void Normalize(float* weights, size_t count, float best) {
    const Vec8 shift = Broadcast(best);
    Vec8 sum = Zero();
    for (size_t i = 0; i < count; i += 8) {
        Vec8 e = ExpNonPositive(Sub(Load(weights + i), shift));
        if (i + 8 > count) e = And(e, FirstLanes(count - i));
        Store(weights + i, e);
        sum = Add(sum, e);
    }
    const Vec8 inverse = Broadcast(1.0f / HorizontalSum(sum));
    for (size_t i = 0; i < count; i += 8)
        Store(weights + i, Mul(Load(weights + i), inverse));
}

// result = sum of weights[i] * (value of list[i]). Sixty-four elements at a
// time keep both multiply-add units busy.
inline void Combine(const Rows& values, const uint32_t* list, size_t count, size_t dim, const float* weights,
    float* result) {
    size_t d = 0;
    for (; d + 64 <= dim; d += 64) {
        Vec8 a0 = Zero(), a1 = Zero();
        Vec8 a2 = Zero(), a3 = Zero();
        Vec8 a4 = Zero(), a5 = Zero();
        Vec8 a6 = Zero(), a7 = Zero();
        for (size_t i = 0; i < count; ++i) {
            const Vec8 w = BroadcastAt(weights + i);
            const float* value = values.row(list[i]) + d;
            a0 = Fma(w, Load(value), a0);
            a1 = Fma(w, Load(value + 8), a1);
            a2 = Fma(w, Load(value + 16), a2);
            a3 = Fma(w, Load(value + 24), a3);
            a4 = Fma(w, Load(value + 32), a4);
            a5 = Fma(w, Load(value + 40), a5);
            a6 = Fma(w, Load(value + 48), a6);
            a7 = Fma(w, Load(value + 56), a7);
        }
        Store(result + d, a0);
        Store(result + d + 8, a1);
        Store(result + d + 16, a2);
        Store(result + d + 24, a3);
        Store(result + d + 32, a4);
        Store(result + d + 40, a5);
        Store(result + d + 48, a6);
        Store(result + d + 56, a7);
    }
    for (; d < dim; d += 8) {
        Vec8 a0 = Zero();
        for (size_t i = 0; i < count; ++i)
            a0 = Fma(BroadcastAt(weights + i),
                Load(values.row(list[i]) + d), a0);
        Store(result + d, a0);
    }
}

}  // namespace

// The tokens `first` to `last` - 1 of one head. Token r has its query at
// query + r * query_stride and its result at out + r * out_stride, and sees
// the tokens seen[seen_start[r]] to seen[seen_start[r + 1] - 1]: a number
// below past_count is a token of an earlier run (a row of past_keys and
// past_values), the others are the run's own tokens (rows of new_keys and
// new_values); a row holds dim numbers, a multiple of eight. No list is longer
// than `longest`; weights has room for four times `longest` rounded up to
// eight.
//
// The tokens are taken four at a time: the normalizer of a token is one long
// chain of operations, and four of them run side by side. It also reads the
// scores eight at a time, which waits on scores stored one by one unless
// other work has passed since.
extern "C" void nc_trie_attention_head_vector(const float* query, size_t query_stride, const float* past_keys,
    const float* past_values, size_t past_count, const float* new_keys, const float* new_values,
    const uint32_t* seen, const size_t* seen_start, size_t first, size_t last, size_t dim, float scale,
    size_t longest, float* weights, float* out, size_t out_stride) {
    const Rows keys(past_keys, past_count, new_keys, dim), values(past_values, past_count, new_values, dim);
    const size_t room = (longest + 7) & ~static_cast<size_t>(7);
    for (size_t group = first; group < last; group += kTogether) {
        const size_t end = group + kTogether < last ? group + kTogether : last;
        float best[kTogether];
        for (size_t row = group; row < end; ++row) {
            const size_t count = seen_start[row + 1] - seen_start[row];
            if (count == 0) continue;
            const float* q = query + row * query_stride;
            float* scores = weights + (row - group) * room;
            best[row - group] = dim == 64 ? Scores64(q, keys, seen + seen_start[row], count, scale, scores)
                : Scores(q, keys, seen + seen_start[row], count, dim, scale, scores);
        }
        for (size_t row = group; row < end; ++row) {
            const size_t count = seen_start[row + 1] - seen_start[row];
            if (count > 0) Normalize(weights + (row - group) * room, count, best[row - group]);
        }
        for (size_t row = group; row < end; ++row) {
            const size_t count = seen_start[row + 1] - seen_start[row];
            float* result = out + row * out_stride;
            if (count > 0) {
                Combine(values, seen + seen_start[row], count, dim, weights + (row - group) * room, result);
            } else {
                for (size_t d = 0; d < dim; d += 8) Store(result + d, Zero());
            }
        }
    }
}
