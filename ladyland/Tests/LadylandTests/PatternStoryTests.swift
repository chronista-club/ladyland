import AVFoundation
import Foundation
import Testing
import StoryKit
@testable import Ladyland

struct PatternStoryTests {
    @Test func starterRoundTripsAllThreeKinds() throws {
        var story = StoryDocument.starter
        story.patterns.append(Pattern(id: "audio", name: "Take", trackIndex: 63, lengthBeats: 128,
            kind: .rawAudio(clip: RawAudioClip(filePath: "/take.wav", durationSeconds: 64, peaks: [0.4]))))
        let restored = try JSONDecoder().decode(StoryDocument.self, from: JSONEncoder().encode(story))
        #expect(restored == story)
        #expect(story.patterns.contains { if case .midi = $0.kind { true } else { false } })
        #expect(story.patterns.contains { if case .parametric = $0.kind { true } else { false } })
    }

    @Test func waveformsAndRecordedPoints() {
        var rule = ParametricRule(knob: 0, waveform: .sine, minValue: 0, maxValue: 1, steps: 0)
        for (wave, expected): (ParametricWaveform, Float) in [
            (.sine, 1), (.triangle, 0.5), (.sawUp, 0.25), (.sawDown, 0.75),
            (.square, 1), (.step, 0.25), (.manual, 0.5)
        ] {
            rule.waveform = wave
            #expect(abs(rule.evaluateParametric(atBeat: 1, lengthBeats: 4) - expected) < 0.0001)
        }
        rule.waveform = .step
        rule.steps = 4
        #expect(rule.evaluateParametric(atBeat: 1, lengthBeats: 4) == 1.0 / 3)
        rule.waveform = .smoothRandom
        let random = rule.evaluateParametric(atBeat: 1, lengthBeats: 4)
        #expect((0...1).contains(random))
        #expect(rule.evaluateParametric(atBeat: 1, lengthBeats: 4) == random)
        rule.waveform = .sawUp
        rule.steps = 0
        rule.cyclesPerPattern = 2
        rule.phase = 0.125
        rule.skew = 0.5
        rule.minValue = 0.25
        rule.maxValue = 0.75
        #expect(abs(rule.evaluateParametric(atBeat: 0.5, lengthBeats: 4) - 0.5) < 0.0001)
        let points = [ParametricPoint(beat: 3, value: 1), ParametricPoint(beat: 1, value: 0)]
        #expect(rule.evaluateParametric(atBeat: 2, lengthBeats: 4, points: points) == 0.5)
        rule.waveform = .manual
        #expect(rule.evaluateParametric(atBeat: 0, lengthBeats: 4, points: points) == 0)
    }

    @Test func singleSampleBlendsIntoGeneratedWaveOnlyNearItsBeat() {
        let rule = ParametricRule(knob: 0, waveform: .square, minValue: 0, maxValue: 1, steps: 0)
        let points = [ParametricPoint(beat: 1, value: 0)]
        let samples = [0.5, 0.875, 1, 1.125, 1.5].map {
            rule.evaluateParametric(atBeat: $0, lengthBeats: 8, points: points)
        }
        #expect(samples == [1, 0.5, 0, 0.5, 1])
    }

    @Test func partialReplacementRestoresBaseAndLayerKeepsBoth() {
        func pattern(_ id: String, _ note: UInt8) -> Pattern {
            Pattern(id: id, name: id, trackIndex: 0, lengthBeats: 8,
                kind: .midi(notes: [.init(beat: 0, durationBeats: 8, note: note, velocity: 100)]))
        }
        let base = pattern("base", 60)
        let take = pattern("take", 64)
        var story = StoryDocument(patterns: [base, take], steps: [
            .init(id: "a", patternID: base.id), .init(id: "b", patternID: base.id)
        ], overrides: [.init(id: "punch", startBeat: 3, lengthBeats: 2,
                             overridePatternID: take.id, mode: .replace)])
        #expect(story.totalStoryBeats == 16)
        #expect(story.resolve(atStoryBeat: 2).midi.map(\.note) == [60])
        #expect(story.resolve(atStoryBeat: 3).midi.map(\.note) == [64])
        #expect(story.resolve(atStoryBeat: 5).midi.map(\.note) == [60])
        #expect(story.resolve(atStoryBeat: 8).midi.map(\.note) == [60])
        story.overrides[0].mode = .layer
        #expect(story.resolve(atStoryBeat: 3).midi.map(\.note) == [60, 64])
        #expect(story.resolve(atStoryBeat: 3).activeOverrideIDs == ["punch"])
    }

