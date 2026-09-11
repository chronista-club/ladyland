//! ノブストリップ（ノブ HUD）のテスト。
//!
//! ページは受信 CC から直読み — ページ = CC ÷ 8 が正典（`KeystageKnobs`）。
//! Page +/- 自体は MIDI 無音（Keystage_MIDIimp.txt 精査 2026-08-01）なので、
//! 追従は最初のノブ 1 動きから。帯の外を材料にしない規則と、
//! ページ → 8 セルの導出をピン留めする。

import Testing

@testable import Ladyland

@Suite("ノブページ推定")
struct KnobPageInferenceTests {
    /// ⭐ **ノブ帯（CC0-63）は CC 番号がページを自己申告している**
    /// （mako 裁定 2026-08-07）。実機はデバイス自身のページ（PAGE -/+）が
    /// 送る組を決めるので、**推定ではなくそのまま読める**
    /// （`KnobSelect` は KONTROL EDITOR の表示切替にすぎず、設定不要）
    @Test("ノブ帯のページは CC から直接引ける")
    func pageFromKnobBand() {
        for (index, cells) in KnobPages.pages.enumerated() {
            for cc in cells {
                #expect(
                    FaceKnobAssignment.inferredPage(cc: cc) == index,
                    "CC\(cc) は P\(index + 1)")
            }
        }
    }

    /// ⚠️ **帯の外は材料外**（mako 裁定 2026-08-09「Page は 8 つで」）。
    /// かつては「席プールの並びの位置から引く」第 2 の答えがあり、帯と
    /// 食い違うページを返しうる出口になっていた（監査 B-1。2026-08-09 削除）
    @Test("帯の外はページを名乗らない — 第 2 の答えは消えた")
    func pageOutsideBand() {
        for cc in [64, 65, 100, 119, 127] {
            #expect(FaceKnobAssignment.inferredPage(cc: cc) == nil, "CC\(cc) は帯の外")
        }
        #expect(FaceKnobAssignment.inferredPage(cc: 0) == 0, "帯の先頭は P1")
        #expect(FaceKnobAssignment.inferredPage(cc: 63) == 7, "帯の末尾は P8")
    }

    @Test("ノブ以外が送る同番号 CC は除外 — Mod/Exp/予約/PB で誤追従しない")
    func excludesNonKnobSources() {
        #expect(
            FaceKnobAssignment.inferredPage(cc: FaceKnobAssignment.modWheelCC) == nil,
            "Mod ホイール（実機で焼いた値。CC1 ではない）")
        #expect(FaceKnobAssignment.inferredPage(cc: FaceKnobAssignment.expressionCC) == nil, "Exp ペダル")
        // ⚠️ **CC62/63 は 2026-08-07 に解放**（ページ送りが 104/105 へ移った）。
        // いまは Keystage のノブ帯 P8 の席なので、ページが引けるのが正しい
        #expect(FaceKnobAssignment.inferredPage(cc: 62) == KnobPages.page(forCC: 62))
        #expect(FaceKnobAssignment.inferredPage(cc: 63) == KnobPages.page(forCC: 63))
        #expect(FaceKnobAssignment.inferredPage(cc: 64) == nil, "サスティンペダル")
        #expect(
            FaceKnobAssignment.inferredPage(cc: FaceKnobAssignment.pitchBendControl) == nil,
            "PB 擬似 Ctrl")
        #expect(FaceKnobAssignment.inferredPage(cc: -1) == nil)
    }

    @Test("見出しラベル — 帯から引く（真下の 8 枠と同じ CC）、未確定は P?")
    func pageLabel() {
        // ⚠️⚠️ **見出しは帯（`KeystageKnobs`）から引く**（監査 2026-08-08 の B-2）。
        // 以前は席プールの分割で「P1 · CC1-6,8-9」と出ていて、**真下の 8 枠
        // （帯分割 = CC0-7）と食い違っていた**。見出しと中身が同じ源であること
        // が主張の本体
        for index in [0, 2, KnobPages.pageCount - 1] {
            #expect(
                FaceKnobAssignment.pageLabel(index)
                    == "P\(index + 1) · CC" + AssignList.compactRanges(KnobPages.page(index)),
                "P\(index + 1) が帯の席と食い違う")
        }
        // ⭐ **P1 = CC0-7 と読めること**が B-2 修正の目に見える成果。
        // ここだけは値を直書きする — 「帯の先頭 = 0」自体が主張
        #expect(FaceKnobAssignment.pageLabel(0) == "P1 · CC0-7")
        // 整形そのもの（連番は `-` で畳み、飛びは `,` で継ぐ）
        #expect(AssignList.compactRanges([1, 2, 3, 4, 5, 6, 8, 9]) == "1-6,8-9")
        #expect(FaceKnobAssignment.pageLabel(nil) == "P?")
        #expect(FaceKnobAssignment.pageLabel(KnobPages.pageCount) == "P?", "帯の外は P?")
        #expect(FaceKnobAssignment.pageLabel(99) == "P?", "範囲外も P?")
    }

    @Test("トレースからの材料抽出 — 横取り済みと素通し CC の両方、他は対象外")
    func keystageCCFromRoute() {
        #expect(MidiRoute.knob(cc: 5, value: 64).keystageCC == 5)
        #expect(MidiRoute.knob(cc: 128, value: 64).keystageCC == 128, "PB は拾って推定側で除外")
        #expect(
            MidiRoute.keyboard(status: 0xB0, data1: 34, data2: 10, hasTarget: true)
                .keystageCC == 34,
            "素通し CC も材料に拾う（帯の CC は実際には .knob で来る — B-7）")
        #expect(
            MidiRoute.keyboard(status: 0xB3, data1: 34, data2: 10, hasTarget: true)
                .keystageCC == 34, "チャンネル不問（Keystage のノブ ch は Scene 設定次第）")
        #expect(
            MidiRoute.keyboard(status: 0x90, data1: 60, data2: 100, hasTarget: true)
                .keystageCC == nil, "ノートは材料外")
        #expect(MidiRoute.drumKnob(cc: 80, value: 64).keystageCC == nil, "LPD8 側は対象外")
        #expect(MidiRoute.unassignedCh16(cc: 60, value: 0).keystageCC == nil, "ch16 は対象外")
        #expect(MidiRoute.nav(direction: 1).keystageCC == nil)
    }
}

