//! 割当一覧の構造導出のテスト（mako 裁定 2026-08-02）。
//!
//! 守りたいこと:
//!   - **並びは割当セル順** — 行番号 1-8 が物理ノブ 1-8 と一致する
//!   - セクション = ページ（物理のノブ 1 面）。使っている分 + 伸びしろ 1 面
//!   - 読み取り専用は出さない（割り当てても動かない）
//!   - 予約セル（VALUE / サスティン）は割当対象外として区別される

import AudioToolbox
import Foundation
import Testing

@testable import Ladyland

@Suite("割当一覧の構造")
struct AssignListTests {
    private func info(
        _ address: UInt64, _ name: String, group: String? = nil, writable: Bool = true
    ) -> ParameterInfo {
        ParameterInfo(address: address, name: name, group: group, writable: writable)
    }

    private func mapping(_ cc: Int, _ address: UInt64, _ name: String) -> FaceKnobMapping {
        FaceKnobMapping(knob: cc, address: address, name: name)
    }

    /// ⚠️ **順序は Pn → 未割当 → 演奏**（mako 要望 2026-08-06）。
    ///
    /// **履歴**: 2026-08-04 に「固定値のやつは演奏グループに入るのが自然」で
    /// 演奏を先頭へ、「未割り当てを P1 の上に」で未割当を P1 の上へ置いていた。
    /// 2026-08-06 にどちらも後ろへ回して**実機のページを起点**にした
    @Test("Keystage の順序は Pn → 未割当 → 演奏")
    func keystageSectionOrder() {
        let sections = AssignList.sections(
            mappings: [mapping(16, 1, "Cutoff")],
            parameters: [info(1, "Cutoff"), info(2, "Reso")],
            surface: .keystage)

        let titles = sections.map(\.title)
        let pageIndex = try! #require(titles.firstIndex { $0.hasPrefix("P") })
        let freeIndex = try! #require(titles.firstIndex(of: "未割当"))
        let playIndex = try! #require(titles.firstIndex(of: "演奏"))

        #expect(pageIndex < freeIndex, "ページが未割当より先")
        #expect(freeIndex < playIndex, "未割当が演奏より先")
        #expect(titles.first?.hasPrefix("P") == true, "先頭はページ")
        #expect(titles.last == "演奏", "末尾は演奏")
    }

    /// 未割当が無くても順序が壊れない（セクションごと出ないだけ）
    @Test("未割当が無ければ Pn → 演奏")
    func orderWithoutUnassigned() {
        let sections = AssignList.sections(
            mappings: [mapping(16, 1, "Cutoff")],
            parameters: [info(1, "Cutoff")],  // 全部割当済み
            surface: .keystage)
        let titles = sections.map(\.title)
        #expect(titles.contains("未割当") == false)
        #expect(titles.first?.hasPrefix("P") == true)
        #expect(titles.last == "演奏")
    }

    /// ⚠️ **LPD8 面は演奏セクションを持たない**（ホイール・ペダルは Keystage 側）。
    /// 並べ替えの影響を受けていないこと
    @Test("LPD8 の順序は K1-K8 → 未割当（演奏は無い）")
    func lpd8SectionOrder() {
        let sections = AssignList.sections(
            mappings: [], parameters: [info(1, "Cutoff")],
            surface: .lpd8(knobCCs: Array(70..<78)))

        #expect(sections.map(\.title) == ["K1-K8", "未割当"])
        #expect(sections.contains { $0.title == "演奏" } == false, "LPD8 に演奏は無い")
    }

