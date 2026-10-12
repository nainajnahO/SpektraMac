#include <metal_stdlib>
using namespace metal;

// Per-pixel building blocks. Shader files are concatenated in name order, so helpers here are
// visible to every later file.

// Spektrafilm's fast_interp for one channel: linear interpolation on a K-point axis, clamped to
// the end values. The binary search is numba's np.searchsorted(side="right") step for step, so
// non-monotonic axes (a positive film's -density curve) pick the same segment as Python.
// `axis`, `values` and `inverse_dx` are K×3 / K×3 / (K−1)×3, channel-interleaved.
inline float interpolate_channel(float x, uint c, constant float *axis, constant float *values,
                                 constant float *inverse_dx, uint k) {
    if (x <= axis[c]) return values[c];
    if (x >= axis[(k - 1) * 3 + c]) return values[(k - 1) * 3 + c];
    uint low = 0, high = k;
    while (low < high) {
        uint mid = low + ((high - low) >> 1);
        if (axis[mid * 3 + c] <= x) low = mid + 1; else high = mid;
    }
    uint i = low - 1;
    float t = (x - axis[i * 3 + c]) * inverse_dx[i * 3 + c];
    return values[i * 3 + c] + t * (values[(i + 1) * 3 + c] - values[i * 3 + c]);
}

kernel void interpolate_curves(texture2d<float, access::read> input [[texture(0)]],
                               texture2d<float, access::write> output [[texture(1)]],
                               constant float *axis [[buffer(0)]],
                               constant float *values [[buffer(1)]],
                               constant float *inverse_dx [[buffer(2)]],
                               constant uint &k [[buffer(3)]],
                               uint2 gid [[thread_position_in_grid]]) {
    float3 x = input.read(gid).rgb;
    float3 y = float3(interpolate_channel(x.r, 0, axis, values, inverse_dx, k),
                      interpolate_channel(x.g, 1, axis, values, inverse_dx, k),
                      interpolate_channel(x.b, 2, axis, values, inverse_dx, k));
    output.write(float4(y, 1.0), gid);
}

// Multiplies RGB by per-channel constants (exposure: `image * 2 ** ev`, mixture weights).
kernel void scale_rgb(texture2d<float, access::read> input [[texture(0)]],
                      texture2d<float, access::write> output [[texture(1)]],
                      constant float3 &factor [[buffer(0)]],
                      uint2 gid [[thread_position_in_grid]]) {
    output.write(float4(input.read(gid).rgb * factor, 1.0), gid);
}

// log10(max(x, 0) + 1e-10): light to log exposure, as every Spektrafilm stage ends.
kernel void log_exposure(texture2d<float, access::read> input [[texture(0)]],
                         texture2d<float, access::write> output [[texture(1)]],
                         uint2 gid [[thread_position_in_grid]]) {
    output.write(float4(log10(fmax(input.read(gid).rgb, 0.0) + 1e-10), 1.0), gid);
}

// 10**x: log exposure back to light.
kernel void exp10_rgb(texture2d<float, access::read> input [[texture(0)]],
                      texture2d<float, access::write> output [[texture(1)]],
                      uint2 gid [[thread_position_in_grid]]) {
    output.write(float4(exp10(input.read(gid).rgb), 1.0), gid);
}

// rgb' = M · rgb (colour-space changes; M is the row-major matrix NumPy would use).
kernel void matrix_rgb(texture2d<float, access::read> input [[texture(0)]],
                       texture2d<float, access::write> output [[texture(1)]],
                       constant float3x3 &matrix [[buffer(0)]],
                       uint2 gid [[thread_position_in_grid]]) {
    output.write(float4(matrix * input.read(gid).rgb, 1.0), gid);
}
