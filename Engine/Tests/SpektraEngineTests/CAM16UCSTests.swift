import simd
import Testing
@testable import SpektraEngine

/// Forward and inverse against colour-science on the golden samples (stored as float32, so they
/// resolve ~6e-8 relative at best), plus an f64 round trip on the samples inside the RGB gamut:
/// CAM16 doesn't invert colours whose sharpened cone responses go negative, in colour-science either.
@Test(arguments: ["sRGB", "ProPhoto RGB"])
func cam16ucsMatchesColourScience(space: String) throws {
    let tables = try Tables.load()
    let model = CAM16UCS(white: tables.colourSpaces[space]!.whitepoint, cat16: tables.chromaticAdaptation["CAT16"]!)
    let suffix = space.split(separator: " ")[0]
    func triples(_ name: String) throws -> [SIMD3<Double>] {
        let values = try golden("primitives", "cam16ucs_\(name)_\(suffix)").values.map(Double.init)
        return stride(from: 0, to: values.count, by: 3).map { SIMD3(values[$0], values[$0 + 1], values[$0 + 2]) }
    }
    func flat(_ triples: [SIMD3<Double>]) -> [Double] { triples.flatMap { [$0.x, $0.y, $0.z] } }

    let xyz = try triples("xyz")
    let jab = xyz.map(model.jab(fromXYZ:))
    let reference = flat(try triples("jab"))
    // Negative-luminance samples give NaN (log1p of a colourfulness below −1/c2) in both.
    #expect(flat(jab).map(\.isNaN) == reference.map(\.isNaN))
    let forward = Difference(flat(jab), reference, floor: 1e-6)
    let inverse = Difference(flat(try triples("inverse_jab").map(model.xyz(fromJab:))), flat(try triples("inverse_xyz")),
                             floor: 1e-6)
    let toRGB = simd_double3x3(rows: tables.colourSpaces[space]!.xyzToRGB)
    let inGamut = xyz.filter { (toRGB * $0).min() >= 0 && (toRGB * $0).max() <= 1 }
    let roundTrip = Difference(flat(inGamut.map { model.xyz(fromJab: model.jab(fromXYZ: $0)) }), flat(inGamut), floor: 1e-6)
    print("CAM16-UCS around \(space) white: forward \(forward); inverse \(inverse); f64 round trip on \(inGamut.count) in gamut \(roundTrip)")
    #expect(forward.maxRelative < 1e-7)
    #expect(inverse.maxRelative < 1e-7)
    #expect(roundTrip.maxAbsolute < 1e-10)
}