    @Test("並びはセル順 — プラグインの定義順に引きずられない")
    func orderFollowsCells() {
        // ⭐ **P1 = 実機のノブが送る CC**（ページ = CC ÷ 8 が正典。
        // mako 裁定 2026-08-07 夜「base = 0 / pageCount = 8」— P1 = CC0-7）。
        // ⚠️ **番号を直書きしない** — `KeystageKnobs` から引く。
        // プラグイン順は Repeat → Pump だが、割当は Pump が P1-1、
        // Repeat が P1-2
        let p1 = KnobPages.page(0)
        let parameters = [info(1, "Repeat"), info(2, "Pump")]
        let mappings = [mapping(p1[1], 1, "Repeat"), mapping(p1[0], 2, "Pump")]

        let sections = AssignList.sections(
            mappings: mappings, parameters: parameters, surface: .keystage)
        let page1 = try! #require(sections.first { $0.title == "P1" })

        // **どのページも 8 席揃う**（演奏席・危険牌を除いた並びを 8 個ずつ束ねる）
        #expect(page1.rows.count == 8)
        #expect(page1.rows[0].name == "Pump", "P1-1 が先頭")
        #expect(page1.rows[1].name == "Repeat", "P1-2 = ページ 2 番目の席")
        #expect(page1.rows.map(\.position) == Array(1...8), "位置は 1-8 で連続")
        #expect(page1.rows[2].name == nil, "空きセルは名前を持たない")
        #expect(page1.rows[2].isEmptyCell)
        #expect(
            page1.subtitle == "CC" + AssignList.compactRanges(p1),
            "見出しが実機のノブ帯と一致する")
    }

    @Test("セクションはページ単位 — 使っている分 + 伸びしろ 1 面")
    func pagesInUsePlusOne() {
        // 何も割り当てていなければ コントローラ + P1 だけ
        let empty = AssignList.sections(mappings: [], parameters: [], surface: .keystage)
        #expect(empty.map(\.title) == ["P1", "演奏"])

        // P2 に 1 つ割り当てたら P3 まで出る（⚠️ 番号は `KeystageKnobs` から引く）
        let onP2 = KnobPages.page(1)[0]
        let sections = AssignList.sections(
            mappings: [mapping(onP2, 1, "Cutoff")], parameters: [info(1, "Cutoff")],
            surface: .keystage)
        #expect(sections.map(\.title) == ["P1", "P2", "P3", "演奏"])
        let page2 = try! #require(sections.first { $0.title == "P2" })
        #expect(page2.subtitle == "CC" + AssignList.compactRanges(KnobPages.page(1)))
        #expect(page2.rows.first { $0.cc == onP2 }?.name == "Cutoff")
        let page3 = try! #require(sections.first { $0.title == "P3" })
        #expect(
            page3.subtitle == "CC" + AssignList.compactRanges(KnobPages.page(2)),
            "抜けが無ければ連続表記")
    }

    @Test("読み取り専用は未割当に出さない（割り当てても動かない）")
    func readOnlyExcluded() {
        let parameters = [
            info(1, "Cutoff"), info(2, "Meter", writable: false), info(3, "Reso"),
        ]
        let sections = AssignList.sections(
            mappings: [], parameters: parameters, surface: .keystage)
        let free = try! #require(sections.first { $0.title == "未割当" })
        #expect(free.rows.map(\.name) == ["Cutoff", "Reso"])
        #expect(free.subtitle == "2 個")
    }

    @Test("割当済みは未割当セクションから消える")
    func assignedLeavesFreeList() {
        let parameters = [info(1, "Cutoff"), info(2, "Reso")]
        let sections = AssignList.sections(
            mappings: [mapping(1, 1, "Cutoff")], parameters: parameters, surface: .keystage)
        let free = try! #require(sections.first { $0.title == "未割当" })
        #expect(free.rows.map(\.name) == ["Reso"])
    }

    @Test("予約セルと物理コントローラの目印")
    func reservedAndBadges() {
        // ⚠️ CC62/63 は 2026-08-07 に解放されて **P8 のただの席**になった
        // （予約は EXIT(120) と keep 時の Damper(64) だけ = どちらも帯の外）。
        // ここでは割当が帯の外（65）だけなので P1 しか出ず、ページに
        // 予約セルが並ばないこと（reserved = false）を見る
        let sections = AssignList.sections(
            mappings: [mapping(65, 1, "Something")], parameters: [info(1, "Something")],
            surface: .keystage)
        for section in sections where section.title.hasPrefix("P") {
            #expect(!section.rows.contains { $0.reserved }, "\(section.title) に予約セルは無い")
            #expect(!section.rows.contains { $0.cc == 62 || $0.cc == 63 })
        }
        // Damper は演奏枠に居て、keep モードでは予約扱い
        let damper = try! #require(
            sections.first { $0.title == "演奏" }?.rows
                .first { $0.cc == FaceKnobAssignment.damperCC })
        #expect(damper.reserved, "pedalMode=keep では CC64 は予約")

        // Mod / Exp はページではなく演奏枠に居る
        let controllers = try! #require(sections.first { $0.title == "演奏" })
        #expect(controllers.rows.first { $0.cc == FaceKnobAssignment.modWheelCC }?.badge == "M", "Mod ホイール（CC116）")
        #expect(controllers.rows.first { $0.cc == FaceKnobAssignment.expressionCC }?.badge == "E", "Exp ペダル（CC115）")
    }

    /// ⚠️⚠️ **「⚠︎ MIDI 予約」バッジは 2026-08-08 に消した** — 前提が死んだから。
    ///
    /// あれは「危険牌は回した瞬間に楽器へ届いて音が切れる」という警告だったが、
    /// ⭐ **#75（`base = 0` / 64 席全部横取り）で帯の CC は何番であれ楽器に
    /// 届かなくなった**。残すと **P1 の CC0/CC7 などに「起きない事故」の警告**が
    /// 出る — **脅しが嘘になると、本物の警告まで信じられなくなる**。
    ///
    /// ⚠️ **`isUnsafe` 自体は残っている**（自動割振の順序に効く）ので、
    /// 「危険牌ではない」ではなく「**危険牌だが警告は出さない**」を固定する
    @Test("危険牌に警告バッジを出さない — 帯の CC は楽器へ届かない")
    func noReservedWarningBadge() {
        let sections = AssignList.sections(mappings: [], parameters: [], surface: .keystage)
        let rows = sections.flatMap(\.rows)
        #expect(!rows.isEmpty)
        for row in rows {
            #expect(
                row.badge?.contains("MIDI 予約") != true,
                "CC\(row.cc) に起きない事故の警告が出ている")
        }
        // ⭐ **前提が死んだことの根拠**: 危険牌はノブ帯の中に居て、横取りされる
        let unsafeInBand = FaceKnobAssignment.unsafeCCs.filter {
            KeystageKnobs.intercepted.contains($0)
        }
        #expect(!unsafeInBand.isEmpty, "危険牌が 1 つも帯に無いなら前提は死んでいない")
        // ⚠️ **`isUnsafe` は残っている**（自動割振の順序に効く。整理は 8/8 後）
        #expect(FaceKnobAssignment.isUnsafe(cc: 7), "CC7 = Channel Volume の分類は残す")
    }

    /// ⭐ 役割名のバッジは**本物の情報なので残る**
    @Test("役割名のバッジは残る（ModWheel / Damper など）")
    func controllerBadgesRemain() {
        let sections = AssignList.sections(mappings: [], parameters: [], surface: .keystage)
        let lane = try! #require(sections.first { $0.title == "演奏" })
        for cc in FaceKnobAssignment.controllerCCs {
            #expect(
                lane.rows.first { $0.cc == cc }?.badge == FaceKnobAssignment.controllerBadge(cc),
                "CC\(cc) の役割名が消えている")
        }
    }

    @Test("演奏枠に体で動かす席が集まる")
    func performanceLane() {
        let sections = AssignList.sections(mappings: [], parameters: [], surface: .keystage)
        let lane = try! #require(sections.first { $0.title == "演奏" })
        // Mod(1) / Exp(11) / Damper(64) / PB(128) の 4 席
        #expect(lane.rows.map(\.cc) == FaceKnobAssignment.controllerCCs)
        #expect(lane.rows.first { $0.cc == FaceKnobAssignment.pitchBendControl }?.badge == "PB")
        // ページ側には出てこない（二重表示しない）
        let page1 = try! #require(sections.first { $0.title == "P1" })
        #expect(!page1.rows.contains { $0.cc == FaceKnobAssignment.modWheelCC })
    }

    @Test("LPD8 面は K1-K8 の 1 セクション（予約セルの概念は無い）")
    func lpd8Surface() {
        let ccs = [79, 80, 81, 82, 83, 84, 85, 86]
        let sections = AssignList.sections(
            mappings: [mapping(81, 1, "Decay")], parameters: [info(1, "Decay")],
            surface: .lpd8(knobCCs: ccs))
        #expect(sections.map(\.title) == ["K1-K8"])
        let row = try! #require(sections[0].rows.first { $0.cc == 81 })
        #expect(row.position == 3, "K3")
        #expect(row.name == "Decay")
        #expect(sections[0].rows.allSatisfy { !$0.reserved }, "LPD8 に予約セルは無い")
    }

    @Test("グループ名は行の添え物として持ち回る（並びは壊さない）")
    func groupRidesAlong() {
        let parameters = [info(1, "Cutoff", group: "FILTER"), info(2, "Pitch", group: "OSC")]
        let sections = AssignList.sections(
            mappings: [mapping(KnobPages.page(0)[0], 1, "Cutoff")],
            parameters: parameters, surface: .keystage)
        let page1 = try! #require(sections.first { $0.title == "P1" })
        #expect(page1.rows[0].group == "FILTER")
        let free = try! #require(sections.first { $0.title == "未割当" })
        #expect(free.rows[0].group == "OSC")
    }
}


