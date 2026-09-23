//! 席を空にする（mako 要望 2026-09-23「右クリックで空にできるようにしたい」）。
//!
//! 差し替え（load）と同じ外し方で、今の姿は暗黙 draft として棚に入る —
//! 「空にしてみたけどやっぱり戻す」が無損失で往復できることを固定する。
//! 楽器はプロセス内登録の LadySynth を使う（第三者プラグインに依存しない）。

import AVFoundation
import Testing

@testable import Ladyland

@Suite("席を空にする", .serialized)
@MainActor
struct UnloadTests {
    /// LadySynth を席 1 に載せたラック（音は極力小さく）
    private func rackWithSynth() async throws -> (InstrumentRack, InstrumentSlot) {
        let rack = InstrumentRack()
        try rack.start()
        rack.engine.mainMixerNode.outputVolume = 0.02
        let synth = try #require(rack.catalog.first { $0.name == LadySynth.displayName })
        let slot = rack.slots[0]
        try await rack.load(synth, into: slot)
        return (rack, slot)
    }

    @Test("外すと席が空になり、ノードもエンジンから外れる")
    func unloadEmptiesSlot() async throws {
        let (rack, slot) = try await rackWithSynth()
        let unit = try #require(slot.audioUnit)

        rack.unload(slot)

        #expect(slot.audioUnit == nil)
        #expect(slot.displayName == nil)
        #expect(slot.knobMappings.isEmpty)
        #expect(unit.engine == nil, "エンジンに残ったノードは鳴らないのに負荷だけ残る")
    }

    @Test("外した姿は draft として棚に残り、着せ直せば戻る")
    func unloadStashesDraft() async throws {
        let (rack, slot) = try await rackWithSynth()

        rack.unload(slot)

        let draft = try #require(slot.drafts.last)
        #expect(slot.drafts.count == 1)
        #expect(draft.name == LadySynth.displayName)

        await rack.activateDraft(withID: draft.id, on: slot)
        #expect(slot.displayName == LadySynth.displayName)
        #expect(slot.drafts.isEmpty, "着た draft は棚から消える")
    }

    @Test("差し替えも同じ外し方を通る — 旧楽器は棚に入り、新楽器が載る")
    func replaceStashesPrevious() async throws {
        let (rack, slot) = try await rackWithSynth()
        let old = try #require(slot.audioUnit)
        let sampler = try #require(rack.catalog.first { $0.name == LadySampler.displayName })

        try await rack.load(sampler, into: slot)

        #expect(slot.displayName == LadySampler.displayName)
        #expect(old.engine == nil)
        #expect(slot.drafts.map(\.name) == [LadySynth.displayName])
    }

    @Test("空の席を外しても何も起きない（棚も増えない）")
    func unloadEmptySlotIsNoop() async throws {
        let (rack, slot) = try await rackWithSynth()
        rack.unload(slot)

        rack.unload(slot)

        #expect(slot.drafts.count == 1)
    }

    @Test("席の属性（色・名前・既定）は外しても再起動をまたいで残る")
    func seatAttributesSurviveRestart() async throws {
        let (rack, slot) = try await rackWithSynth()
        slot.rotoColor = 12
        slot.customName = "Lead"
        slot.rememberAsDefault()

        rack.unload(slot)
        let saved = rack.snapshot()

        let restored = InstrumentRack()
        await restored.restore(from: saved)
        let seat = restored.slots[0]
        #expect(seat.audioUnit == nil, "空にした席は空のまま戻る")
        #expect(seat.rotoColor == 12)
        #expect(seat.customName == "Lead")
        #expect(seat.defaultSnapshot?.name == LadySynth.displayName)
        #expect(seat.drafts.count == 1)
    }
}
