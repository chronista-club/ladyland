//! Optional vendor compatibility checks. Authorize/install Gadget before opting in.
import AVFoundation
import Testing
@testable import Ladyland

@Suite("KORG Gadget compatibility", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["LADYLAND_TEST_GADGET"] == "1"))
@MainActor
struct GadgetCompatibilityTests {
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

    @Test("MIDI モードの席 CC が割当パラメータに効く")
    func seatCCAppliesToParameter() async throws {
        let rack = InstrumentRack()
        let korg = try #require(rack.catalog.first(where: { $0.name.contains("Memphis") }), "Opt-in Gadget tests require an installed, authorized plugin")
        try rack.start()
        defer { rack.engine.stop() }
        quiet(rack)
        try await rack.load(korg, into: rack.slots[0])
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
        let korg = try #require(rack.catalog.first(where: { $0.name.contains("Memphis") }), "Opt-in Gadget tests require an installed, authorized plugin")
        try rack.start()
        defer { rack.engine.stop() }
        quiet(rack)
        try await rack.load(korg, into: rack.slots[0])

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

    @Test("ドラムスロット経路 — London をロードしてドラムノートで発音")
    func drumSlotPath() async throws {
        let rack = InstrumentRack()
        let london = try #require(rack.catalog.first(where: { $0.name.contains("London") }), "Opt-in Gadget tests require an installed, authorized plugin")
        try rack.start()
        defer { rack.engine.stop() }
        quiet(rack)
        try await rack.load(london, into: rack.drumSlot)

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

    @Test("ロード済みスロットへの差し替え — 別のガジェットに入れ替えて発音")
    func reloadIntoOccupiedSlot() async throws {
        let rack = InstrumentRack()
        let korgs = rack.catalog.filter { $0.manufacturer.contains("KORG") }
        try #require(korgs.count >= 2, "Install and authorize at least two Gadget instruments")
        try rack.start()
        defer { rack.engine.stop() }
        quiet(rack)

        // 1 台目をロード → 2 台目に差し替え（レベル tap が付いた状態の detach 経路）
        try await rack.load(korgs[0], into: rack.drumSlot)
        try await rack.load(korgs[1], into: rack.drumSlot)
        #expect(rack.drumSlot.displayName == korgs[1].name)

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

    @Test("スナップショット → 別ラックへ復元 — 楽器と gain が戻る")
    func snapshotRestore() async throws {
        let rack = InstrumentRack()
        let korg = try #require(rack.catalog.first(where: { $0.manufacturer.contains("KORG") }), "Opt-in Gadget tests require an installed, authorized plugin")
        try rack.start()
        defer { rack.engine.stop() }
        try await rack.load(korg, into: rack.slots[2])
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
        #expect(restored.slots[2].displayName == korg.name)
        #expect(restored.slots[2].gain == 0.42)
        #expect(restored.selected == 2)
        restored.engine.stop()
    }

    @Test("差し替え後のオフスクリーン自動サムネ — 実 AU の顔が撮れる")
    func offscreenThumbnailRefresh() async throws {
        let rack = InstrumentRack()
        let korg = try #require(rack.catalog.first(where: { $0.manufacturer.contains("KORG") }), "Opt-in Gadget tests require an installed, authorized plugin")
        try rack.start()
        defer { rack.engine.stop() }
        try await rack.load(korg, into: rack.slots[0])
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
        let korg = try #require(rack.catalog.first(where: { $0.manufacturer.contains("KORG") }), "Opt-in Gadget tests require an installed, authorized plugin")
        try rack.start()
        defer { rack.engine.stop() }
        try await rack.load(korg, into: rack.slots[0])

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
        let korg = try #require(rack.catalog.first(where: { $0.manufacturer.contains("KORG") }), "Opt-in Gadget tests require an installed, authorized plugin")
        try rack.start()
        defer { rack.engine.stop() }
        try await rack.load(korg, into: rack.slots[0])

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
        let view = editors.borrowFocusPaneView(for: rack.slots[0])
        #expect(view != nil, "focus pane が view を借りられること")
        #expect(!editors.isOpenOnScreen(0), "貸出中はウィンドウは隠れている")

        // アイコンで開く = 返却してからウィンドウが前面へ（VC は再要求されない —
        // KORG AU は 2 回目の requestViewController に nil を返すため、
        // ここで開ければ custody の返却が正しく機能している証拠）
        editors.open(for: rack.slots[0])
        var opened = false
        for _ in 0..<40 {
            if editors.isOpenOnScreen(0) { opened = true; break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(opened, "返却後にウィンドウで開けること")
        #expect(
            editors.borrowFocusPaneView(for: rack.slots[0]) == nil,
            "ウィンドウ表示中は借りられない（そちらが優先）")
        editors.close(for: 0)
        rack.engine.stop()
    }

    @Test("Drafts — 差し替えで棚に残り、切替で戻り、昇格で舞台へ移る")
    func draftLifecycle() async throws {
        let rack = InstrumentRack()
        let korgs = rack.catalog.filter { $0.manufacturer.contains("KORG") }
        try #require(korgs.count >= 2, "Install and authorize at least two Gadget instruments")
        try rack.start()
        defer { rack.engine.stop() }
        quiet(rack)

        // 差し替え → 前の姿が暗黙で棚に入る（音色が消えない）
        try await rack.load(korgs[0], into: rack.slots[0])
        #expect(rack.slots[0].drafts.isEmpty)
        try await rack.load(korgs[1], into: rack.slots[0])
        #expect(rack.slots[0].drafts.map(\.name) == [korgs[0].name])

        // 棚の draft を着る → 今の姿と入れ替わる（無損失の往復）
        let stashed = try #require(rack.slots[0].drafts.first)
        await rack.activateDraft(withID: stashed.id, on: rack.slots[0])
        #expect(rack.slots[0].displayName == korgs[0].name)
        #expect(rack.slots[0].drafts.map(\.name) == [korgs[1].name])

        // 昇格（Cmd+Return 相当）→ live が空席へ移り選択も移る。
        // 工房は棚の最新（korgs[1]）を着せ直し、棚は空になる
        rack.select(0)
        let target = await rack.promoteActiveDraft()
        #expect(target == 1)
        #expect(rack.selected == 1)
        #expect(rack.slots[1].displayName == korgs[0].name, "昇格した音が舞台に立つ")
        #expect(rack.slots[1].drafts.isEmpty, "棚は工房に残る — 舞台には付いていかない")
        #expect(rack.slots[0].displayName == korgs[1].name, "工房は棚の最新を着せ直す")
        #expect(rack.slots[0].drafts.isEmpty)

        // 棚つきの状態が snapshot に残ることも一周確認
        try await rack.load(korgs[1], into: rack.slots[1])  // korgs[0] が棚へ
        let snap = rack.snapshot()
        let slot1 = try #require(snap.slots.first { $0.index == 1 })
        #expect(slot1.drafts?.map(\.name) == [korgs[0].name])

        rack.engine.stop()
    }
}
