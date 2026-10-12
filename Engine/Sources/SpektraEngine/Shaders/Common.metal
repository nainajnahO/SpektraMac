#include <metal_stdlib>
using namespace metal;

// Random numbers for the stochastic kernels (glare, grain). Counter-based, so nothing is stored
// between dispatches and a render is reproducible: each pixel runs its own SplitMix64 sequence
// (Steele, Lea & Flood 2014), started at a hash of (seed, stream, pixel). Python draws from
// numba's unseeded generator instead, so only the statistics are comparable.
inline ulong splitmix64_mix(ulong z) {
    z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9ul;
    z = (z ^ (z >> 27)) * 0x94D049BB133111EBul;
    return z ^ (z >> 31);
}

struct Random {
    ulong state;

    Random(uint seed, uint stream, uint2 pixel)
        : state(splitmix64_mix((ulong(seed) << 32 | stream) ^ splitmix64_mix(ulong(pixel.y) << 32 | pixel.x))) {}

    ulong next() {
        state += 0x9E3779B97F4A7C15ul;
        return splitmix64_mix(state);
    }

    // Uniform in (0, 1): 24 random bits, offset by half a step so neither end is reached.
    float uniform() { return (float(next() >> 40) + 0.5f) / 16777216.0f; }

    // Standard normal (Box–Muller).
    float normal() { return sqrt(-2.0f * log(uniform())) * cospi(2.0f * uniform()); }
};