@Suite("ノブストリップのセル導出")
struct KnobStripCellsTests {
    private let mappings = [
        FaceKnobMapping(knob: 16, address: 0xA1, name: "Cutoff"),
        FaceKnobMapping(knob: 23, address: 0xA2, name: "Resonance"),
        FaceKnobMapping(knob: 1, address: 0xA3, name: "Vibrato"),
        FaceKnobMapping(knob: 40, address: 0xA4, name: "圏外（別ページ）"),
    ]

    @Test("ページの 8 セル — 位置と CC が連続し、割当名が載る")
    func cellsShape() {
        let cells = KnobStrip.cells(page: 2, mappings: mappings)
        #expect(cells.count == 8)
        #expect(cells.map(\.cc) == Array(16..<24))
        #expect(cells.map(\.position) == Array(0..<8))
        #expect(cells[0].name == "Cutoff")
        #expect(cells[7].name == "Resonance")
        #expect(cells[1].name == nil, "未割当 = 名前なし（帯が飲むので楽器へも届かない）")
    }

    @Test("別ページの割当は混ざらない")
    func otherPageExcluded() {
        let cells = KnobStrip.cells(page: 2, mappings: mappings)
        #expect(!cells.contains { $0.name == "圏外（別ページ）" })
        #expect(!cells.contains { $0.name == "Vibrato" })
    }

