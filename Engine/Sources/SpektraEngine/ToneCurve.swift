import simd

extension ToneGraph {
    /// One of the graph's curves: a colour's, by its layer and the print's channel, or the neutral one.
    public enum Channel: String, CaseIterable, Sendable {
        case neutral, red, green, blue

        public static let colours: [Channel] = [.red, .green, .blue]

        /// Its layer and the print's channel; none for neutral.
        public var index: Int? {
            switch self {
            case .neutral: nil
            case .red: 0
            case .green: 1
            case .blue: 2
            }
        }
    }

    /// One colour's tone curve, or the neutral one, from a ``ToneGraph``: per grey of its ramp, the
    /// tone (the film's exposure, in stops), the paper's log₁₀ exposure and the print's brightness.
    /// What the app's tone graph draws: predicted for controls the engine hasn't rendered yet
    /// (``predicted(for:from:)``), and burned in (``burned(stops:threshold:)``).
    public struct Curve: Sendable {
        /// The curve's points: the print exposure's in the middle (where the paper's exposure is 0),
        /// the shadow and highlight contrasts' either side.
        public struct Handle: Sendable {
            public enum Kind: Sendable {
                case shadows, middle, highlights
            }

            public let kind: Kind
            public let tone: Float
            public let print: Float
        }

        public let channel: Channel
        public let tones: [Float]
        public let paper: [Float]
        public let print: [Float]
        /// Each grey's exposure as the burn's mask takes it: the layers' mean exposure, in stops over
        /// mid-grey, as the `burn_threshold` kernel takes a pixel's.
        let burnExposures: [Float]

        init(channel: Channel, tones: [Float], paper: [Float], print: [Float], burnExposures: [Float]) {
            (self.channel, self.tones, self.paper, self.print, self.burnExposures)
                = (channel, tones, paper, print, burnExposures)
        }

        public init(_ graph: ToneGraph, channel: Channel) {
            self.channel = channel
            if let index = channel.index {
                tones = graph.curve.map { $0.film[index] }
                paper = graph.curve.map { $0.paper[index] }
                print = graph.curve.map { $0.print[index] }
            } else {
                // The layers' mean, as the histogram has them together; the brightness as Rec. 709 luma.
                tones = graph.curve.map { $0.film.sum() / 3 }
                paper = graph.curve.map { $0.paper.sum() / 3 }
                print = graph.curve.map { ($0.print * SIMD3(0.2126, 0.7152, 0.0722)).sum() }
            }
            burnExposures = graph.curve.map { log2(exp2($0.film).sum() / 3) }
        }

        /// The curve `controls` would make, from this one made with `rendered`: the print exposure
        /// adds its log₁₀ to the paper's exposure, and the contrasts scale that about 0 (Contrast all
        /// of it, Shadow contrast above 0, Highlight contrast below), the print's brightness for each
        /// paper exposure staying this curve's. Exact for the print exposure (but for preflash) and
        /// Contrast; near for the other two, as their sub-layers aren't all of the paper's response.
        /// The other controls change nothing here: the engine's next curve shows them.
        public func predicted(for controls: Controls, from rendered: Controls) -> Curve {
            let shift = Float(log10(controls.printExposure / rendered.printExposure))
            let contrast = Float(controls.printContrast / rendered.printContrast)
            let change = SIMD3(shift, contrast * Float(controls.printShadowContrast / rendered.printShadowContrast),
                               contrast * Float(controls.printHighlightContrast / rendered.printHighlightContrast))
            guard shift.isFinite, change != SIMD3(0, 1, 1) else { return self }
            return Curve(channel: channel, tones: tones, paper: paper.map { $0 + shift },
                         print: tones.map { brightness(at: $0, change) }, burnExposures: burnExposures)
        }

        /// The brightness at `tone` with `change`: the paper's exposure shifted by its x, then scaled
        /// by its y above 0 and its z below (``predicted(for:from:)``), looked up on this curve.
        private func brightness(at tone: Float, _ change: SIMD3<Float>) -> Float {
            let exposure = value(of: paper, at: tone) + change.x
            let scaled = exposure > 0 ? exposure * change.y : exposure * change.z
            return value(of: print, at: self.tone(where: paper, is: scaled, near: tone))
        }

        /// This curve burned in (``Parameters/Burn``) as the engine burns a photo, but with a mask
        /// not fitted to its edges: each grey's paper exposure up by `stops` × its mask, log₁₀ 2 a
        /// stop, and the brightness for that looked up on this curve, as ``predicted(for:from:)``
        /// looks it up. The mask is the `burn_threshold` kernel's (``burnExposures``): 0 under
        /// `threshold`, 1 from a stop over, smoothly between.
        public func burned(stops: Float, threshold: Float) -> Curve {
            let burned = paper.indices.map { index in
                paper[index] + log10(2) * stops * simd_smoothstep(threshold, threshold + 1, burnExposures[index])
            }
            let print = burned.indices.map { index in
                value(of: self.print, at: tone(where: paper, is: burned[index], near: tones[index]))
            }
            return Curve(channel: channel, tones: tones, paper: burned, print: print, burnExposures: burnExposures)
        }

        /// The middle point where the paper's exposure is 0 (a mid-grey negative's at a print
        /// exposure of 1), and the side points `sideDistance` stops either side; none if it's never 0.
        public func handles(sideDistance: Float) -> [Handle] {
            guard paper.contains(where: { $0 <= 0 }), paper.contains(where: { $0 >= 0 }) else { return [] }
            let middle = tone(where: paper, is: 0, near: 0)
            return [(Handle.Kind.shadows, middle - sideDistance), (.middle, middle), (.highlights, middle + sideDistance)]
                .map { Handle(kind: $0, tone: $1, print: value(of: print, at: $1)) }
        }

        /// The ramp's greys within `range` as (tone, brightness), and the nearest past each end, so a
        /// line through them reaches them.
        public func points(in range: ClosedRange<Float>) -> [SIMD2<Float>] {
            let first = max((tones.firstIndex { $0 >= range.lowerBound } ?? 0) - 1, 0)
            let last = min((tones.lastIndex { $0 <= range.upperBound } ?? tones.count - 1) + 1, tones.count - 1)
            return (first...last).map { SIMD2(tones[$0], print[$0]) }
        }

        /// `values` at `tone`, between the ramp's greys; past its ends, the end's.
        public func value(of values: [Float], at tone: Float) -> Float {
            guard let above = tones.firstIndex(where: { $0 >= tone }) else { return values[values.count - 1] }
            guard above > 0 else { return values[0] }
            let fraction = (tone - tones[above - 1]) / (tones[above] - tones[above - 1])
            return values[above - 1] + fraction * (values[above] - values[above - 1])
        }

        /// The tone nearest `near` where `values` are `target`, brought within their range.
        public func tone(where values: [Float], is target: Float, near: Float) -> Float {
            let target = min(max(target, values.min()!), values.max()!)
            var nearest = near
            var nearestDistance = Float.infinity
            for index in values.indices.dropLast() {
                let (from, to) = (values[index], values[index + 1])
                guard min(from, to) <= target && target <= max(from, to) else { continue }
                let fraction = from == to ? 0 : (target - from) / (to - from)
                let tone = tones[index] + fraction * (tones[index + 1] - tones[index])
                if abs(tone - near) < nearestDistance {
                    (nearest, nearestDistance) = (tone, abs(tone - near))
                }
            }
            return nearest
        }
    }
}
