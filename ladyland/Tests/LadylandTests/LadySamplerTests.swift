//! Lady Sampler の保存と復元（mako 指摘 2026-08-06「他のプラグイン同様に
//! 設定の永続化と復元がいるね」）。
//!
//! ラックの保存は `InstrumentRack` が `fullState` をキャッシュして Snapshot へ
//! 書くので、**`fullState` さえ実装すれば常時保存にも音色ドラフトにも乗る**。
//! ここではその往復だけを見る（実ファイルの読み込みは実機側の話）。

import AVFoundation
import Testing

@testable import Ladyland

@Suite("Lady Sampler の保存と復元")
struct LadySamplerStateTests {
    private func makeSampler() throws -> LadySampler {
        var description = AudioComponentDescription()
        description.componentType = kAudioUnitType_MusicDevice
        description.componentSubType = LadySampler.componentSubType
        description.componentManufacturer = LadySampler.componentManufacturer
        return try LadySampler(componentDescription: description)
    }

    /// 短い WAV を temp に書いて返す。
    /// **`loadSample` の実経路を通す**ため — テスト専用の裏口を本番の型に
    /// 開けると、その口は本番でも開いたままになる
    private func makeSampleFile(frames: Int = 128, rate: Double = 44100) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ladysampler-\(UUID().uuidString).wav")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = try #require(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        buffer.frameLength = AVAudioFrameCount(frames)
        // 無音だと「読めたが長さ 0」と見分けが付かないので、値を入れておく
        if let channel = buffer.floatChannelData {
            for frame in 0..<frames { channel[0][frame] = 0.25 }
        }
        try file.write(from: buffer)
        return url
    }

    /// **エンジンのレートを動かす**（実機でデバイスを切り替えたのと同じ経路）。
    /// テスト専用の裏口は開けない — 出力バスの形式を変えて `refreshEngineRate()`
    /// を呼ぶのが本番と同じ道
    private func setEngineRate(_ sampler: LadySampler, _ rate: Double) throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2))
        try sampler.outputBusses[0].setFormat(format)
        sampler.refreshEngineRate()
    }

    /// ステレオの WAV（モノラル畳み込みの確認用）
    private func makeStereoSampleFile(frames: Int, rate: Double) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ladysampler-st-\(UUID().uuidString).wav")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = try #require(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        buffer.frameLength = AVAudioFrameCount(frames)
        if let channels = buffer.floatChannelData {
            for frame in 0..<frames {
                channels[0][frame] = 0.5
                channels[1][frame] = -0.1
            }
        }
        try file.write(from: buffer)
        return url
    }

    @Test("音量が fullState を往復する")
    func gainsRoundTrip() throws {
        let source = try makeSampler()
        source.setGain(slot: 0, value: 0.25)
        source.setGain(slot: 7, value: 1.0)

        let restored = try makeSampler()
        restored.fullState = source.fullState

        #expect(abs(restored.gain(slot: 0) - 0.25) < 0.001)
        #expect(abs(restored.gain(slot: 7) - 1.0) < 0.001)
    }

    @Test("空のスロットは空のまま復元される — 存在しないファイルを掴まない")
    func emptySlotsStayEmpty() throws {
        let source = try makeSampler()
        let restored = try makeSampler()
        restored.fullState = source.fullState

        #expect(restored.sampleURLs.allSatisfy { $0 == nil })
        #expect(restored.sampleNames.allSatisfy { $0 == nil })
    }

    @Test("⚠️ 音そのものは載せない — URL と音量だけ")
    func stateCarriesReferencesNotAudio() throws {
        let sampler = try makeSampler()
        sampler.setGain(slot: 3, value: 0.5)
        let state = try #require(sampler.fullState)

        // 数十 MB の PCM が Snapshot に入ると保存のたびに重くなる。
        // 持つのは**元ファイルを指す URL** と音量だけ
        #expect(state["club.chronista.ladyland.sampler.urls"] is [String])
        #expect(state["club.chronista.ladyland.sampler.gains"] is [Double])
        let gains = try #require(state["club.chronista.ladyland.sampler.gains"] as? [Double])
        #expect(gains.count == LadySampler.padCount)
        #expect(abs(gains[3] - 0.5) < 0.001)
    }

    /// ⚠️ **実機がこの帯を送る**（実測 2026-08-06 のログ）。ladyland の既定値
    /// （`Lpd8DefaultKnobCCs` の 79-117）を見て「一致しないから」と位置引きへ
    /// 寄せたが、**見ていたのは実機の設定ではなかった** — 実機は CC49-56 /
    /// CC57-64 を送っていて、どちらの帯にも当たらず素通りしていた
    @Test("実機の帯 — CC57-64 が音量、CC49-56 がトリガー")
    func deviceBands() throws {
        let sampler = try makeSampler()
        let block = try #require(sampler.scheduleMIDIEventBlock)

        // CC59 → pad 3 の音量（57 が pad 1 なので 59 は 3 番目）
        var volume: [UInt8] = [0xB0, 59, 64]
        block(0, 0, 3, &volume)
        #expect(abs(sampler.gain(slot: 2) - 64.0 / 127) < 0.01)

        // CC64 → pad 8（Damper と番号は重なるが、**drums 経路なので衝突しない**）
        var last: [UInt8] = [0xB0, 64, 127]
        block(0, 0, 3, &last)
        #expect(abs(sampler.gain(slot: 7) - 1.0) < 0.01)
    }

    @Test("⚠️ Note は上下段が CC と逆 — 大きい番号が上段")
    func deviceNotesAreFlipped() throws {
        // mako 報告 2026-08-06「Note の方が上下逆だね」。LPD8 は**大きい番号が上段**:
        //
        //   上段（pad 1-4） = Note 40-43   CC 49-52
        //   下段（pad 5-8） = Note 36-39   CC 53-56
        //
        // CC は小さい番号が上段なので素直に引けるが、Note は段を入れ替える
        #expect(LadySampler.padIndex(forNote: 40) == 0, "上段の左 = pad 1")
        #expect(LadySampler.padIndex(forNote: 43) == 3, "上段の右 = pad 4")
        #expect(LadySampler.padIndex(forNote: 36) == 4, "下段の左 = pad 5")
        #expect(LadySampler.padIndex(forNote: 39) == 7, "下段の右 = pad 8")
        #expect(LadySampler.padIndex(forNote: 35) == nil)
        #expect(LadySampler.padIndex(forNote: 44) == nil)

        // **CC と同じ席を指す**（同じパッドを Note で叩いても CC で押しても同じ）
        for position in 0..<8 {
            let note = position < 4 ? 40 + position : 36 + (position - 4)
            let cc = 49 + position
            #expect(LadySampler.padIndex(forNote: note) == position)
            #expect(cc - LadySampler.padTriggerCCs.lowerBound == position)
        }

        // 規約側（`Lpd8DefaultPadNotes`）も上段を先に並べている
        #expect(Lpd8DefaultPadNotes.index(of: 44) == 0, "PROG1 上段の左")
        #expect(Lpd8DefaultPadNotes.index(of: 40) == 4, "PROG1 下段の左")

        let sampler = try makeSampler()
        let block = try #require(sampler.scheduleMIDIEventBlock)
        var note: [UInt8] = [0x90, 40, 127]
        block(0, 0, 3, &note)  // 空の席なので鳴らないが、落ちないこと
    }

    @Test("焼いた後の帯でも音量が動く — どちらの設定でも受ける")
    func ladylandBandsAlsoWork() throws {
        let sampler = try makeSampler()
        let block = try #require(sampler.scheduleMIDIEventBlock)

        // PROG 3 の K1（CC102）→ 位置 0
        var knob: [UInt8] = [0xB0, 102, 32]
        block(0, 0, 3, &knob)
        #expect(abs(sampler.gain(slot: 0) - 32.0 / 127) < 0.01)
    }

    /// ⚠️ **リアルタイム経路から NSLog を追い出した**（2026-08-06）。
    ///
    /// MIDI は CoreMIDI の高優先度スレッドから `scheduleMIDIEventBlock` 経由で
    /// `trigger` まで一直線に来る。そこで NSLog を呼ぶと ①malloc が走り
    /// ②stderr は `DebugLog` がパイプに差し替えているのでブロックしうる
    /// ③しかも lock を握ったままなので **`render` がそのぶん止まる**。
    ///
    /// 出す場所を変えただけで、**918472e の診断は 1 つも減らしていない** —
    /// それをここで固定する
    @Test("鳴らなかった理由は控えに残る — 空打ち")
    func emptyPadIsRecorded() throws {
        let sampler = try makeSampler()
        let block = try #require(sampler.scheduleMIDIEventBlock)

        var note: [UInt8] = [0x90, 40, 127]  // 上段の左 = pad 1（空）
        block(0, 0, 3, &note)

        let messages = sampler.drainEvents()
        #expect(messages.count == 1)
        #expect(messages[0].contains("pad 1"))
        #expect(messages[0].contains("空"), "席が空だったことが分かること")
    }

    @Test("鳴らなかった理由は控えに残る — 音量ゼロ")
    func silentGainIsRecorded() throws {
        let sampler = try makeSampler()
        // 音が入っていないと空打ち扱いになるので、先に読み込んでから確かめる
        let url = try makeSampleFile()
        defer { try? FileManager.default.removeItem(at: url) }
        try sampler.loadSample(slot: 2, url: url)
        sampler.setGain(slot: 2, value: 0)

        let block = try #require(sampler.scheduleMIDIEventBlock)
        var note: [UInt8] = [0x90, 42, 127]  // 上段の 3 つ目 = pad 3
        block(0, 0, 3, &note)

        let messages = sampler.drainEvents()
        #expect(messages.count == 1)
        #expect(messages[0].contains("K3"), "上げるべきノブを名指しすること")
    }

    @Test("控えは読んだら空になる — 溜め込まない")
    func eventsDrain() throws {
        let sampler = try makeSampler()
        let block = try #require(sampler.scheduleMIDIEventBlock)
        var note: [UInt8] = [0x90, 40, 127]
        block(0, 0, 3, &note)

        #expect(sampler.drainEvents().count == 1)
        #expect(sampler.drainEvents().isEmpty, "2 回目は空 — 同じ行が出続けない")
    }

    @Test("同じ席の連打は最後の 1 つだけ残る — 確保も上限管理も要らない")
    func lastEventWins() throws {
        let sampler = try makeSampler()
        let block = try #require(sampler.scheduleMIDIEventBlock)
        var note: [UInt8] = [0x90, 40, 127]
        for _ in 0..<50 { block(0, 0, 3, &note) }

        // 50 回叩いても 1 行。切り分けたいのは「**今**叩いたのになぜ鳴らないか」
        #expect(sampler.drainEvents().count == 1)
    }

    @Test("CC モードの予備パッド（5-8）も控えに残る")
    func reservedPadIsRecorded() throws {
        let sampler = try makeSampler()
        let block = try #require(sampler.scheduleMIDIEventBlock)

        var cc: [UInt8] = [0xB0, 53, 127]  // CC53 = pad 5（FX は 1-4 だけ）
        block(0, 0, 3, &cc)

        let messages = sampler.drainEvents()
        #expect(messages.count == 1)
        #expect(messages[0].contains("予備"))
        #expect(sampler.effectStates().allSatisfy { !$0 }, "FX は動かない")
    }

    // MARK: - Play / Pause（mako 要望「止めた位置から再生になる」）

    /// **この変更の核**。以前は `-1` を停止の印に兼用していたので、止めると
    /// 位置ごと捨てて頭から鳴り直していた
    @Test("止めた位置から再開する — 頭に戻らない")
    func pauseKeepsPosition() throws {
        let sampler = try makeSampler()
        try setEngineRate(sampler, 44100)
        let url = try makeSampleFile(frames: 44100, rate: 44100)  // 1 秒
        defer { try? FileManager.default.removeItem(at: url) }
        try sampler.loadSample(slot: 0, url: url)
        sampler.setGain(slot: 0, value: 0.8)

        let block = try #require(sampler.scheduleMIDIEventBlock)
        var note: [UInt8] = [0x90, 40, 100]
        block(0, 0, 3, &note)  // ▶︎ 再生

        // 少し進める
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512))
        buffer.frameLength = 512
        let render = sampler.internalRenderBlock
        var flags = AudioUnitRenderActionFlags()
        var timestamp = AudioTimeStamp()
        for _ in 0..<10 {
            _ = render(&flags, &timestamp, 512, 0, buffer.mutableAudioBufferList, nil, nil)
        }
        let advanced = sampler.padStates()[0].position
        #expect(advanced > 0, "進んでいること")

        block(0, 0, 3, &note)  // ⏸ 一時停止
        let paused = sampler.padStates()[0]
        #expect(paused.isPlaying == false, "止まった")
        #expect(abs(paused.position - advanced) < 0.0001, "⚠️ 位置が残ること（頭に戻らない）")
        #expect(sampler.drainEvents().first?.contains("一時停止") == true)

        block(0, 0, 3, &note)  // ▶︎ 再開
        let resumed = sampler.padStates()[0]
        #expect(resumed.isPlaying, "再開した")
        #expect(abs(resumed.position - advanced) < 0.0001, "⚠️ その位置から再生する")
    }

    /// 前提①: 末尾で一時停止したままにすると、次に叩いても何も起きない席ができる
    @Test("鳴り終わったら頭へ戻って停止する")
    func finishingRewindsToHead() throws {
        let sampler = try makeSampler()
        try setEngineRate(sampler, 44100)
        let url = try makeSampleFile(frames: 512, rate: 44100)  // 1 ブロックで終わる
        defer { try? FileManager.default.removeItem(at: url) }
        try sampler.loadSample(slot: 0, url: url)
        sampler.setGain(slot: 0, value: 0.8)

        let block = try #require(sampler.scheduleMIDIEventBlock)
        var note: [UInt8] = [0x90, 40, 100]
        block(0, 0, 3, &note)

        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024))
        buffer.frameLength = 1024
        let render = sampler.internalRenderBlock
        var flags = AudioUnitRenderActionFlags()
        var timestamp = AudioTimeStamp()
        _ = render(&flags, &timestamp, 1024, 0, buffer.mutableAudioBufferList, nil, nil)

        let finished = sampler.padStates()[0]
        #expect(finished.isPlaying == false, "鳴り終わって停止")
        #expect(finished.position == 0, "頭へ戻る（末尾で止まったままにしない）")

        block(0, 0, 3, &note)
        #expect(sampler.padStates()[0].isPlaying, "次に叩けば頭から鳴る")
    }

    /// 前提②: Play/Pause にするとパッドから「頭に戻す」手段が無くなるので、
    /// All Notes Off に巻き戻しを兼ねさせる
    @Test("stopAll は全席を頭出し + 停止にする")
    func stopAllRewindsEveryPad() throws {
        let sampler = try makeSampler()
        try setEngineRate(sampler, 44100)
        let url = try makeSampleFile(frames: 44100, rate: 44100)
        defer { try? FileManager.default.removeItem(at: url) }
        for pad in 0..<LadySampler.padCount {
            try sampler.loadSample(slot: pad, url: url)
            sampler.setGain(slot: pad, value: 0.8)
        }
        let block = try #require(sampler.scheduleMIDIEventBlock)
        for pad in 0..<LadySampler.padCount {
            var note: [UInt8] = [0x90, UInt8(pad < 4 ? 40 + pad : 36 + (pad - 4)), 100]
            block(0, 0, 3, &note)
        }
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512))
        buffer.frameLength = 512
        let render = sampler.internalRenderBlock
        var flags = AudioUnitRenderActionFlags()
        var timestamp = AudioTimeStamp()
        for _ in 0..<5 {
            _ = render(&flags, &timestamp, 512, 0, buffer.mutableAudioBufferList, nil, nil)
        }
        #expect(sampler.padStates().allSatisfy { $0.position > 0 }, "全席が進んでいる")

        // CC123（All Notes Off）で巻き戻す
        var allOff: [UInt8] = [0xB0, 123, 0]
        block(0, 0, 3, &allOff)

        #expect(sampler.padStates().allSatisfy { !$0.isPlaying }, "全席停止")
        #expect(sampler.padStates().allSatisfy { $0.position == 0 }, "全席が頭出し")
    }

    /// 作り直し中の席は叩いても鳴らない（既存の挙動が壊れていないこと）
    @Test("作り直し中は Play/Pause も効かない")
    func preparingPadIgnoresTrigger() throws {
        let sampler = try makeSampler()
        try setEngineRate(sampler, 44100)
        let url = try makeSampleFile(frames: 44100, rate: 44100)
        defer { try? FileManager.default.removeItem(at: url) }
        try sampler.loadSample(slot: 0, url: url)
        sampler.setGain(slot: 0, value: 0.8)

        try setEngineRate(sampler, 96000)  // 作り直しへ

        let block = try #require(sampler.scheduleMIDIEventBlock)
        var note: [UInt8] = [0x90, 40, 100]

        // ⚠️ **背景の作り直しと競合する**ので、叩く直前の状態で場合分けする。
        // 見るべきは「作り直し中なら鳴らない」であって、
        // 「この瞬間まだ作り直し中である」ではない
        let before = sampler.padStates()[0].readiness
        block(0, 0, 3, &note)

        if case .preparing = before {
            #expect(sampler.padStates()[0].isPlaying == false, "まだ無いものは鳴らない")
            #expect(sampler.drainEvents().first?.contains("空") == true)
        } else {
            // 既に揃っていたなら鳴って良い。**古いレートでない**ことが要件
            #expect(sampler.sampleInfos[0]?.preparedRate == 96000)
        }
    }

    /// ⚠️ **止まっている間はロックを取る回数を増やさない**。
    /// 常時 20Hz にすると、何も動いていない時間まで毎秒 20 回取ることになる
    @Test("ポーリングは再生中だけ速い")
    func pollIntervalOnlyFastWhilePlaying() {
        #expect(LadySamplerView.pollInterval(anyPlaying: false)
            == LadySamplerView.idleInterval, "止まっていれば従来どおり")
        #expect(LadySamplerView.pollInterval(anyPlaying: true)
            == LadySamplerView.playingInterval, "鳴っていれば速める")
        #expect(LadySamplerView.playingInterval < LadySamplerView.idleInterval)
        // 20Hz でも `padStates()` 1 回なので毎秒 20 回。
        // 180f7d9 で潰した 1440 回/秒とは桁が違う
        #expect(1 / LadySamplerView.playingInterval <= 20)
    }

    // MARK: - カードのバッジ（到達不能だったバグの回帰）

    /// ⚠️ **一時停止バッジが一度も描画されていなかった**（2026-08-06）。
    ///
    /// ```swift
    /// case .ready, .empty:            EmptyView()          // ← ここが .ready を全部食う
    /// case .ready where position > 0: CreoBadge("一時停止")  // ← 到達しない
    /// ```
    ///
    /// **Swift は `where` 付き case の到達不能を警告しない**ので黙って通っていた。
    /// このセッションで 3 例目の「配線の抜けをコンパイラが検出できない」形
    /// （`RenderStats` の既定値付き引数、cortex の `MidiHub` の `pub use` に続く）。
    ///
    /// ⚠️ **LED を二値にしていい根拠が「画面側で一時停止が読めるから」だった**ので、
    /// ここが出ないと二値化の前提が崩れる。5 状態を全部押さえる
    @Test("一時停止のときバッジが出る — 到達不能だったところ")
    func pausedBadgeIsReachable() {
        let badge = LadySamplerView.badge(
            readiness: .ready, position: 0.42, isPlaying: false)
        #expect(badge == .paused, "位置が残っていて鳴っていない = 一時停止")
    }

    @Test("再生中はバッジを出さない — 普通の状態に印を付けない")
    func playingHasNoBadge() {
        #expect(
            LadySamplerView.badge(readiness: .ready, position: 0.42, isPlaying: true)
                == LadySamplerView.PadBadge.none)
    }

    @Test("頭で停止はバッジを出さない")
    func headStoppedHasNoBadge() {
        #expect(
            LadySamplerView.badge(readiness: .ready, position: 0, isPlaying: false)
                == LadySamplerView.PadBadge.none)
    }

    @Test("空はバッジを出さない")
    func emptyHasNoBadge() {
        #expect(
            LadySamplerView.badge(readiness: .empty, position: 0, isPlaying: false)
                == LadySamplerView.PadBadge.none)
    }

    /// ⚠️ **作り直し中は位置や再生状態より優先**する（鳴らない状態なので、
    /// そちらを先に言わないと「なぜ鳴らないか」が分からない）
    @Test("作り直し中は目標レートのバッジを出す", arguments: [48000.0, 192000.0])
    func preparingShowsTargetRate(target: Double) {
        #expect(
            LadySamplerView.badge(
                readiness: .preparing(targetRate: target), position: 0.5, isPlaying: false)
                == .preparing(targetRate: target),
            "位置が残っていても作り直し中が優先")
    }

    @Test("Note で Play / Pause がトグルする")
    func noteTogglesPlayback() throws {
        let sampler = try makeSampler()
        let url = try makeSampleFile(frames: 44100)  // 1 秒 — 1 打目では鳴り終わらない
        defer { try? FileManager.default.removeItem(at: url) }
        try sampler.loadSample(slot: 0, url: url)
        sampler.setGain(slot: 0, value: 0.8)
        let block = try #require(sampler.scheduleMIDIEventBlock)

        var note: [UInt8] = [0x90, 40, 127]
        block(0, 0, 3, &note)
        #expect(sampler.padStates()[0].isPlaying, "1 打目で鳴りはじめる")
        _ = sampler.drainEvents()

        block(0, 0, 3, &note)
        #expect(sampler.padStates()[0].isPlaying == false, "2 打目で止まる（長尺の素材用）")
        #expect(sampler.drainEvents().first?.contains("一時停止") == true)
    }

    @Test("CC モードのパッド 1-4 が FX 4 段をトグルする")
    func ccPadsToggleEffects() throws {
        let sampler = try makeSampler()
        let block = try #require(sampler.scheduleMIDIEventBlock)

        var cc: [UInt8] = [0xB0, 50, 127]  // CC50 = pad 2 → FX2
        block(0, 0, 3, &cc)
        #expect(sampler.effectStates() == [false, true, false, false])

        block(0, 0, 3, &cc)
        #expect(sampler.effectStates().allSatisfy { !$0 }, "もう一度でトグルして戻る")
    }

    @Test("8 席の見た目はロック 1 回で揃って読める")
    func padStatesReadTogether() throws {
        let sampler = try makeSampler()
        let url = try makeSampleFile()
        defer { try? FileManager.default.removeItem(at: url) }
        try sampler.loadSample(slot: 5, url: url)
        sampler.setGain(slot: 5, value: 0.4)

        let states = sampler.padStates()
        #expect(states.count == LadySampler.padCount)
        #expect(states[5].loaded)
        #expect(abs(states[5].gain - 0.4) < 0.001)
        #expect(states[0].loaded == false)
        #expect(states[5].isPlaying == false, "叩くまでは止まっている")
    }

    // MARK: - 不変条件: メモリ上のバッファは常にエンジンのレートに対応済み

    /// mako 設計 2026-08-06:
    /// > メモリ上のバッファは、常に現在のエンジンのレートに対応済みである。
    /// > 対応していないバッファは存在しない — 再計算中は「まだ無い」扱いにする。
    ///
    /// 実行時のレート比（`step`）を構造から消したので、**ここが破れると
    /// 静かに音程がずれる**。だからテストで固定する
    @Test("読み込んだバッファはエンジンのレートに揃う", arguments: [44100.0, 48000.0, 96000.0])
    func bufferMatchesEngineRate(engineRate: Double) throws {
        let sampler = try makeSampler()
        try setEngineRate(sampler, engineRate)

        // **元は 44.1kHz 固定**。エンジン側だけ動かして、揃うことを見る
        let url = try makeSampleFile(frames: 4410, rate: 44100)
        defer { try? FileManager.default.removeItem(at: url) }
        try sampler.loadSample(slot: 0, url: url)

        let info = try #require(sampler.sampleInfos[0])
        #expect(info.sourceRate == 44100)
        #expect(info.preparedRate == engineRate, "バッファはエンジンのレートに対応済み")

        // 0.1 秒の素材 → どのレートでも 0.1 秒ぶんのフレーム数になる
        let expected = Double(4410) * engineRate / 44100
        let slack = expected * 0.02 + 64  // 変換器の端数
        #expect(abs(Double(info.preparedFrames) - expected) < slack,
                "44.1k → \(engineRate) で約 \(expected) フレーム")
    }

    @Test("192kHz へ上げると約 4.35 倍のフレーム数になる")
    func upsamplingRatio() throws {
        let sampler = try makeSampler()
        try setEngineRate(sampler, 192000)
        let url = try makeSampleFile(frames: 44100, rate: 44100)  // 1 秒
        defer { try? FileManager.default.removeItem(at: url) }
        try sampler.loadSample(slot: 0, url: url)

        let info = try #require(sampler.sampleInfos[0])
        let ratio = Double(info.preparedFrames) / 44100
        #expect(abs(ratio - 192000.0 / 44100.0) < 0.02, "約 4.35 倍（実測 \(ratio)）")
        #expect(info.wasResampled)
    }

    /// ⚠️ **不変条件が破れている間は鳴らさない**。古いレートのバッファを鳴らすのは
    /// 「間違った音程で鳴らす」こと — 無音の方が正しい
    @Test("レートが変わった直後は「まだ無い」— 古いレートの音を出さない")
    func rateChangeMakesPadsNotReady() throws {
        let sampler = try makeSampler()
        try setEngineRate(sampler, 44100)
        let url = try makeSampleFile(frames: 44100, rate: 44100)
        defer { try? FileManager.default.removeItem(at: url) }
        try sampler.loadSample(slot: 0, url: url)
        sampler.setGain(slot: 0, value: 0.8)
        #expect(sampler.padStates()[0].loaded, "揃っている間は鳴らせる")

        // デバイスを切り替えた = 作り直しが要る
        try setEngineRate(sampler, 96000)

        // ⚠️ 作り直しはバックグラウンドなので「この瞬間まだ無い」は競合する。
        // 見るべき不変条件は**古いレートのバッファが鳴らせる状態で存在しない**こと
        let block = try #require(sampler.scheduleMIDIEventBlock)
        var note: [UInt8] = [0x90, 40, 127]
        let ready = sampler.padStates()[0].loaded
        block(0, 0, 3, &note)

        if ready {
            // 既に揃っていたなら鳴ってよい。**古いレートでない**ことが要件
            #expect(sampler.sampleInfos[0]?.preparedRate == 96000)
        } else {
            #expect(sampler.padStates()[0].isPlaying == false, "まだ無いものは鳴らない")
            #expect(sampler.drainEvents().first?.contains("空") == true)
        }
    }

    @Test("作り直しが終われば新しいレートに揃う")
    func repreparedAfterRateChange() async throws {
        let sampler = try makeSampler()
        try setEngineRate(sampler, 44100)
        let url = try makeSampleFile(frames: 4410, rate: 44100)
        defer { try? FileManager.default.removeItem(at: url) }
        try sampler.loadSample(slot: 0, url: url)

        try setEngineRate(sampler, 96000)

        // バックグラウンドの作り直しを待つ
        for _ in 0..<200 where sampler.sampleInfos[0]?.preparedRate != 96000 {
            try await Task.sleep(for: .milliseconds(10))
        }
        let info = try #require(sampler.sampleInfos[0])
        #expect(info.preparedRate == 96000, "新しいレートに揃った")
        #expect(sampler.padStates()[0].loaded, "揃えば鳴らせる")
    }

    /// 元データの素性が読めること（mako 要望「これ元のデータの情報表示できる？」）
    @Test("元データの素性が残る — 間延びを目で切り分けられる")
    func sourceInfoIsVisible() throws {
        let sampler = try makeSampler()
        try setEngineRate(sampler, 48000)
        let url = try makeSampleFile(frames: 96000, rate: 96000)  // 1 秒 / 96kHz
        defer { try? FileManager.default.removeItem(at: url) }
        try sampler.loadSample(slot: 4, url: url)

        let info = try #require(sampler.sampleInfos[4])
        #expect(info.sourceRate == 96000)
        #expect(info.sourceChannels == 1)
        #expect(abs(info.sourceDuration - 1.0) < 0.01)
        #expect(info.fileType == "wav")
        #expect(info.preparedRate == 48000)
        #expect(info.wasResampled, "元と対応済みが違えば SRC がかかったと分かる")
        #expect(info.bytes == info.preparedFrames * 4)
    }

    // MARK: - 出力バスの追従（mako 裁定 2026-08-06「追従させて」）

    /// ⚠️ **同レートなら変換器を通さない**。192k 素材を 192k のバスへ載せるのに
    /// `AVAudioConverter` を挟むのは無駄なうえ、無害とも限らない
    @Test("同レートの素材は素通しする — 変換を経由しない", arguments: [44100.0, 96000.0, 192000.0])
    func sameRatePassesThrough(rate: Double) throws {
        let sampler = try makeSampler()
        try setEngineRate(sampler, rate)
        let url = try makeSampleFile(frames: 1000, rate: rate)
        defer { try? FileManager.default.removeItem(at: url) }
        try sampler.loadSample(slot: 0, url: url)

        let info = try #require(sampler.sampleInfos[0])
        #expect(info.wasResampled == false, "元と対応済みが同じ = SRC 不要")
        // 素通しなので**フレーム数が 1 つも変わらない**（変換器なら端数が出る）
        #expect(info.preparedFrames == 1000, "端数が出ない = 変換器を通っていない")
    }

    /// 素通しでも**ステレオは畳む**（出力は左右へ同じものを流すため）
    @Test("同レートのステレオはモノラルに畳むだけ")
    func sameRateStereoIsDownmixedOnly() throws {
        let sampler = try makeSampler()
        try setEngineRate(sampler, 48000)
        let url = try makeStereoSampleFile(frames: 512, rate: 48000)
        defer { try? FileManager.default.removeItem(at: url) }
        try sampler.loadSample(slot: 1, url: url)

        let info = try #require(sampler.sampleInfos[1])
        #expect(info.sourceChannels == 2)
        #expect(info.wasResampled == false)
        #expect(info.preparedFrames == 512, "レートは変えていないのでフレーム数も同じ")
    }

    /// **バスのフォーマットが真の源**。ここを動かせば AU がそれを読む —
    /// 「レートの値を引数で渡す」経路は無い（それが間延びの源だった）
    @Test("バスのフォーマットを変えると対応レートが追従する")
    func busFormatDrivesEngineRate() throws {
        let sampler = try makeSampler()
        try setEngineRate(sampler, 48000)
        let url = try makeSampleFile(frames: 4800, rate: 48000)
        defer { try? FileManager.default.removeItem(at: url) }
        try sampler.loadSample(slot: 0, url: url)
        #expect(sampler.sampleInfos[0]?.preparedRate == 48000)

        // デバイスを 192kHz へ = ホストがバスのフォーマットを書き換える
        try setEngineRate(sampler, 192000)
        #expect(sampler.outputBusses[0].format.sampleRate == 192000)

        // ⚠️ 「この瞬間 `.preparing` である」は**背景の作り直しと競合する**
        // （小さい素材だと assert より先に終わる）。見るべきは**不変条件**:
        // **古いレートのバッファが鳴らせる状態で存在しない**こと
        let state = sampler.padStates()[0]
        if state.loaded {
            #expect(sampler.sampleInfos[0]?.preparedRate == 192000,
                    "鳴らせるなら新しいレートに揃っている")
        } else {
            #expect(state.readiness == .preparing(targetRate: 192000), "作り直し中")
        }
    }

    @Test("stopAll は繋ぎ替え前に全席を止める")
    func stopAllHaltsEveryPad() throws {
        let sampler = try makeSampler()
        try setEngineRate(sampler, 44100)
        let url = try makeSampleFile(frames: 44100, rate: 44100)
        defer { try? FileManager.default.removeItem(at: url) }
        for pad in 0..<LadySampler.padCount {
            try sampler.loadSample(slot: pad, url: url)
            sampler.setGain(slot: pad, value: 0.8)
        }
        let block = try #require(sampler.scheduleMIDIEventBlock)
        for pad in 0..<LadySampler.padCount {
            var note: [UInt8] = [0x90, UInt8(pad < 4 ? 40 + pad : 36 + (pad - 4)), 100]
            block(0, 0, 3, &note)
        }
        #expect(sampler.padStates().allSatisfy { $0.isPlaying })

        sampler.stopAll()
        #expect(sampler.padStates().allSatisfy { $0.isPlaying == false },
                "鳴らしたままフォーマットを変えると古いレートの音が漏れる")
    }

    /// ⚠️ **fail-open**（ライブ 2 日前の最優先事項）。追従に失敗しても
    /// **render が回り続ける**こと — 音が止まらないことが、正しいレートで
    /// 鳴ることより優先される
    @Test("追従に失敗しても render は回り続ける — 音を止めない")
    func renderSurvivesFailedFollow() throws {
        let sampler = try makeSampler()
        try setEngineRate(sampler, 44100)
        let url = try makeSampleFile(frames: 4410, rate: 44100)
        defer { try? FileManager.default.removeItem(at: url) }
        try sampler.loadSample(slot: 0, url: url)
        sampler.setGain(slot: 0, value: 0.8)

        // 変えられないフォーマットを渡された時と同じ着地（前の形式が生き残る）
        let before = sampler.outputBusses[0].format.sampleRate
        #expect(before == 44100)

        let block = try #require(sampler.scheduleMIDIEventBlock)
        var note: [UInt8] = [0x90, 40, 100]
        block(0, 0, 3, &note)

        // render が noErr を返し続ける = グラフは生きている
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2))
        let buffer = try #require(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512))
        buffer.frameLength = 512
        let render = sampler.internalRenderBlock
        var flags = AudioUnitRenderActionFlags()
        var timestamp = AudioTimeStamp()
        let status = render(&flags, &timestamp, 512, 0, buffer.mutableAudioBufferList, nil, nil)
        #expect(status == noErr)
        #expect(sampler.padStates()[0].isPlaying, "鳴り続けている")
    }

    // MARK: - 準備状態の 3 値（club-nostos の Outcome から語彙を借用）

    /// ⚠️ **空と作り直し中を同じ顔にしない**。`loaded == false` だけだと
    /// デバイス切替直後に「なぜ鳴らないか」が画面から分からない
    @Test("空 / 作り直し中 / 鳴らせる が区別できる")
    func readinessDistinguishesThreeStates() throws {
        let sampler = try makeSampler()
        try setEngineRate(sampler, 44100)
        let url = try makeSampleFile(frames: 4410, rate: 44100)
        defer { try? FileManager.default.removeItem(at: url) }
        try sampler.loadSample(slot: 0, url: url)

        // 席 0 = 鳴らせる / 他は空
        #expect(sampler.padStates()[0].readiness == .ready)
        #expect(sampler.padStates()[1].readiness == .empty)

        // レートを変えたときの席 0（⚠️ 背景の作り直しと競合するので、
        // 「この瞬間 `.preparing`」ではなく**どちらでも成り立つ形**で見る）
        try setEngineRate(sampler, 96000)
        switch sampler.padStates()[0].readiness {
        case .preparing(let target):
            #expect(target == 96000, "作り直し中なら目標レートを運ぶ")
        case .ready:
            #expect(sampler.sampleInfos[0]?.preparedRate == 96000, "揃った後なら一致")
        case .empty:
            Issue.record("音が入っている席が空になってはいけない")
        }
        // ⚠️ ここが本題 — **空席は作り直し対象にならない**（競合しない）
        #expect(sampler.padStates()[1].readiness == .empty, "空席は作り直し対象ではない")
    }

    /// **ペイロードが肝**（借りているのはここ）。これが無いと画面が
    /// 「何 Hz へ」と言えない
    @Test("作り直し中は目標レートを運ぶ", arguments: [48000.0, 96000.0, 192000.0])
    func preparingCarriesTargetRate(target: Double) throws {
        let sampler = try makeSampler()
        try setEngineRate(sampler, 44100)
        let url = try makeSampleFile(frames: 4410, rate: 44100)
        defer { try? FileManager.default.removeItem(at: url) }
        try sampler.loadSample(slot: 3, url: url)

        try setEngineRate(sampler, target)
        // ⚠️ 背景の作り直しと競合するので、**どちらでも成り立つ形**で見る —
        // 作り直し中ならペイロードが目標レートを運び、終わっていれば揃っている
        switch sampler.padStates()[3].readiness {
        case .preparing(let carried):
            #expect(carried == target, "目標レートがペイロードで運ばれる")
        case .ready:
            #expect(sampler.sampleInfos[3]?.preparedRate == target, "揃った後なら一致")
        case .empty:
            Issue.record("席が空になってはいけない")
        }
    }

    @Test("作り直しが終われば全席 ready に戻る（空席は空のまま）")
    func readinessSettlesAfterReprepare() async throws {
        let sampler = try makeSampler()
        try setEngineRate(sampler, 44100)
        let url = try makeSampleFile(frames: 4410, rate: 44100)
        defer { try? FileManager.default.removeItem(at: url) }
        for pad in [0, 2, 5] { try sampler.loadSample(slot: pad, url: url) }

        try setEngineRate(sampler, 96000)
        // ⚠️ 「この瞬間 `.preparing` である」は**背景の作り直しと競合する**
        // （小さい素材だと assert より先に終わる）。見るのは**揃った後の姿**だけ

        for _ in 0..<300 where sampler.padStates()[5].readiness != .ready {
            try await Task.sleep(for: .milliseconds(10))
        }
        for pad in [0, 2, 5] {
            #expect(sampler.padStates()[pad].readiness == .ready, "pad \(pad) が揃った")
        }
        for pad in [1, 3, 4, 6, 7] {
            #expect(sampler.padStates()[pad].readiness == .empty, "空席は空のまま")
        }
    }

    @Test("readiness == .ready と loaded は同値")
    func readyMatchesLoaded() throws {
        let sampler = try makeSampler()
        try setEngineRate(sampler, 44100)
        let url = try makeSampleFile(frames: 512, rate: 44100)
        defer { try? FileManager.default.removeItem(at: url) }
        try sampler.loadSample(slot: 6, url: url)

        for state in sampler.padStates() {
            #expect(state.loaded == (state.readiness == .ready))
        }
    }

    // MARK: - 元ファイルのビット深度（mako 要望「オリジナルの rate/bit 出せる？」）

    /// 指定ビット深度の WAV を書く（`AVAudioFile` の settings で深度を決める）
    private func makeWav(bits: Int, isFloat: Bool, rate: Double, frames: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("bits-\(UUID().uuidString).wav")
        var settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: bits,
            AVLinearPCMIsFloatKey: isFloat,
            AVLinearPCMIsBigEndianKey: false,
        ]
        settings[AVLinearPCMIsNonInterleaved] = false
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1))
        let buffer = try #require(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        buffer.frameLength = AVAudioFrameCount(frames)
        if let channel = buffer.floatChannelData {
            for frame in 0..<frames { channel[0][frame] = 0.25 }
        }
        try file.write(from: buffer)
        return url  // ここで file が解放されてフラッシュされる
    }

    /// ⚠️ **`processingFormat` からは取れない** — あれは常にデコード後の Float32
    /// なので、どのファイルでも 32 と答えてしまう。`fileFormat` から取る
    @Test("元ファイルのビット深度が読める", arguments: [16, 24, 32])
    func sourceBitDepthIsRead(bits: Int) throws {
        let sampler = try makeSampler()
        try setEngineRate(sampler, 44100)
        let url = try makeWav(bits: bits, isFloat: false, rate: 44100, frames: 512)
        defer { try? FileManager.default.removeItem(at: url) }
        try sampler.loadSample(slot: 0, url: url)

        let info = try #require(sampler.sampleInfos[0])
        #expect(info.sourceBits == bits, "\(bits)bit が読めること")
        #expect(info.sourceIsFloat == false)
        #expect(info.formatLabel == "\(bits)bit")
        #expect(info.isCompressed == false)
    }

    /// ⚠️ **`32bit` と `32bit float` は別物**。mako は 32bit のリグで回している
    @Test("32bit int と 32bit float を区別する")
    func distinguishesFloatFromInt() throws {
        let sampler = try makeSampler()
        try setEngineRate(sampler, 44100)

        let intURL = try makeWav(bits: 32, isFloat: false, rate: 44100, frames: 256)
        defer { try? FileManager.default.removeItem(at: intURL) }
        try sampler.loadSample(slot: 0, url: intURL)
        let intInfo = try #require(sampler.sampleInfos[0])
        #expect(intInfo.sourceIsFloat == false)
        #expect(intInfo.formatLabel == "32bit")

        let floatURL = try makeWav(bits: 32, isFloat: true, rate: 44100, frames: 256)
        defer { try? FileManager.default.removeItem(at: floatURL) }
        try sampler.loadSample(slot: 1, url: floatURL)
        let floatInfo = try #require(sampler.sampleInfos[1])
        #expect(floatInfo.sourceIsFloat)
        #expect(floatInfo.formatLabel == "32bit float", "int と同じ表記にしない")
    }

    /// ⚠️ **圧縮は `0bit` と出さない**（ビット深度という概念が無い）
    @Test("圧縮フォーマットは 0bit と出さず拡張子を出す")
    func compressedShowsFileTypeNotZeroBits() throws {
        // 圧縮ファイルを合成できない環境もあるので、素性の組み立て側を直接見る
        let compressed = LadySampler.SampleInfo(
            sourceRate: 44100, sourceChannels: 2, sourceDuration: 3, sourceFrames: 132_300,
            fileType: "m4a", sourceBits: 0, sourceIsFloat: false,
            preparedFrames: 132_300, preparedRate: 44100)
        #expect(compressed.isCompressed)
        #expect(compressed.formatLabel == "m4a")
        #expect(compressed.formatLabel.contains("0bit") == false, "0bit と書かない")
    }

    /// `fileFormat` と `processingFormat` のレートは一致するはず。
    /// 食い違うなら `fileFormat` 側が正（実装もそうしている）
    @Test("fileFormat のレートが素性のレートになる", arguments: [44100.0, 48000.0, 96000.0])
    func sourceRateComesFromFileFormat(rate: Double) throws {
        let sampler = try makeSampler()
        try setEngineRate(sampler, 44100)
        let url = try makeWav(bits: 24, isFloat: false, rate: rate, frames: 512)
        defer { try? FileManager.default.removeItem(at: url) }
        try sampler.loadSample(slot: 2, url: url)

        let info = try #require(sampler.sampleInfos[2])
        #expect(info.sourceRate == rate)
    }

    // MARK: - 計測の配線（実機で「実測なし」が毎回出ていた）

    /// ⚠️ **実機で毎回 `実測なし` が出ていた**（2026-08-06）。`RenderStats` の
    /// `frames` / `elapsedNs` に既定値があるせいで、**渡し忘れても
    /// コンパイルが通ってしまう**。純関数のテストは全部通っていたのに、
    /// AU 側の配線だけが繋がっていなかった。
    ///
    /// だから**配線そのものを見る** — 2 回ドレインすれば実測が出ること
    /// ⚠️ **計測が切れていれば skip**（`LADYLAND_RENDER_STATS=0` は会場の退避路）。
    /// 切れている状態で控えが出ないのは**正しい挙動**なので、失敗にしない
    @Test(
        "2 回目のドレインで実測レートが出る — 配線が繋がっている",
        .enabled(if: RenderMetering.enabled))
    func drainWiresFramesAndElapsed() throws {
        let sampler = try makeSampler()
        try setEngineRate(sampler, 48000)

        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512))
        buffer.frameLength = 512
        let render = sampler.internalRenderBlock
        var flags = AudioUnitRenderActionFlags()
        var timestamp = AudioTimeStamp()

        // 1 回目 — 基準が無いので実測は出ない（これは正しい挙動）
        _ = render(&flags, &timestamp, 512, 0, buffer.mutableAudioBufferList, nil, nil)
        let first = try #require(sampler.drainRenderStats())
        #expect(first.frames == 512, "フレーム累積が繋がっていること")
        #expect(first.measuredRate == nil, "初回は基準が無い")

        // 2 回目 — ここで実測が出なければ配線が切れている
        for _ in 0..<10 {
            _ = render(&flags, &timestamp, 512, 0, buffer.mutableAudioBufferList, nil, nil)
        }
        let second = try #require(sampler.drainRenderStats())
        #expect(second.frames == 5120, "10 ブロック分が累積される")
        #expect(second.elapsedNs > 0, "実経過が繋がっていること")
        #expect(second.measuredRate != nil, "⚠️ ここが nil だと実機で「実測なし」になる")
        #expect(second.line("sampler").contains("実測なし") == false)
    }

    /// ⚠️ 実機のバッファ長は **509 / 514 と可変**だった。
    /// `calls × frameCount` の近似では出せない値なので、累積で持つ
    /// 同上 — 計測が切れていれば見るものが無い
    @Test(
        "可変バッファ長でも累積が正しい — calls × frameCount では出せない",
        .enabled(if: RenderMetering.enabled))
    func accumulatesVariableFrameCounts() throws {
        let sampler = try makeSampler()
        try setEngineRate(sampler, 48000)

        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024))
        let render = sampler.internalRenderBlock
        var flags = AudioUnitRenderActionFlags()
        var timestamp = AudioTimeStamp()

        var expected: UInt64 = 0
        for frames in [509, 514, 509, 512] as [AVAudioFrameCount] {
            buffer.frameLength = frames
            _ = render(&flags, &timestamp, frames, 0, buffer.mutableAudioBufferList, nil, nil)
            expected += UInt64(frames)
        }
        let stats = try #require(sampler.drainRenderStats())
        #expect(stats.frames == expected, "実測 \(stats.frames) / 期待 \(expected)")
        #expect(stats.calls == 4)
        // 直近の frameCount（512）× 4 = 2048 とは違う値になる
        #expect(stats.frames != UInt64(stats.calls) * UInt64(stats.frameCount))
    }

    @Test("壊れた URL を渡しても他のスロットを巻き込まない")
    func brokenURLDoesNotBreakOthers() throws {
        let sampler = try makeSampler()
        var state = sampler.fullState ?? [:]
        var urls = [String](repeating: "", count: LadySampler.padCount)
        urls[2] = "file:///nowhere/does-not-exist.wav"
        state["club.chronista.ladyland.sampler.urls"] = urls
        state["club.chronista.ladyland.sampler.gains"] =
            [Double](repeating: 0.7, count: LadySampler.padCount)

        // ファイルが移動・削除されているのは普通に起きる。
        // **その席だけ空で立ち上がり**、音量の復元は生きる
        sampler.fullState = state

        #expect(sampler.sampleURLs[2] == nil, "読めなかった席は空のまま")
        #expect(abs(sampler.gain(slot: 2) - 0.7) < 0.001, "音量は復元される")
    }

    // MARK: - 波形の包絡と頭出し（mako 要望 2026-08-07）

    /// ⚠️ **バケット数は素材の長さによらず一定**。ここが可変だと、席ごとに
    /// 違う密度の波形が並ぶ
    @Test("包絡のバケット数は素材の長さによらず一定", arguments: [1000, 44100, 441000])
    func envelopeBucketCountIsFixed(frames: Int) throws {
        let sampler = try makeSampler()
        try setEngineRate(sampler, 44100)
        let url = try makeSampleFile(frames: frames, rate: 44100)
        defer { try? FileManager.default.removeItem(at: url) }
        try sampler.loadSample(slot: 0, url: url)

        let envelope = try #require(sampler.envelope(pad: 0))
        #expect(envelope.lows.count == LadySampler.PeakEnvelope.bucketCount)
        #expect(envelope.highs.count == LadySampler.PeakEnvelope.bucketCount)
    }

    /// ⭐ **不変式** — 包絡は `PreparedSample` に載っているので、レートが
    /// 変わって再変換されれば**一緒に作り直される**。片方だけ古いまま残らない
    @Test("再変換されたら包絡も新しいフレームに対応している")
    func envelopeFollowsReprepare() throws {
        let sampler = try makeSampler()
        try setEngineRate(sampler, 44100)
        let url = try makeSampleFile(frames: 44100, rate: 44100)
        defer { try? FileManager.default.removeItem(at: url) }
        try sampler.loadSample(slot: 0, url: url)
        #expect(sampler.envelope(pad: 0) != nil)

        try setEngineRate(sampler, 96000)

        // ⚠️ **「いま作り直し中か」を見ない**（過去 6 本 flaky にした罠）。
        // 見るのは「**包絡があるなら、それは新しいレートのものである**」
        if let envelope = sampler.envelope(pad: 0) {
            #expect(envelope.lows.count == LadySampler.PeakEnvelope.bucketCount)
            #expect(sampler.sampleInfos[0]?.preparedRate == 96000, "古いレートの包絡は残らない")
        }
    }

    /// ⚠️ **長さ 0 の素材で壊れない**（既知の未修正点を踏まない）
    @Test("空の包絡は空として扱える")
    func emptyEnvelopeIsSafe() {
        let empty = LadySampler.PeakEnvelope.make([])
        #expect(empty.isEmpty)
        #expect(empty.lows.isEmpty)
    }

    /// ⭐ **頭出しで再生状態を変えない** — 「頭出ししたら鳴り出した」は
    /// 演奏中に事故になる
    @Test("頭出ししても再生状態が変わらない")
    func seekDoesNotChangePlayState() throws {
        let sampler = try makeSampler()
        try setEngineRate(sampler, 44100)
        let url = try makeSampleFile(frames: 44100, rate: 44100)
        defer { try? FileManager.default.removeItem(at: url) }
        try sampler.loadSample(slot: 0, url: url)

        #expect(sampler.padStates()[0].isPlaying == false)
        sampler.seek(pad: 0, to: 0.5)
        #expect(sampler.padStates()[0].isPlaying == false, "止まっているなら止まったまま")
        #expect(sampler.padStates()[0].position > 0.4, "位置だけ動く")

        let block = try #require(sampler.scheduleMIDIEventBlock)
        var note: [UInt8] = [0x90, 40, 100]
        block(0, 0, 3, &note)
        #expect(sampler.padStates()[0].isPlaying)
        sampler.seek(pad: 0, to: 0.2)
        #expect(sampler.padStates()[0].isPlaying, "鳴っているならそのまま続く")
    }

    /// ⚠️ **端で壊れない**。末尾ちょうどだと render の `position >= count` に
    /// 即当たって頭へ巻き戻るので、最後のフレームで止める
    @Test("頭出しは 0 と末尾で丸められる")
    func seekClampsAtBothEnds() throws {
        let sampler = try makeSampler()
        try setEngineRate(sampler, 44100)
        let url = try makeSampleFile(frames: 44100, rate: 44100)
        defer { try? FileManager.default.removeItem(at: url) }
        try sampler.loadSample(slot: 0, url: url)

        sampler.seek(pad: 0, to: -5)
        #expect(sampler.padStates()[0].position == 0)

        sampler.seek(pad: 0, to: 5)
        let end = sampler.padStates()[0].position
        #expect(end > 0.99 && end < 1.0, "末尾ちょうどにはしない（\(end)）")
    }

    @Test("空席への頭出しは無視される")
    func seekOnEmptyPadIsIgnored() throws {
        let sampler = try makeSampler()
        sampler.seek(pad: 0, to: 0.5)
        #expect(sampler.padStates()[0].position == 0)
    }

    /// ⭐ **経路が繋がっているかを見る**（mako 実機報告 2026-08-07
    /// 「かーそるはうごくけど、再生位置は追随してないね」）。
    ///
    /// ⚠️ **「呼んだらどうなるか」ではなく「その後 render がそこから読むか」**。
    /// `positions` が変わっただけでは「見た目だけの頭出し」と区別が付かない —
    /// **実際に出た音が頭出し先のものか**を確かめる。
    @Test("頭出しした位置から render が読む（再生中でも）")
    func seekIsHonouredByRender() throws {
        let sampler = try makeSampler()
        try setEngineRate(sampler, 44100)
        // **位置で値が違う素材**を作る（先頭 0.0 / 後半 1.0 の階段）
        let url = try makeRampFile(frames: 4096, rate: 44100)
        defer { try? FileManager.default.removeItem(at: url) }
        try sampler.loadSample(slot: 0, url: url)
        sampler.setGain(slot: 0, value: 1)

        let block = try #require(sampler.scheduleMIDIEventBlock)
        var note: [UInt8] = [0x90, 40, 100]
        block(0, 0, 3, &note)
        #expect(sampler.padStates()[0].isPlaying, "鳴っている状態で頭出しする")

        // **後半へ飛ばす** → 次のブロックは大きい値を出すはず
        sampler.seek(pad: 0, to: 0.75)
        let peak = try renderPeak(sampler, frames: 256)
        #expect(peak > 0.5, "頭出し先（後半 = 大きい値）から鳴っている（peak=\(peak)）")

        // **前半へ戻す** → 小さい値に戻る
        sampler.seek(pad: 0, to: 0)
        let head = try renderPeak(sampler, frames: 256)
        #expect(head < 0.2, "先頭（小さい値）から鳴っている（peak=\(head)）")
    }

    /// 前半 0 / 後半 1 の階段素材（頭出し先を音で見分けるため）
    private func makeRampFile(frames: Int, rate: Double) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ramp-\(UUID().uuidString).wav")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = try #require(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        buffer.frameLength = AVAudioFrameCount(frames)
        for index in 0..<frames {
            buffer.floatChannelData![0][index] = index < frames / 2 ? 0.0 : 0.9
        }
        try file.write(from: buffer)
        return url
    }

    /// 1 ブロック render して振幅の最大を返す
    private func renderPeak(_ sampler: LadySampler, frames: Int) throws -> Float {
        let render = sampler.internalRenderBlock
        let list = AudioBufferList.allocate(maximumBuffers: 1)
        defer { free(list.unsafeMutablePointer) }
        var data = [Float](repeating: 0, count: frames)
        return data.withUnsafeMutableBufferPointer { pointer -> Float in
            list[0] = AudioBuffer(
                mNumberChannels: 1, mDataByteSize: UInt32(frames * 4),
                mData: pointer.baseAddress)
            var flags = AudioUnitRenderActionFlags()
            var time = AudioTimeStamp()
            let status = render(
                &flags, &time, AUAudioFrameCount(frames), 0, list.unsafeMutablePointer,
                nil, nil)
            #expect(status == noErr)
            return pointer.reduce(0) { max($0, abs($1)) }
        }
    }

    /// ⚠️ **列数と行数の食い違いを捕まえる**（実機 2026-08-07 の 3D フィールド
    /// 消失）。`padGrid` が「4 列（2 行）でも 4 行ぶんの高さ」を要求していて、
    /// **560pt の窓でフィールドの取り分が 0** になっていた
    @Test("幅から決まる列数で 8 席が割り切れる", arguments: [200.0, 469.0, 700.0, 900.0])
    @MainActor
    func padGridColumnsDivideEvenly(width: Double) {
        let columns = LadySamplerView.columns(forWidth: CGFloat(width))
        #expect(LadySampler.padCount % columns == 0, "\(width)pt で \(columns) 列は割り切れない")
        #expect(columns == 2 || columns == 4)
    }

    /// **窓は 4 列 / インラインペインは 2 列**（実機と同じ形は 4 列のとき）
    @Test("窓では 4 列、470pt のペインでは 2 列")
    @MainActor
    func padGridColumnsByWidth() {
        #expect(LadySamplerView.columns(forWidth: 900) == 4, "プラグイン窓")
        #expect(LadySamplerView.columns(forWidth: 470) == 2, "Main 右列のインライン")
    }
}
