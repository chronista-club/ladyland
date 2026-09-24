//! **自作の MPE シンセ**（mako 要望 2026-08-05「MPE 対応の自作のプラグインを
//! 一つ作って、Ladyland のトラックとして動かしたい」）。
//!
//! ## なぜ AUv3 拡張にしないのか
//!
//! AUv3 は App Extension なので、配布用の別ターゲット・Info.plist・
//! サンドボックスの作法が要る。**プロセス内に登録するだけなら
//! `AUAudioUnit.registerSubclass` で済む** — 既存のカタログ
//! （`AVAudioUnitComponentManager`）にそのまま並び、他のプラグインと
//! 同じ経路でスロットに載る。まず小さく試す（mako 裁定）ので後者を取る。
//!
//! ## MPE のかたち
//!
//! MPE（MIDI Polyphonic Expression）は**ノートごとに MIDI チャンネルを割り当てる**。
//! Keystage の AT Mode を MPE にすると:
//!
//! | | |
//! |---|---|
//! | ch1 | Master — 全体にかかる PB / CC |
//! | ch2-16 | 1 鍵につき 1 チャンネル。押すたびに順に配られる |
//! | Pitch Bend | **その鍵だけ**曲がる（普通は ±48 半音） |
//! | Channel Pressure | **その鍵だけ**の圧力 |
//! | CC74 | **その鍵だけ**の音色（明るさ） |
//!
//! だから「チャンネルごとに 1 ボイス」を持てば、そのまま MPE になる。
//! 普通の MIDI（全部 ch1）でも動く — その場合 1 音しか出ないが、
//! **まず音が出ることを確かめる**段階なのでよしとする。

import AVFoundation
import AppKit
import Foundation
import SwiftUI

/// 1 ボイス（= 1 チャンネル）の状態。
/// **レンダースレッドから触る** — Swift の参照型を避けて構造体で持つ
private struct Voice {
    var note: UInt8 = 0
    var velocity: Double = 0
    /// 鍵ごとのピッチベンド（-1...1）。MPE では ±48 半音が既定
    var bend: Double = 0
    /// 鍵ごとの圧力（0...1）
    var pressure: Double = 0
    /// 鍵ごとの音色（CC74。0...1）
    var timbre: Double = 0.5
    /// 位相（0...1 を回す）
    var phase: Double = 0
    /// 音量エンベロープの現在値（クリックを避けるため一次遅れで追う）
    var envelope: Double = 0
    var isOn = false
}

/// MPE 対応のシンプルなシンセ。
///
/// 波形はノコギリ（倍音があるとフィルタと表情が分かりやすい）。
/// フィルタは 1 次のローパス — **CC74 と圧力で開く**のが MPE の定石。
final class LadySynth: AUAudioUnit, @unchecked Sendable {
    /// AudioComponent の素性。**カタログに出る名前はここで決まる**
    static let componentSubType: OSType = 0x6C647973  // 'ldys'
    static let componentManufacturer: OSType = 0x4348524E  // 'CHRN'（chronista）
    static let displayName = "Lady MPE"

    /// MPE のピッチベンド幅（半音）。仕様の既定は ±48
    static let bendRangeSemitones = 48.0

    /// ch1 = Master、ch2-16 = ノート。配列は 16 個持って添字をチャンネルにする
    private var voices = [Voice](repeating: Voice(), count: 16)
    /// レンダーとメインの往復を避けるためのロック。
    /// **MIDI は scheduleMIDIEventBlock 経由でレンダースレッドに届く**ので
    /// 実際には同じスレッドだが、AU の実装によっては別スレッドから来る
    private let lock = NSLock()

    private var sampleRate: Double = 44100

    private var outputBus: AUAudioUnitBus
    private var busArray: AUAudioUnitBusArray!

