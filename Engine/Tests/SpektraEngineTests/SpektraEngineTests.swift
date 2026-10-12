import Testing
@testable import SpektraEngine

@Test func gpuRoundTripIsBitExact() throws {
    let gpu = try GPU()
    // The photo's final output has negative values and a wide range: a good bit-pattern check.
    let image = try golden("photo-kodak_portra_400-kodak_portra_endura", "rgb_out")
    let (height, width) = (image.shape[0], image.shape[1])
    let texture = gpu.upload(rgb: image.values, width: width, height: height)
    #expect(gpu.download(texture) == image.values)

    for factor: Float in [1, 2] {
        let output = gpu.makeTexture(width: width, height: height)
        try gpu.run { encoder in
            gpu.encodeScale(on: encoder, input: texture, output: output, by: Double(factor))
        }
        #expect(gpu.download(output) == image.values.map { $0 * factor })
    }
}

@Test func deltaE2000MatchesColourScience() {
    // Sharma, Wu & Dalal (2005) test pairs; references from colour.delta_E(method="CIE 2000").
    let cases: [(SIMD3<Double>, SIMD3<Double>, Double)] = [
        (SIMD3(50, 2.6772, -79.7751), SIMD3(50, 0, -82.7485), 2.0424596801565738),
        (SIMD3(50, 0, 0), SIMD3(50, -1, 2), 2.3668588191717523),
        (SIMD3(50, 2.5, 0), SIMD3(73, 25, -18), 27.14923130074626),
        (SIMD3(60.2574, -34.0099, 36.2677), SIMD3(60.4626, -34.1751, 39.4387), 1.2644200135991919),
        (SIMD3(22.7233, 20.0904, -46.694), SIMD3(23.0331, 14.973, -42.5619), 2.0372582697089734),
        (SIMD3(90.9257, -0.5406, -0.9208), SIMD3(88.6381, -0.8985, -0.7239), 1.538117005439684),
    ]
    for (lab1, lab2, expected) in cases {
        #expect(abs(deltaE2000(lab1, lab2) - expected) < 1e-12)
    }
    let d50Lab = lab(fromXYZ: SIMD3(0.2, 0.3, 0.4), white: SIMD2(0.3457, 0.3585))
    #expect(Difference([d50Lab.x, d50Lab.y, d50Lab.z], [61.65422221, -38.74949368, -23.22696525]).maxAbsolute < 1e-8)
}
