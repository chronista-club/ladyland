//! Track Drafts のテスト（design/06 §8、mako 発案「工房と舞台の分離」）。
//!
//! 昇格先の解決（純関数）と、棚の永続化 roundtrip / 後方互換。
//! AU 実機が要るライフサイクル（暗黙 stash → 切替 → 昇格）は
//! IntegrationTests 側（認証不要のテスト専用 AU）。

import Foundation
import Testing

@testable import Ladyland

@Suite("Draft 昇格先の解決")
struct PromotionTargetTests {
    @Test("現在位置から前方の最初の空席（ラップあり）")
    func nextEmptyForward() {
        // ○ = 空席。[占,占,○,占,○] で index 0 から → 2
        let occupied = [true, true, false, true, false]
        #expect(InstrumentRack.promotionTarget(from: 0, occupied: occupied) == 2)
        // index 3 から → 4（前方優先）
        #expect(InstrumentRack.promotionTarget(from: 3, occupied: occupied) == 4)
        // index 4（自分は空席でも自分には昇格しない）から → ラップして 2
        #expect(InstrumentRack.promotionTarget(from: 4, occupied: occupied) == 2)
    }

    @Test("末尾からのラップで先頭側の空席を見つける")
    func wrapsAround() {
        let occupied = [false, true, true, true]
        #expect(InstrumentRack.promotionTarget(from: 3, occupied: occupied) == 0)
    }

    @Test("満席なら nil（昇格しない — 事故でどこかを潰さない）")
    func fullRackReturnsNil() {
        let occupied = [Bool](repeating: true, count: 8)
        #expect(InstrumentRack.promotionTarget(from: 3, occupied: occupied) == nil)
    }
}

@Suite("Draft の永続化")
struct DraftPersistenceTests {
    private func makeDraft(name: String) -> Draft {
        Draft(
            id: UUID(),
            componentType: 0x6175_6D75,
            componentSubType: 0x4B47_3338,
            componentManufacturer: 0x4B4F_5247,
            name: name,
            gain: 0.6,
            state: Data([0x0A, 0x0B]),
            knobs: [FaceKnobMapping(knob: 2, address: 7, name: "Reso")],
            savedAt: Date(timeIntervalSinceReferenceDate: 1_000_000)
        )
    }

    @Test("棚つきスナップショットが roundtrip する")
    func draftsRoundtrip() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ladyland-drafts-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        var slot = SlotSnapshot(
            index: 0, componentType: 1, componentSubType: 2, componentManufacturer: 3,
            name: "Live", gain: 0.8, state: nil)
        slot.drafts = [makeDraft(name: "着 A"), makeDraft(name: "着 B")]
        let snapshot = RackSnapshot(slots: [slot], selected: 0)

        try RackStore.save(snapshot, to: url)
        let loaded = try #require(RackStore.load(from: url))
        let drafts = try #require(loaded.slots[0].drafts)
        #expect(drafts.map(\.name) == ["着 A", "着 B"])
        #expect(drafts[0].knobs == [FaceKnobMapping(knob: 2, address: 7, name: "Reso")])
        #expect(drafts[0].state == Data([0x0A, 0x0B]))
    }

    @Test("drafts 導入前の rack.json は棚なし（nil）で読める")
    func legacyWithoutDrafts() throws {
        let json = """
            {"selected":0,"slots":[{"index":0,"componentType":1,"componentSubType":2,
            "componentManufacturer":3,"name":"Legacy","gain":0.5}]}
            """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ladyland-nodrafts-\(UUID().uuidString).json")
        try Data(json.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let loaded = try #require(RackStore.load(from: url))
        #expect(loaded.slots[0].drafts == nil)
    }
}
