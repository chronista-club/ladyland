//! **render の 1 ブロックあたりのコストを測る**（mako 裁定 2026-08-06
//! 「まず計測してから決める」）。
//!
//! ## なぜ 192kHz を測るのか
//!
//! 本番リグは Zenith 2 / **192kHz** / 32bit。44.1kHz の 4.35 倍なので、
//! 毎サンプルにぶら下がる固定費が全部 4.35 倍で効き、**バッファあたりの
//! 締切は 1/4.35 になる**。
//!
//! | frameCount | 192kHz の締切 | 44.1kHz の締切 |
//! |---|---|---|
//! | 128 | 0.67ms | 2.90ms |
//! | 256 | 1.33ms | 5.80ms |
//! | 512 | 2.67ms | 11.61ms |
//!
//! ## 回し方
//!
//! ```bash
//! LADYLAND_BENCH=1 swift test -c release --filter "render ベンチ"
//! ```
//!
//! ⚠️ **環境変数が無いと丸ごと skip する**。普段の `swift test` を重くしない
//! ため（ベンチは秒単位で回る）。
//!
//! ⚠️ **`-c release` でしか意味が無い**。CLAUDE.md の「debug は負荷余裕が
//! 別物」どおり、debug の数字を根拠にしてはいけない。
//!
//! ## 測り方
//!
//! - **最悪ケース**で測る: sampler = 8 pad 全部再生中 / synth = 16 voice 全部発音中
//! - ウォームアップを捨ててから統計を取る（初回は確保とページフォルトが乗る）
//! - 出すのは**中央値と最大**。平均は外れ値に引きずられて締切の判断に使えない

import AVFoundation
import Testing

@testable import Ladyland

/// 1 条件ぶんの計測結果
private struct BenchResult {
    let label: String
    let rate: Double
    let frameCount: Int
    let medianNs: UInt64
    let maxNs: UInt64

    /// このブロックを出し切るまでの締切（ns）
    var deadlineNs: Double { Double(frameCount) / rate * 1_000_000_000 }

    /// 締切に対する占有率（中央値ベース）
    var medianLoad: Double { Double(medianNs) / deadlineNs * 100 }

    /// 締切に対する占有率（最大ベース）— **ここが 100% を超えるとドロップする**
    var maxLoad: Double { Double(maxNs) / deadlineNs * 100 }

    var row: String {
        String(
            format: "| %@ | %.0f | %d | %@ | %@ | %.1f%% | %.1f%% |",
            label, rate, frameCount,
            BenchResult.us(medianNs), BenchResult.us(maxNs), medianLoad, maxLoad)
    }

    private static func us(_ ns: UInt64) -> String {
        String(format: "%.2fus", Double(ns) / 1000)
    }
}

/// 計測の土台。**確保は測る前に済ませる**
private struct Bench {
    /// 捨てる回数（確保・ページフォルト・分岐予測の暖機）
    static let warmup = 200
    /// 測る回数
    static let iterations = 500

    /// `block` を繰り返し呼んで ns の中央値と最大を返す
    static func measure(
        label: String, rate: Double, frameCount: Int,
        _ block: (AUAudioFrameCount, UnsafeMutablePointer<AudioBufferList>) -> Void
    ) -> BenchResult {
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
        let buffer = AVAudioPCMBuffer(
            pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount))!
        buffer.frameLength = AVAudioFrameCount(frameCount)
        let list = buffer.mutableAudioBufferList
        let frames = AVAudioFrameCount(frameCount)

        for _ in 0..<warmup { block(frames, list) }

        // 測定値の入れ物は**測る前に**確保する
        var samples = [UInt64](repeating: 0, count: iterations)
        for index in 0..<iterations {
            let start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            block(frames, list)
            samples[index] = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - start
        }

        samples.sort()
        return BenchResult(
            label: label, rate: rate, frameCount: frameCount,
            medianNs: samples[iterations / 2], maxNs: samples[iterations - 1])
    }
}

@Suite(
    "render ベンチ",
    .enabled(if: ProcessInfo.processInfo.environment["LADYLAND_BENCH"] != nil))
struct RenderBenchTests {
    static let rates: [Double] = [192000, 44100]
    static let frameCounts = [128, 256, 512]

    // MARK: - 素材

