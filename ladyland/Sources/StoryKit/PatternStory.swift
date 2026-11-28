import Foundation

package struct MIDINoteEvent: Codable, Equatable, Sendable {
    package var beat: Double
    package var durationBeats: Double
    package var note: UInt8
    package var velocity: UInt8

    package init(beat: Double, durationBeats: Double, note: UInt8, velocity: UInt8) {
        self.beat = beat
        self.durationBeats = durationBeats
        self.note = note
        self.velocity = velocity
    }
}

package enum ParametricWaveform: String, Codable, CaseIterable, Sendable {
    case sine, triangle, sawUp, sawDown, square, step, smoothRandom, manual

    package var title: String {
        switch self {
        case .sawUp: "Saw Up"
        case .sawDown: "Saw Down"
        case .smoothRandom: "Smooth Random"
        default: rawValue.capitalized
        }
    }
}

package struct ParametricPoint: Codable, Equatable, Sendable {
    package var beat: Double
    package var value: Float

    package init(beat: Double, value: Float) {
        self.beat = beat
        self.value = value
    }
}

package struct ParametricRule: Codable, Equatable, Sendable {
    package var knob: Int
    package var waveform: ParametricWaveform
    package var cyclesPerPattern: Double
    package var minValue: Float
    package var maxValue: Float
    package var phase: Double
    package var skew: Double
    package var steps: Int

    package init(knob: Int, waveform: ParametricWaveform = .sine, cyclesPerPattern: Double = 1,
                 minValue: Float = 0.15, maxValue: Float = 0.85, phase: Double = 0,
                 skew: Double = 0, steps: Int = 8) {
        self.knob = knob
        self.waveform = waveform
        self.cyclesPerPattern = cyclesPerPattern
        self.minValue = minValue
        self.maxValue = maxValue
        self.phase = phase
        self.skew = skew
        self.steps = steps
    }

    package func evaluateParametric(atBeat beat: Double, lengthBeats: Double,
                                    points: [ParametricPoint] = []) -> Float {
        evaluate(at: beat, length: lengthBeats, orderedPoints: Self.ordered(points))
    }

    package func preview(lengthBeats: Double, points: [ParametricPoint], segments: Int) -> [Float] {
        let ordered = Self.ordered(points)
        let segments = max(1, segments)
        return (0...segments).map {
            evaluate(at: Double($0) / Double(segments) * lengthBeats,
                     length: lengthBeats, orderedPoints: ordered)
        }
    }

    fileprivate static func ordered(_ points: [ParametricPoint]) -> [ParametricPoint] {
        points.sorted { $0.beat < $1.beat }
    }

    fileprivate func evaluate(at beat: Double, length: Double, orderedPoints: [ParametricPoint]) -> Float {
        guard beat.isFinite else { return 0 }
        let position = beat / max(length, 0.001) * cyclesPerPattern + phase
        guard position.isFinite else { return 0 }
        let cycle = floor(position)
        let fraction = position - cycle
        let skew = min(max(skew, -1), 1)
        // Move the midpoint while keeping the cycle endpoints fixed.
        let midpoint = 0.5 - skew * 0.25
        let warped = fraction < midpoint
            ? fraction / midpoint * 0.5
            : 0.5 + (fraction - midpoint) / (1 - midpoint) * 0.5
        var unit: Double
        switch waveform {
        case .sine: unit = 0.5 + 0.5 * sin(warped * 2 * .pi)
        case .triangle: unit = 1 - abs(2 * warped - 1)
        case .sawUp, .step: unit = warped
        case .sawDown: unit = 1 - warped
        case .square: unit = warped < 0.5 ? 1 : 0
        case .smoothRandom:
            let first = Self.randomValue(cycle)
            let second = Self.randomValue(cycle + 1)
            unit = first + (second - first) * warped * warped * (3 - 2 * warped)
        case .manual: unit = 0.5
        }

        let levels = min(max(steps, 0), 32)
        if levels >= 2 && waveform != .manual {
            let scale = Double(levels - 1)
            unit = waveform == .step
                ? min(floor(unit * Double(levels)), scale) / scale
                : (unit * scale).rounded() / scale
        }
        let generated = min(max(minValue + (maxValue - minValue) * Float(unit), 0), 1)
        guard let first = orderedPoints.first, let last = orderedPoints.last else { return generated }
        let recorded = interpolate(at: beat, ordered: orderedPoints, first: first, last: last)
        if waveform == .manual { return recorded }
        let outside = max(first.beat - beat, beat - last.beat, 0)
        let fadeWidth = max(min(0.25, length / 8), .leastNonzeroMagnitude)
        let blend = Float(max(0, 1 - outside / fadeWidth))
        return generated + (recorded - generated) * blend
    }

    private static func randomValue(_ cycle: Double) -> Double {
        // Use a stable integer mix so arbitrary seeks and independent processes agree.
        var bits = cycle == 0 ? 0 : cycle.bitPattern
        bits = (bits ^ (bits >> 30)) &* 0xbf58476d1ce4e5b9
        bits = (bits ^ (bits >> 27)) &* 0x94d049bb133111eb
        return Double((bits ^ (bits >> 31)) >> 11) / Double(1 << 53)
    }

    private func interpolate(at beat: Double, ordered: [ParametricPoint],
                             first: ParametricPoint, last: ParametricPoint) -> Float {
        if beat < first.beat { return min(max(first.value, 0), 1) }
        if beat >= last.beat { return min(max(last.value, 0), 1) }
        var low = 0
        var high = ordered.count - 1
        while low + 1 < high {
            let middle = (low + high) / 2
            if ordered[middle].beat <= beat { low = middle } else { high = middle }
        }
        let left = ordered[low]
        let right = ordered[high]
        let value = left.value + (right.value - left.value) * Float((beat - left.beat) / (right.beat - left.beat))
        return min(max(value, 0), 1)
    }
}

