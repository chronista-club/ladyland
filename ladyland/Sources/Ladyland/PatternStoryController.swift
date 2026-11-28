import AVFoundation
import Combine
import Foundation
import StoryKit

@MainActor
final class PatternStoryController: ObservableObject {
    enum Recording: String, CaseIterable {
        case pattern = "New Pattern"
        case punchIn = "Punch In"
    }

    @Published private(set) var document: StoryDocument
    @Published private(set) var currentBeat = 0.0
    @Published private(set) var isPlaying = false
    @Published private(set) var isRecording = false
    @Published private(set) var message: String?
    @Published var loop = false
    @Published var recording: Recording = .pattern
    @Published var punchBars = 1
    @Published var selectedPatternID: String?
    @Published var sculptsWithKnobs = false

    private(set) var timeline: StoryTimeline
    private let store: StoryStore
    private var reloadTimer: Timer?
    private var clockTimer: Timer?
    private var lastTick = 0.0
    private var lastCaptureStart = 0.0
    private var capture: StoryCapture?
    private var captureElapsed = 0.0
    private var captureEnd: Double?
    private var unsavedCapture: (take: StoryCapture, elapsed: Double)?
    private var pendingRules: [String: ParametricRule] = [:]
    private var rulesSave: Task<Void, Never>?
    private var voices: [Pitch: [StoryResolution.MIDI]] = [:]

    var tempo: () -> Double = { 120 }
    var sendNote: (Int, UInt8, UInt8) -> Void = { _, _, _ in }
    var setParameter: (Int, Int, Float) -> Void = { _, _, _ in }
    var updateAudio: ([StoryResolution.Audio], Double) -> Void = { _, _ in }
    var recordingChanged: (Bool) -> Void = { _ in }

    private struct Pitch: Hashable, Comparable {
        let track: Int
        let note: UInt8

        static func < (lhs: Self, rhs: Self) -> Bool {
            (lhs.track, lhs.note) < (rhs.track, rhs.note)
        }
    }

    init(store: StoryStore = StoryStore()) {
        self.store = store
        document = store.document
        timeline = store.document.timeline
        reload()
        selectedPatternID = document.patterns.first?.id
    }

    func beginMonitoring() {
        guard reloadTimer == nil else { return }
        reloadTimer = scheduleTimer(every: 0.5) { $0.checkForExternalChanges() }
    }

    private func updateClockTimer() {
        if isPlaying || isRecording {
            if clockTimer == nil {
                clockTimer = scheduleTimer(every: 1.0 / 120) { $0.syncClock() }
            }
        } else {
            clockTimer?.invalidate()
            clockTimer = nil
        }
    }

    private func scheduleTimer(every interval: TimeInterval,
                               _ action: @escaping @MainActor (PatternStoryController) -> Void) -> Timer {
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                action(self)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }

    func reload() {
        do {
            if try store.reloadIfChanged() || document != store.document {
                install(store.document)
            }
            try saveRules()
            try saveCapture()
            message = nil
        } catch {
            message = error.localizedDescription
        }
    }

    @discardableResult
    func edit<T>(_ change: (inout StoryDocument) throws -> T) -> T? {
        do {
            try saveRules()
            let result = try store.update(change)
            install(store.document)
            message = nil
            return result
        } catch {
            message = error.localizedDescription
            return nil
        }
    }

    func report(_ error: Error) { message = error.localizedDescription }

    private func install(_ document: StoryDocument) {
        var updated = document
        for index in updated.patterns.indices {
            if let rule = pendingRules[updated.patterns[index].id],
               case let .parametric(_, points) = updated.patterns[index].kind {
                updated.patterns[index].kind = .parametric(rule: rule, points: points)
            }
        }
        guard self.document != updated else { return }
        timeline = updated.timeline
        self.document = updated
        if isPlaying {
            if currentBeat >= timeline.totalBeats { endPlayback() }
            else { applyPosition() }
        }
        if selectedPatternID.flatMap(updated.pattern) == nil {
            selectedPatternID = updated.patterns.first?.id
        }
    }

    func start() {
        guard !isPlaying, timeline.totalBeats > 0 else { return }
        syncClock()
        if currentBeat >= timeline.totalBeats { currentBeat = 0 }
        isPlaying = true
        updateClockTimer()
        applyPosition()
    }

    func stop() {
        syncClock(advancesPlayback: false)
        endPlayback()
        finishCapture()
        flushEdits()
        currentBeat = 0
    }

    func seek(to beat: Double) {
        guard beat.isFinite else { return }
        syncClock()
        if captureEnd != nil { finishCapture() }
        silence()
        currentBeat = min(max(beat, 0), timeline.totalBeats)
        if isPlaying {
            if currentBeat >= timeline.totalBeats { endPlayback() }
            else { applyPosition() }
        }
    }