    /// 指定レート・長さの WAV を temp に書く（`loadSample` の実経路を通す）
    private func makeSampleFile(frames: Int, rate: Double) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("bench-\(UUID().uuidString).wav")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = try #require(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        buffer.frameLength = AVAudioFrameCount(frames)
        if let channel = buffer.floatChannelData {
            // 0 埋めだと分岐予測が現実離れするので、実際の波形に近い値を入れる
            for frame in 0..<frames {
                channel[0][frame] = Float(sin(Double(frame) * 0.01)) * 0.5
            }
        }
        try file.write(from: buffer)
        return url
    }

    private func makeSampler() throws -> LadySampler {
        var description = AudioComponentDescription()
        description.componentType = kAudioUnitType_MusicDevice
        description.componentSubType = LadySampler.componentSubType
        description.componentManufacturer = LadySampler.componentManufacturer
        return try LadySampler(componentDescription: description)
    }

    private func makeSynth() throws -> LadySynth {
        var description = AudioComponentDescription()
        description.componentType = kAudioUnitType_MusicDevice
        description.componentSubType = LadySynth.componentSubType
        description.componentManufacturer = LadySynth.componentManufacturer
        return try LadySynth(componentDescription: description)
    }

    // MARK: - A-1: サンプラー（8 pad 全部再生中）

    @Test("Lady Sampler — 8 pad 同時再生")
    func samplerWorstCase() throws {
        var results: [BenchResult] = []

        for rate in Self.rates {
            for frameCount in Self.frameCounts {
                // **測る回数ぶん鳴り続ける長さ**を用意する（途中で止まると
                // 0 本再生を測ってしまい、最悪ケースにならない）。
                // ファイルのレートを出力に合わせて歩幅 1.0 にし、余裕を 2 倍取る
                let needed = (Bench.warmup + Bench.iterations) * frameCount * 2
                let url = try makeSampleFile(frames: needed, rate: rate)
                defer { try? FileManager.default.removeItem(at: url) }

                let sampler = try makeSampler()
                // エンジンのレートを動かすのは本番と同じ経路（出力バスの形式）。
                // **素材はここへ変換されて持たれる**ので、歩幅は常に 1
                let busFormat = try #require(
                    AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2))
                try sampler.outputBusses[0].setFormat(busFormat)
                sampler.refreshEngineRate()
                let midi = try #require(sampler.scheduleMIDIEventBlock)

                for pad in 0..<LadySampler.padCount {
                    try sampler.loadSample(slot: pad, url: url)
                    sampler.setGain(slot: pad, value: 0.8)
                    // 上段 pad1-4 = Note 40-43 / 下段 pad5-8 = Note 36-39
                    let note = UInt8(pad < 4 ? 40 + pad : 36 + (pad - 4))
                    var on: [UInt8] = [0x90, note, 100]
                    midi(0, 0, 3, &on)
                }
                // 8 席すべてが鳴っている状態から測る（最悪ケースの確認）
                #expect(sampler.padStates().allSatisfy { $0.isPlaying })

                let render = sampler.internalRenderBlock
                var flags = AudioUnitRenderActionFlags()
                var timestamp = AudioTimeStamp()
                results.append(
                    Bench.measure(
                        label: "sampler×8", rate: rate, frameCount: frameCount
                    ) { frames, list in
                        _ = render(&flags, &timestamp, frames, 0, list, nil, nil)
                    })

                // 測り終えた時点でもまだ鳴っていること = 最悪ケースを測れていた
                #expect(sampler.padStates().allSatisfy { $0.isPlaying })
            }
        }

        Self.report("Lady Sampler（8 pad 同時再生）", results)
    }

    // MARK: - A-2: シンセ（16 voice 全部発音中）

    @Test("Lady MPE — 16 voice 同時発音")
    func synthWorstCase() throws {
        var results: [BenchResult] = []

        for rate in Self.rates {
            for frameCount in Self.frameCounts {
                let synth = try makeSynth()
                // ⚠️ `outputBus` の format は init で 44.1kHz 固定なので、
                // **測る前にレートを差し替えて確保し直す**
                let format = try #require(
                    AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2))
                try synth.outputBusses[0].setFormat(format)
                try synth.allocateRenderResources()
                defer { synth.deallocateRenderResources() }

                let midi = try #require(synth.scheduleMIDIEventBlock)
                for channel in 0..<16 {
                    // 音程をばらす（同じ周波数だと分岐と位相が揃って現実離れする）
                    var on: [UInt8] = [0x90 | UInt8(channel), UInt8(48 + channel * 2), 100]
                    midi(0, 0, 3, &on)
                    var timbre: [UInt8] = [0xB0 | UInt8(channel), 74, 90]
                    midi(0, 0, 3, &timbre)
                }

                let render = synth.internalRenderBlock
                var flags = AudioUnitRenderActionFlags()
                var timestamp = AudioTimeStamp()
                results.append(
                    Bench.measure(
                        label: "synth×16", rate: rate, frameCount: frameCount
                    ) { frames, list in
                        _ = render(&flags, &timestamp, frames, 0, list, nil, nil)
                    })
            }
        }

        Self.report("Lady MPE（16 voice 同時発音）", results)
    }

    // MARK: - 出力

    /// ⚠️ **Markdown の表で出す**。数字は報告に貼られて mako が判断に使うので、
    /// そのまま貼れる形にしておく
    private static func report(_ title: String, _ results: [BenchResult]) {
        var out = "\n### \(title)\n\n"
        out += "| 対象 | rate | frames | 中央値 | 最大 | 占有率(中央) | 占有率(最大) |\n"
        out += "|---|---|---|---|---|---|---|\n"
        for result in results { out += result.row + "\n" }
        print(out)
    }
}
