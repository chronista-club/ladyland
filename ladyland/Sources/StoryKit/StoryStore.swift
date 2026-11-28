import AVFoundation
import Darwin
import Foundation

package final class StoryStore {
    package static let defaultURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/ladyland/story.json")

    package let url: URL
    package private(set) var document = StoryDocument.starter
    private var data: Data?

    package init(url: URL = StoryStore.defaultURL) {
        self.url = url
    }

    @discardableResult
    package func reloadIfChanged() throws -> Bool {
        let contents = try read()
        guard contents != data else { return false }
        document = try decode(contents)
        data = contents
        return true
    }

    // Re-read under a lock shared by Ladyland and RigBench. Atomic replacement
    // keeps file readers (including editors that do not take the lock) consistent.
    @discardableResult
    package func update<T>(_ change: (inout StoryDocument) throws -> T) throws -> T {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fd = open(url.appendingPathExtension("lock").path, O_RDWR | O_CREAT, 0o600)
        guard fd >= 0 else { throw failure() }
        defer { close(fd) }
        while flock(fd, LOCK_EX) != 0 {
            if errno != EINTR { throw failure() }
        }
        // Closing the descriptor releases the lock, including on decode/write failure.
        let currentData = try read()
        var next = try decode(currentData)
        let result = try change(&next)
        try next.validate()
        let encoded = try Self.encoder().encode(next)
        if encoded != currentData { try encoded.write(to: url, options: .atomic) }
        document = next
        data = encoded
        return result
    }

    package static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private func read() throws -> Data? {
        do { return try Data(contentsOf: url) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
    }

    private func decode(_ bytes: Data?) throws -> StoryDocument {
        guard let bytes else { return .starter }
        let decoded = try JSONDecoder().decode(StoryDocument.self, from: bytes)
        try decoded.validate()
        return decoded
    }

    private func failure() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
}

extension StoryDocument {
    fileprivate func validate() throws {
        guard Set(patterns.map(\.id)).count == patterns.count,
              Set(steps.map(\.id)).count == steps.count,
              Set(overrides.map(\.id)).count == overrides.count else {
            throw StoryCLI.Error("Pattern, Step, and Override IDs must be unique within their lists.")
        }
        for pattern in patterns {
            guard (0..<Self.trackCount).contains(pattern.trackIndex),
                  pattern.lengthBeats.isFinite, pattern.lengthBeats > 0 else {
                throw StoryCLI.Error("Invalid track or beat length for pattern \(pattern.id).")
            }
            switch pattern.kind {
            case let .midi(notes):
                guard notes.allSatisfy({
                    $0.beat >= 0 && $0.beat < pattern.lengthBeats && $0.durationBeats > 0
                        && ($0.beat + $0.durationBeats).isFinite && $0.note < 128 && (1...127).contains($0.velocity)
                }) else { throw StoryCLI.Error("Invalid note in pattern \(pattern.id).") }
            case let .parametric(rule, points):
                guard (0..<Self.knobCount).contains(rule.knob), rule.cyclesPerPattern > 0,
                      rule.cyclesPerPattern.isFinite, (0...1).contains(rule.minValue),
                      (rule.minValue...1).contains(rule.maxValue), (0...1).contains(rule.phase),
                      (-1...1).contains(rule.skew), (0...32).contains(rule.steps),
                      points.allSatisfy({
                          (0...pattern.lengthBeats).contains($0.beat) && (0...1).contains($0.value)
                      }) else { throw StoryCLI.Error("Invalid parametric rule or point in pattern \(pattern.id).") }
            case let .rawAudio(clip):
                guard clip.durationSeconds >= 0, clip.durationSeconds.isFinite,
                      clip.peaks.allSatisfy({ (0...1).contains($0) }) else {
                    throw StoryCLI.Error("Invalid audio clip in pattern \(pattern.id).")
                }
            }
        }
        let lengths = Dictionary(uniqueKeysWithValues: patterns.map { ($0.id, $0.lengthBeats) })
        var storyLength = 0.0
        for step in steps {
            guard let length = lengths[step.patternID] else {
                throw StoryCLI.Error("Unknown pattern \(step.patternID).")
            }
            storyLength += length
        }
        guard storyLength.isFinite, overrides.allSatisfy({
            lengths[$0.overridePatternID] != nil && $0.startBeat >= 0
                && $0.lengthBeats > 0 && ($0.startBeat + $0.lengthBeats).isFinite
        }) else { throw StoryCLI.Error("Invalid Story length, override range or pattern reference.") }
    }
}

extension RawAudioClip {
    package static func load(_ url: URL) throws -> RawAudioClip {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let totalFrames = file.length
        let rate = file.processingFormat.sampleRate
        guard totalFrames > 0, rate > 0, let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat, frameCapacity: 8192
        ) else { throw StoryCLI.Error("The clip contains no readable audio.") }
        var peaks = Array(repeating: Float(0), count: 128)
        var offset: AVAudioFramePosition = 0
        while offset < totalFrames {
            try file.read(into: buffer, frameCount: AVAudioFrameCount(min(8192, totalFrames - offset)))
            let count = Int(buffer.frameLength)
            guard count > 0, let channels = buffer.floatChannelData else { break }
            for frame in 0..<count {
                let bin = min(peaks.count - 1, Int(Double(offset + Int64(frame)) / Double(totalFrames) * Double(peaks.count)))
                for channel in 0..<Int(buffer.format.channelCount) {
                    let peak = abs(channels[channel][frame])
                    if peak.isFinite { peaks[bin] = max(peaks[bin], min(peak, 1)) }
                }
            }
            offset += Int64(count)
        }
        return RawAudioClip(filePath: url.standardizedFileURL.path, durationSeconds: Double(offset) / rate, peaks: peaks)
    }
}