    @Test func capturesNotesAndKnobsAsPunchPatterns() {
        var capture = StoryCapture(mode: .punchIn(startBeat: 4, lengthBeats: 4))
        capture.note(track: 2, status: 0x90, note: 62, velocity: 100, at: 0.25)
        capture.note(track: 2, status: 0x90, note: 62, velocity: 0, at: 1)
        capture.knob(track: 2, knob: 3, value: 0.75, at: 1)
        var story = StoryDocument.starter
        capture.commit(to: &story, elapsed: 4)
        let result = story.resolve(atStoryBeat: 4.5)
        #expect(result.activeOverrideIDs.count == 2)
        #expect(result.midi.contains { $0.trackIndex == 2 && $0.note == 62 })
        #expect(result.parameters.contains { $0.trackIndex == 2 && $0.knob == 3 && $0.value == 0.75 })
        #expect(story.resolve(atStoryBeat: 8).activeOverrideIDs.isEmpty)
    }

    @Test func replaceKeepsIndependentLayersAndOtherKnobs() throws {
        func automation(_ id: String, track: Int = 0, knob: Int, value: Float) -> Pattern {
            Pattern(id: id, name: id, trackIndex: track, lengthBeats: 4, kind: .parametric(
                rule: .init(knob: knob, waveform: .manual), points: [.init(beat: 0, value: value)]))
        }
        let base = automation("base", knob: 0, value: 0.1)
        let other = automation("other", knob: 1, value: 0.2)
        let layer = automation("layer", knob: 0, value: 0.3)
        let replacement = automation("replace", knob: 0, value: 0.4)
        let story = StoryDocument(patterns: [base, other, layer, replacement],
            steps: [.init(patternID: base.id)], overrides: [
                .init(id: "other", startBeat: 0, lengthBeats: 4, overridePatternID: other.id, mode: .layer),
                .init(id: "layer", startBeat: 0, lengthBeats: 4, overridePatternID: layer.id, mode: .layer),
                .init(id: "replace", startBeat: 1, lengthBeats: 1, overridePatternID: replacement.id)
            ])
        let during = story.resolve(atStoryBeat: 1)
        #expect(during.activePatternIDs == ["other", "layer", "replace"])
        #expect(during.activeOverrideIDs == ["other", "layer", "replace"])
        #expect(during.parameters.first { $0.knob == 0 }?.value == 0.4)
        #expect(during.parameters.first { $0.knob == 1 }?.value == 0.2)
        #expect(story.resolve(atStoryBeat: 2).parameters.first { $0.knob == 0 }?.value == 0.3)
    }

    @Test func recordsReleaseOnTheOriginalTrackAfterRoutingChanges() throws {
        var capture = StoryCapture(mode: .pattern)
        capture.note(track: 4, status: 0x90, note: 60, velocity: 90, at: 1)
        capture.note(track: 7, status: 0x80, note: 60, velocity: 0, at: 2)
        var story = StoryDocument()
        capture.commit(to: &story, elapsed: 100)
        let pattern = try #require(story.patterns.first)
        #expect(pattern.trackIndex == 4)
        #expect(pattern.lengthBeats == 100)
        #expect(pattern.kind == .midi(notes: [.init(beat: 1, durationBeats: 1, note: 60, velocity: 90)]))
        #expect(story.overrides.isEmpty)
    }

