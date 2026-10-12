import Foundation

/// A NumPy `.npy` array, converted to `Float`.
///
/// Custom because neither Foundation nor Accelerate reads `.npy`; the format is a short text
/// header followed by raw little-endian values. Handles what Spektrafilm and `tools/golden.py`
/// write: C-ordered float16/32/64.
public struct NPYArray: Sendable {
    public let shape: [Int]
    public let values: [Float]

    public enum ReadError: Error {
        case notNPY(URL)
        case unsupported(URL, header: String)
    }

    public init(contentsOf url: URL) throws {
        let data = try Data(contentsOf: url)
        guard data.count > 10, data.prefix(6) == Data([0x93] + Array("NUMPY".utf8)) else {
            throw ReadError.notNPY(url)
        }
        // Version 1 stores the header length in 2 bytes, versions 2 and 3 in 4.
        let major = data[data.startIndex + 6]
        let lengthBytes = major == 1 ? 2 : 4
        let headerLength = data[(data.startIndex + 8)..<(data.startIndex + 8 + lengthBytes)]
            .reversed().reduce(0) { $0 << 8 | Int($1) }
        let headerStart = data.startIndex + 8 + lengthBytes
        let header = String(decoding: data[headerStart..<(headerStart + headerLength)], as: UTF8.self)

        guard let descr = header.firstMatch(of: /'descr':\s*'([^']*)'/)?.1,
              header.contains("'fortran_order': False"),
              let shapeText = header.firstMatch(of: /'shape':\s*\(([^)]*)\)/)?.1
        else { throw ReadError.unsupported(url, header: header) }

        shape = shapeText.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        let count = shape.reduce(1, *)
        let body = data[(headerStart + headerLength)...]

        switch descr {
        case "<f2": values = Self.read(Float16.self, count, from: body).map(Float.init)
        case "<f4": values = Self.read(Float.self, count, from: body)
        case "<f8": values = Self.read(Double.self, count, from: body).map(Float.init)
        default: throw ReadError.unsupported(url, header: header)
        }
    }

    // Copies instead of rebinding: the body starts at an arbitrary byte offset.
    private static func read<T: BinaryFloatingPoint>(_: T.Type, _ count: Int, from body: Data) -> [T] {
        var out = [T](repeating: 0, count: count)
        _ = out.withUnsafeMutableBytes { body.copyBytes(to: $0) }
        return out
    }
}