@Suite("パラメータ現在値の整形")
struct ParameterFormatTests {
    /// ⚠️ AUParameter.string(fromValue:) は AUv2 ブリッジ経由でプラグイン本体へ
    /// 問い合わせに行き、KORG のプラグイン内で落ちた（実機クラッシュ 2026-08-02）。
    /// 自前で組むこの経路がその代替 — プラグインを一切呼ばない
    @Test("単位ごとの整形")
    func unitsAreFormatted() {
        #expect(ParameterFormat.text(value: 45, unit: .percent) == "45 %")
        #expect(ParameterFormat.text(value: -6, unit: .decibels) == "-6 dB")
        #expect(ParameterFormat.text(value: 440, unit: .hertz) == "440 Hz")
        #expect(ParameterFormat.text(value: 1950, unit: .hertz) == "1.95 kHz", "kHz に畳む")
        #expect(ParameterFormat.text(value: 0.012, unit: .seconds) == "12 ms", "1 秒未満は ms")
        #expect(ParameterFormat.text(value: 2, unit: .seconds) == "2 s")
        #expect(ParameterFormat.text(value: 1, unit: .boolean) == "on")
        #expect(ParameterFormat.text(value: 0, unit: .boolean) == "off")
        #expect(ParameterFormat.text(value: 3, unit: .indexed) == "3")
    }

