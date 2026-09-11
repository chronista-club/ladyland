//! INST マトリクスの席編集（mako 要望 2026-08-12「drag & drop で割り当て変更」
//! 「ページのコピー/並べ替え」）— 配置換えの純関数を守る

import Testing

@testable import Ladyland

@Suite("席の配置換え")
struct SeatEditTests {
    private func mapping(_ knob: Int, name: String = "") -> FaceKnobMapping {
        FaceKnobMapping(knob: knob, address: UInt64(1000 + knob), name: name.isEmpty ? "P\(knob)" : name)
    }

    @Test("埋 → 空 = 移動（元の席が空く）")
    func moveToEmpty() {
        let moved = FaceKnobAssignment.swappingSeats([mapping(0)], 0, 5)
        #expect(moved.count == 1)
        #expect(moved[0].knob == 5)
    }

    @Test("埋 → 埋 = 交換 — 消えない操作（billboard のタイル交換と同じ）")
    func swapOccupied() {
        let swapped = FaceKnobAssignment.swappingSeats(
            [mapping(0, name: "Cutoff"), mapping(5, name: "Reso")], 0, 5)
        #expect(swapped.first { $0.name == "Cutoff" }?.knob == 5)
        #expect(swapped.first { $0.name == "Reso" }?.knob == 0)
        #expect(swapped.count == 2)
    }

    @Test("同じ席への drop は何もしない")
    func dropOnSelf() {
        let mappings = [mapping(3)]
        #expect(FaceKnobAssignment.swappingSeats(mappings, 3, 3) == mappings)
    }

    @Test("ページ交換は 8 席まとめて — ページ内の位置は保たれる")
    func swapPages() {
        // P1（CC0-7）に 2 席、P3（CC16-23）に 1 席
        let mappings = [mapping(0), mapping(7), mapping(18)]
        let swapped = FaceKnobAssignment.swappingPages(mappings, 0, 2)
        #expect(Set(swapped.map(\.knob)) == [16, 23, 2])
    }

    @Test("ページコピーは複製 — コピー先の既存は消え、他ページは無傷")
    func copyPage() {
        let mappings = [mapping(0, name: "Cutoff"), mapping(16, name: "Old"), mapping(8)]
        let copied = FaceKnobAssignment.copyingPage(mappings, from: 0, to: 2)
        // P3 には Cutoff の複製（CC16）だけ。元の P1 も残る。P2（CC8）は無傷
        #expect(copied.count == 3)
        #expect(copied.filter { $0.name == "Cutoff" }.map(\.knob).sorted() == [0, 16])
        #expect(!copied.contains { $0.name == "Old" })
        #expect(copied.contains { $0.knob == 8 })
    }

    @Test("自分へのコピーは何もしない")
    func copyOntoSelf() {
        let mappings = [mapping(0)]
        #expect(FaceKnobAssignment.copyingPage(mappings, from: 0, to: 0) == mappings)
    }
}
