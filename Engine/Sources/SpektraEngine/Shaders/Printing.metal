#include <metal_stdlib>
using namespace metal;

// Σ over spectral bands of the light a dye layer stack transmits, 10^−(Σ cmy·dye_density + base),
// times a per-band weight (light × sensitivity, or light × CMF). `bands[b]` holds the three dye
// densities in .xyz and the base density in .w; bands with missing data are left out by the host.
inline float3 spectral_transmission(float3 density, constant float4 *bands, constant float4 *weights, uint count) {
    float3 sum = 0.0f;
    for (uint band = 0; band < count; band++) {
        sum += exp10(-(dot(density, bands[band].xyz) + bands[band].w)) * weights[band].xyz;
    }
    return sum;
}

// PrintingStage.expose: per spectral band, the negative transmits 10^−(dye densities + base) of
// the enlarger light, which the paper integrates through its sensitivity (paper_bands holds
// light × sensitivity). Then mid-grey normalisation (factors.x), preflash, print exposure
// (factors.y) and burn, as log10 — Python's log10 → 10^ round trip in between is the identity —
// or with `linear`, before the log (for the enlarger's diffusion filter).
//
// The burn isn't Spektrafilm's: `burn.x` stops more at the top edge, fading linearly to none
// `burn.y` of the height down (at pixel centres, so every size of the image burns alike). At 0
// stops it's left out, so the print is Spektrafilm's to the bit; the host only passes stops
// with a reach above 0.
kernel void print_exposure(texture2d<float, access::read> cmy [[texture(0)]],
                           texture2d<float, access::write> output [[texture(1)]],
                           constant float4 *film_bands [[buffer(0)]],
                           constant float4 *paper_bands [[buffer(1)]],
                           constant uint &band_count [[buffer(2)]],
                           constant float2 &factors [[buffer(3)]],
                           constant float3 &preflash [[buffer(4)]],
                           constant uint &linear [[buffer(5)]],
                           constant float2 &burn [[buffer(6)]],
                           uint2 gid [[thread_position_in_grid]]) {
    float3 raw = spectral_transmission(cmy.read(gid).rgb, film_bands, paper_bands, band_count);
    raw = fmax(raw * factors.x + preflash, 0.0f) + 1e-10f;
    float3 exposure = raw * factors.y;
    if (burn.x != 0.0f) {
        float ramp = saturate(1.0f - (float(gid.y) + 0.5f) / (burn.y * float(output.get_height())));
        exposure *= exp2(burn.x * ramp);
    }
    output.write(float4(linear ? exposure : log10(fmax(exposure, 0.0f) + 1e-10f), 1.0f), gid);
}