    @Test("桁は値の大きさに合わせる")
    func precisionFollowsMagnitude() {
        #expect(ParameterFormat.text(value: 0.42, unit: .generic) == "0.42")
        #expect(ParameterFormat.text(value: 12.5, unit: .generic) == "12.5")
        #expect(ParameterFormat.text(value: 1950, unit: .generic) == "1950")
    }
}

/// 別名（design/06 §8 追補 2026-08-03）。
///
/// **なぜ要るか**: AU が実名を出さないプラグインがある。実測で KORG Fairbanks は
/// 16 個中 12 個が `Edit 1-8` / `Mod Fx Edit 1` のような位置スロット名
/// （`swift run RigBench au-params Fairbanks`）。ROTO の LCD は 12 字なので
/// 「Edit 1」と出たらライブでは使い物にならない
@Suite("割当の別名")
struct KnobAliasTests {
    @Test("表示名は 別名 > AU の現在名 > 控えた名前 の順で決まる")
    func resolutionOrder() {
        #expect(
            KnobLabel.resolve(alias: "Cutoff", live: "Edit 3", remembered: "Edit 3") == "Cutoff")
        #expect(KnobLabel.resolve(alias: nil, live: "Edit 3", remembered: "旧名") == "Edit 3")
        // AU が引けなくなっても割当時に控えた名前が残る
        #expect(KnobLabel.resolve(alias: nil, live: nil, remembered: "旧名") == "旧名")
        #expect(KnobLabel.resolve(alias: nil, live: nil, remembered: nil) == nil)
    }

    @Test("空白だけの別名は無かったことにする（実名に戻る）")
    func blankAliasIsIgnored() {
        #expect(KnobLabel.resolve(alias: "   ", live: "Edit 3", remembered: nil) == "Edit 3")

        let mappings = [FaceKnobMapping(knob: 0, address: 10, name: "Edit 1", alias: "Cutoff")]
        let cleared = FaceKnobAssignment.aliasing(mappings, knob: 0, alias: "  ")
        #expect(cleared[0].alias == nil)
    }

    @Test("別名はパラメータについて回る — セルを移しても付け直さない")
    func aliasSurvivesReassignment() {
        // ライブ前に付け直す羽目になると貴重な設営時間を溶かす
        let mappings = [FaceKnobMapping(knob: 0, address: 10, name: "Edit 1", alias: "Cutoff")]
        let moved = FaceKnobAssignment.assigning(
            mappings, knob: 5, address: 10, name: "Edit 1")
        #expect(moved.count == 1)
        #expect(moved[0].knob == 5)
        #expect(moved[0].alias == "Cutoff")
    }

    @Test("別名は保存形に載る — 旧データ（別名なし）も読める")
    func aliasRoundTrips() throws {
        let mapping = FaceKnobMapping(knob: 2, address: 7, name: "Edit 3", alias: "Filter")
        let encoded = try JSONEncoder().encode(mapping)
        #expect(try JSONDecoder().decode(FaceKnobMapping.self, from: encoded) == mapping)

        // alias フィールドが無い旧 JSON（後方互換）
        let legacy = Data(#"{"knob":2,"address":7,"name":"Edit 3"}"#.utf8)
        let decoded = try JSONDecoder().decode(FaceKnobMapping.self, from: legacy)
        #expect(decoded.alias == nil)
        #expect(decoded.name == "Edit 3")
    }

    @Test("一覧の行は別名を表示に使い、別名かどうかも持つ")
    func rowsCarryAlias() {
        // ⚠️ **席は `KeystageKnobs` から引く**（実機のノブ帯。番号を直書きしない）
        let seat = KnobPages.page(0)[0]
        let mappings = [FaceKnobMapping(knob: seat, address: 10, name: "Edit 1", alias: "Cutoff")]
        let parameters = [
            ParameterInfo(address: 10, name: "Edit 1", group: nil, writable: true)
        ]
        let sections = AssignList.sections(
            mappings: mappings, parameters: parameters, surface: .keystage)
        let row = sections.flatMap(\.rows).first { $0.cc == seat }
        #expect(row?.name == "Cutoff")
        #expect(row?.alias == "Cutoff")
    }
}

