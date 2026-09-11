//! トラックグリッドのテスト（design/06 §8 追補）。
//!
//! N=24 を 8 列 × 3 バンクの全面グリッドで表示（表示窓は 2026-08-01 中に
//! 廃止 — 全部見えるなら窓は要らない）。bankStart は選択からの導出値、
//! Cmd+矢印のカーソル移動は全体ラップ、新旧 rack.json の復元先解決。

import Testing

@testable import Ladyland

@Suite("トラックグリッド")
@MainActor
struct TrackGridTests {
    @Test("bankStart は選択のいる行の先頭（導出値 — 状態を持たない）")
    func bankStartDerivation() {
        let rack = InstrumentRack()
        #expect(rack.bankStart == 0)
        rack.select(11)
        #expect(rack.bankStart == 8)
        rack.select(17)
        #expect(rack.bankStart == 16)
        rack.select(2)
        #expect(rack.bankStart == 0)
    }

    @Test("slotRows は 8 列 × バンク行で、絶対 index が連続する")
    func slotRowsShape() {
        let rack = InstrumentRack()
        let rows = rack.slotRows
        #expect(rows.count == InstrumentRack.bankCount)
        #expect(rows[0].map(\.index) == Array(0..<8))
        #expect(rows[1].map(\.index) == Array(8..<16))
        #expect(rows.last?.map(\.index) == Array((InstrumentRack.trackCount - 8)..<InstrumentRack.trackCount))
    }

    @Test("selectOffset ±1 は全体をラップする（0 の左 = 末尾）")
    func horizontalWrap() {
        let rack = InstrumentRack()
        rack.selectOffset(-1)
        #expect(rack.selected == InstrumentRack.trackCount - 1)
        rack.selectOffset(+1)
        #expect(rack.selected == 0)
    }

    @Test("selectOffset ±8 は行ジャンプ（末尾行からのさらに下はラップ）")
    func verticalJumpWraps() {
        let rack = InstrumentRack()
        // ⚠️ 行数を直書きしない — trackCount は 24 → 32 → 64 と動いている
        // （2026-08-09 に 64 へ。ここが 32 前提の直書きで落ちた）
        let width = InstrumentRack.visibleCount
        rack.select(1)
        for row in 1..<InstrumentRack.bankCount {
            rack.selectOffset(+width)
            #expect(rack.selected == 1 + row * width, "\(row + 1) 行目へ")
        }
        let lastRowSeat = rack.selected
        rack.selectOffset(+width)
        #expect(rack.selected == 1, "最下行から下は先頭行へラップ")
        rack.selectOffset(-width)
        #expect(rack.selected == lastRowSeat)
    }

    @Test("復元先の解決 — 総数 8 / 16 / 24 時代の rack.json も現行 32 で読める")
    func restoreTargets() {
        // 総数 8 の時代（trackCount 無し）: drum=8
        #expect(InstrumentRack.restoreTarget(snapIndex: 8, savedTrackCount: 8) == .drum)
        #expect(InstrumentRack.restoreTarget(snapIndex: 5, savedTrackCount: 8) == .track(5))
        // 総数 16 の時代: drum=16
        #expect(InstrumentRack.restoreTarget(snapIndex: 16, savedTrackCount: 16) == .drum)
        #expect(InstrumentRack.restoreTarget(snapIndex: 8, savedTrackCount: 16) == .track(8))
        // 現行 24
        #expect(InstrumentRack.restoreTarget(snapIndex: 24, savedTrackCount: 24) == .drum)
        #expect(InstrumentRack.restoreTarget(snapIndex: 23, savedTrackCount: 24) == .track(23))
        // 範囲外は捨てる（fail-open — 1 スロットの異常で起動を止めない）
        #expect(InstrumentRack.restoreTarget(snapIndex: 30, savedTrackCount: 24) == .invalid)
        #expect(InstrumentRack.restoreTarget(snapIndex: -1, savedTrackCount: 24) == .invalid)
    }
}