    override init(
        componentDescription: AudioComponentDescription,
        options: AudioComponentInstantiationOptions = []
    ) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
        outputBus = try AUAudioUnitBus(format: format)
        try super.init(componentDescription: componentDescription, options: options)
        busArray = AUAudioUnitBusArray(
            audioUnit: self, busType: .output, busses: [outputBus])
    }

    override var outputBusses: AUAudioUnitBusArray { busArray }

    override func allocateRenderResources() throws {
        try super.allocateRenderResources()
        refreshEngineRate()
    }

    /// **出力バスの形式を読み直す**（`EngineRateFollowing`。実測 2026-08-07）。
    ///
    /// ⚠️ `engine.stop()` → `start()` では **`allocateRenderResources` が
    /// 呼ばれ直さない**ので、デバイスを切り替えてもここは古いレートのままになる。
    /// ホストが節目で呼ぶ。
    ///
    /// ⚠️ **`inverseRate` も `follow` も `increment` も持たない** — 全部
    /// render のたびに `sampleRate` から作り直しているので、ここを更新すれば
    /// 次のブロックから正しくなる（`EngineRateFollowing` の doc に表がある）
    func refreshEngineRate() {
        lock.lock()
        defer { lock.unlock() }
        let next = outputBus.format.sampleRate
        guard next > 0 else { return }
        sampleRate = next
    }

    /// **鳴っているボイスを切る**（`EngineRateFollowing`）。
    ///
    /// ⚠️ **エンベロープを 0 にせず `isOn` だけ折る** — 次の render で
    /// 5ms かけて落ちるので、**プチッと言わずに消える**。
    /// ⚠️ **位相はそのまま** — 0 に戻すと波形の途中で段差ができて、
    /// 消え際にかえってノイズが乗る
    func silenceForRateChange() {
        lock.lock()
        defer { lock.unlock() }
        for index in voices.indices { voices[index].isOn = false }
    }

    // MARK: - 画面へ渡す読み取り口

    /// 1 ボイスの見え方（**値のコピー**。画面はこれだけを見る）。
    ///
    /// ⚠️ **`Voice` をそのまま出さない** — あれはレンダースレッドが毎サンプル
    /// 触る構造体で、画面に渡すと「表示のために中身を読む」経路ができる。
    /// 値型のコピーで切っておけば、あとで `Voice` の持ち物が変わっても画面は壊れない
    struct VoiceState: Equatable, Identifiable {
        /// MIDI チャンネル 1-16（MPE では 1 = Master、2-16 が鍵ごと）
        let channel: Int
        let note: UInt8
        let velocity: Double
        /// -1...1（`bendRangeSemitones` を掛けると半音）
        let bend: Double
        let pressure: Double
        /// CC74（0...1、既定 0.5）
        let timbre: Double
        /// 音量エンベロープの現在値。**鳴り終わりの減衰中もここに出る**
        let envelope: Double
        let isOn: Bool

        var id: Int { channel }

        /// ⚠️ **鳴っていなくても減衰中なら「生きている」** — 画面で沈めるかの判定
        var isAudible: Bool { isOn || envelope > 0.0001 }

        /// ベンド後の実音（半音）。表示用に音名へ落とすときの元
        var bentSemitones: Double {
            Double(note) + bend * LadySynth.bendRangeSemitones
        }
    }

    /// **16 ボイスを ロック 1 回**でまとめて読む（`LadySampler.padStates()` と同じ作法）。
    ///
    /// ⚠️ **レンダースレッドには何も足していない。** ここは main（描画）から
    /// 呼ばれ、既存の `lock` を短く取るだけ — 確保はロックの外で済ませる
    func voiceStates() -> [VoiceState] {
        var states = [VoiceState]()
        states.reserveCapacity(voices.count)
        lock.lock()
        for (index, voice) in voices.enumerated() {
            states.append(
                VoiceState(
                    channel: index + 1, note: voice.note, velocity: voice.velocity,
                    bend: voice.bend, pressure: voice.pressure, timbre: voice.timbre,
                    envelope: voice.envelope, isOn: voice.isOn))
        }
        lock.unlock()
        return states
    }

    /// **いまエンジンが回っているレート**（画面に出す）。
    ///
    /// ⚠️ **2026-08-07 に丸 1 日「synth だけ 44100 のまま」で音程が 4.35 倍
    /// ずれていた**（`d130658` で修正）。画面に出ていれば即座に分かった
    var engineRate: Double {
        lock.lock()
        defer { lock.unlock() }
        return sampleRate
    }

    // MARK: - MIDI

    /// ホストからの MIDI をこのブロックで受ける。
    /// **レンダースレッドから呼ばれる** — 確保・解放をしないこと
    override var scheduleMIDIEventBlock: AUScheduleMIDIEventBlock? {
        { [weak self] _, _, count, bytes in
            guard let self, count > 0 else { return }
            let status = bytes[0]
            let channel = Int(status & 0x0F)
            let kind = status & 0xF0
            let data1 = count > 1 ? bytes[1] : 0
            let data2 = count > 2 ? bytes[2] : 0
            self.handleMIDI(kind: kind, channel: channel, data1: data1, data2: data2)
        }
    }

    private func handleMIDI(kind: UInt8, channel: Int, data1: UInt8, data2: UInt8) {
        lock.lock()
        defer { lock.unlock() }
        switch kind {
        case 0x90 where data2 > 0:
            voices[channel].note = data1
            voices[channel].velocity = Double(data2) / 127
            voices[channel].isOn = true
            // ⚠️ 位相はリセットしない — 同じチャンネルで鍵を替えたときに
            // プチッと鳴るのを避ける（MPE では 1 チャンネル 1 鍵なので稀だが）
        case 0x80, 0x90:  // Note Off（0x90 で velocity 0 も含む）
            if voices[channel].note == data1 { voices[channel].isOn = false }
        case 0xD0:  // Channel Pressure — MPE では「その鍵の圧力」
            voices[channel].pressure = Double(data1) / 127
        case 0xA0:  // Poly Pressure（非 MPE の鍵盤から）
            if voices[channel].note == data1 {
                voices[channel].pressure = Double(data2) / 127
            }
        case 0xE0:  // Pitch Bend — MPE では「その鍵だけ」曲がる
            let raw = Int(data2) << 7 | Int(data1)
            voices[channel].bend = (Double(raw) - 8192) / 8192
        case 0xB0 where data1 == 74:  // CC74 = 音色（MPE の第 3 次元）
            voices[channel].timbre = Double(data2) / 127
        case 0xB0 where data1 == 123 || data1 == 120:  // All Notes/Sound Off
            for i in voices.indices { voices[i].isOn = false }
        default:
            break
        }
    }

    // MARK: - レンダー

    override var internalRenderBlock: AUInternalRenderBlock {
        { [weak self] _, _, frameCount, _, outputData, _, _ in
            guard let self else { return kAudioUnitErr_NoConnection }
            // ⚠️ **入口で時刻を取る** — ロックの待ち時間も込みで測る
            // （`RenderStats` の説明。切り方もそこに書いてある）
            let start = RenderMetering.enabled ? clock_gettime_nsec_np(CLOCK_UPTIME_RAW) : 0
            return self.render(
                frameCount: frameCount, outputData: outputData, startNs: start)
        }
    }

    /// 控え（**加算と max だけ** — 確保も割り算も文字化もしない）
    private var renderCalls: UInt64 = 0
    private var renderTotalNs: UInt64 = 0
    private var renderMaxNs: UInt64 = 0
    private var renderFrameCount: UInt32 = 0
    /// **出したフレームの累積**（実測レートの分子）。
    /// ⚠️ RT 経路に足したのは**この加算 1 つだけ**（`RenderStats` の説明）
    private var renderFrames: UInt64 = 0
    /// 前回ドレインした時刻。**実経過を測る**ため（0.5 秒と決め打ちしない）
    private var renderDrainedAt: UInt64 = 0

    /// ⚠️ **lock を持ったまま呼ぶこと**（`render` の defer から）
    private func recordRenderLocked(startNs: UInt64, frameCount: AUAudioFrameCount) {
        let elapsed = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - startNs
        renderCalls &+= 1
        renderTotalNs &+= elapsed
        if elapsed > renderMaxNs { renderMaxNs = elapsed }
        renderFrameCount = UInt32(frameCount)
        renderFrames &+= UInt64(frameCount)  // ← 実測レートの分子（加算 1 つ）
    }

    private func render(
        frameCount: AUAudioFrameCount, outputData: UnsafeMutablePointer<AudioBufferList>,
        startNs: UInt64
    ) -> AUAudioUnitStatus {
        let buffers = UnsafeMutableAudioBufferListPointer(outputData)
        for buffer in buffers {
            memset(buffer.mData, 0, Int(buffer.mDataByteSize))
        }

        lock.lock()
        // ⚠️ 控えるのは**ロックを持ったまま** — 取り直すと 1 ブロックに 2 回になる
        defer {
            if startNs != 0 { recordRenderLocked(startNs: startNs, frameCount: frameCount) }
            lock.unlock()
        }

        let inverseRate = 1 / sampleRate
        // エンベロープの追従速度（クリック回避。5ms 相当）
        let follow = min(1, 200 * inverseRate)

        for channel in voices.indices {
            // ⚠️ **ch1 でも鳴らす**（実測 2026-08-05: mako が Polyphonic のまま
            // 試したら無音だった）。
            //
            // MPE の仕様では ch1 は Master（全体にかかる操作の担当）で音を
            // 出さないが、**それを厳密に守ると非 MPE の鍵盤で完全に無音**になる。
            // 普通の MIDI は全部 ch1 に来るので、そこを捨てたら何も鳴らない。
            // 1 音しか出ない（同じチャンネルを使い回すため）が、
            // 「まず音が出る」ことの方が大事
            var voice = voices[channel]
            let target = voice.isOn ? voice.velocity : 0
            // 鳴っていないうえに減衰も終わっていれば飛ばす
            if !voice.isOn && voice.envelope < 0.0001 { continue }

            let bendSemitones = voice.bend * Self.bendRangeSemitones
            let frequency = 440 * pow(2, (Double(voice.note) + bendSemitones - 69) / 12)
            let increment = frequency * inverseRate
            // **圧力と CC74 で明るさを変える** — MPE の表情はここに乗る。
            // 素のノコギリから、倍音を削った丸い音までを行き来する
            let brightness = min(1, 0.15 + voice.timbre * 0.6 + voice.pressure * 0.5)

            for frame in 0..<Int(frameCount) {
                voice.envelope += (target - voice.envelope) * follow
                // ノコギリ（-1...1）
                let saw = voice.phase * 2 - 1
                // 1 次ローパス相当 — 位相の進みに対する追従を brightness で絞る
                let sample = saw * brightness + (1 - brightness) * sin(voice.phase * 2 * .pi)
                let value = Float(sample * voice.envelope * 0.2)
                for buffer in buffers {
                    guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else {
                        continue
                    }
                    data[frame] += value
                }
                voice.phase += increment
                if voice.phase >= 1 { voice.phase -= 1 }
            }
            voices[channel] = voice
        }
        return noErr
    }

    // MARK: - 画面

    /// **自作 AU に画面を持たせる**（`LadySampler` と同じ作法。新しい仕組みを
    /// 作らない — 既存の `PluginEditorWindows` の窓にそのまま乗る）。
    ///
    /// ⚠️ **幅は 440pt に揃える**。`ContentView` が「サンプラーの画面が 440pt
    /// 前提」で組んであるので、違えると窓のレイアウトが崩れる。
    ///
    /// ⚠️ **縦は 16 行ぶんの実測**（400pt）。実ウィンドウに出して撮ったところ
    /// 460pt では 85pt 余っていた — 余白は「まだ何か出るのでは」と読ませるので詰める
    override func requestViewController(
        completionHandler: @escaping (NSViewController?) -> Void
    ) {
        Task { @MainActor in
            let controller = NSHostingController(
                rootView: ThemedRoot { LadySynthView(synth: self) })
            controller.preferredContentSize = NSSize(width: 440, height: 400)
            // ⚠️ **SwiftUI にサイズの制約を張らせない**（実測 2026-09-23、スタジオで
            // トラック切替のたびに落ちた）。既定だと最小・最大サイズが制約になり、
            // focus pane の frame / bounds 縮小とぶつかって窓のレイアウトが収束しない
            // （NSGenericException: Update Constraints in Window）。大きさは
            // preferredContentSize と focus pane の fit が決める
            controller.sizingOptions = []
            completionHandler(controller)
        }
    }

    // MARK: - 登録

    /// **プロセス内に登録する**（起動時に一度）。
    /// これで `AVAudioUnitComponentManager` の列挙に出て、
    /// 既存のカタログからそのまま選べるようになる
    static func register() {
        var description = AudioComponentDescription()
        description.componentType = kAudioUnitType_MusicDevice
        description.componentSubType = componentSubType
        description.componentManufacturer = componentManufacturer
        description.componentFlags = 0
        description.componentFlagsMask = 0
        AUAudioUnit.registerSubclass(
            LadySynth.self,
            as: description,
            name: displayName,
            version: 1)
    }
}

// MARK: - 計測

extension LadySynth: RenderMetered {
    var meteredName: String { "synth" }

    /// 控えを読んで**即クリア**する（`LadySampler` と同じ作法）
    func drainRenderStats() -> RenderStats? {
        // ⚠️ **実経過を測る**（`Timer` の 0.5 秒を信じない）。
        // ここがずれると実測レートがそのまま嘘になる
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)

        lock.lock()
        let calls = renderCalls
        let total = renderTotalNs
        let peak = renderMaxNs
        let frameCount = renderFrameCount
        let frames = renderFrames
        let rate = sampleRate
        let since = renderDrainedAt
        renderCalls = 0
        renderTotalNs = 0
        renderMaxNs = 0
        renderFrames = 0
        renderDrainedAt = now
        lock.unlock()

        guard calls > 0 else { return nil }
        return RenderStats(
            calls: calls, totalNs: total, maxNs: peak,
            frameCount: frameCount, sampleRate: rate,
            frames: frames,
            // 初回は基準が無いので実測しない（0 = measuredRate が nil になる）
            elapsedNs: since > 0 ? now - since : 0)
    }
}
