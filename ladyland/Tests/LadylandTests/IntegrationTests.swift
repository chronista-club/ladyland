//! 認証不要のプロセス内 AU によるホスト統合テスト。
//!
//! テスト専用 AU を実カタログ・ロード経路へ登録する。不在は失敗扱い。
//! 実行時は実際に音が出る（出力は OS 既定 or L6max）。
//!
//! 検証する経路: カタログ → ロード → MIDI 送信 → 発音（RMS）→
//! fullState スナップショット → 復元。P1/P2 の背骨がまとめて通る。

import AppKit
import AVFoundation
import Testing

@testable import Ladyland

@Suite("実 AU 統合", .serialized)
@MainActor
struct IntegrationTests {
    init() { TestInstrumentAU.register() }
    /// テスト中の実音を極力小さくする（mako 裁定 2026-08-01「テストの音が
    /// 出過ぎ」）。mainMixer の出力段で約 -34dB に絞る — RMS タップは
    /// mainMixer（絞り後）なのでしきい値も同率縮小済み。スロット側の
    /// レベル計測（slot.level = unit 直タップ）は絞りの影響を受けない
    private func quiet(_ rack: InstrumentRack) {
        // 聴感確認したいとき（出音の実在チェック等）は絞りを外せる:
        //   LADYLAND_AUDIBLE_TEST=1 swift test --filter "ドラムスロット経路"
        guard ProcessInfo.processInfo.environment["LADYLAND_AUDIBLE_TEST"] == nil else { return }
        rack.engine.mainMixerNode.outputVolume = 0.02
    }

    /// 発音判定のしきい値（旧 0.001 を outputVolume 0.02 で同率縮小）
    private let audibleRMS: Float = 0.00002

    /// 消音判定のしきい値（旧 0.01 の同率縮小）
    private let silentRMS: Float = 0.0002

