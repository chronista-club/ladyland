import Foundation

package enum StoryCLI {
    package struct Error: LocalizedError {
        package let message: String
        package var errorDescription: String? { message }
        package init(_ message: String) { self.message = message }
    }

    package static func run(arguments: [String], storeURL: URL = StoryStore.defaultURL) throws -> String {
        guard let command = arguments.first else {
            return "story <list|show|add-parametric|add-midi|add-audio|story-append|story-clear|story-override|eval>"
        }
        let store = StoryStore(url: storeURL)
        let allowed: Set<String>
        switch command {
        case "list", "show", "story-clear": allowed = []
        case "eval": allowed = ["beat"]
        case "story-append": allowed = ["pattern"]
        case "story-override": allowed = ["start-bar", "bars", "pattern", "mode"]
        case "add-midi": allowed = ["track", "bars", "name", "notes"]
        case "add-parametric": allowed = ["track", "bars", "name", "knob", "wave", "cycles", "min", "max", "phase", "skew", "steps"]
        case "add-audio": allowed = ["track", "bars", "name", "file"]
        default: throw Error("Unknown Story command: \(command).")
        }
        let options = try Options(arguments.dropFirst(), allowed: allowed)
        switch command {
        case "list", "show", "eval":
            try store.reloadIfChanged()
            if command == "eval" {
                return try json(store.document.resolve(atStoryBeat: options.double("beat", in: 0...Double.greatestFiniteMagnitude)))
            }
            return try json(store.document)
        case "story-clear":
            return try store.update {
                $0.steps.removeAll()
                $0.overrides.removeAll()
                return "Story cleared"
            }
        case "story-append":
            let pattern = try options.required("pattern")
            return try store.update {
                guard $0.pattern(pattern) != nil else { throw Error("Unknown pattern \(pattern).") }
                let step = StoryStep(patternID: pattern)
                $0.steps.append(step)
                return step.id
            }
        case "story-override":
            let bar = try options.double("start-bar", in: 1...(Double.greatestFiniteMagnitude / 4))
            let length = try options.length()
            let pattern = try options.required("pattern")
            guard let mode = OverrideMode(rawValue: options.values["mode"] ?? "replace") else {
                throw Error("--mode must be replace or layer.")
            }
            return try store.update {
                guard $0.pattern(pattern) != nil else { throw Error("Unknown pattern \(pattern).") }
                let region = StoryOverride(startBeat: (bar - 1) * StoryDocument.beatsPerBar,
                                           lengthBeats: length, overridePatternID: pattern, mode: mode)
                $0.overrides.append(region)
                return region.id
            }
        default:
            let track = try options.integer("track", in: 1...StoryDocument.trackCount) - 1
            let kind: PatternKind
            let length: Double
            switch command {
            case "add-parametric":
                length = try options.length(default: 4)
                let knob = try options.integer("knob", in: 1...StoryDocument.knobCount) - 1
                let wave = try options.required("wave")
                guard let waveform = ParametricWaveform(rawValue: wave) else { throw Error("Unknown waveform: \(wave).") }
                let minValue = try options.double("min", default: 0.15, in: 0...1)
                let maxValue = try options.double("max", default: 0.85, in: 0...1)
                kind = .parametric(rule: try ParametricRule(knob: knob, waveform: waveform,
                    cyclesPerPattern: options.double("cycles", default: 1, in: Double.leastNonzeroMagnitude...Double.greatestFiniteMagnitude),
                    minValue: Float(minValue), maxValue: Float(maxValue),
                    phase: options.double("phase", default: 0, in: 0...1),
                    skew: options.double("skew", default: 0, in: -1...1),
                    steps: options.integer("steps", default: 8, in: 0...32)), points: [])
            case "add-midi":
                length = try options.length(default: 4)
                let input = options.values["notes"] ?? ""
                let notes = try input.isEmpty ? [] : input.split(separator: ",", omittingEmptySubsequences: false)
                    .map { try parseNote($0, length: length) }
                kind = .midi(notes: notes)
            default:
                let clip = try options.values["file"].map { try RawAudioClip.load(URL(fileURLWithPath: $0)) } ?? RawAudioClip()
                length = try options.length(default: clip.durationSeconds > 0 ? clip.durationSeconds * 2 : 4)
                kind = .rawAudio(clip: clip)
            }
            let pattern = Pattern(name: options.values["name"] ?? kind.label, trackIndex: track,
                                  lengthBeats: length, kind: kind)
            return try store.update {
                $0.patterns.append(pattern)
                return pattern.id
            }
        }
    }

    // Shared by both executable entry points before any app or hardware startup.
    package static func handle(arguments: [String]) -> Never {
        do {
            print(try run(arguments: arguments))
            exit(EXIT_SUCCESS)
        } catch {
            FileHandle.standardError.write(Data(("story: \(error.localizedDescription)\n").utf8))
            exit(EXIT_FAILURE)
        }
    }

    private static func json<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try StoryStore.encoder().encode(value), as: UTF8.self)
    }

    private static func parseNote(_ value: Substring, length: Double) throws -> MIDINoteEvent {
        let fields = value.split(separator: ":", omittingEmptySubsequences: false)
        guard fields.count == 4, let beat = Double(fields[0]), beat >= 0, beat < length,
              let duration = Double(fields[1]), duration > 0, (beat + duration).isFinite,
              let note = UInt8(fields[2]), note < 128,
              let velocity = UInt8(fields[3]), (1...127).contains(velocity) else {
            throw Error("Expected beat:duration:note:velocity within the pattern, got \(value).")
        }
        return MIDINoteEvent(beat: beat, durationBeats: duration, note: note, velocity: velocity)
    }

    private struct Options {
        let values: [String: String]

        init(_ input: ArraySlice<String>, allowed: Set<String>) throws {
            var iterator = input.makeIterator()
            var values: [String: String] = [:]
            while let flag = iterator.next() {
                let key = String(flag.dropFirst(2))
                guard flag.hasPrefix("--"), allowed.contains(key), values[key] == nil,
                      let value = iterator.next(), !value.hasPrefix("--") else {
                    throw Error("Unknown, repeated, or missing-value option: \(flag).")
                }
                values[key] = value
            }
            self.values = values
        }

        func required(_ key: String) throws -> String {
            guard let value = values[key], !value.isEmpty else { throw Error("Missing --\(key).") }
            return value
        }

        func integer(_ key: String, default defaultValue: Int? = nil, in range: ClosedRange<Int>) throws -> Int {
            let value = try values[key].map { Int($0) } ?? defaultValue ?? Int(required(key))
            guard let value, range.contains(value) else {
                throw Error("--\(key) must be an integer in \(range).")
            }
            return value
        }

        func double(_ key: String, default defaultValue: Double? = nil, in range: ClosedRange<Double>) throws -> Double {
            let value = try values[key].map { Double($0) } ?? defaultValue ?? Double(required(key))
            guard let value, range.contains(value) else {
                throw Error("--\(key) must be a number in \(range).")
            }
            return value
        }

        func length(default defaultBeats: Double? = nil) throws -> Double {
            if values["bars"] == nil, let defaultBeats { return defaultBeats }
            return try double("bars", in: Double.leastNonzeroMagnitude...(Double.greatestFiniteMagnitude / 4))
                * StoryDocument.beatsPerBar
        }
    }
}