    @Test func audioImportBuildsPeaksAndDuration() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 8000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 800))
        buffer.frameLength = buffer.frameCapacity
        let samples = try #require(buffer.floatChannelData?[0])
        for index in 0..<Int(buffer.frameLength) { samples[index] = index < 400 ? 0 : -0.5 }
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
        }
        let clip = try RawAudioClip.load(url)
        #expect(clip.durationSeconds == 0.1)
        #expect(clip.peaks.count == 128)
        #expect(clip.peaks.prefix(64).allSatisfy { $0 == 0 })
        #expect(clip.peaks.suffix(64).allSatisfy { abs($0 - 0.5) < 0.001 })
    }

    @MainActor @Test func playbackCrossesShortNotesAndRearticulatesRepeatedSteps() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = StoryStore(url: directory.appendingPathComponent("story.json"))
        let pattern = Pattern(name: "Short", trackIndex: 0, lengthBeats: 1, kind: .midi(notes: [
            .init(beat: 0, durationBeats: 0.125, note: 60, velocity: 80),
            .init(beat: 0.875, durationBeats: 0.125, note: 60, velocity: 90)
        ]))
        try store.update { $0 = StoryDocument(patterns: [pattern], steps: [
            .init(patternID: pattern.id), .init(patternID: pattern.id)
        ]) }
        let controller = PatternStoryController(store: store)
        var velocities: [UInt8] = []
        controller.sendNote = { _, _, velocity in velocities.append(velocity) }
        controller.start()
        controller.advance(by: 1.25)
        #expect(velocities == [80, 0, 90, 0, 80, 0])
        controller.loop = true
        controller.advance(by: 1)
        #expect(controller.currentBeat == 0.25)
        #expect(velocities == [80, 0, 90, 0, 80, 0, 90, 0, 80, 0])
        controller.stop()
    }

    @MainActor @Test func controllerAutomaticallyReloadsValidExternalEdits() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("story.json")
        let controller = PatternStoryController(store: StoryStore(url: url))
        controller.beginMonitoring()
        _ = try StoryCLI.run(arguments: ["story-clear"], storeURL: url)
        for _ in 0..<30 where !controller.document.steps.isEmpty {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(controller.document.steps.isEmpty)
        #expect(controller.document.overrides.isEmpty)
    }

    @Test func concurrentCLIAddsPreserveBothEdits() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("story.json")
        let ids = try await withThrowingTaskGroup(of: String.self, returning: Set<String>.self) { group in
            for track in 1...8 {
                group.addTask {
                    try StoryCLI.run(arguments: ["add-midi", "--track", String(track)], storeURL: url)
                }
            }
            var ids = Set<String>()
            for try await id in group { ids.insert(id) }
            return ids
        }
        let store = StoryStore(url: url)
        try store.reloadIfChanged()
        #expect(ids.count == 8)
        #expect(store.document.patterns.count == StoryDocument.starter.patterns.count + ids.count)
        #expect(ids.isSubset(of: Set(store.document.patterns.map(\.id))))
    }

    @Test func cliCommandsAndExternalReload() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("story.json")
        let store = StoryStore(url: url)
        func run(_ args: String...) throws -> String { try StoryCLI.run(arguments: args, storeURL: url) }
        #expect(try JSONDecoder().decode(StoryDocument.self, from: Data(run("list").utf8)) == .starter)
        _ = try run("story-clear")
        let midi = try run("add-midi", "--track", "64", "--notes", "0:4:60:100")
        let param = try run("add-parametric", "--track", "64", "--knob", "8", "--wave", "sawUp",
                            "--steps", "0", "--min", "0", "--max", "1")
        let audio = try run("add-audio", "--track", "1")
        _ = try run("story-append", "--pattern", midi)
        _ = try run("story-override", "--start-bar", "1", "--bars", "1", "--pattern", param, "--mode", "layer")
        #expect(try store.reloadIfChanged())
        #expect(try !store.reloadIfChanged())
        let result = try JSONDecoder().decode(StoryResolution.self, from: Data(run("eval", "--beat", "1").utf8))
        #expect(result.midi.first?.trackIndex == 63)
        #expect(result.parameters.first?.value == 0.25)
        #expect(store.document.patterns.contains { $0.id == audio })
        #expect(throws: StoryCLI.Error.self) { try run("add-midi", "--track", "65") }
    }
}
