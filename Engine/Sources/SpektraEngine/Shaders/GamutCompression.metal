#include <metal_stdlib>
using namespace metal;

// OutputCompressionConstants in GamutCompression.swift.
struct OutputCompression {
    float3x3 to_cone;          // output RGB → CAM16 cone responses (D_RGB · M16 · 100 · RGB→XYZ)
    float3x3 from_cone;        // cone responses → output RGB
    float4 lightness_knee;     // threshold, limit, power, 1 if on
    float4 chroma_knee;        // threshold, limit, power
    float f_l, n_bb, white_a, cz;
    float k;                   // 50000/13 · N_c · N_cb
    float k_n;                 // (1.64 − 0.29^n)^0.73
    float f_l_quarter;         // F_L^0.25
    float white_lightness;     // J' of the output white
    float hue_start, hue_step; // the C_max table's h' grid
};

// spow (Filming.metal) per channel.
inline float3 spow(float3 x, float p) { return copysign(pow(fabs(x), p), x); }

// MSL has neither log1p nor expm1: Kahan's accurate forms (Goldberg 1991, theorem 4).
static float log1p_accurate(float x) {
    float u = 1.0f + x;
    return u == 1.0f ? x : log(u) * x / (u - 1.0f);
}
static float expm1_accurate(float x) {
    float u = exp(x);
    if (u == 1.0f) return x;
    return u - 1.0f == -1.0f ? -1.0f : (u - 1.0f) * x / log(u);
}

// reinhard_knee: identity up to the threshold, then a smooth approach to the limit. The
// rational part rewritten for large x so x^power can't overflow in float.
static float reinhard_knee(float d, float3 knee) {
    if (!(d > knee.x)) return d;
    float scale = knee.y - knee.x;
    float x = (d - knee.x) / scale;
    float y = x <= 1.0f ? x / powr(1.0f + powr(x, knee.z), 1.0f / knee.z)
                        : 1.0f / powr(powr(x, -knee.z) + 1.0f, 1.0f / knee.z);
    return knee.x + scale * y;
}

// _c_max_lookup: bilinear in the 64 × 720 table, J' clamped to [1, 110], h' wrapping around.
static float max_chroma(constant float *table, float lightness, float2 hue, constant OutputCompression &p) {
    float l = (clamp(lightness, 1.0f, 110.0f) - 1.0f) / 109.0f * 63.0f;
    int l_low = clamp(int(floor(l)), 0, 62);
    float l_fraction = l - float(l_low);
    float h = (atan2(hue.y, hue.x) - p.hue_start) / p.hue_step;
    int h_low = int(floor(h)) % 720;
    h_low = h_low < 0 ? h_low + 720 : h_low;
    int h_high = (h_low + 1) % 720;
    float h_fraction = h - floor(h);
    return table[l_low * 720 + h_low] * (1.0f - l_fraction) * (1.0f - h_fraction)
         + table[l_low * 720 + h_high] * (1.0f - l_fraction) * h_fraction
         + table[(l_low + 1) * 720 + h_low] * l_fraction * (1.0f - h_fraction)
         + table[(l_low + 1) * 720 + h_high] * l_fraction * h_fraction;
}