@Suite("CC 範囲の圧縮表記")
struct CompactRangeTests {
    @Test("連番はハイフンでまとめる")
    func joinsRuns() {
        #expect(AssignList.compactRanges([0, 1, 2, 3]) == "0-3")
        #expect(AssignList.compactRanges([16, 17, 18, 19, 20, 21, 22, 23]) == "16-23")
    }

    @Test("飛びはカンマで区切る")
    func splitsGaps() {
        // いまのページは連番（P1 = CC0-7）だが、整形の仕様として飛びも固定する。
        // 例はかつて演奏席（CC1/11/64）が帯の中に居た頃のページの形
        #expect(AssignList.compactRanges([0, 2, 3, 4, 5, 6, 7]) == "0,2-7")
        #expect(AssignList.compactRanges([8, 9, 10, 12, 13, 14, 15]) == "8-10,12-15")
        #expect(AssignList.compactRanges([65, 66, 67, 68, 69, 70, 71]) == "65-71")
    }

    @Test("単発と空")
    func edges() {
        #expect(AssignList.compactRanges([5]) == "5")
        #expect(AssignList.compactRanges([1, 3, 5]) == "1,3,5")
        #expect(AssignList.compactRanges([]) == "")
    }

    @Test("順不同でも正しく畳む")
    func sortsFirst() {
        #expect(AssignList.compactRanges([7, 3, 5, 4, 6]) == "3-7")
    }
}