    func toggleRecord() {
        syncClock()
        if isRecording {
            finishCapture()
            return
        }
        do { try saveCapture() }
        catch { report(error); return }
        captureElapsed = 0
        switch recording {
        case .pattern:
            capture = StoryCapture(mode: .pattern)
        case .punchIn:
            let bar = StoryDocument.beatsPerBar
            let start = floor(currentBeat / bar) * bar
            let length = Double(max(1, punchBars)) * bar
            let leadIn = currentBeat - start
            captureEnd = length - leadIn
            capture = StoryCapture(mode: .punchIn(startBeat: start, lengthBeats: length), leadIn: leadIn)
        }
        isRecording = true
        lastCaptureStart = lastTick
        updateClockTimer()
        recordingChanged(true)
    }

    func captureNote(track: Int, status: UInt8, note: UInt8, velocity: UInt8,
                     source: String, time: Double) {
        guard capture != nil, time >= lastCaptureStart else { return }
        capture?.note(track: track, status: status, note: note, velocity: velocity,
                      at: elapsedAt(time), source: source)
    }

    // Returns true when this gesture belongs to the waveform editor.
    func knobInput(track: Int, seat: Int, position: Int, value: Float) -> Bool {
        if sculptsWithKnobs, (0..<7).contains(position), let id = selectedPatternID,
           let pattern = document.pattern(id), case var .parametric(rule, _) = pattern.kind {
            let unit = Double(value)
            switch position {
            case 0:
                let waves = ParametricWaveform.allCases
                rule.waveform = waves[min(Int(unit * Double(waves.count)), waves.count - 1)]
            case 1: rule.cyclesPerPattern = 0.25 + (8 - 0.25) * unit
            case 2: rule.minValue = min(value, rule.maxValue)
            case 3: rule.maxValue = max(value, rule.minValue)
            case 4: rule.phase = unit
            case 5: rule.skew = unit * 2 - 1
            default: rule.steps = Int((unit * 32).rounded())
            }
            stageRule(rule, for: id)
            return true
        }
        capture?.knob(track: track, knob: seat, value: value,
                      at: elapsedAt(ProcessInfo.processInfo.systemUptime))
        return false
    }

    func stageRule(_ rule: ParametricRule, for id: String) {
        guard let pattern = document.pattern(id), case let .parametric(previous, _) = pattern.kind,
              previous != rule else { return }
        pendingRules[id] = rule
        install(document)
        rulesSave?.cancel()
        rulesSave = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(180)) }
            catch { return }
            self?.flushEdits()
        }
    }

    func flushEdits() {
        do { try saveRules() }
        catch { report(error) }
    }

    private func saveRules() throws {
        guard !pendingRules.isEmpty else { return }
        let changes = pendingRules
        try store.update { story in
            for index in story.patterns.indices {
                if let rule = changes[story.patterns[index].id],
                   case let .parametric(_, points) = story.patterns[index].kind {
                    story.patterns[index].kind = .parametric(rule: rule, points: points)
                }
            }
        }
        pendingRules.removeAll()
        install(store.document)
    }

    private func elapsedAt(_ time: Double) -> Double {
        max(0, captureElapsed + (time - lastTick) * bpm / 60)
    }

    private var bpm: Double {
        let value = tempo()
        return value.isFinite && value > 0 ? value : 120
    }

    private func syncClock(advancesPlayback: Bool = true) {
        let now = ProcessInfo.processInfo.systemUptime
        let delta = lastTick == 0 ? 0 : (now - lastTick) * bpm / 60
        lastTick = now
        if isRecording {
            captureElapsed += delta
            if let captureEnd, captureElapsed >= captureEnd { finishCapture() }
        }
        if isPlaying, advancesPlayback { advance(by: delta) }
    }

    private func checkForExternalChanges() {
        // Polling can see malformed JSON mid-write. Keep the last valid document.
        do {
            if try store.reloadIfChanged() {
                install(store.document)
                try saveCapture()
                message = nil
            }
        } catch {
            let description = error.localizedDescription
            if message != description { message = description }
        }
    }

    private func finishCapture() {
        guard let capture else { return }
        unsavedCapture = (capture, min(captureElapsed, captureEnd ?? captureElapsed))
        self.capture = nil
        captureEnd = nil
        isRecording = false
        updateClockTimer()
        recordingChanged(false)
        do { try saveCapture() }
        catch { report(error) }
    }

    private func saveCapture() throws {
        guard var pending = unsavedCapture else { return }
        try saveRules()
        let ids = try store.update { pending.take.commit(to: &$0, elapsed: pending.elapsed) }
        unsavedCapture = nil
        install(store.document)
        if let id = ids.first { selectedPatternID = id }
    }

    func advance(by beats: Double) {
        guard isPlaying, beats.isFinite, beats >= 0, timeline.totalBeats > 0 else { return }
        var remaining = beats
        while remaining >= timeline.totalBeats - currentBeat {
            let end = timeline.totalBeats
            guard end > currentBeat else { endPlayback(); return }
            crossMIDIBoundaries(through: end)
            remaining -= end - currentBeat
            if !loop {
                currentBeat = end
                endPlayback()
                return
            }
            silence()
            currentBeat = 0
            applyMIDIVoices(timeline.resolve(atStoryBeat: 0).midi)
            // After a long sleep, skip whole missed iterations.
            if remaining >= end { remaining.formTruncatingRemainder(dividingBy: end) }
        }
        let next = currentBeat + remaining
        crossMIDIBoundaries(through: next)
        if next != currentBeat { currentBeat = next }
        applyPosition()
    }

    private func crossMIDIBoundaries(through nextBeat: Double) {
        for boundary in timeline.midiChangeBeats(after: currentBeat, through: nextBeat) {
            applyMIDIVoices(timeline.resolve(atStoryBeat: boundary).midi)
        }
    }

    private func applyPosition() {
        let active = timeline.resolve(atStoryBeat: currentBeat)
        applyMIDIVoices(active.midi)
        for event in active.parameters { setParameter(event.trackIndex, event.knob, event.value) }
        updateAudio(active.audio, bpm)
    }

    private func applyMIDIVoices(_ active: [StoryResolution.MIDI]) {
        let next = Dictionary(grouping: active) { Pitch(track: $0.trackIndex, note: $0.note) }
        for pitch in Set(voices.keys).union(next.keys).sorted() {
            let before = voices[pitch, default: []]
            let after = next[pitch, default: []]
            let overlaps = before.contains { old in
                after.contains { $0.occurrenceID == old.occurrenceID && $0.eventIndex == old.eventIndex }
            }
            guard !overlaps else { continue }
            if !before.isEmpty { sendNote(pitch.track, pitch.note, 0) }
            if let event = after.last { sendNote(pitch.track, pitch.note, event.velocity) }
        }
        voices = next
    }

    private func endPlayback() {
        silence()
        isPlaying = false
        updateClockTimer()
    }

    private func silence() {
        applyMIDIVoices([])
        updateAudio([], bpm)
    }
}

