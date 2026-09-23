//! テンポの口（`musicalContextBlock`）は載せる前に 1 回だけ渡し、以後差し替えない。
//!
//! 実測 2026-09-23（スタジオ練習で 1 時間に約 10 回落ちた）: テンポが変わるたびに
//! 口を丸ごと差し替えていたので、**別プロセスの AUv3（MediSynth）が render 中に
//! 解放済みの口を呼んで落ちた**（`AUAudioUnit_XPC internalRenderBlock` → PC 0）。
//! 再現: MediSynth を載せて 2ms ごとに差し替えると 200 回以内に SIGBUS。
//! AUv2（Gadget）は 4000 回差し替えても落ちない — 落ちるのは XPC だけ。
//!
//! テスト用 AU が「render の資源を持っている間に差し替えられた回数」を数える。

import AVFoundation
import Testing

@testable import Ladyland

@Suite("テンポの口", .serialized)
@MainActor
struct HostTempoTests {
    init() { TestInstrumentAU.register() }

    private func rack() throws -> InstrumentRack {
        let rack = InstrumentRack()
        try rack.start()
        rack.engine.mainMixerNode.outputVolume = 0.02
        return rack
    }

    private func load(into slot: InstrumentSlot, of rack: InstrumentRack) async throws
        -> TestInstrumentAU
    {
        let tone = try await TestInstrumentAU.component(in: rack)
        try await rack.load(tone, into: slot)
        return try #require(slot.audioUnit?.auAudioUnit as? TestInstrumentAU)
    }

    /// 口を呼んで (成否, テンポ) を読む — AU が render の頭でやるのと同じ呼び方
    private func ask(_ unit: TestInstrumentAU) throws -> (Bool, Double) {
        let block = try #require(unit.musicalContextBlock)
        var tempo = 0.0
        let ok = block(&tempo, nil, nil, nil, nil, nil)
        return (ok, tempo)
    }

    @Test("口は render の資源を持つ前に 1 回だけ渡る")
    func blockIsSetOnceBeforeRendering() async throws {
        let rack = try rack()
        defer { rack.engine.stop() }
        let unit = try await load(into: rack.slots[0], of: rack)

        #expect(unit.musicalContextSets == 1)
        #expect(unit.musicalContextSetsWhileRendering == 0)
    }

    @Test("テンポが変わっても口は差し替わらず、新しいテンポを返す")
    func tempoChangeKeepsBlock() async throws {
        let rack = try rack()
        defer { rack.engine.stop() }
        let unit = try await load(into: rack.slots[0], of: rack)

        for bpm in stride(from: 100.0, through: 130.0, by: 1.5) {
            rack.setMusicalTempo(bpm)
        }

        #expect(unit.musicalContextSetsWhileRendering == 0,
                "render 中の差し替えが別プロセスの AU を落とす")
        let (ok, tempo) = try ask(unit)
        #expect(ok)
        #expect(tempo == 130.0)
    }

    @Test("同期を切っても口は残し、「分からない」と答える（プラグインが自前の既定で動く）")
    func syncOffAnswersFalse() async throws {
        let rack = try rack()
        defer { rack.engine.stop() }
        let unit = try await load(into: rack.slots[0], of: rack)
        rack.setMusicalTempo(120)

        rack.setMusicalTempo(nil)

        #expect(unit.musicalContextSetsWhileRendering == 0)
        #expect(try ask(unit).0 == false)
    }

    @Test("載せる前に決まっていたテンポも最初から届く")
    func tempoBeforeLoadIsDelivered() async throws {
        let rack = try rack()
        defer { rack.engine.stop() }
        rack.setMusicalTempo(98)

        let unit = try await load(into: rack.slots[3], of: rack)

        let (ok, tempo) = try ask(unit)
        #expect(ok)
        #expect(tempo == 98)
    }

    @Test("並べ替えでも口は差し替わらない")
    func swapKeepsBlock() async throws {
        let rack = try rack()
        defer { rack.engine.stop() }
        let unit = try await load(into: rack.slots[0], of: rack)
        rack.setMusicalTempo(110)

        rack.swapSlots(0, 5)

        #expect(unit.musicalContextSetsWhileRendering == 0)
        #expect(try ask(unit).1 == 110)
    }
}