package struct RawAudioClip: Codable, Equatable, Sendable {
    package var filePath: String?
    package var durationSeconds: Double
    package var peaks: [Float]

    package init(filePath: String? = nil, durationSeconds: Double = 0, peaks: [Float] = []) {
        self.filePath = filePath
        self.durationSeconds = durationSeconds
        self.peaks = peaks
    }
}

package enum PatternKind: Codable, Equatable, Sendable {
    case midi(notes: [MIDINoteEvent])
    case parametric(rule: ParametricRule, points: [ParametricPoint])
    case rawAudio(clip: RawAudioClip)

    package var label: String {
        switch self {
        case .midi: "MIDI"
        case .parametric: "PARAM"
        case .rawAudio: "AUDIO"
        }
    }

    fileprivate func matchesTarget(_ other: Self) -> Bool {
        switch (self, other) {
        case (.midi, .midi), (.rawAudio, .rawAudio): true
        case let (.parametric(lhs, _), .parametric(rhs, _)): lhs.knob == rhs.knob
        default: false
        }
    }
}

package struct Pattern: Identifiable, Codable, Equatable, Sendable {
    package var id: String
    package var name: String
    package var trackIndex: Int
    package var lengthBeats: Double
    package var kind: PatternKind

    package init(id: String = UUID().uuidString, name: String, trackIndex: Int, lengthBeats: Double, kind: PatternKind) {
        self.id = id
        self.name = name
        self.trackIndex = trackIndex
        self.lengthBeats = lengthBeats
        self.kind = kind
    }
}

package struct StoryStep: Identifiable, Codable, Equatable, Sendable {
    package var id: String
    package var patternID: String

    package init(id: String = UUID().uuidString, patternID: String) {
        self.id = id
        self.patternID = patternID
    }
}

package enum OverrideMode: String, Codable, CaseIterable, Sendable {
    case replace, layer
}

package struct StoryOverride: Identifiable, Codable, Equatable, Sendable {
    package var id: String
    package var startBeat: Double
    package var lengthBeats: Double
    package var overridePatternID: String
    package var mode: OverrideMode

    package init(id: String = UUID().uuidString, startBeat: Double, lengthBeats: Double,
                 overridePatternID: String, mode: OverrideMode = .replace) {
        self.id = id
        self.startBeat = startBeat
        self.lengthBeats = lengthBeats
        self.overridePatternID = overridePatternID
        self.mode = mode
    }
}