@MainActor
final class StoryAudioOutput {
    private struct Voice {
        let node: AVAudioPlayerNode
        let clip: RawAudioClip
    }

    private var voices: [String: Voice] = [:]
    private var attempts: [String: RawAudioClip] = [:]

    func update(_ clips: [StoryResolution.Audio], bpm: Double, rack: InstrumentRack) {
        let engine = rack.engine
        let active = Set(clips.map(\.occurrenceID))
        attempts = attempts.filter { active.contains($0.key) }
        for id in Array(voices.keys) where !active.contains(id) {
            remove(id, from: engine)
        }
        for event in clips {
            guard rack.slots.indices.contains(event.trackIndex) else { continue }
            if let voice = voices[event.occurrenceID], voice.clip != event.clip {
                remove(event.occurrenceID, from: engine)
            }
            if voices[event.occurrenceID] == nil, engine.isRunning, attempts[event.occurrenceID] != event.clip {
                attempts[event.occurrenceID] = event.clip
                play(event, bpm: bpm, engine: engine)
            }
            let node = voices[event.occurrenceID]?.node
            let track = rack.slots[event.trackIndex]
            node?.volume = track.effectiveGain
            node?.pan = track.pan
        }
    }

    private func play(_ event: StoryResolution.Audio, bpm: Double, engine: AVAudioEngine) {
        guard let path = event.clip.filePath,
              let file = try? AVAudioFile(forReading: URL(fileURLWithPath: path)) else { return }
        let frame = event.localBeat * 60 / bpm * file.processingFormat.sampleRate
        guard frame >= 0, frame < Double(file.length) else { return }
        let start = AVAudioFramePosition(frame)
        let count = AVAudioFrameCount(min(file.length - start, Int64(UInt32.max)))
        let node = AVAudioPlayerNode()
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: file.processingFormat)
        node.scheduleSegment(file, startingFrame: start, frameCount: count, at: nil)
        node.play()
        voices[event.occurrenceID] = Voice(node: node, clip: event.clip)
    }

    private func remove(_ id: String, from engine: AVAudioEngine) {
        guard let voice = voices.removeValue(forKey: id) else { return }
        voice.node.stop()
        engine.detach(voice.node)
    }
}

extension ParametricRule {
    var knobPositions: [Double] {
        let waves = ParametricWaveform.allCases
        let wave = (Double(waves.firstIndex(of: waveform) ?? 0) + 0.5) / Double(waves.count)
        return [wave, min(max((cyclesPerPattern - 0.25) / 7.75, 0), 1), Double(minValue), Double(maxValue),
                phase, (skew + 1) / 2, Double(steps) / 32]
    }
}
