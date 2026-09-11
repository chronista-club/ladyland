//! タイル並び替えのテスト（design/06 §8 追補）。
//!
//! TileDragMath（ヒットテスト・着地 offset）と InstrumentRack.swapSlots
//! （中身交換・選択追従・guard）。AU 実機なしで検証できる範囲を固定する —
//! AU ありの移植（タップ張り直し・エディタ追従）は実機確認の領分。

import CoreGraphics
import Testing

@testable import Ladyland

@Suite("TileDragMath")
struct TileDragMathTests {
    /// 96×244 のタイルが spacing 8 で 3 枚並ぶ Lane を模す
    private let frames: [Int: CGRect] = [
        0: CGRect(x: 0, y: 0, width: 96, height: 244),
        1: CGRect(x: 104, y: 0, width: 96, height: 244),
        2: CGRect(x: 208, y: 0, width: 96, height: 244),
    ]

    @Test("セル内のポイントはそのセルに落ちる")
    func hitInsideCell() {
        #expect(TileDragMath.target(frames: frames, point: CGPoint(x: 150, y: 100)) == 1)
        #expect(TileDragMath.target(frames: frames, point: CGPoint(x: 10, y: 10)) == 0)
    }

    @Test("どのセルにも掛からないポイントは nil（枠外リリース = 元に戻る）")
    func missOutside() {
        #expect(TileDragMath.target(frames: frames, point: CGPoint(x: 100, y: 100)) == nil)
        #expect(TileDragMath.target(frames: frames, point: CGPoint(x: 150, y: 300)) == nil)
        #expect(TileDragMath.target(frames: frames, point: CGPoint(x: -5, y: 10)) == nil)
    }

    @Test("着地 offset はセル原点の差分")
    func settleOffsetIsFrameDelta() {
        let offset = TileDragMath.settleOffset(source: frames[0]!, target: frames[2]!)
        #expect(offset == CGSize(width: 208, height: 0))
        let back = TileDragMath.settleOffset(source: frames[2]!, target: frames[0]!)
        #expect(back == CGSize(width: -208, height: 0))
    }
}

@Suite("InstrumentRack スロット入れ替え")
@MainActor
struct SwapSlotsTests {
    @Test("gain とつまみ割当が入れ替わる（空スロット同士でも成立）")
    func swapExchangesContents() {
        let rack = InstrumentRack()
        rack.slots[1].gain = 0.3
        rack.slots[5].gain = 0.9
        rack.slots[5].knobMappings = [FaceKnobMapping(knob: 0, address: 42, name: "Cutoff")]

        rack.swapSlots(1, 5)

        #expect(rack.slots[1].gain == 0.9)
        #expect(rack.slots[5].gain == 0.3)
        #expect(rack.slots[1].knobMappings == [FaceKnobMapping(knob: 0, address: 42, name: "Cutoff")])
        #expect(rack.slots[5].knobMappings.isEmpty)
        #expect(rack.slots[1].displayName == nil, "空スロットの名前は nil のまま")
    }

    @Test("選択中スロットを動かすと選択が追従する（keyboard target の楽器が変わらない）")
    func selectionFollowsInstrument() {
        let rack = InstrumentRack()
        rack.select(2)

        rack.swapSlots(2, 6)
        #expect(rack.selected == 6, "掴んだ側に追従")

        rack.swapSlots(0, 6)
        #expect(rack.selected == 0, "相手側でも追従")

        rack.swapSlots(3, 4)
        #expect(rack.selected == 0, "無関係な交換では動かない")
    }

    @Test("同一 index・範囲外（ドラム枠含む）は no-op")
    func guardsInvalidIndices() {
        let rack = InstrumentRack()
        rack.select(3)
        rack.slots[3].gain = 0.42

        rack.swapSlots(3, 3)
        rack.swapSlots(0, InstrumentRack.trackCount)  // = ドラム枠は対象外
        rack.swapSlots(-1, 2)

        #expect(rack.selected == 3)
        #expect(rack.slots[3].gain == 0.42)
    }
}
