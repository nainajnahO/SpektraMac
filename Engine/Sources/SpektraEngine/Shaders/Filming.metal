#include <metal_stdlib>
using namespace metal;

// colour-science's cctf_decoding (encoded → linear), float. `transfer`: 0 linear, 1 sRGB,
// 2 gamma, 3 BT.2020, 4 ROMM RGB — Tables.ColourSpace.decode is the f64 reference.
inline float spow(float x, float p) { return copysign(pow(fabs(x), p), x); }

inline float decode_channel(float v, uint transfer, float gamma) {
    switch (transfer) {
    case 1: return 0.0031308f * 12.92f >= v ? v / 12.92f : spow((v + 0.055f) / 1.055f, 2.4f);
    case 2: return pow(v, gamma);
    case 3: {
        const float alpha = 1.099f, beta = 0.018f;
        float threshold = alpha * spow(beta, 0.45f) - (alpha - 1.0f);
        return v < threshold ? v / 4.5f : spow((v + (alpha - 1.0f)) / alpha, 1.0f / 0.45f);
    }
    case 4: return v < 16.0f * pow(16.0f, 1.8f / (1.0f - 1.8f)) ? v / 16.0f : spow(v, 1.8f);
    default: return v;
    }
}

// Mitchell–Netravali weight, B = C = 1/3 (fast_interp_lut.mitchell_weight).
inline float mitchell(float t) {
    const float B = 1.0f / 3.0f, C = 1.0f / 3.0f;
    float x = fabs(t);
    if (x < 1.0f) return ((12 - 9 * B - 6 * C) * x * x * x + (-18 + 12 * B + 6 * C) * x * x + (6 - 2 * B)) / 6;
    if (x < 2.0f) return ((-B - 6 * C) * x * x * x + (6 * B + 30 * C) * x * x + (-12 * B - 48 * C) * x + (8 * B + 24 * C)) / 6;
    return 0.0f;
}

// _cubic_interp_lut_at_2d: 4×4 Mitchell taps around the clamped coordinate, reflected indices,
// normalised by the weight sum. LUT entry (i, j) is texel (j, i).
inline float3 cubic_lookup(texture2d<float, access::read> lut, float2 coordinate) {
    uint size = lut.get_width();
    float last = float(size - 1);
    int2 base;
    float2 fraction;
    for (int axis = 0; axis < 2; axis++) {
        float c = clamp(coordinate[axis], 0.0f, last);
        if (c >= last) { base[axis] = int(size) - 2; fraction[axis] = 1.0f; }
        else { base[axis] = int(floor(c)); fraction[axis] = c - floor(c); }
    }
    auto reflect = [&](int i) { return i < 0 ? -i : (i >= int(size) ? 2 * (int(size) - 1) - i : i); };
    float3 sum = 0.0f;
    float weight_sum = 0.0f;
    for (int i = 0; i < 4; i++) {
        float wx = mitchell(fraction.x + 1.0f - float(i));
        int xi = reflect(base.x - 1 + i);
        for (int j = 0; j < 4; j++) {
            float weight = wx * mitchell(fraction.y + 1.0f - float(j));
            weight_sum += weight;
            sum += weight * lut.read(uint2(reflect(base.y - 1 + j), xi)).rgb;
        }
    }
    return weight_sum != 0.0f ? sum / weight_sum : sum;
}

// rgb_to_raw_hanatos2025: input RGB → (decode) → XYZ adapted to the film's reference white
// (one matrix) → chromaticity → tc → film raw from the tc LUT, scaled back by X + Y + Z;
// then × `exposure` (2^exposure_compensation_ev).
kernel void hanatos2025_raw(texture2d<float, access::read> input [[texture(0)]],
                            texture2d<float, access::write> output [[texture(1)]],
                            texture2d<float, access::read> lut [[texture(2)]],
                            constant float3x3 &rgb_to_xyz [[buffer(0)]],
                            constant uint &transfer [[buffer(1)]],
                            constant float &gamma [[buffer(2)]],
                            constant float &exposure [[buffer(3)]],
                            uint2 gid [[thread_position_in_grid]]) {
    float3 rgb = input.read(gid).rgb;
    if (transfer != 0) {
        rgb = float3(decode_channel(rgb.r, transfer, gamma), decode_channel(rgb.g, transfer, gamma),
                     decode_channel(rgb.b, transfer, gamma));
    }
    float3 xyz = rgb_to_xyz * rgb;
    float b = xyz.x + xyz.y + xyz.z;
    float2 xy = xyz.xy / fmax(b, 1e-10f);
    // _tri2quad
    float2 tc = clamp(float2((1.0f - xy.x) * (1.0f - xy.x), xy.y / fmax(1.0f - xy.x, 1e-10f)), 0.0f, 1.0f);
    if (isnan(b)) b = 0.0f;  // np.nan_to_num
    float3 raw = cubic_lookup(lut, tc * float(lut.get_width() - 1)) * b;
    output.write(float4(raw * exposure, 1.0), gid);
}