package struct StoryResolution: Codable, Equatable, Sendable {
    package struct MIDI: Codable, Equatable, Sendable {
        package let trackIndex: Int
        package let note: UInt8
        package let velocity: UInt8
        package let occurrenceID: String
        package let eventIndex: Int
    }

    package struct Parameter: Codable, Equatable, Sendable {
        package let trackIndex: Int
        package let knob: Int
        package let value: Float
    }

    package struct Audio: Codable, Equatable, Sendable {
        package let trackIndex: Int
        package let clip: RawAudioClip
        package let occurrenceID: String
        package let localBeat: Double
    }

    package var activePatternIDs: [String] = []
    package var activeOverrideIDs: [String] = []
    package var midi: [MIDI] = []
    package var parameters: [Parameter] = []
    package var audio: [Audio] = []
}

package struct StoryDocument: Codable, Equatable, Sendable {
    package static let beatsPerBar = 4.0
    package static let trackCount = 64
    package static let knobCount = 8

    package var patterns: [Pattern]
    package var steps: [StoryStep]
    package var overrides: [StoryOverride]

    package init(patterns: [Pattern] = [], steps: [StoryStep] = [], overrides: [StoryOverride] = []) {
        self.patterns = patterns
        self.steps = steps
        self.overrides = overrides
    }

    package func pattern(_ id: String) -> Pattern? { patterns.first { $0.id == id } }

    package var totalStoryBeats: Double { timeline.totalBeats }

    package var timeline: StoryTimeline { StoryTimeline(document: self) }

    package func resolve(atStoryBeat beat: Double) -> StoryResolution {
        timeline.resolve(atStoryBeat: beat)
    }

    package static let starter: Self = {
        let notes = Pattern(id: "starter-midi", name: "Opening Notes", trackIndex: 0, lengthBeats: 8,
            kind: .midi(notes: (0..<8).map {
                MIDINoteEvent(beat: Double($0), durationBeats: 0.75,
                              note: [60, 63, 67, 70][$0 % 4], velocity: 92)
            }))
        let curve = Pattern(id: "starter-curve", name: "Filter Sine", trackIndex: 0, lengthBeats: 8,
            kind: .parametric(rule: .init(knob: 0, steps: 0), points: []))
        let alternate = Pattern(id: "starter-punch", name: "Filter Rise", trackIndex: 0, lengthBeats: 4,
            kind: .parametric(rule: .init(knob: 0, waveform: .sawUp, steps: 0), points: []))
        return Self(patterns: [notes, curve, alternate], steps: [
            .init(id: "opening", patternID: notes.id), .init(id: "filter", patternID: curve.id)
        ], overrides: [
            .init(id: "last-bar", startBeat: 12, lengthBeats: 4, overridePatternID: alternate.id)
        ])
    }()
}

