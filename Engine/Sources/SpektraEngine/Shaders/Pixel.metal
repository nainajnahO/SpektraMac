#include <metal_stdlib>
using namespace metal;

// Multiplies RGB by a constant (exposure: `image * 2 ** ev`).
kernel void scale_rgb(texture2d<float, access::read> input [[texture(0)]],
                      texture2d<float, access::write> output [[texture(1)]],
                      constant float &factor [[buffer(0)]],
                      uint2 gid [[thread_position_in_grid]]) {
    float4 pixel = input.read(gid);
    output.write(float4(pixel.rgb * factor, 1.0), gid);
}