    /// ⚠️ **実経路（`handleShort`）を通す** — mako 報告 2026-08-12「ノブの LCD を
    /// 回しても、反映しない」の再発防止。ch1 の席 CC はモーター同期の帳簿に
    /// 記録するだけで**適用経路が無かった**（受信側が呼んでいなければ
    /// 純関数が正しくても意味が無い、の実例がまた増えた）
    @Test("MIDI モードの席 CC が割当パラメータに効く")
    func seatCCAppliesToParameter() async throws {
        let rack = InstrumentRack()
        let tone = try await TestInstrumentAU.component(in: rack)
        try rack.start()
        defer { rack.engine.stop() }
        quiet(rack)
        try await rack.load(tone, into: rack.slots[0])
        let param = try #require(
            rack.slots[0].parameterList.first(where: { $0.maxValue > $0.minValue }))
        rack.slots[0].knobMappings = [
            FaceKnobMapping(knob: 5, address: param.address, name: param.displayName)
        ]
        let roto = RotoService()
        roto.attach(rack: rack)
        roto.receiveShortForTesting(0xB0, 5, 127)  // ch1 席 CC5 = 最大へ
        try await Task.sleep(for: .milliseconds(100))  // AU の適用を待つ
        #expect(
            abs(Double(param.value) - Double(param.maxValue)) < 0.001,
            "席 CC が割当パラメータへ届くこと（受信の帳簿記録だけでは足りない）")
    }

    @Test("ロード → ノートオン → 発音（RMS > 0）→ 切替作法で消音")
    func loadPlayAndRelease() async throws {
        let rack = InstrumentRack()
        let tone = try await TestInstrumentAU.component(in: rack)
        try rack.start()
        defer { rack.engine.stop() }
        quiet(rack)
        try await rack.load(tone, into: rack.slots[0])

        // mixer 出力の RMS を収集
        let collector = RMSCollector()
        rack.engine.mainMixerNode.installTap(onBus: 0, bufferSize: 4096, format: nil) {
            buffer, _ in
            collector.add(buffer)
        }

        rack.slots[0].sendMIDI([0x90, 60, 100])  // C4 on
        try await Task.sleep(for: .seconds(1.5))
        let playingRMS = collector.maxRMS
        #expect(playingRMS > audibleRMS, "ノートオンで発音していること (RMS=\(playingRMS))")
        #expect(rack.slots[0].level > 0.001, "レベルメーターが発音を捉えていること")

        // 切替作法（サスティンオフ + All Notes Off）で音が止まりリリースに入る
        rack.slots[0].allNotesOff()
        try await Task.sleep(for: .seconds(2))
        collector.reset()
        try await Task.sleep(for: .seconds(0.5))
        let decayed = collector.maxRMS
        #expect(decayed < silentRMS, "All Notes Off 後は静まること (RMS=\(decayed))")

        rack.engine.mainMixerNode.removeTap(onBus: 0)
        rack.engine.stop()
    }

    @Test("ドラムスロット経路 — テスト AU をロードしてドラムノートで発音")
    func drumSlotPath() async throws {
        let rack = InstrumentRack()
        let tone = try await TestInstrumentAU.component(in: rack)
        try rack.start()
        defer { rack.engine.stop() }
        quiet(rack)
        try await rack.load(tone, into: rack.drumSlot)

        let collector = RMSCollector()
        rack.engine.mainMixerNode.installTap(onBus: 0, bufferSize: 4096, format: nil) {
            buffer, _ in
            collector.add(buffer)
        }

        // LPD8 mk2 のデフォルトパッド域（note 36-43）を叩く
        for note: UInt8 in 36...43 {
            rack.routeDrums([0x90, note, 110])
        }
        try await Task.sleep(for: .seconds(1.5))
        let rms = collector.maxRMS
        #expect(rms > audibleRMS, "ドラムスロットが発音すること (RMS=\(rms))")
        #expect(rack.drumSlot.level > 0.001, "ドラムスロットのレベルメーターが動くこと")

        rack.engine.mainMixerNode.removeTap(onBus: 0)
        rack.engine.stop()
    }

    @Test("ロード済みスロットへの差し替え — 別のテスト AU に入れ替えて発音")
    func reloadIntoOccupiedSlot() async throws {
        let rack = InstrumentRack()
        let tones = try await [TestInstrumentAU.component(in: rack), TestInstrumentAU.component(in: rack, index: 1)]
        try rack.start()
        defer { rack.engine.stop() }
        quiet(rack)

        // 1 台目をロード → 2 台目に差し替え（レベル tap が付いた状態の detach 経路）
        try await rack.load(tones[0], into: rack.drumSlot)
        try await rack.load(tones[1], into: rack.drumSlot)
        #expect(rack.drumSlot.displayName == tones[1].name)

        // 差し替え後も発音できること
        let collector = RMSCollector()
        rack.engine.mainMixerNode.installTap(onBus: 0, bufferSize: 4096, format: nil) {
            buffer, _ in
            collector.add(buffer)
        }
        for note: UInt8 in 36...48 {
            rack.routeDrums([0x90, note, 110])
        }
        try await Task.sleep(for: .seconds(1.5))
        #expect(
            collector.maxRMS > audibleRMS,
            "差し替え後も発音すること (RMS=\(collector.maxRMS))")

        rack.engine.mainMixerNode.removeTap(onBus: 0)
        rack.engine.stop()
    }

    // MARK: - 出力バスの追従（fail-open の要）

    /// ⚠️ **走行中に `engine.connect` を呼んではいけない**（2026-08-06）。
    ///
    /// `AVAudioEngine.connect` はフォーマット不整合で **ObjC の `NSException`**
    /// を raise する。Swift の `catch` はこれを捕まえられないので、走行中に
    /// 繋ぎ替えるとプロセスごと落ちる。**止めた窓の中でやる**ことで、
    /// 捕まえられない例外が `engine.start()` の Swift throw に変わる。
    ///
    /// ここで見るのは「実エンジンの上で追従が完走し、**音が出続ける**」こと。
    /// 落ちたらテストごと落ちるので、通ること自体が回帰の砦になる
    @Test("出力バスの追従がエンジンを止めた窓の中で完走する")
    @MainActor
    func busFollowSurvivesOnLiveEngine() async throws {
        // ⚠️ **既定に頼らない**。既定は倒れうるので、追従の挙動を見るテストは
        // 明示的に on を与える（既定が変わっても意味が保たれる）
        let previous = BusFollowing.enabled
        defer { BusFollowing.enabled = previous }
        BusFollowing.enabled = true

        let rack = InstrumentRack()
        guard let sampler = rack.catalog.first(where: { $0.name == LadySampler.displayName })
        else { return }  // 自作 AU が登録されていない環境ではスキップ
        try rack.start()
        defer { rack.engine.stop() }
        quiet(rack)
        try await rack.load(sampler, into: rack.drumSlot)

        let unit = try #require(rack.drumSlot.audioUnit?.auAudioUnit as? LadySampler)
        let before = unit.outputBusses[0].format.sampleRate
        #expect(rack.engine.isRunning, "追従の前はエンジンが走っている")

        // 追従を走らせる（デバイス切替と同じ経路）。**落ちないこと**が第一
        rack.followOutputRate()

        #expect(rack.engine.isRunning, "追従の後もエンジンが走っている = 音が出続ける")
        let after = unit.outputBusses[0].format.sampleRate
        #expect(after > 0)
        // 追従できていれば装置のレート、できなければ元のまま（fail-open）。
        // **どちらでも良い** — 落ちないことと鳴り続けることが要件
        let device = rack.engine.outputNode.outputFormat(forBus: 0).sampleRate
        #expect(after == device || after == before, "追従したか、元のまま生き残ったか")

        // 追従後も render が回る（グラフが壊れていない）
        #expect(rack.drumSlot.audioUnit != nil)
    }

    /// ⚠️ **楽器を 1 つ足したときに追従から漏れたら落ちるテスト**
    /// （mako 指示 2026-08-07。今回のバグがまさにそれだった）。
    ///
    /// `as? LadySampler` で絞っていたので `LadySynth` にレートが渡らず、
    /// **192000 / 44100 = 4.35 倍**音程がずれていた。実機では 2 行のログを
    /// 人が見比べて気づくしか無かった。
    ///
    /// ⚠️ **個々の楽器を名指しで確かめない** — 名指しだと、次に足した楽器が
    /// また漏れる。**カタログに出ている自作楽器を全部**回して、
    /// **どれも追従の入口を通れること**を見る
    @Test("自作楽器はどれも追従の入口を通れる — 具体型で絞られていない")
    @MainActor
    func everyOwnInstrumentCanFollow() async throws {
        let previous = BusFollowing.enabled
        defer { BusFollowing.enabled = previous }
        BusFollowing.enabled = true

        let names = [LadySampler.displayName, LadySynth.displayName]
        var checked = 0
        for name in names {
            let component = try #require(
                rackCatalogEntry(named: name), "\(name) がカタログに出ていない")
            let rack = InstrumentRack()
            try rack.start()
        defer { rack.engine.stop() }
            quiet(rack)
            try await rack.load(component, into: rack.drumSlot)
            let unit = try #require(rack.drumSlot.audioUnit?.auAudioUnit)

            // ⭐ **これが本体** — 追従側が見ているのと同じ判定を掛ける。
            // ここを通らない楽器は `followOutputRate` から黙って漏れる
            #expect(
                unit is any EngineRateFollowing,
                "\(name) が EngineRateFollowing に適合していない = 追従から漏れる")
            checked += 1
        }
        // ⚠️ **空転していないこと**（過去に 2 本やった）。1 つも載らなかったら
        // このテストは何も確かめていない
        #expect(checked > 0, "自作楽器が 1 つも載らなかった = テストが空転している")
    }

    /// ⚠️ **不変式で書く**（過去に「今の状態を見る」テストを 6 本 flaky にした）。
    ///
    /// 見るのは「追従が走った**後**、楽器のレートがエンジンのレートと一致する」。
    /// 途中の状態も、どちらが先かも見ない
    @Test("追従の後、楽器のレートはエンジンと一致する", arguments: [
        LadySampler.displayName, LadySynth.displayName,
    ])
    @MainActor
    func rateMatchesEngineAfterFollow(name: String) async throws {
        let previous = BusFollowing.enabled
        defer { BusFollowing.enabled = previous }
        BusFollowing.enabled = true

        // ⚠️ **黙ってスキップしない**（過去に空転テストを 2 本作った）。
        // 自作 AU の登録は `InstrumentRack.init` で必ず走るので、
        // 見つからないなら**それ自体が不具合**
        let component = try #require(
            rackCatalogEntry(named: name), "\(name) がカタログに出ていない")
        let rack = InstrumentRack()
        try rack.start()
        defer { rack.engine.stop() }
        quiet(rack)
        try await rack.load(component, into: rack.drumSlot)
        let unit = try #require(
            rack.drumSlot.audioUnit?.auAudioUnit as? any EngineRateFollowing)


        rack.followOutputRate()

        let device = rack.engine.outputNode.outputFormat(forBus: 0).sampleRate
        let instrument = unit.outputBusses[0].format.sampleRate
        #expect(rack.engine.isRunning, "追従の後も鳴り続ける")
        // ⚠️ 追従できなければ **fail-open で元のまま**（それも正しい着地）。
        // 固定するのは「**中途半端な第 3 の値にならない**」こと
        #expect(
            instrument == device || instrument == 44100,
            "\(name): \(instrument)Hz — 装置(\(device)) でも初期値でもない")
    }

    /// ⭐ **組み上げの順序ごと再現するテスト**（実機 2026-08-07 の再発を受けて）。
    ///
    /// ⚠️ **前のテストは「追従を呼んだらどうなるか」しか見ていなかった。**
    /// だから `followOutputRate` の絞りを直した時点で緑になり、
    /// **ロード経路の門（`if unit.auAudioUnit is LadySampler`）が
    /// 残っていることに気づけなかった** — 実機では synth が 44100 のままだった。
    ///
    /// ここでは **`followOutputRate` を呼ばない**。守りたいのは
    /// 「**普通に起動してロードしたら、もう揃っている**」ことだから
    @Test("ロードしただけでエンジンのレートに揃っている（追従を呼ばない）", arguments: [
        LadySampler.displayName, LadySynth.displayName,
    ])
    @MainActor
    func rateMatchesRightAfterLoad(name: String) async throws {
        let previous = BusFollowing.enabled
        defer { BusFollowing.enabled = previous }
        BusFollowing.enabled = true

        let component = try #require(
            rackCatalogEntry(named: name), "\(name) がカタログに出ていない")
        let rack = InstrumentRack()
        try rack.start()
        defer { rack.engine.stop() }
        quiet(rack)
        try await rack.load(component, into: rack.drumSlot)
        // ⚠️ **ここで followOutputRate() を呼ばない**（呼べば当然揃う）

        let unit = try #require(
            rack.drumSlot.audioUnit?.auAudioUnit as? any EngineRateFollowing)
        let device = rack.engine.outputNode.outputFormat(forBus: 0).sampleRate
        #expect(
            unit.outputBusses[0].format.sampleRate == device,
            "\(name) が \(unit.outputBusses[0].format.sampleRate)Hz — 装置は \(device)Hz")
    }

    /// ⚠️ **楽器を混ぜて載せても全部揃うこと**（片方だけ通る門が残っていないか）。
    /// 実機のバグは「sampler だけ 192000 / synth だけ 44100」という形で出た
    @Test("種類の違う楽器を並べても全部エンジンのレートに揃う")
    @MainActor
    func mixedInstrumentsAllMatch() async throws {
        let previous = BusFollowing.enabled
        defer { BusFollowing.enabled = previous }
        BusFollowing.enabled = true

        let rack = InstrumentRack()
        try rack.start()
        defer { rack.engine.stop() }
        quiet(rack)
        let sampler = try #require(rackCatalogEntry(named: LadySampler.displayName))
        let synth = try #require(rackCatalogEntry(named: LadySynth.displayName))
        try await rack.load(sampler, into: rack.drumSlot)
        try await rack.load(synth, into: rack.slots[0])

        let device = rack.engine.outputNode.outputFormat(forBus: 0).sampleRate
        var checked = 0
        for slot in [rack.drumSlot, rack.slots[0]] {
            let unit = try #require(slot.audioUnit?.auAudioUnit as? any EngineRateFollowing)
            #expect(
                unit.outputBusses[0].format.sampleRate == device,
                "\(slot.displayName ?? "?") が \(unit.outputBusses[0].format.sampleRate)Hz")
            checked += 1
        }
        #expect(checked == 2, "2 台とも確かめた")
    }

    /// カタログから自作楽器を引く（登録されていない環境では nil）
    @MainActor
    private func rackCatalogEntry(named name: String) -> InstrumentComponent? {
        InstrumentRack().catalog.first { $0.name == name }
    }

    /// ⚠️ **書き出しは関数に閉じる**。`AVAudioFile` は deinit でフラッシュするので、
    /// 同じスコープに生かしたまま読むと**長さ 0 のファイル**を掴む
    /// （このテストが実際にそれを踏んで教えてくれた）
    private func writeSilentWav(frames: Int, rate: Double) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("busfollow-\(UUID().uuidString).wav")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = try #require(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        buffer.frameLength = AVAudioFrameCount(frames)
        if let channel = buffer.floatChannelData {
            for frame in 0..<frames { channel[0][frame] = 0.2 }
        }
        try file.write(from: buffer)
        return url  // ここで file が解放されてフラッシュされる
    }

    // MARK: - バス追従のスイッチ

    /// ⚠️ **既定は on**（mako 裁定 2026-08-06。実機で全段 192k を確認済み）。
    /// **`=0` は会場での最後の手段**なので、退避路が消えていないことも固定する
    @Test("既定は on — 退避路は `LADYLAND_BUS_FOLLOW=0`")
    @MainActor
    func followsByDefault() {
        if ProcessInfo.processInfo.environment["LADYLAND_BUS_FOLLOW"] == nil {
            #expect(BusFollowing.enabled, "未設定なら追従する")
        }
        // 退避路が生きていること（`=0` だけが off という判定）
        #expect(("0" != "0") == false)
        #expect(BusFollowing.describe.contains("bus-follow:"))
    }

    /// ⚠️ **`standardFormatWithSampleRate:channels:` は 3ch 以上で nil を返す**
    /// （実測 2026-08-06）。これが実機で `mixer 44100` が残った真因だった —
    /// 多チャンネルのインターフェースでは `deviceFormat()` が nil を返し、
    /// 合流点は `format: nil` で繋がれて 44.1k のままになっていた。
    ///
    /// **チャンネル数に関わらずフォーマットが作れること**を固定する
    @Test("多チャンネルのデバイスでもフォーマットが作れる", arguments: [1, 2, 3, 4, 6, 8])
    func multichannelDeviceStillYieldsFormat(channels: Int) {
        // 素の `standardFormat` は 3ch 以上で nil（これが罠だった）
        let raw = AVAudioFormat(
            standardFormatWithSampleRate: 192000, channels: AVAudioChannelCount(channels))
        if channels > 2 { #expect(raw == nil, "3ch 以上は作れない") }

        // 2ch に落とせば必ず作れる（`deviceFormat()` が採っている手）
        let clamped = AVAudioFormat(
            standardFormatWithSampleRate: 192000,
            channels: AVAudioChannelCount(max(1, min(channels, 2))))
        #expect(clamped != nil, "\(channels)ch のデバイスでも合流点の形式は作れる")
        #expect(clamped?.sampleRate == 192000, "レートは device のものを保つ")
    }

    // MARK: - バス追従を切った状態（退避路）

    /// ⚠️ **既定 off が本番の姿**。バスもバッファも 44.1kHz で一貫するので
    /// 確実に鳴る（`99dea4a` の状態）。ここが崩れると 4.35 倍の間延びが戻る
    @Test("off ならロード時にバスを触らない — 44.1kHz のまま")
    @MainActor
    func busFollowOffKeepsDefaultFormat() async throws {
        let previous = BusFollowing.enabled
        defer { BusFollowing.enabled = previous }
        BusFollowing.enabled = false

        let rack = InstrumentRack()
        guard let sampler = rack.catalog.first(where: { $0.name == LadySampler.displayName })
        else { return }
        try rack.start()
        defer { rack.engine.stop() }
        quiet(rack)
        try await rack.load(sampler, into: rack.drumSlot)

        let unit = try #require(rack.drumSlot.audioUnit?.auAudioUnit as? LadySampler)
        #expect(unit.outputBusses[0].format.sampleRate == 44100, "init の既定のまま")

        // ⚠️ **切替時も止まっていること**（片方だけ止めると半分追従で最悪になる）
        rack.followOutputRate()
        #expect(unit.outputBusses[0].format.sampleRate == 44100, "切替経路でも触らない")
        #expect(rack.engine.isRunning, "止めてもいない = 無駄な音切れも無い")
    }

    /// off でも `99dea4a` の不変条件は成立している —
    /// 「エンジンのレート」が 44.1k というだけ
    @Test("off でもバッファはエンジンのレート（44.1kHz）に対応済み")
    @MainActor
    func busFollowOffKeepsInvariant() async throws {
        let previous = BusFollowing.enabled
        defer { BusFollowing.enabled = previous }
        BusFollowing.enabled = false

        let rack = InstrumentRack()
        guard let entry = rack.catalog.first(where: { $0.name == LadySampler.displayName })
        else { return }
        try rack.start()
        defer { rack.engine.stop() }
        quiet(rack)
        try await rack.load(entry, into: rack.drumSlot)
        let sampler = try #require(rack.drumSlot.audioUnit?.auAudioUnit as? LadySampler)

        let url = try writeSilentWav(frames: 4410, rate: 44100)
        defer { try? FileManager.default.removeItem(at: url) }
        try sampler.loadSample(slot: 0, url: url)

        let info = try #require(sampler.sampleInfos[0])
        #expect(info.preparedRate == 44100, "バスと同じ = 一貫している")
        #expect(info.wasResampled == false, "44.1k 素材はそのまま")
        #expect(sampler.padStates()[0].readiness == .ready)
    }

    /// on の側。**落ちないことと鳴り続けること**が要件で、追従できたか否かは
    /// 実機のデバイス次第（できなければ fail-open で 44.1k に戻る）
    @Test("on なら追従が走る — 失敗しても鳴り続ける")
    @MainActor
    func busFollowOnRunsAndSurvives() async throws {
        let previous = BusFollowing.enabled
        defer { BusFollowing.enabled = previous }
        BusFollowing.enabled = true

        let rack = InstrumentRack()
        guard let entry = rack.catalog.first(where: { $0.name == LadySampler.displayName })
        else { return }
        try rack.start()
        defer { rack.engine.stop() }
        quiet(rack)
        try await rack.load(entry, into: rack.drumSlot)
        let sampler = try #require(rack.drumSlot.audioUnit?.auAudioUnit as? LadySampler)

        rack.followOutputRate()

        #expect(rack.engine.isRunning, "追従の後もエンジンが走っている")
        let device = rack.engine.outputNode.outputFormat(forBus: 0).sampleRate
        let bus = sampler.outputBusses[0].format.sampleRate
        #expect(bus == device || bus == 44100, "追従したか、fail-open で戻ったか")
        // どちらに転んでも**不変条件は成立している**
        #expect(sampler.outputBusses[0].format.sampleRate > 0)
    }

    // MARK: - 合流点（mainMixerNode）— ⚠️ 全楽器が通る共有ノード

    /// ⚠️ **off なら合流点に触らない**。`mainMixerNode` は KORG も第三者 AU も
    /// 全部が通る共有ノードなので、既定では従来どおりの挙動でなければならない
    @Test("off なら合流点のフォーマットに触らない — 従来どおり鳴る")
    @MainActor
    func mixerUntouchedWhenOff() throws {
        let previous = BusFollowing.enabled
        defer { BusFollowing.enabled = previous }
        BusFollowing.enabled = false

        let rack = InstrumentRack()
        try rack.start()
        defer { rack.engine.stop() }
        defer { rack.engine.stop() }

        #expect(rack.engine.isRunning, "起動できること（第一要件）")
        #expect(rack.engine.mainMixerNode.outputFormat(forBus: 0).sampleRate > 0)

        // 切替経路でも触らない
        let before = rack.engine.mainMixerNode.outputFormat(forBus: 0).sampleRate
        rack.followOutputRate()
        #expect(rack.engine.mainMixerNode.outputFormat(forBus: 0).sampleRate == before)
        #expect(rack.engine.isRunning)
    }

    /// on では合流点をデバイスのレートへ合わせる。
    /// ⚠️ **落ちないことと鳴り続けることが第一要件** — 追従できたか否かは
    /// デバイス次第で、できなければ fail-open が従来の繋ぎ方へ戻す
    @Test("on なら合流点がデバイスのレートに揃う（揃わなくても鳴り続ける）")
    @MainActor
    func mixerFollowsDeviceWhenOn() throws {
        let previous = BusFollowing.enabled
        defer { BusFollowing.enabled = previous }
        BusFollowing.enabled = true

        let rack = InstrumentRack()
        try rack.start()
        defer { rack.engine.stop() }
        defer { rack.engine.stop() }

        #expect(rack.engine.isRunning, "明示フォーマットでも起動できること")
        let device = rack.engine.outputNode.outputFormat(forBus: 0).sampleRate
        let mixer = rack.engine.mainMixerNode.outputFormat(forBus: 0).sampleRate
        #expect(mixer > 0)
        // 揃っていれば 192/32 が通る。揃わなければ fail-open が働いた形
        if mixer != device {
            #expect(rack.engine.isRunning, "揃わなくても音は出続ける")
        }

        rack.followOutputRate()
        #expect(rack.engine.isRunning, "追従の後もエンジンが走っている")
    }

    /// ⚠️ **デバイスが確定するのは `start()` の後**（AVAudioEngine の定番の罠）。
    /// 前に読んだ `outputNode.outputFormat` はプレースホルダのことがあり、
    /// その値で繋ぐと**明示フォーマット自体が 44.1kHz**になる。
    ///
    /// ここで見るのは「**掛かった後に合流点がデバイスと揃っている**」こと。
    /// 揃わなくても fail-open で鳴り続けるので、落ちないことが第一要件
    @Test("on なら start() の後に合流点がデバイスと揃う")
    @MainActor
    func mixerRealignsAfterStart() throws {
        let previous = BusFollowing.enabled
        defer { BusFollowing.enabled = previous }
        BusFollowing.enabled = true

        let rack = InstrumentRack()
        try rack.start()
        defer { rack.engine.stop() }
        defer { rack.engine.stop() }

        #expect(rack.engine.isRunning, "揃え直しの後もエンジンが走っている")
        let device = rack.engine.outputNode.outputFormat(forBus: 0).sampleRate
        let mixer = rack.engine.mainMixerNode.outputFormat(forBus: 0).sampleRate
        let limiter = rack.masterLimiter.outputFormat(forBus: 0).sampleRate
        // 揃っていれば 192/32 が端まで通る。揃わなければ fail-open が働いた形
        #expect(mixer > 0 && limiter > 0)
        if mixer == device {
            #expect(limiter == device, "合流点が揃うならリミッターも揃う")
        }
    }

    /// ⚠️ **既に合っていれば繋ぎ直さない** — 無駄な stop/start を作らない。
    /// `start()` を通った直後にもう一度揃え直しを走らせても、
    /// 何も起きない（= エンジンが走り続ける）ことで確かめる
    @Test("既に合っていれば揃え直さない — 無駄な瞬断を作らない")
    @MainActor
    func realignIsNoOpWhenAligned() throws {
        let previous = BusFollowing.enabled
        defer { BusFollowing.enabled = previous }
        BusFollowing.enabled = true

        let rack = InstrumentRack()
        try rack.start()
        defer { rack.engine.stop() }
        defer { rack.engine.stop() }
        let settled = rack.engine.mainMixerNode.outputFormat(forBus: 0).sampleRate

        // 2 回目の追従（`followOutputRate` が同じ揃え直しを通る）
        rack.followOutputRate()
        #expect(rack.engine.isRunning)
        #expect(
            rack.engine.mainMixerNode.outputFormat(forBus: 0).sampleRate == settled,
            "合流点が動かない")
    }

    /// 同レートなら**エンジンを止めない**（無駄な音切れを作らない）
    @Test("既に合っていれば何もしない — 止めも繋ぎ直しもしない")
    @MainActor
    func busFollowIsNoOpWhenAlreadyMatching() async throws {
        // ⚠️ 既定に頼らない（同上）
        let previous = BusFollowing.enabled
        defer { BusFollowing.enabled = previous }
        BusFollowing.enabled = true

        let rack = InstrumentRack()
        guard let sampler = rack.catalog.first(where: { $0.name == LadySampler.displayName })
        else { return }
        try rack.start()
        defer { rack.engine.stop() }
        quiet(rack)
        try await rack.load(sampler, into: rack.drumSlot)

        // ロード時に既に追従済みなので、2 回目は何もしないはず
        rack.followOutputRate()
        let settled = try #require(
            rack.drumSlot.audioUnit?.auAudioUnit as? LadySampler
        ).outputBusses[0].format.sampleRate

        rack.followOutputRate()
        #expect(rack.engine.isRunning)
        let again = try #require(
            rack.drumSlot.audioUnit?.auAudioUnit as? LadySampler
        ).outputBusses[0].format.sampleRate
        #expect(again == settled, "同レートなら触らない")
    }

    @Test("スナップショット → 別ラックへ復元 — 楽器と gain が戻る")
    func snapshotRestore() async throws {
        let rack = InstrumentRack()
        let tone = try await TestInstrumentAU.component(in: rack)
        try rack.start()
        defer { rack.engine.stop() }
        try await rack.load(tone, into: rack.slots[2])
        rack.slots[2].parameterList.first?.value = 0.37
        rack.slots[2].refreshStateCache()
        rack.slots[2].gain = 0.42
        rack.select(2)

        let snapshot = rack.snapshot()
        rack.engine.stop()
        #expect(snapshot.slots.count == 1)
        #expect(snapshot.slots[0].index == 2)
        #expect(snapshot.slots[0].state != nil, "fullState が取れていること")

        // 新しいラックに復元
        let restored = InstrumentRack()
        try restored.start()
        await restored.restore(from: snapshot)
        #expect(restored.slots[2].displayName == tone.name)
        #expect(restored.slots[2].gain == 0.42)
        #expect(restored.selected == 2)
        let restoredLevel = try #require(restored.slots[2].parameterList.first)
        #expect(abs(restoredLevel.value - 0.37) < 0.001)
        restored.engine.stop()
    }

    @Test("差し替え後のオフスクリーン自動サムネ — 実 AU の顔が撮れる")
    func offscreenThumbnailRefresh() async throws {
        let rack = InstrumentRack()
        let tone = try await TestInstrumentAU.component(in: rack)
        try rack.start()
        defer { rack.engine.stop() }
        try await rack.load(tone, into: rack.slots[0])
        let unit = try #require(rack.slots[0].audioUnit)

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ladyland-thumbs-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = PluginThumbnailStore(directory: dir)
        let editors = PluginEditorWindows()
        editors.thumbnails = store

        editors.refreshThumbnail(for: rack.slots[0])
        // VC 取得 + 1.2s 描画待ち + キャプチャを最大 6 秒待つ
        for _ in 0..<60 where store.image(for: unit.audioComponentDescription) == nil {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(store.image(for: unit.audioComponentDescription) != nil,
                "エディタを開かずにサムネが撮れること（標準 view の AU）")

        // 撮影後にエディタを開けること（二重要求バグの再発防止 — 実機で発覚）
        editors.open(for: rack.slots[0])
        try await Task.sleep(for: .seconds(1))
        editors.close(for: 0)
        rack.engine.stop()
    }

    @Test("画面外撮影の店じまい後にエディタを開き直せる（実機バグ再現）")
    func reopenAfterOffscreenClose() async throws {
        let rack = InstrumentRack()
        let tone = try await TestInstrumentAU.component(in: rack)
        try rack.start()
        defer { rack.engine.stop() }
        try await rack.load(tone, into: rack.slots[0])

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ladyland-thumbs-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = PluginThumbnailStore(directory: dir)
        let editors = PluginEditorWindows()
        editors.thumbnails = store

        // 撮影 → 店じまい（VC 取得 + 1.2s 撮影 + 2.0s close）を確実に過ぎるまで待つ
        editors.refreshThumbnail(for: rack.slots[0])
        try await Task.sleep(for: .seconds(5))
        #expect(!editors.isOpenOnScreen(0), "この時点では閉じているはず")

        // 実機の操作: サムネ/ボタンを押してエディタを開く
        editors.open(for: rack.slots[0])
        var opened = false
        for _ in 0..<40 {
            if editors.isOpenOnScreen(0) { opened = true; break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(opened, "店じまい後の開き直しでプラグイン画面が出ること")
        editors.close(for: 0)
        rack.engine.stop()
    }

    @Test("focus pane custody — 借用 → ウィンドウへ返却 → 開き直し（VC 1 回制約下）")
    func focusPaneCustodyLifecycle() async throws {
        let rack = InstrumentRack()
        let tone = try await TestInstrumentAU.component(in: rack)
        try rack.start()
        defer { rack.engine.stop() }
        try await rack.load(tone, into: rack.slots[0])

        let editors = PluginEditorWindows()

        // 初回 borrow は VC 未取得 → nil を返しつつ駐機取得を蹴る
        var ready = false
        editors.onViewReady = { if $0 == 0 { ready = true } }
        #expect(editors.borrowFocusPaneView(for: rack.slots[0]) == nil)
        for _ in 0..<60 where !ready {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(ready, "VC が届くこと")

        // 届いたら借りられる（custody は focus pane 側、ウィンドウは隠れる）
        let view = try #require(editors.borrowFocusPaneView(for: rack.slots[0]))
        let pane = FocusPaneContainerView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
        pane.host(view, audioUnit: rack.slots[0].audioUnit?.auAudioUnit)
        pane.layout()
        #expect(view.frame.size == NSSize(width: 320, height: 180))
        pane.setFrameSize(NSSize(width: 480, height: 360))
        pane.layout()
        #expect(view.frame.size == NSSize(width: 480, height: 270))
        #expect(!editors.isOpenOnScreen(0), "貸出中はウィンドウは隠れている")

        // アイコンで開く = 返却してからウィンドウが前面へ（VC は再要求されない —
        // テスト AU も 2 回目の requestViewController に nil を返すため、
        // ここで開ければ custody の返却が正しく機能している証拠）
        editors.open(for: rack.slots[0])
        var opened = false
        for _ in 0..<40 {
            if editors.isOpenOnScreen(0) { opened = true; break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(opened, "返却後にウィンドウで開けること")
        pane.host(nil)
        #expect(view.window != nil, "旧ペインの解除が別窓からビューを取り去らない")
        #expect(
            editors.borrowFocusPaneView(for: rack.slots[0]) == nil,
            "ウィンドウ表示中は借りられない（そちらが優先）")
        editors.close(for: 0)
        rack.engine.stop()
    }

    @Test("Drafts — 差し替えで棚に残り、切替で戻り、昇格で舞台へ移る")
    func draftLifecycle() async throws {
        let rack = InstrumentRack()
        let tones = try await [TestInstrumentAU.component(in: rack), TestInstrumentAU.component(in: rack, index: 1)]
        try rack.start()
        defer { rack.engine.stop() }
        quiet(rack)

        // 差し替え → 前の姿が暗黙で棚に入る（音色が消えない）
        try await rack.load(tones[0], into: rack.slots[0])
        #expect(rack.slots[0].drafts.isEmpty)
        try await rack.load(tones[1], into: rack.slots[0])
        #expect(rack.slots[0].drafts.map(\.name) == [tones[0].name])

        // 棚の draft を着る → 今の姿と入れ替わる（無損失の往復）
        let stashed = try #require(rack.slots[0].drafts.first)
        await rack.activateDraft(withID: stashed.id, on: rack.slots[0])
        #expect(rack.slots[0].displayName == tones[0].name)
        #expect(rack.slots[0].drafts.map(\.name) == [tones[1].name])

        // 昇格（Cmd+Return 相当）→ live が空席へ移り選択も移る。
        // 工房は棚の最新（tones[1]）を着せ直し、棚は空になる
        rack.select(0)
        let target = await rack.promoteActiveDraft()
        #expect(target == 1)
        #expect(rack.selected == 1)
        #expect(rack.slots[1].displayName == tones[0].name, "昇格した音が舞台に立つ")
        #expect(rack.slots[1].drafts.isEmpty, "棚は工房に残る — 舞台には付いていかない")
        #expect(rack.slots[0].displayName == tones[1].name, "工房は棚の最新を着せ直す")
        #expect(rack.slots[0].drafts.isEmpty)

        // 棚つきの状態が snapshot に残ることも一周確認
        try await rack.load(tones[1], into: rack.slots[1])  // tones[0] が棚へ
        let snap = rack.snapshot()
        let slot1 = try #require(snap.slots.first { $0.index == 1 })
        #expect(slot1.drafts?.map(\.name) == [tones[0].name])

        rack.engine.stop()
    }

    @Test("マスターリミッターが mainMixer と output の間に常設される")
    func masterLimiterInChain() throws {
        let rack = InstrumentRack()
        try rack.start()
        defer { rack.engine.stop() }
        #expect(rack.engine.attachedNodes.contains(rack.masterLimiter))
        // 暗黙の mainMixer → output 接続が limiter 経由に置き換わっていること
        let destination = rack.engine.outputConnectionPoints(
            for: rack.engine.mainMixerNode, outputBus: 0
        ).first
        #expect(destination?.node === rack.masterLimiter)
        rack.engine.stop()
    }

    @Test("出力デバイス切替 — 切替後もエンジンが生きている")
    func outputSwitchSurvives() async throws {
        let devices = OutputDevice.all()
        guard !devices.isEmpty else { return }  // オーディオデバイスなし環境はスキップ
        #expect(devices.allSatisfy { !$0.uid.isEmpty }, "全デバイスが UID を持つこと")

        let rack = InstrumentRack()
        try rack.start()
        defer { rack.engine.stop() }

        // 既定デバイス（= 今鳴っているデバイス）への切替で経路の生存を検証する
        let target = devices.first { $0.id == OutputDevice.defaultOutputID() } ?? devices[0]
        let switched = rack.switchOutput(toUID: target.uid)
        #expect(switched, "切替が成功すること (\(target.name))")
        #expect(rack.engine.isRunning, "切替後もエンジンが動いていること")
        #expect(rack.outputDeviceUID == target.uid)

        // 不在 UID への切替は何もしない（エンジンを止めない）
        let missing = rack.switchOutput(toUID: "no-such-device-uid")
        #expect(!missing)
        #expect(rack.engine.isRunning, "不在デバイスでエンジンが止まらないこと")

        rack.engine.stop()
    }
}

/// テスト用の RMS 収集器（audio tap スレッドから書かれる）
final class RMSCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var _maxRMS: Float = 0

    var maxRMS: Float {
        lock.lock()
        defer { lock.unlock() }
        return _maxRMS
    }

    func add(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData?[0] else { return }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return }
        var sum: Float = 0
        for i in 0..<frames { sum += data[i] * data[i] }
        let rms = (sum / Float(frames)).squareRoot()
        lock.lock()
        _maxRMS = max(_maxRMS, rms)
        lock.unlock()
    }

    func reset() {
        lock.lock()
        _maxRMS = 0
        lock.unlock()
    }
}