package struct StoryTimeline: Sendable {
    package struct Placement: Identifiable, Sendable {
        package let id: String
        package let pattern: Pattern
        package let startBeat: Double
        package let lengthBeats: Double
        package let mode: OverrideMode?

        var end: Double { startBeat + lengthBeats }
        var occurrenceID: String { (mode == nil ? "step:" : "override:") + id }
    }

    package let steps: [Placement]
    package let overrides: [Placement]
    package let totalBeats: Double
    private let midiBoundaries: [Double]

    init(document: StoryDocument) {
        let patterns = Dictionary(document.patterns.map { original in
            var pattern = original
            if case let .parametric(rule, points) = pattern.kind {
                pattern.kind = .parametric(rule: rule, points: ParametricRule.ordered(points))
            }
            return (pattern.id, pattern)
        }, uniquingKeysWith: { first, _ in first })
        var cursor = 0.0
        let steps: [Placement] = document.steps.compactMap { step in
            guard let pattern = patterns[step.patternID], pattern.lengthBeats > 0,
                  (cursor + pattern.lengthBeats).isFinite else { return nil }
            defer { cursor += pattern.lengthBeats }
            return Placement(id: step.id, pattern: pattern, startBeat: cursor,
                             lengthBeats: pattern.lengthBeats, mode: nil)
        }
        let overrides: [Placement] = document.overrides.compactMap { region in
            guard let pattern = patterns[region.overridePatternID], region.startBeat >= 0,
                  region.lengthBeats > 0, (region.startBeat + region.lengthBeats).isFinite else { return nil }
            return Placement(id: region.id, pattern: pattern, startBeat: region.startBeat,
                             lengthBeats: region.lengthBeats, mode: region.mode)
        }
        self.steps = steps
        self.overrides = overrides
        totalBeats = max(cursor, overrides.map(\.end).max() ?? 0)

        var boundaries = Set<Double>()
        for placement in steps + overrides {
            guard case let .midi(notes) = placement.pattern.kind else { continue }
            let playableLength = min(placement.lengthBeats, placement.pattern.lengthBeats)
            boundaries.formUnion([placement.startBeat, placement.end])
            for note in notes where note.beat >= 0 && note.beat < playableLength {
                boundaries.insert(placement.startBeat + note.beat)
                boundaries.insert(placement.startBeat + min(note.beat + note.durationBeats, playableLength))
            }
        }
        midiBoundaries = boundaries.sorted()
    }

    package func midiChangeBeats(after start: Double, through end: Double) -> ArraySlice<Double> {
        func firstAfter(_ beat: Double) -> Int {
            var low = 0
            var high = midiBoundaries.count
            while low < high {
                let middle = (low + high) / 2
                if midiBoundaries[middle] <= beat { low = middle + 1 } else { high = middle }
            }
            return low
        }
        return midiBoundaries[firstAfter(start)..<firstAfter(max(start, end))]
    }

    package func resolve(atStoryBeat beat: Double) -> StoryResolution {
        guard beat >= 0 && beat < totalBeats else { return StoryResolution() }
        // Step ends are monotonic. Search by end to retain half-open interval semantics.
        var low = 0
        var high = steps.count
        while low < high {
            let middle = (low + high) / 2
            if steps[middle].end <= beat { low = middle + 1 } else { high = middle }
        }
        var active = low < steps.count ? [steps[low]] : []
        let regions = overrides.filter { $0.startBeat <= beat && beat < $0.end }
        for region in regions {
            if region.mode == .replace {
                active.removeAll {
                    $0.mode != .layer && $0.pattern.trackIndex == region.pattern.trackIndex
                        && $0.pattern.kind.matchesTarget(region.pattern.kind)
                }
            }
            active.append(region)
        }
        var resolution = StoryResolution()
        resolution.activeOverrideIDs = active.filter { $0.mode != nil }.map(\.id)
        for placement in active {
            let pattern = placement.pattern
            let local = beat - placement.startBeat
            guard local < pattern.lengthBeats else { continue }
            if !resolution.activePatternIDs.contains(pattern.id) {
                resolution.activePatternIDs.append(pattern.id)
            }
            switch pattern.kind {
            case let .midi(notes):
                for (index, event) in notes.enumerated()
                    where placement.startBeat + event.beat <= beat
                    && beat < placement.startBeat + (event.beat + event.durationBeats) {
                    resolution.midi.append(.init(trackIndex: pattern.trackIndex, note: event.note,
                        velocity: event.velocity, occurrenceID: placement.occurrenceID, eventIndex: index))
                }
            case let .parametric(rule, points):
                // A knob can receive one value. The latest active layer takes precedence.
                resolution.parameters.removeAll { $0.trackIndex == pattern.trackIndex && $0.knob == rule.knob }
                resolution.parameters.append(.init(trackIndex: pattern.trackIndex, knob: rule.knob,
                    value: rule.evaluate(at: local, length: pattern.lengthBeats, orderedPoints: points)))
            case let .rawAudio(clip):
                resolution.audio.append(.init(trackIndex: pattern.trackIndex, clip: clip,
                                               occurrenceID: placement.occurrenceID, localBeat: local))
            }
        }
        return resolution
    }
}