    @Test("Mod は CC1 を離れた — ページ 1 の CC1 はただのノブ")
    func modMovedOffPageOne() {
        // 実機で Wheel を焼き替えたので（CC1 → CC119 → CC116）、
        // **CC1 はもう Mod ホイールではない** — 物理ノブ 2 の席として使える
        let cells = KnobStrip.cells(page: 0, mappings: mappings)
        #expect(cells[1].name == "Vibrato")
        #expect(cells[1].badge == nil, "CC1 にバッジは付かない")

        // ⚠️ **Mod（CC116）は帯の外 — ノブストリップに席は無い**（監査 2026-08-08
        // の B-2）。以前はプール分割の P14 として描けてしまい、ここが「M バッジが
        // 載る」を固定していた。役割バッジは割当一覧の演奏セクション側で出す
        // （`KnobPickupTests` の controllerBadge が押さえている）
        #expect(
            KnobPages.page(forCC: FaceKnobAssignment.modWheelCC) == nil,
            "Mod は帯の外 — ストリップに描かれない")
    }

    /// ⚠️ **CC62/63 の予約は 2026-08-07 に解いた**（ページ送りが Rec/Loop へ
    /// 移り、Keystage のノブ帯の一部になった）。
    ///
    /// ⚠️⚠️ **P9 は存在しない**（監査 2026-08-08 の B-2）。以前はここが
    /// `cells(page: 8)` = CC64-71（ペダル帯）を「SUSTAIN が出る」として
    /// **固定してしまっていた** — `KeystageKnobs` が全力で禁じているページを
    /// 表示層だけが描けた。帯から引くようになった今、**空**が正しい
    @Test("最終ページの席は解放済み — P9 は存在しない")
    func reservedCells() {
        let page7 = KnobStrip.cells(page: 7, mappings: [])
        #expect(!page7[6].reserved, "CC62 は解放された")
        #expect(!page7[7].reserved, "CC63 は解放された")
        #expect(
            KnobStrip.cells(page: KnobPages.pageCount, mappings: []).isEmpty,
            "帯の外（ペダル帯）を描いてはいけない")
    }
}

/// **未割り当ての表示規則**（mako 裁定 2026-08-06「パラメータが未割り当ての場合、
/// グレー背景で `‐` で表示する」）。GUI 全体で同じ規則にする。
@Suite("未割り当ての表示")
struct KnobStripCaptionTests {
    @Test("未割り当ては `‐`")
    func unassignedShowsHyphen() {
        let caption = KnobStripCellView.caption(isPlaceholder: false, name: nil)
        #expect(caption == .unassigned)
        #expect(caption.text == "‐")
        #expect(caption.isUnassigned, "グレー背景の判定に使う")
    }

    /// ⚠️ **退行していないこと** — 割当があれば名前を出す
    @Test("割り当て済みは名前を出す")
    func assignedShowsName() {
        let caption = KnobStripCellView.caption(isPlaceholder: false, name: "Cutoff")
        #expect(caption == .assigned("Cutoff"))
        #expect(caption.text == "Cutoff")
        #expect(caption.isUnassigned == false, "地はグレーにしない")
    }

    /// ⚠️ **プレースホルダと未割り当ては別の状態**。
    /// - プレースホルダ = 枠そのものが未確定（ページが決まっていない）
    /// - 未割り当て = 枠はあるが何も載っていない（回せば素通しで楽器へ飛ぶ）
    ///
    /// 「回して良いか」が正反対なので、同じ見た目にしてはいけない
    @Test("プレースホルダと未割り当ては区別される")
    func placeholderDiffersFromUnassigned() {
        let placeholder = KnobStripCellView.caption(isPlaceholder: true, name: nil)
        let unassigned = KnobStripCellView.caption(isPlaceholder: false, name: nil)

        #expect(placeholder == .placeholder)
        #expect(placeholder.text == "—", "em dash（長い）")
        #expect(unassigned.text == "‐", "hyphen（短い）")
        #expect(placeholder.text != unassigned.text, "字面でも見分けが付くこと")
        #expect(placeholder.isUnassigned == false, "プレースホルダは地をグレーにしない")
    }

    /// プレースホルダは名前の有無に関わらずプレースホルダ（枠が無いので）
    @Test("プレースホルダは名前より優先される")
    func placeholderWins() {
        #expect(
            KnobStripCellView.caption(isPlaceholder: true, name: "Cutoff") == .placeholder)
    }
}
