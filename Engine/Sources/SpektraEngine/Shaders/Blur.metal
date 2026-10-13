#include <metal_stdlib>
using namespace metal;

// Spektrafilm's fast_gaussian_filter: a separable FIR with scipy's mode="reflect" edges for small
// sigmas, and Young & van Vliet's recursive (IIR) Gaussian for large ones.

// scipy.ndimage mode="reflect" (d c b a | a b c d | d c b a), as Spektrafilm's _reflect.
inline int reflect_index(int i, int n) {
    if (i >= 0 && i < n) return i;
    if (i >= -n && i < 0) return -i - 1;
    if (i >= n && i < 2 * n) return 2 * n - 1 - i;
    int period = 2 * n;
    i = i % period;
    if (i < 0) i += period;
    if (i >= n) i = period - 1 - i;
    return i;
}

// Taps run from -radius to radius; each holds the three channels' weights in .xyz (zero past a
// channel's own radius, so channels with different sigmas share one pass).
kernel void fir_vertical(texture2d<float, access::read> input [[texture(0)]],
                         texture2d<float, access::write> output [[texture(1)]],
                         constant float4 *taps [[buffer(0)]],
                         constant int &radius [[buffer(1)]],
                         uint2 gid [[thread_position_in_grid]]) {
    int n = input.get_height();
    float3 sum = 0.0;
    for (int k = -radius; k <= radius; k++) {
        sum += input.read(uint2(gid.x, reflect_index(int(gid.y) + k, n))).rgb * taps[k + radius].xyz;
    }
    output.write(float4(sum, 1.0), gid);
}

kernel void fir_horizontal(texture2d<float, access::read> input [[texture(0)]],
                           texture2d<float, access::write> output [[texture(1)]],
                           constant float4 *taps [[buffer(0)]],
                           constant int &radius [[buffer(1)]],
                           uint2 gid [[thread_position_in_grid]]) {
    int m = input.get_width();
    float3 sum = 0.0;
    for (int k = -radius; k <= radius; k++) {
        sum += input.read(uint2(reflect_index(int(gid.x) + k, m), gid.y)).rgb * taps[k + radius].xyz;
    }
    output.write(float4(sum, 1.0), gid);
}

// The recursion w = B·x + B1·w1 + B2·w2 + B3·w3 amplifies rounding errors in its state by up to
// 1/B (2.4e5 at sigma 100), so the state and coefficients are double-float pairs (hi + lo, about
// 44 bits) and only the stored samples are rounded to float. Error-free transforms after Dekker
// and Knuth; they rely on the library being compiled without fast math.
struct df3 {
    float3 hi;
    float3 lo;
};

inline df3 quick_two_sum(float3 a, float3 b) {
    float3 s = a + b;
    return {s, b - (s - a)};
}

inline df3 two_sum(float3 a, float3 b) {
    float3 s = a + b;
    float3 v = s - a;
    return {s, (a - (s - v)) + (b - v)};
}

inline df3 df_add(df3 a, df3 b) {
    df3 s = two_sum(a.hi, b.hi);
    return quick_two_sum(s.hi, s.lo + a.lo + b.lo);
}

inline df3 df_mul(df3 a, df3 b) {
    float3 p = a.hi * b.hi;
    float3 e = fma(a.hi, b.hi, -p) + (a.hi * b.lo + a.lo * b.hi);
    return quick_two_sum(p, e);
}

// One sweep along a row (Vertical = false) or column of `line`. The state starts at the first
// sample of the sweep: the input's for the forward sweep, the forward output's for the backward
// one (Spektrafilm's sample-replication edges). `c` holds hi, lo pairs of B, B1, B2, B3.
template <bool Vertical, bool Backward>
inline void yvv_sweep(texture2d<float, access::read> input, texture2d<float, access::write> output,
                      constant float4 *c, uint line) {
    int length = Vertical ? input.get_height() : input.get_width();
    df3 b = {c[0].xyz, c[1].xyz}, b1 = {c[2].xyz, c[3].xyz};
    df3 b2 = {c[4].xyz, c[5].xyz}, b3 = {c[6].xyz, c[7].xyz};
    auto at = [&](int i) { return Vertical ? uint2(line, i) : uint2(i, line); };
    float3 edge = input.read(at(Backward ? length - 1 : 0)).rgb;
    df3 w1 = {edge, 0.0}, w2 = w1, w3 = w1;
    for (int step = 0; step < length; step++) {
        int i = Backward ? length - 1 - step : step;
        df3 x = {input.read(at(i)).rgb, 0.0};
        df3 w = df_add(df_add(df_add(df_mul(b, x), df_mul(b1, w1)), df_mul(b2, w2)), df_mul(b3, w3));
        output.write(float4(w.hi + w.lo, 1.0), at(i));
        w3 = w2;
        w2 = w1;
        w1 = w;
    }
}

#define YVV_KERNEL(name, vertical, backward)                                                   \
    kernel void name(texture2d<float, access::read> input [[texture(0)]],                      \
                     texture2d<float, access::write> output [[texture(1)]],                    \
                     constant float4 *c [[buffer(0)]], uint line [[thread_position_in_grid]]) { \
        yvv_sweep<vertical, backward>(input, output, c, line);                                 \
    }
YVV_KERNEL(yvv_rows_forward, false, false)
YVV_KERNEL(yvv_rows_backward, false, true)
YVV_KERNEL(yvv_columns_forward, true, false)
YVV_KERNEL(yvv_columns_backward, true, true)

// output = weightA · a + weightB · b (blends and mixtures of blurs).
kernel void weighted_sum(texture2d<float, access::read> a [[texture(0)]],
                         texture2d<float, access::read> b [[texture(1)]],
                         texture2d<float, access::write> output [[texture(2)]],
                         constant float3 &weightA [[buffer(0)]],
                         constant float3 &weightB [[buffer(1)]],
                         uint2 gid [[thread_position_in_grid]]) {
    output.write(float4(weightA * a.read(gid).rgb + weightB * b.read(gid).rgb, 1.0), gid);
}
