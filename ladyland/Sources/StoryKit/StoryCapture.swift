import Foundation

package enum StoryRecordMode: Equatable, Sendable {
    case pattern
    case punchIn(startBeat: Double, lengthBeats: Double)
}

package struct StoryCapture: Sendable {
    private struct Key: Hashable, Sendable {
        let source: String
        let channel: UInt8
        let note: UInt8
    }

    private struct HeldNote: Sendable {
        let track: Int
        let beat: Double
        let velocity: UInt8
    }

    private struct Knob: Hashable, Sendable {
        let track: Int
        let seat: Int
    }

    private let mode: StoryRecordMode
    private let leadIn: Double
    private var held: [Key: HeldNote] = [:]
    private var notes: [Int: [MIDINoteEvent]] = [:]
    private var points: [Knob: [ParametricPoint]] = [:]

    package init(mode: StoryRecordMode, leadIn: Double = 0) {
        self.mode = mode
        self.leadIn = leadIn
    }

    package mutating func note(track: Int, status: UInt8, note: UInt8, velocity: UInt8,
                               at elapsed: Double, source: String = "local") {
        guard (0..<StoryDocument.trackCount).contains(track), note < 128, velocity < 128 else { return }
        let family = status & 0xf0
        guard family == 0x90 || family == 0x80 else { return }
        let beat = elapsed + leadIn
        let key = Key(source: source, channel: status & 0x0f, note: note)
        if let previous = held.removeValue(forKey: key) { finish(key, previous, at: beat) }
        if family == 0x90 && velocity > 0 { held[key] = HeldNote(track: track, beat: beat, velocity: velocity) }
    }

    package mutating func knob(track: Int, knob: Int, value: Float, at elapsed: Double) {
        guard (0..<StoryDocument.trackCount).contains(track), (0..<StoryDocument.knobCount).contains(knob) else { return }
        points[Knob(track: track, seat: knob), default: []]
            .append(ParametricPoint(beat: elapsed + leadIn, value: min(max(value, 0), 1)))
    }

    private mutating func finish(_ key: Key, _ held: HeldNote, at beat: Double) {
        notes[held.track, default: []].append(MIDINoteEvent(
            beat: held.beat, durationBeats: max(beat - held.beat, 0.001),
            note: key.note, velocity: held.velocity))
    }

    @discardableResult
    package mutating func commit(to story: inout StoryDocument, elapsed: Double) -> [String] {
        let end = elapsed + leadIn
        for (key, note) in held { finish(key, note, at: end) }
        held.removeAll()
        let length: Double
        if case let .punchIn(_, regionLength) = mode {
            length = regionLength
        } else {
            length = max(end, 0.001)
        }
        var takes: [Pattern] = []
        for track in notes.keys.sorted() {
            let events = notes[track, default: []].filter { $0.beat < length }.map {
                MIDINoteEvent(beat: $0.beat, durationBeats: min($0.durationBeats, length - $0.beat),
                              note: $0.note, velocity: $0.velocity)
            }.sorted { ($0.beat, $0.note, $0.velocity, $0.durationBeats) < ($1.beat, $1.note, $1.velocity, $1.durationBeats) }
            if !events.isEmpty {
                takes.append(Pattern(name: "MIDI Take", trackIndex: track, lengthBeats: length, kind: .midi(notes: events)))
            }
        }
        for key in points.keys.sorted(by: { ($0.track, $0.seat) < ($1.track, $1.seat) }) {
            let take = points[key, default: []].filter { $0.beat <= length }
            if !take.isEmpty {
                let rule = ParametricRule(knob: key.seat, waveform: .manual, steps: 0)
                takes.append(Pattern(name: "Knob \(key.seat + 1) Take", trackIndex: key.track,
                    lengthBeats: length, kind: .parametric(rule: rule, points: take)))
            }
        }
        notes.removeAll()
        points.removeAll()
        story.patterns.append(contentsOf: takes)
        if case let .punchIn(start, _) = mode {
            story.overrides.append(contentsOf: takes.map {
                StoryOverride(startBeat: start, lengthBeats: length, overridePatternID: $0.id)
            })
        }
        return takes.map(\.id)
    }
}
