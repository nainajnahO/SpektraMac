#include <metal_stdlib>
using namespace metal;

// MSL has neither log1p nor expm1: Kahan's accurate forms (Goldberg 1991, theorem 4).
inline float log1p_accurate(float x) {
    float u = 1.0f + x;
    return u == 1.0f ? x : log(u) * x / (u - 1.0f);
}
inline float expm1_accurate(float x) {
    float u = exp(x);
    if (u == 1.0f) return x;
    return u - 1.0f == -1.0f ? -1.0f : (u - 1.0f) * x / log(u);
}

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

    // exp(μ + σ z), as fast_lognormal (σ below 1e-6 is treated as 0).
    float lognormal(float mu, float sigma) { return sigma < 1e-6f ? exp(mu) : exp(mu + sigma * normal()); }

    // Poisson(λ), as fast_poisson: Knuth's product of uniforms below λ = 30, above it the normal
    // approximation rounded and floored at 0.
    uint poisson(float lambda) {
        if (!(lambda > 0.0f)) return 0;
        if (lambda >= 30.0f) return uint(fmax(rint(lambda + sqrt(lambda) * normal()), 0.0f));
        float limit = exp(-lambda), product = uniform();
        uint count = 0;
        while (product > limit) {
            product *= uniform();
            count++;
        }
        return count;
    }

    // Binomial(n, p), as fast_binomial: n Bernoulli trials below n = 25, the normal approximation
    // rounded into [0, n] when the variance exceeds 10. Its third branch, inverting the CDF by a
    // running sum, is replaced by Devroye's waiting-time method (geometric gaps between successes;
    // the same distribution): in float the sum can end short of the uniform and return n. Drawn
    // for min(p, 1 − p) and mirrored, so the small-variance branch stays short near p = 1.
    uint binomial(uint n, float p) {
        if (p <= 0.0f) return 0;
        if (p >= 1.0f) return n;
        bool mirrored = p > 0.5f;
        float q = mirrored ? 1.0f - p : p;
        uint count = 0;
        if (n < 25) {
            for (uint trial = 0; trial < n; trial++) count += uniform() < q ? 1 : 0;
        } else if (float(n) * q * (1.0f - q) > 10.0f) {
            float mean = float(n) * q;
            count = uint(clamp(rint(mean + sqrt(mean * (1.0f - q)) * normal()), 0.0f, float(n)));
        } else {
            float logFailure = log1p_accurate(-q), position = 0.0f;
            while (true) {
                position += floor(log(uniform()) / logFailure) + 1.0f;
                if (position > float(n)) break;
                count++;
            }
        }
        return mirrored ? n - count : count;
    }
};
