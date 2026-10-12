#include <metal_stdlib>
using namespace metal;

// ScanningStage._density_to_rgb up to output gamut compression: the dye densities viewed under
// the scan illuminant, integrated against the CIE 1931 CMFs (cmf_bands: illuminant × CMF /
// Σ illuminant·ȳ) to XYZ — floored as Python's log10/10^ round trip does — then one matrix:
// CAT02 from the illuminant's white to the output space's, and XYZ → RGB.
kernel void scan_rgb(texture2d<float, access::read> cmy [[texture(0)]],
                     texture2d<float, access::write> output [[texture(1)]],
                     constant float4 *dye_bands [[buffer(0)]],
                     constant float4 *cmf_bands [[buffer(1)]],
                     constant uint &band_count [[buffer(2)]],
                     constant float3x3 &xyz_to_rgb [[buffer(3)]],
                     uint2 gid [[thread_position_in_grid]]) {
    float3 xyz = spectral_transmission(cmy.read(gid).rgb, dye_bands, cmf_bands, band_count);
    xyz = fmax(xyz, 0.0f) + 1e-10f;
    output.write(float4(xyz_to_rgb * xyz, 1.0f), gid);
}

// colour-science's cctf_encoding (linear → encoded), the inverse of decode_channel (Filming.metal),
// same `transfer` numbering; `gamma` is the encoding exponent.
inline float encode_channel(float v, uint transfer, float gamma) {
    switch (transfer) {
    case 1: return v <= 0.0031308f ? v * 12.92f : 1.055f * spow(v, 1.0f / 2.4f) - 0.055f;
    case 2: return pow(v, gamma);
    case 3: return v < 0.018f ? v * 4.5f : 1.099f * spow(v, 0.45f) - 0.099f;
    case 4: return v < pow(16.0f, 1.8f / (1.0f - 1.8f)) ? v * 16.0f : spow(v, 1.0f / 1.8f);
    default: return v;
    }
}

// colour's RGB_to_RGB from the output space to itself with encoding: `matrix` (RGB → XYZ → RGB,
// not quite the identity where colour stores a rounded XYZ → RGB matrix), then the transfer function.
kernel void encode_rgb(texture2d<float, access::read> input [[texture(0)]],
                       texture2d<float, access::write> output [[texture(1)]],
                       constant float3x3 &matrix [[buffer(0)]],
                       constant uint &transfer [[buffer(1)]],
                       constant float &gamma [[buffer(2)]],
                       uint2 gid [[thread_position_in_grid]]) {
    float3 v = matrix * input.read(gid).rgb;
    output.write(float4(encode_channel(v.r, transfer, gamma), encode_channel(v.g, transfer, gamma),
                        encode_channel(v.b, transfer, gamma), 1.0f), gid);
}