// compress_rgb_cam16ucs_chroma: output RGB → CAM16-UCS (L_A 64, Y_b 20, Average surround) →
// lightness knee toward white, chroma knee against C_max(J', h') → back. The same maths as
// colour's XYZ_to_CAM16UCS / CAM16UCS_to_XYZ, arranged for float: the hue travels as a unit
// vector (no degrees, no polar round trip), e_t uses cos(2 + h) = cos 2 cos h − sin 2 sin h, and
// the opponent dimensions are solved in the division-free form a, b = P2 t (cos h, sin h) /
// (K e_t + t (11/23 cos h + 108/23 sin h)), which equals colour's branch on |sin h| ≥ |cos h|.
kernel void compress_cam16ucs(texture2d<float, access::read> input [[texture(0)]],
                              texture2d<float, access::write> output [[texture(1)]],
                              constant OutputCompression &p [[buffer(0)]],
                              constant float *table [[buffer(1)]],
                              uint2 gid [[thread_position_in_grid]]) {
    // Forward: post-adaptation cone responses, then lightness J and colourfulness M.
    float3 cone = p.to_cone * input.read(gid).rgb;
    float3 f = powr(p.f_l * abs(cone) / 100.0f, 0.42f);
    float3 rgb_a = 400.0f * sign(cone) * f / (27.13f + f) + 0.1f;
    float2 ab = float2(rgb_a.r - 12.0f * rgb_a.g / 11.0f + rgb_a.b / 11.0f,
                       (rgb_a.r + rgb_a.g - 2.0f * rgb_a.b) / 9.0f);
    float radius = length(ab);
    float2 hue = radius > 0.0f ? ab / radius : float2(1.0f, 0.0f);
    float e_t = 0.25f * (cos(2.0f) * hue.x - sin(2.0f) * hue.y + 3.8f);
    float achromatic = (2.0f * rgb_a.r + rgb_a.g + rgb_a.b / 20.0f - 0.305f) * p.n_bb;
    float j = 100.0f * spow(achromatic / p.white_a, p.cz);
    float t = p.k * e_t * radius / (rgb_a.r + rgb_a.g + 21.0f * rgb_a.b / 20.0f);
    t = isfinite(t) ? t : 0.0f;
    float m = spow(t, 0.9f) * spow(j / 100.0f, 0.5f) * p.k_n * p.f_l_quarter;

    // CAM16-UCS (c1 = 0.007, c2 = 0.0228). A negative M' is a chroma along the opposite hue. A
    // NaN one (M < −1/c2, outside CAM16's domain) comes back achromatic in Python, whose inverse
    // leaves a = b = 0 for the NaN hue that follows: chroma 0 does the same here.
    float lightness = 1.7f * j / (1.0f + 0.007f * j);
    float chroma = log1p_accurate(0.0228f * m) / 0.0228f;
    if (isnan(chroma)) {
        chroma = 0.0f;
    } else if (chroma < 0.0f) {
        chroma = -chroma;
        hue = -hue;
    }

    if (p.lightness_knee.w > 0.0f) {
        lightness = reinhard_knee(lightness / p.white_lightness, p.lightness_knee.xyz) * p.white_lightness;
    }
    float limit = fmax(max_chroma(table, lightness, hue, p), 1e-9f);
    chroma = reinhard_knee(chroma / limit, p.chroma_knee.xyz) * limit;

    // Inverse.
    j = -lightness / (0.007f * lightness - 1.7f);
    m = expm1_accurate(0.0228f * chroma) / 0.0228f;
    t = spow(m / p.f_l_quarter / (sqrt(fmax(j, 2.220446e-16f) / 100.0f) * p.k_n), 1.0f / 0.9f);
    achromatic = p.white_a * spow(j / 100.0f, 1.0f / p.cz);
    float p2 = achromatic / p.n_bb + 0.305f;
    e_t = 0.25f * (cos(2.0f) * hue.x - sin(2.0f) * hue.y + 3.8f);
    ab = p2 * t * hue / (p.k * e_t + t * (11.0f / 23.0f * hue.x + 108.0f / 23.0f * hue.y));
    rgb_a = (460.0f * p2 + float3(451.0f, -891.0f, -220.0f) * ab.x + float3(288.0f, -261.0f, -6300.0f) * ab.y)
          / 1403.0f;
    float3 offset = abs(rgb_a - 0.1f);
    cone = sign(rgb_a - 0.1f) * 100.0f / p.f_l * spow(27.13f * offset / (400.0f - offset), 1.0f / 0.42f);
    output.write(float4(p.from_cone * cone, 1.0f), gid);
}
