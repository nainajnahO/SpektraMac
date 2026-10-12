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
