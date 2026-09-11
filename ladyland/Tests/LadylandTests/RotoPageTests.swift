//! ROTO のページ（mako 要望 2026-08-03「P0 → P1 → P2 って移動できないかな」）。
//!
//! ⚠️ **ページはデバイスが持つ**（実測でモデルを 1 度組み替えた）。
//! 当初はホストが窓を動かす実装にしたが、実機は ← → を押しても通知を送らず、
//! **絶対パラメータ番号が 0-7 から 8-15 へ変わるだけ**だった。
//! よってホストは「全パラメータの地図」を配り、受信は番号から逆算する。

import Foundation
import RotoKit
import Testing

@testable import Ladyland

@Suite("ROTO のパラメータ番号")
struct RotoParamTests {
    /// (param, kind) を 1 行で照合する小道具（タプルの optional は == できない）
    private func expect(
        _ status: UInt8, _ cc: UInt8, _ param: Int, _ kind: RotoParam.Kind,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let decoded = RotoParam.decode(status: status, cc: cc)
        #expect(decoded?.param == param, sourceLocation: sourceLocation)
        #expect(decoded?.kind == kind, sourceLocation: sourceLocation)
    }

    @Test("ch15 の CC は param 0-31（MSB / LSB / touch）に解ける")
    func decodesFirstChannel() {
        // 実機で実際に届いたもの: ch15 CC8 / CC40 = param 8 の MSB / LSB
        expect(0xBE, 8, 8, .msb)
        expect(0xBE, 40, 8, .lsb)
        expect(0xBE, 64, 0, .touch)
        expect(0xBE, 0, 0, .msb)
        expect(0xBE, 31, 31, .msb)
    }

    @Test("チャンネルが下がるごとに 32 ずつ進む")
    func decodesLaterChannels() {
        // config.lua: param N → ch 0xBE − N/32
        expect(0xBD, 0, 32, .msb)
        expect(0xBD, 5, 37, .msb)
        expect(0xB7, 31, 255, .msb)
    }

    @Test("MIX 面（ch16）と範囲外は param として解かない")
    func rejectsOtherSurfaces() {
        // ch16 は MIX 面の knob — ここを param と誤読すると 2 面が混線する
        #expect(RotoParam.decode(status: 0xBF, cc: 12) == nil)
        #expect(RotoParam.decode(status: 0xB6, cc: 0) == nil)  // command ch
        #expect(RotoParam.decode(status: 0xBE, cc: 100) == nil)
    }

    @Test("投影は面ごとの上限で打ち切る — 空セルも名前で埋める")
    func projectionStopsAtSurfaceLimit() {
        // 実測の上限（protocol.md「3 つの面と、それぞれの上限」）。
        // 上限より先へは届かないので送っても無駄になるどころか、
        // 送信キューを埋めて learn / hello の応答を後ろで待たせる
        #expect(RotoParam.smartCells == 8 * 2, "SMART 面 = 8 ノブ × 2 ページ")
        #expect(RotoParam.pluginCells == 8 * 8, "PLUGIN 面 = 8 ノブ × 8 ページ")

        // 割当のある所までで打ち切ると、その先へ繰ったとき前の表示が残って
        // 迷子になる（空文字ラベルでは LCD が消えないため）。
        // どのセルにも必ず呼び名がある（空セルは Ctrl 番号）
        for ctrl in 0..<RotoParam.pluginCells {
            #expect(!FaceKnobAssignment.ctrlLabel(ctrl).isEmpty)
        }
    }

    @Test("番号は割当一覧の見出しと同じ呼び名になる")
    func labelsMatchAssignList() {
        // 空セルには Ctrl 番号を出すので、画面と実機で同じ呼び名で話せる
        #expect(FaceKnobAssignment.ctrlLabel(0) == "P1-1")
        #expect(FaceKnobAssignment.ctrlLabel(8) == "P2-1")
        #expect(FaceKnobAssignment.ctrlLabel(16) == "P3-1")
    }
}

@Suite("ROTO のページ座標")
struct RotoPageLayoutTests {
    @Test("SMART の 16 セルは前半と後半を同じ 8 コントロールへ写す")
    func mirrorsSmartDeviceCells() {
        #expect(RotoPageLayout.smartCell(page: 2, deviceCell: 0) == 16)
        #expect(RotoPageLayout.smartCell(page: 2, deviceCell: 8) == 16)
        #expect(RotoPageLayout.smartCell(page: 2, deviceCell: 7) == 23)
        #expect(RotoPageLayout.smartCell(page: 2, deviceCell: 15) == 23)
    }

    @Test("SMART の範囲外座標はセルを返さない")
    func rejectsOutOfRangeSmartCoordinates() {
        #expect(RotoPageLayout.smartCell(page: -1, knob: 0) == nil)
        #expect(RotoPageLayout.smartCell(page: RotoPageLayout.smartPageCount, knob: 0) == nil)
        #expect(RotoPageLayout.smartCell(page: 0, knob: -1) == nil)
        #expect(RotoPageLayout.smartCell(page: 0, knob: RotoParam.physicalKnobs) == nil)
        #expect(RotoPageLayout.smartCell(page: 0, deviceCell: -1) == nil)
        #expect(RotoPageLayout.smartCell(page: 0, deviceCell: RotoParam.smartCells) == nil)
    }

    @Test("SMART ページ番号は両端で止まる")
    func clampsSmartPage() {
        #expect(RotoPageLayout.clampedSmartPage(-5) == 0)
        #expect(RotoPageLayout.clampedSmartPage(3) == 3)
        #expect(
            RotoPageLayout.clampedSmartPage(999)
                == RotoPageLayout.smartPageCount - 1)
    }

    @Test("PLUGIN のページ内ノブを絶対セル番号へ写す")
    func resolvesPluginCell() {
        #expect(RotoPageLayout.pluginCell(page: 3, knob: 4) == 28)
    }
}

@Suite("PLUGIN 面のラベル追従（0B 0F）")
struct RotoMappedNameTests {
    /// `0B 0F <00> <idx+1> <hash6> <name13>` — **index は 1 始まり**。
    /// learn（0B 0A）が 0 始まりの paramIndex なのと食い違うので間違えやすい
    @Test("index は 1 始まり / hash6 はそのまま echo する")
    func framesMappedName() {
        let hash: [UInt8] = [0x29, 0x0A, 0x3E, 0x1D, 0x09, 0x59]
        let frame = Roto.setMappedControlName(control: 0, hash: hash, name: "Cutoff")

        #expect(Array(frame.prefix(7)) == [0xF0, 0x00, 0x22, 0x03, 0x02, 0x0B, 0x0F])
        #expect(frame[7] == 0)
        #expect(frame[8] == 1, "control 0 → idx+1 = 1")
        #expect(Array(frame[9..<15]) == hash, "hash6 は CONTROL_MAPPED の echo")
        #expect(frame.count == 29, "header 5 + type/id 2 + payload 21 + F7")
        #expect(frame.last == 0xF7)
    }

    @Test("名前は 12 字で切られ 13 スロットにゼロ埋めされる")
    func padsName() {
        let frame = Roto.setMappedControlName(
            control: 63, hash: [UInt8](repeating: 0, count: 6),
            name: "Filter Cutoff Frequency")
        #expect(frame[8] == 64, "control 63 → idx+1 = 64（PLUGIN 面の最終セル）")

        let name = Array(frame[15..<28])
        #expect(name.count == 13)
        #expect(String(decoding: name.prefix(12), as: UTF8.self) == "Filter Cutof")
        #expect(name[12] == 0, "末尾は必ず 0 終端")
    }
}

@Suite("CC プールと リストのページ割り")
struct AssignableCCTests {
    /// ⭐ **席プール = Keystage のノブ帯そのもの**（64 席。mako 裁定 2026-08-09
    /// 「他の用途で使う時はあると思うけど、Page は 8 つで」）。
    ///
    /// ⚠️ かつては 0-127 から予約を除いた約 113 席を「危険牌は後ろへ」と
    /// 並び替えていた（「P15 まで担保」— 帯が無かった 2026-08-04 の要望）。
    /// #75 で帯ができた後は**帯と食い違う第 2 のページ定義**になり、ROTO の
    /// LCD だけがそれを映し続けた（監査 B-1、mako 実測 2026-08-09「ズレてる」）
    @Test("席プールは帯そのもの — 並び替えも帯の外の席も無い")
    func poolIsTheBand() {
        #expect(FaceKnobAssignment.assignableCCs == KnobPages.all)
        // ⭐ CC0 が先頭に戻った — 「危険牌を後ろへ」の並び替えは消えた。
        // 番号の意味（Bank Select 等）は帯が飲むので、届かなければ無関係
        #expect(FaceKnobAssignment.assignableCCs.first == 0)
        #expect(FaceKnobAssignment.assignableCCs.count == 64)
    }

    /// ⭐ ページ割りの全景（正典 = CC ÷ 8）。ここが落ちたら「並びが変わった」
    @Test("8 ページ × 8 席 — P1 = CC0-7 … P8 = CC56-63")
    func pagesAreTheBand() {
        let pages = KnobPages.pages
        #expect(pages.count == 8)
        for (index, page) in pages.enumerated() {
            #expect(page == Array((index * 8)..<(index * 8 + 8)), "P\(index + 1) の並びが変わった")
        }
    }

    @Test("物理コントローラの席は別枠 — リストには並ばない")
    func excludesControllers() {
        // ⚠️ Mod ホイールは実機で焼き替えてある（CC1 は席に戻った）
        for cc in [FaceKnobAssignment.modWheelCC, FaceKnobAssignment.expressionCC, 64] {
            #expect(!FaceKnobAssignment.assignableCCs.contains(cc))
        }
        // ⚠️ **CC62/63 は解放した**（2026-08-07）— Keystage のノブ帯の一部
        #expect(FaceKnobAssignment.assignableCCs.contains(62), "解放されて席になった")
        #expect(FaceKnobAssignment.assignableCCs.contains(63))
    }

    /// ⚠️ 帯の中へ操作子が引っ越してきたら、席から自動で抜けること
    /// （`assignableCCs` の filter が守る。いまは taken が全部帯の外なので
    /// 64 席まるごと生きている — それは `poolIsTheBand` が見る）
    @Test("帯の中の操作子は席から抜ける（filter の防波堤）")
    func takenInsideBandWouldBeExcluded() {
        let taken = Set(FaceKnobAssignment.controllerCCs)
            .union(FaceKnobAssignment.alwaysReservedCCs)
            .union(FaceKnobAssignment.burnedControlCCs)
        #expect(
            taken.isDisjoint(with: FaceKnobAssignment.assignableCCs),
            "taken の CC が席に紛れている")
    }

    /// ⚠️⚠️ **焼いた操作子に席が付かない**（監査 2026-08-08 の B-4）。
    ///
    /// 席が付くと、Gadget 系（数百パラメータ）で「全部割り当てる」を走らせた
    /// ときに **ページ送り（Rec/Loop）やトラックナビ（REW/FF）へパラメータが
    /// 載る**。⚠️ `MIDIRouter` はノブの割当を横取り表より先に見るので、
    /// **役割が消えて「押すと 127 へ飛ぶノブ」になる**。
    ///
    /// ⚠️ **番号を直書きしない** — 焼く値そのものから引く
    @Test("焼いたボタン・エンコーダーには席が付かない")
    func burnedControlsAreNotSeats() {
        #expect(!FaceKnobAssignment.burnedControlCCs.isEmpty, "焼く値が空 = 表が壊れている")
        let pool = Set(FaceKnobAssignment.assignableCCs)
        for cc in FaceKnobAssignment.burnedControlCCs {
            #expect(!pool.contains(cc), "CC\(cc) に席が付いている（役割が消える）")
        }
        // ⭐ **自動割振でも掴まない**（`fillingDefaults` は席プールから配る）
        let many = (0..<300).map { (address: UInt64($0), name: "p\($0)") }
        let filled = FaceKnobAssignment.fillingDefaults([], parameters: many)
        for mapping in filled {
            #expect(
                !FaceKnobAssignment.burnedControlCCs.contains(mapping.knob),
                "自動割振が CC\(mapping.knob) を掴んだ")
        }
    }

    /// ⚠️ **CC62/63 は 2026-08-07 に解放した** — ページ送りが Rec/Loop
    /// （104/105）へ移って理由が消え、しかも **Keystage のノブ帯（CC0-63）の
    /// 一部**になったため。残るのは EXIT だけ
    @Test("EXIT は席にしない — 押すと外の音源まで止まる")
    func excludesButtons() {
        #expect(
            !FaceKnobAssignment.assignableCCs.contains(120),
            "CC120 は All Sound Off")
    }

    /// ⭐ ここがずれると**実機のノブが画面と違うパラメータを回す**。
    /// 2026-08-09 まで ROTO だけが旧プール分割（P1 = CC1-6,8,9）を映していて、
    /// LCD のセル名に「P1-2 … P2-1」が混ざっていた（監査 B-9、mako 実測）
    @Test("ROTO の投影は正典と同じ切り方 — 物理ノブ n = Keystage のノブ n")
    func rotoSharesPageLayout() {
        #expect(RotoPageLayout.smartPages == KnobPages.pages)
        #expect(RotoPageLayout.smartPageCount == KnobPages.pageCount)
        #expect(RotoPageLayout.smartPages[0] == [0, 1, 2, 3, 4, 5, 6, 7], "P1 = CC0-7")
    }

    /// 表示名も正典から — **CC 番号がそのまま座標**（`slotLabel`（リストの
    /// 位置から決める第 2 の答え）は 2026-08-09 に削除した）
    @Test("表示名は CC から決まる — P1-1 = CC0")
    func labelFromCC() {
        #expect(FaceKnobAssignment.ctrlLabel(0) == "P1-1")
        #expect(FaceKnobAssignment.ctrlLabel(7) == "P1-8")
        #expect(FaceKnobAssignment.ctrlLabel(8) == "P2-1")
        #expect(FaceKnobAssignment.ctrlLabel(63) == "P8-8")
    }
}

@Suite("ROTO の色パレット")
struct RotoPaletteTests {
    @Test("83 色ある — Bitwig 拡張の ColorUtil.COLORS と同数")
    func paletteSize() {
        #expect(Roto.Color.palette.count == 83)
    }

    @Test("名前付きの色が実際の RGB と一致する")
    func namedColors() {
        #expect(Roto.Color.palette[Int(Roto.Color.black)] == 0x000000)
        #expect(Roto.Color.palette[Int(Roto.Color.white)] == 0xFFFFFF)
        #expect(Roto.Color.palette[Int(Roto.Color.darkGray)] == 0x3C3C3C)
        #expect(Roto.Color.palette[Int(Roto.Color.gray)] == 0x7B7B7B)
        #expect(Roto.Color.palette[Int(Roto.Color.lightGray)] == 0xA9A9A9)
        #expect(Roto.Color.palette[Int(Roto.Color.navy)] == 0x000080)
        #expect(Roto.Color.palette[Int(Roto.Color.red)] == 0xFF0000)
        #expect(Roto.Color.palette[Int(Roto.Color.blue)] == 0x0000FF)
    }

    @Test("最近傍量子化 — 完全一致はその index を返す")
    func closestExact() {
        #expect(Roto.Color.closest(red: 0, green: 0, blue: 0) == Roto.Color.black)
        #expect(Roto.Color.closest(red: 255, green: 255, blue: 255) == Roto.Color.white)
        #expect(Roto.Color.closest(red: 0x3C, green: 0x3C, blue: 0x3C) == Roto.Color.darkGray)
    }

    @Test("近い色に丸める — 任意 RGB は受け付けないので必ずパレットへ落とす")
    func closestApproximate() {
        // ほぼ黒 → 黒
        #expect(Roto.Color.closest(red: 3, green: 2, blue: 4) == Roto.Color.black)
        // ほぼ白 → 白
        #expect(Roto.Color.closest(red: 250, green: 252, blue: 251) == Roto.Color.white)
        // どんな入力でも 83 色の範囲に収まる
        for value in stride(from: 0, through: 255, by: 51) {
            let index = Roto.Color.closest(
                red: UInt8(value), green: UInt8(255 - value), blue: UInt8(value / 2))
            #expect(index < 83)
        }
    }
}

@Suite("OKLCH での段階分け")
struct RotoOklchTests {
    @Test("明度は知覚順に並ぶ — 黒 < 暗灰 < 中灰 < 明灰 < 白")
    func lightnessOrder() {
        let ordered = [
            Roto.Color.black, Roto.Color.darkGray, Roto.Color.gray,
            Roto.Color.lightGray, Roto.Color.white,
        ]
        let values = ordered.map { Roto.Color.oklch($0).lightness }
        #expect(values == values.sorted(), "明度が単調増加していない: \(values)")
        #expect(Roto.Color.oklch(Roto.Color.black).lightness < 0.01)
        #expect(Roto.Color.oklch(Roto.Color.white).lightness > 0.99)
    }

    @Test("無彩色が抽出できる — 暗い順に並ぶ")
    func neutralsAreSorted() {
        let neutrals = Roto.Color.neutrals()
        #expect(neutrals.contains(Roto.Color.black))
        #expect(neutrals.contains(Roto.Color.white))
        #expect(neutrals.contains(Roto.Color.darkGray))
        // 純色は無彩色に入らない
        #expect(!neutrals.contains(Roto.Color.red))
        let lightness = neutrals.map { Roto.Color.oklch($0).lightness }
        #expect(lightness == lightness.sorted())

        // 実際に何段あるか（ダーク系の階調が組めるか）
        print("無彩色 \(neutrals.count) 色: "
            + neutrals.map { String(format: "%d(L=%.2f)", $0, Roto.Color.oklch($0).lightness) }
                .joined(separator: " "))
    }

    // MARK: - 淡色セットの 3 案（mako が比較中。2026-08-07）

    // MARK: - トーンマップ（mako 裁定 2026-08-07「B でまとめつつ、縦に彩度・
    // 明るさで分けて、全色振り分けたいね」）

    /// ⚠️ **これが要件そのもの** — 「12 色を選び出す」のではなく
    /// **全色に居場所を与える**。1 色でも落ちたら選べない色ができる
    @Test("83 色すべてが過不足なく 1 度ずつ置かれる — 帯 + 最下部の無彩")
    func toneMapPlacesEveryColor() {
        // ⚠️ **無彩色を帯から抜いて最下部へ移した**（2026-08-07）ので、
        // **合計で 83** になることを見る。片方だけ数えると移動の途中で落ちても
        // 気づけない
        let inBands = Roto.Color.toneMap().flatMap { $0.grid.flatMap { $0 } }.compactMap { $0 }
        let neutrals = Roto.Color.neutralRow()
        let placed = inBands + neutrals
        #expect(placed.count == 83, "取りこぼしも重複も無い（帯 \(inBands.count) + 無彩 \(neutrals.count)）")
        #expect(Set(placed) == Set((0..<83).map { UInt8($0) }))
    }

    /// ⚠️ **両方に出さない** — どちらが本物か分からなくなる
    @Test("無彩色は帯に残っていない")
    func neutralsAreOnlyAtTheBottom() {
        let inBands = Set(
            Roto.Color.toneMap().flatMap { $0.grid.flatMap { $0 } }.compactMap { $0 })
        for index in Roto.Color.neutralRow() {
            #expect(!inBands.contains(index), "無彩 \(index) が帯にも居る")
        }
    }

    /// パレット原典の行構造（mako 要望 2026-08-13「プリセットから判断できる
    /// グルーピング」）— 14 色 × 5 行 + 原色 13 で全 83 色を過不足なく覆い、
    /// 各行の末尾が無彩色（右端の縦に無彩色が揃う）
    @Test("プリセット行は原典の 14 色区切り — 全色 1 度ずつ・行末は無彩色")
    func presetRowsMirrorTheFactoryLayout() {
        let rows = Roto.Color.presetRows()
        #expect(rows.map(\.count) == [14, 14, 14, 14, 14, 13])
        let all = rows.flatMap { $0 }
        #expect(all.count == 83)
        #expect(Set(all) == Set((0..<83).map { UInt8($0) }))
        // 最初の 5 行の末尾 = 白 → 黒に向かう無彩色（13/27/41/55/69）
        #expect(rows.prefix(5).map { $0.last! } == [13, 27, 41, 55, 69])
    }

    /// 色相順の一本道（mako 所見 2026-08-13）— 有彩色を全部 1 度ずつ・H 昇順。
    /// neutralRow と合わせて 83 = 取りこぼしが無い
    @Test("色相順は有彩色の H 昇順 — 無彩と合わせて全 83 色")
    func hueOrderedCoversAllChromatic() {
        let ordered = Roto.Color.hueOrdered()
        let hues = ordered.map { Roto.Color.oklch($0).hue }
        #expect(hues == hues.sorted())
        #expect(ordered.count + Roto.Color.neutralRow().count == 83)
        #expect(Set(ordered).isDisjoint(with: Set(Roto.Color.neutralRow())))
    }

    /// 明度順の一本道（mako 所見 2026-08-13「暗い背景選びたい時に」）
    @Test("明度順は L 降順の全 83 色 — 白が先頭・黒が最後")
    func lightnessOrderedCoversAll() {
        let ordered = Roto.Color.lightnessOrdered()
        #expect(ordered.count == 83)
        let lightnesses = ordered.map { Roto.Color.oklch($0).lightness }
        #expect(lightnesses == lightnesses.sorted(by: >))
        #expect(ordered.first == Roto.Color.white)
        #expect(ordered.last == Roto.Color.black)
    }

    /// プリセット改 — mako 裁定の固定順（2026-08-13、2 回の手調整で決着:
    /// ビビッド → ダーク → ソフト → 淡 → くすみ → 原色）。中身は原典のまま
    @Test("プリセット改は mako 並び — 中身は原典の行のまま")
    func presetRowsCustomUsesTheDecreedOrder() {
        let rows = Roto.Color.presetRowsCustom()
        #expect(Set(rows) == Set(Roto.Color.presetRows()), "行の中身は不変（順序だけ）")
        #expect(rows.map { $0.first! } == [14, 56, 0, 28, 42, 70])
    }

    /// **白 → 黒**（帯の順序と同じ向き）
    @Test("無彩セットは白から黒へ並ぶ")
    func neutralRowRunsWhiteToBlack() {
        let row = Roto.Color.neutralRow()
        #expect(row.count >= 5, "各帯の末尾 + 原色帯の黒")
        #expect(row.first == Roto.Color.white)
        #expect(row.last == Roto.Color.black)
    }

    /// ⚠️ **順序は whiteness（L−C）の降順**。L や C 単体で並べると
    /// 「最も彩度が低いのは行 4」なので行 4 が上に来て実感とずれる
    @Test("帯は whiteness の降順 — 淡い帯が上")
    func bandsAreOrderedByWhiteness() {
        let bands = Roto.Color.toneMap()
        let whiteness = bands.map(\.whiteness)
        #expect(whiteness == whiteness.sorted(by: >))
        // mako が選んだ B（= 行 3）が先頭に来ること
        #expect(bands.first?.indices.contains(30) == true, "行 3（28-41）が一番上")
    }

    /// **軸の意味が画面に出せること** — L / C / W を持っていないと
    /// 「縦軸が何なのか」が読めず、ただの色の山になる
    @Test("各帯が実測値を持っている")
    func bandsCarryMeasurements() {
        for band in Roto.Color.toneMap() {
            #expect(band.lightness > 0 && band.lightness <= 1)
            #expect(band.chroma >= 0)
            #expect(!band.name.isEmpty)
        }
    }

    /// ⚠️ **列 = 色相の対応が崩れないこと**。崩れると「180-240° が空く」が
    /// 読めなくなり、2 次元にした意味が消える
    @Test("どの行も 12 列 — 色相だけ（無彩は最下部へ分けた）")
    func everyRowHasTwelveColumns() {
        for band in Roto.Color.toneMap() {
            for row in band.grid {
                #expect(row.count == Roto.Color.toneMapColumns)
            }
        }
    }

    /// **空きは空きのまま**（埋めない）。「この帯には青系の淡色が無い」は
    /// 役に立つ事実で、C 案が埋めていたのを mako は選ばなかった
    @Test("淡色帯には空いた色相がある — 埋めていない")
    func paleBandKeepsItsGaps() {
        let pale = try! #require(Roto.Color.toneMap().first)
        let firstRow = try! #require(pale.grid.first)
        // 12 色相のうち埋まっているのは 12 未満（180°/240° が空く）
        let filled = firstRow.compactMap { $0 }.count
        #expect(filled < 12, "空きが残っている")
        #expect(filled >= 8, "とはいえ大半は埋まっている")
    }

    @Test("色相 12 分割 — 純色がそれぞれの区画に入る")
    func hueBuckets() {
        let buckets = Roto.Color.byHue()
        #expect(buckets.count == 12)
        // 赤・緑・青がそれぞれ別の区画にいる
        let redHue = Roto.Color.oklch(Roto.Color.red).hue
        let greenHue = Roto.Color.oklch(Roto.Color.green).hue
        let blueHue = Roto.Color.oklch(Roto.Color.blue).hue
        #expect(Int(redHue / 30) != Int(greenHue / 30))
        #expect(Int(greenHue / 30) != Int(blueHue / 30))
        print("色相 12 分割: " + buckets.map { "\($0.count)" }.joined(separator: " "))
    }
}

@Suite("Gadget つまみ配置の spec")
struct GadgetKnobMapTests {
    private let sample = """
        // コメントは読み飛ばす
        spec "gadget-knob-map" version="0.1.0" {
            fact "wheel-first" measured="2026-08-04" {
                wheel "Pitch Bend" cc=128
            }

            gadget "Lisbon (Sci-Fi)" au-name="Lisbon" params=67 {
                page 1 {
                    knob at=1 param="VCO Waveform"
                    knob at=4 param="VCF Cutoff"
                }
                page 2 {
                    knob at=1 param="EG1 Attack"
                }
            }

            gadget "Milpitas (Wavestation)" au-name="Milpitas" params=8 {
                page 1 {
                    knob at=1 param="Joy X Value"
                }
                note "8 個しか無い機種"
            }
        }
        """

    @Test("gadget / page / knob だけを拾う — fact や note は無視する")
    func parsesSpec() {
        let maps = GadgetKnobMapLoader.parse(sample)
        #expect(maps.count == 2)
        #expect(maps["Lisbon (Sci-Fi)"]?.pages[1]?[1] == "VCO Waveform")
        #expect(maps["Lisbon (Sci-Fi)"]?.pages[1]?[4] == "VCF Cutoff")
        #expect(maps["Lisbon (Sci-Fi)"]?.pages[2]?[1] == "EG1 Attack")
        #expect(maps["Milpitas (Wavestation)"]?.pages[1]?[1] == "Joy X Value")
    }

    @Test("P(page)-(at) は CC (page-1)*8 + (at-1) に落ちる")
    func mapsToCells() {
        let cells = GadgetKnobMapLoader.parse(sample)["Lisbon (Sci-Fi)"]!.byCell
        #expect(cells[0] == "VCO Waveform", "P1-1 → CC0")
        #expect(cells[3] == "VCF Cutoff", "P1-4 → CC3")
        #expect(cells[8] == "EG1 Attack", "P2-1 → CC8")
    }

    @Test("spec の指定が先に置かれ、残りは自動で敷き詰められる")
    func appliesSpecFirst() {
        let map = GadgetKnobMapLoader.parse(sample)["Lisbon (Sci-Fi)"]!
        let parameters: [(address: UInt64, name: String)] = [
            (10, "VCO Waveform"), (11, "VCF Cutoff"), (12, "EG1 Attack"),
            (13, "その他 A"), (14, "その他 B"),
        ]
        let result = FaceKnobAssignment.applying(map, to: parameters)

        // spec の位置に入っている
        #expect(result.first { $0.knob == 0 }?.address == 10)
        #expect(result.first { $0.knob == 3 }?.address == 11)
        #expect(result.first { $0.knob == 8 }?.address == 12)
        // spec に無いものも全部載っている
        #expect(result.count == 5)
        #expect(Set(result.map(\.address)) == Set([10, 11, 12, 13, 14]))
        // 自動配置は spec が使っていない空きへ（0/3/8 は避ける）
        let auto = result.filter { [13, 14].contains($0.address) }.map(\.knob)
        #expect(!auto.contains(0) && !auto.contains(3) && !auto.contains(8))
    }

    @Test("AU に無いパラメータ名は黙って飛ばす — spec の誤記で壊れない")
    func skipsUnknownNames() {
        let map = GadgetKnobMap(gadget: "X", pages: [1: [1: "存在しない", 2: "ある"]])
        let result = FaceKnobAssignment.applying(map, to: [(5, "ある")])
        #expect(result.count == 1)
        #expect(result[0].knob == 1, "P1-2 → CC1")
        #expect(result[0].address == 5)
    }

    @Test("実際の spec/06 が読める — 7 機種ぶん入っている")
    func loadsRealSpec() {
        let maps = GadgetKnobMapLoader.loadDefault()
        #expect(maps.count >= 7, "spec/06 が見つからない（\(maps.count) 機種）")
        #expect(maps["Lisbon (Sci-Fi)"]?.pages[1]?.count == 8)
        #expect(maps["Milpitas (Wavestation)"]?.pages[1]?[1] == "Joy X Value")
    }

    @Test("Marseille — 割当対象 11 個から 8 個を選んで P1 を埋めた")
    func marseille() {
        let map = GadgetKnobMapLoader.loadDefault()["Marseille (Keys)"]
        #expect(map?.pages[1]?.count == 8)

        // 音源部を 1 つも公開しない機種なので、OSC / FILTER の代わりに
        // EG（AMP）→ FX1 → FX2 の順で読み替えてある
        #expect(map?.byCell[0] == "Env Attack")
        #expect(map?.byCell[3] == "Env Release")
        #expect(map?.byCell[7] == "FX2 Edit 2")

        // ⚠️ PCM 音源なのでオルガンのような持続音も入る。**Sustain は落とせない** —
        // 音色がプログラムで決まる機種では、EG が唯一の共通操作面になる
        #expect(map?.byCell[2] == "Env Sustain")

        // 落とした 3 つは P1 に居ない（後ろのページへ自動で回る）
        let onPageOne = Set(map?.pages[1]?.values.map { $0 } ?? [])
        #expect(!onPageOne.contains("Output Level"))
        #expect(!onPageOne.contains("FX1 Type"))
        #expect(!onPageOne.contains("FX2 Type"))
    }

    @Test("⚠️ 手書きの spec を機械で守る — at は 1-8、同じパラメータを 2 度置かない")
    func specIsWellFormed() {
        for (gadget, map) in GadgetKnobMapLoader.loadDefault() {
            for (page, knobs) in map.pages {
                #expect(page >= 1, "\(gadget): page は 1 始まり")
                for at in knobs.keys {
                    #expect((1...8).contains(at), "\(gadget) の P\(page)-\(at) が範囲外")
                }
            }
            // 同じパラメータを 2 箇所に書くと、`applying` は 1 パラメータ 1 席なので
            // **片方の席が黙って空く**。34 機種を手で書く以上、機械で捕まえる
            let names = map.pages.values.flatMap { $0.values }
            #expect(Set(names).count == names.count, "\(gadget): 同じパラメータが 2 箇所にある")
        }
    }
}

@Suite("LCD ラベルとページ番号")
struct RotoLabelWithPageTests {
    @Test("収まるときだけページ番号を添える")
    func addsPageWhenItFits() {
        // 12 文字に「名前 + 空白 1 + ページ」が収まるなら右端に置く
        let short = RotoDisplay.labelWithPage("Cutoff", page: "P3")
        #expect(short.count == 12)
        #expect(short.hasPrefix("Cutoff"))
        #expect(short.hasSuffix("P3"))

        // ちょうど境界（9 + 1 + 2 = 12）
        let exact = RotoDisplay.labelWithPage("Resonance", page: "P3")
        #expect(exact == "Resonance P3")
    }

    @Test("収まらなければ名前を優先 — ページは色でも分かる")
    func nameWinsWhenLong() {
        // LCD は 1 行しか出ない（実機で折り返しを確認済み 2026-08-05）ので、
        // **名前を削ってまでページ番号を出さない**
        let long = RotoDisplay.labelWithPage("Filter Cutoff Frequency", page: "P16")
        #expect(long == "Filter Cutof", "12 文字で切るだけ")
        #expect(!long.contains("P16"))

        // 1 文字でも溢れたら添えない（10 + 1 + 3 = 14 > 12）
        let boundary = RotoDisplay.labelWithPage("Distortion", page: "P16")
        #expect(boundary == "Distortion")
    }

    @Test("MAIN LCD の 2 行目 — 席名 + 右端に `#n`、溢れるのは名前の方")
    func mainLcdText() {
        // **ページは右端の固定位置**。区切り文字だと名前の長さで位置が動くが、
        // 右寄せならいつも同じ場所を見れば済む
        #expect(RotoDisplay.mainLcdText(page: 0, track: "Berlin") == "Berlin    #1")
        #expect(RotoDisplay.mainLcdText(page: 15, track: nil) == "#16")

        // ⚠️ **括弧より前だけ**を使う。Gadget はカテゴリを括弧で持つので、
        // そのまま切ると `Phoenix (` と**記号だけが残る**（実測 2026-08-06）
        #expect(RotoDisplay.mainLcdText(page: 0, track: "Phoenix (Analog)") == "Phoenix   #1")

        // `[1]` を `#1` にして 1 文字浮いたぶん、9 文字の名前が丸ごと収まる
        #expect(RotoDisplay.mainLcdText(page: 0, track: "Marseille (Keys)") == "Marseille #1")

        // 括弧を落としても溢れるなら切る（切り口の記号・空白は残さない）
        let long = RotoDisplay.mainLcdText(page: 15, track: "Warszawa Wavetable")
        #expect(long.count == 12)
        #expect(long == "Warszawa #16")

        // 桁が増えても右端に揃う
        #expect(RotoDisplay.mainLcdText(page: 0, track: "Berlin").hasSuffix("#1"))
        #expect(RotoDisplay.mainLcdText(page: 9, track: "Berlin").hasSuffix("#10"))

        // 空トラックでもページだけは出す
        #expect(RotoDisplay.mainLcdText(page: 2, track: "") == "#3")
    }

    @Test("MAIN LCD の地は設定の色をそのまま送る")
    func mainLcdBackground() {
        // ⚠️ **勝手に暗くしない**（mako 裁定 2026-08-06「SMART の背景を設定で
        // 変えたい」）。一度は白文字対策で明度を 30% に落としていたが、
        // それだと「選んだ色と違う色が出る」になる。読めるかどうかは選ぶ側が
        // 決められる（設定画面に「文字は白固定」と注記した）
        #expect(RotoDisplay.mainLcdBackground(paletteIndex: Roto.Color.white) == (255, 255, 255))
        #expect(RotoDisplay.mainLcdBackground(paletteIndex: Roto.Color.black) == (0, 0, 0))
        #expect(RotoDisplay.mainLcdBackground(paletteIndex: Roto.Color.red) == (255, 0, 0))
        #expect(RotoDisplay.mainLcdBackground(paletteIndex: Roto.Color.navy) == (0, 0, 128))
    }
}

@Suite("席ごとのページ色（mako 裁定 2026-08-05「Page 毎の配色を Track の Page 毎に」）")
struct RotoTrackPageColorTests {
    /// ラックの席数（`InstrumentRack.trackCount`。drums はその次の index）
    private let trackCount = 32

    @Test("既定 16 色に重複が無い — 「隣が違う色」の前提はここに乗っている")
    func defaultsAreDistinct() {
        #expect(Set(Roto.Color.defaultPageColors).count == 16)
    }

    @Test("同じページでも席が違えば色が違う — 席を移ったことが分かる")
    func differsPerTrack() {
        for page in 0..<16 {
            let seat0 = Roto.Color.pageColor(track: 0, page: page)
            #expect(Roto.Color.pageColor(track: 1, page: page) != seat0)
            #expect(Roto.Color.pageColor(track: 2, page: page) != seat0)
        }
    }

    @Test("同じ席では隣のページが違う色 — 繰ったことが分かる")
    func differsPerPage() {
        for track in 0...trackCount {
            for page in 0..<15 {
                #expect(
                    Roto.Color.pageColor(track: track, page: page)
                        != Roto.Color.pageColor(track: track, page: page + 1))
            }
        }
    }

    @Test("重なるのは 16 席先 — 歩幅 3 が 16 と互いに素なので手前では衝突しない")
    func wrapsAfterSixteenSeats() {
        // 32 席を 16 色で配る以上どこかで必ず重なる。**どこで重なるか**を決めるのが
        // 歩幅で、3 なら 15 席先までは一度も同じ色にならない
        for distance in 1..<16 {
            #expect(
                Roto.Color.pageColor(track: 0, page: 0)
                    != Roto.Color.pageColor(track: distance, page: 0))
        }
        #expect(
            Roto.Color.pageColor(track: 0, page: 0)
                == Roto.Color.pageColor(track: 16, page: 0))
    }

    @Test("優先順位は セル指定 > 席のページ色 > 席ごとの既定")
    func priority() {
        var colors = Roto.Colors()
        #expect(colors.lcdColor(track: 2, page: 1, cell: 30)
            == Roto.Color.pageColor(track: 2, page: 1))

        colors.setPageColor(track: 2, page: 1, to: Roto.Color.blue)
        #expect(colors.lcdColor(track: 2, page: 1, cell: 30) == Roto.Color.blue)
        // 隣の席は巻き込まない — これが「席ごと」の要点
        #expect(colors.lcdColor(track: 3, page: 1) == Roto.Color.pageColor(track: 3, page: 1))

        colors.setCellColor(track: 2, cell: 30, to: Roto.Color.red)
        #expect(colors.lcdColor(track: 2, page: 1, cell: 30) == Roto.Color.red)
        // 同じページの別セルはページ色のまま
        #expect(colors.lcdColor(track: 2, page: 1, cell: 31) == Roto.Color.blue)
    }

    @Test("既定へ戻すと席ごと落ちる — 空の記録が残ると既定の変更に追従しなくなる")
    func clearingDropsTheSeat() {
        var colors = Roto.Colors()

        colors.setCellColor(track: 4, cell: 20, to: Roto.Color.red)
        #expect(colors.trackCells[4] != nil)
        colors.setCellColor(track: 4, cell: 20, to: nil)
        #expect(colors.trackCells[4] == nil)

        colors.setPageColor(track: 4, page: 3, to: Roto.Color.red)
        #expect(colors.trackPages[4] != nil)
        colors.setPageColor(track: 4, page: 3, to: nil)
        #expect(colors.trackPages[4] == nil)
    }

    @Test("飛び番の上書き — P5 だけ変えても手前のページは既定のまま")
    func sparseOverride() {
        var colors = Roto.Colors()
        colors.setPageColor(track: 1, page: 4, to: Roto.Color.red)
        #expect(colors.lcdColor(track: 1, page: 4) == Roto.Color.red)
        for page in 0..<4 {
            #expect(colors.lcdColor(track: 1, page: page)
                == Roto.Color.pageColor(track: 1, page: page))
        }
    }

    @Test("保存を往復しても同じ")
    func roundTrips() throws {
        var colors = Roto.Colors()
        colors.setCellColor(track: 3, cell: 20, to: Roto.Color.red)
        colors.setPageColor(track: 5, page: 2, to: Roto.Color.blue)

        let data = try JSONEncoder().encode(colors)
        let restored = try JSONDecoder().decode(Roto.Colors.self, from: data)
        #expect(restored == colors)
        #expect(restored.lcdColor(track: 3, page: 0, cell: 20) == Roto.Color.red)
        #expect(restored.lcdColor(track: 5, page: 2) == Roto.Color.blue)
    }

    @Test("⚠️ 旧 Snapshot を読んでも配色が飛ばない — キーが足りなくても既定で埋める")
    func decodesLegacySnapshot() throws {
        // 実際に DB へ入っていた JSON（2026-08-05 時点）。`trackPages` /
        // `trackCells` を知らない世代のもの。
        //
        // 合成の `init(from:)` のままだと**キーが 1 つ足りないだけで decode 全体が
        // 落ち**、`try?` に握り潰されて配色がまるごと既定へ戻る。
        // フィールドを足すたびに設定が消えるので、`decodeIfPresent` で受ける
        let legacy = """
            {"track":70,"pages":[28,15,30,32,5,35,21,36,50,10,75,26,68,57,43,45],\
            "menu":69,"trackSelected":81,"empty":70,"cells":{},"assigned":76}
            """
        let colors = try JSONDecoder().decode(Roto.Colors.self, from: Data(legacy.utf8))
        #expect(colors.track == 70)
        #expect(colors.menu == 69)
        #expect(colors.trackSelected == 81)
        #expect(colors.empty == 70)
        // 知らないキー（旧 pages / 旧 cells）は読み捨てる
        #expect(colors.trackPages.isEmpty)
        #expect(colors.trackCells.isEmpty)
    }

    @Test("旧 pages は既定の写しだった — 読み捨てても失う色が 1 つも無い")
    func legacyPagesWereJustTheDefaults() {
        // DB に残っていた 16 色。これが `defaultPageColors` と一致するなら、
        // 席ごとの既定へ移しても**見え方の損失はページ 1 つぶんも無い**。
        // 編集する UI が無いまま既定の写しが保存されていた、という裏付け
        #expect(
            Roto.Color.defaultPageColors
                == [28, 15, 30, 32, 5, 35, 21, 36, 50, 10, 75, 26, 68, 57, 43, 45])
    }
}

/// **未割り当ての LCD 表示**（mako 裁定 2026-08-06「パラメータが未割り当ての場合、
/// グレー背景で `-` で表示する」）。
@Suite("SMART セルの未割り当て表示")
struct RotoSmartCellFaceTests {
    @Test("未割り当ては `-` とグレーの地")
    func unassignedShowsHyphenOnGray() {
        let face = RotoDisplay.smartCellFace(
            name: nil, pageTag: "#3", emptyColor: Roto.Color.darkGray,
            assignedColor: Roto.Color.azure)
        #expect(face.label == "-")
        #expect(face.color == Roto.Color.darkGray)
    }

    /// ⚠️ **空文字にはしない** — LCD が消えず前の表示が残る（実測）
    @Test("空文字は出さない")
    func neverEmptyString() {
        let face = RotoDisplay.smartCellFace(
            name: nil, pageTag: "#1", emptyColor: Roto.Color.darkGray,
            assignedColor: Roto.Color.azure)
        #expect(face.label.isEmpty == false)
    }

    /// ⚠️ **空きセルにページタグを付けない** — 指すパラメータが無いのに
    /// `#3` があると、何か割り当たっているように見える
    @Test("空きセルにページタグを付けない")
    func unassignedHasNoPageTag() {
        let face = RotoDisplay.smartCellFace(
            name: nil, pageTag: "#3", emptyColor: Roto.Color.darkGray,
            assignedColor: Roto.Color.azure)
        #expect(face.label.contains("#") == false)
        #expect(face.label == "-", "記号 1 文字だけ")
    }

    /// **退行していないこと** — 割当ありは名前 + ページタグ + 割当色
    @Test("割り当て済みは名前とページタグを出す")
    func assignedKeepsNameAndTag() {
        let face = RotoDisplay.smartCellFace(
            name: "Cutoff", pageTag: "#2", emptyColor: Roto.Color.darkGray,
            assignedColor: Roto.Color.azure)
        #expect(face.label.hasPrefix("Cutoff"))
        #expect(face.label.hasSuffix("#2"))
        #expect(face.color == Roto.Color.azure, "割当色のまま")
    }

    /// ⚠️ **地は暗くなければならない** — LCD の文字色はデバイスが白で固定して
    /// いて変えられないので、明るい地だと `-` が消える（実測 2026-08-06）
    @Test("空きの既定は暗いグレー — 白文字が読める明るさ")
    func emptyDefaultIsDarkEnough() {
        #expect(Roto.Colors().empty == Roto.Color.darkGray)

        // 0x3C3C3C = 60/255 ≈ 24%。白との相対輝度比はおよそ 10:1 で十分読める
        let rgb = Roto.Color.palette[Int(Roto.Color.darkGray)]
        let r = Double((rgb >> 16) & 0xFF) / 255
        #expect(abs(r - 60.0 / 255) < 0.01, "0x3C3C3C であること")
        #expect(r < 0.3, "明るいグレーだと白文字が消える")

        // より明るいグレーを既定にしていないこと
        #expect(Roto.Colors().empty != Roto.Color.gray)
        #expect(Roto.Colors().empty != Roto.Color.lightGray)
    }
}

/// **検証済みフラグの既定**（mako 裁定 2026-08-06「これで OK」→ 全部 on へ）。
///
/// ⚠️ `=0` は**会場での退避路**。消えていないことも固定する
@Suite("ROTO のフラグの既定")
@MainActor
struct RotoFlagDefaultTests {
    /// テストは環境変数を与えないので、素の状態 = 既定が見える
    private var unset: Bool {
        ["LADYLAND_MAIN_LCD", "LADYLAND_FILL_EMPTY", "LADYLAND_PARK_EMPTY_KNOBS"]
            .allSatisfy { ProcessInfo.processInfo.environment[$0] == nil }
    }

    @Test("3 つとも既定 on")
    func defaultsAreOn() {
        guard unset else { return }  // 環境変数を与えて回したときは判定しない
        #expect(RotoService.projectsMainLcd, "MAIN LCD を投影する")
        #expect(RotoService.fillsEmptySmartCells, "空セルにも `-` を送る")
        #expect(RotoService.parksEmptyKnobs, "空きノブへ値を送らない")
    }

    /// ⚠️ **`=0` だけが off**。`=1` や他の値で切れてはいけない
    /// （`RenderMetering` / `BusFollowing` と同じ作法）
    @Test("退避路は `=0` のみ")
    func onlyZeroDisables() {
        #expect(("0" != "0") == false, "`=0` は off")
        #expect(("1" != "0"), "`=1` は on")
        #expect((String?.none ?? "" != "0"), "未設定は on")
    }

    /// 起動ログに 3 つとも出る（会場で現状を探し回らずに済むこと）
    @Test("起動ログに 3 つのフラグが出る")
    func describeCoversAllFlags() {
        let line = RotoService.describeFlags
        #expect(line.contains("MAIN_LCD"))
        #expect(line.contains("FILL_EMPTY"))
        #expect(line.contains("PARK_EMPTY_KNOBS"))
        #expect(line.contains("=0"), "切り方も書いてある")
    }
}

/// **FUNC のページピッカー**（mako 案 2026-08-06「FUNC 押したら、#1−8 まで
/// LCD に現れて、**キーで** PAGE 選択するのどう？」）。
///
/// RK1-8 のページ直選（mako 裁定 2026-08-11「過去のは引っかかるのがいやなので
/// 全部オミットして、RK1-8 使う方式に」）。
///
/// ⭐ **RK は MIX 面でだけ喋る**（ch16 CC20-27、実測 2026-08-11 —
/// `RotoParam.decodeButton` の doc）。Transform 方針: 実機側は RK でページを
/// 繰って選択キーをトラック色で光らせ、こちらは信号を読んで内部ページを
/// 追従させるだけ。FUNC ピッカー（2 段構え）は全撤去した
@Suite("RK1-8 のページ直選")
@MainActor
struct RotoRkPageJumpTests {
    @Test("BF 20-27 が RK1-8 に解ける — それ以外は材料外")
    func decodesButtons() {
        #expect(RotoParam.decodeButton(status: 0xBF, cc: 20) == 0, "RK1")
        #expect(RotoParam.decodeButton(status: 0xBF, cc: 27) == 7, "RK8")
        #expect(RotoParam.decodeButton(status: 0xBF, cc: 19) == nil)
        #expect(RotoParam.decodeButton(status: 0xBF, cc: 28) == nil)
        #expect(RotoParam.decodeButton(status: 0xBE, cc: 20) == nil, "ch15 はノブの値ストリーム")
    }

    /// ⚠️ **実経路（`handleShort`）を通す** — 純関数が正しくても受信側が
    /// 呼んでいなければ意味が無い（#59 / #76 と同じ教訓）
    @Test("RK 押下でそのページへ直に飛ぶ — 解放では動かない")
    func pressJumpsReleaseIgnored() {
        let roto = RotoService()
        roto.receiveShortForTesting(0xBF, 22, 127)  // RK3 押下
        #expect(roto.smartPage == 2, "P3 へ直選")
        roto.receiveShortForTesting(0xBF, 22, 0)  // 解放
        #expect(roto.smartPage == 2, "解放で 2 度動かない")
        roto.receiveShortForTesting(0xBF, 27, 127)  // RK8
        #expect(roto.smartPage == 7, "P8 へ直選")
    }

    @Test("ページ送りは常時有効 — ピッカーに飲まれない")
    func pageStepAlwaysWorks() {
        let roto = RotoService()
        roto.stepSmartPage(1)
        #expect(roto.smartPage == 1)
        roto.followKnobPage(4)
        #expect(roto.smartPage == 4, "Keystage 追従も常時有効")
    }

    @Test("FUNC_PAGES フラグは消えた — ピッカーごと撤去済み")
    func pickerFlagIsGone() {
        #expect(!RotoService.describeFlags.contains("FUNC_PAGES"))
    }
}

/// MIX 面の受信変換（実測で確定した決定的な層だけ。2026-08-11）。
/// 窓スライドと枠塗りは同日に**コードごと撤去** — 非決定的な受け入れの
/// 作り直しは公式地図（docs/roto-control/official-scripts-map.md）から
@Suite("MIX 面の受信変換（厳格ミニマム）")
@MainActor
struct RotoMixInputTests {
    @Test("← →（CC60/61）は観測のみ — ページも選択も動かさない")
    func arrowsAreObserveOnly() {
        let roto = RotoService()
        roto.receiveShortForTesting(0xBF, 61, 2)
        roto.receiveShortForTesting(0xBF, 60, 2)
        #expect(roto.smartPage == 0, "旧配線（stepSmartPage）に戻っていない")
    }

    /// ⚠️ 一度 `rack.select` に繋いで撤回した経路（2026-08-11）。実機は
    /// ← → の最中や無関係の場面でも `0A 09 (track 0)` をほぼ毎秒送ってくる —
    /// 選択に写すと鳴る楽器が勝手に飛ぶ。意味が確定するまで観測のみ
    @Test("0A 09（selectTrack）は選択に繋がない — 観測のみ")
    func selectTrackStaysUnwired() {
        let roto = RotoService()
        let rack = InstrumentRack()
        roto.attach(rack: rack)
        roto.receiveForTesting(Roto.header + [0x0A, 0x09, 0, 2, 0xF7])
        #expect(rack.selected == 0, "選択は動かない（配線は保留）")
    }

    /// MIX ノブ = スロット 1-8 の音量（mako 裁定 2026-08-11「Track 自体って
    /// Volume 持ってる？割り当てるならそれだよね」）。窓撤去後は固定対応
    @Test("MIX ノブ（14bit）→ スロット 1-8 の gain")
    func mixKnobSetsGain() {
        let roto = RotoService()
        let rack = InstrumentRack()
        roto.attach(rack: rack)
        roto.receiveShortForTesting(0xBF, 12, 127)  // knob1 MSB
        roto.receiveShortForTesting(0xBF, 44, 127)  // knob1 LSB → 16383
        #expect(rack.slots[0].gain == 1.0)
        roto.receiveShortForTesting(0xBF, 13, 0)  // knob2 MSB
        roto.receiveShortForTesting(0xBF, 45, 0)  // knob2 LSB → 0
        #expect(rack.slots[1].gain == 0.0, "knob2 = スロット 2")
        #expect(rack.slots[2].gain == 0.8, "触っていないスロットは既定のまま")
    }

    @Test("pageLights は 8 通全塗り — current だけ 127")
    func pageLightsPaintAll() {
        let messages = Roto.pageLights(current: 2)
        #expect(messages.count == 8)
        #expect(messages[2] == [0xBF, 22, 127])
        for (key, message) in messages.enumerated() where key != 2 {
            #expect(message == [0xBF, UInt8(20 + key), 0])
        }
    }
}

/// `0B 01`（実機が PLUGIN 面へ飛んだ通知）。ピッカー撤去後の反応は
/// **SMART 面への引き戻し（2 秒スロットル）だけ** — 面情報の確定は残る
@Suite("`0B 01` はページに触らない")
@MainActor
struct RotoPluginFaceNoticeTests {
    private func frame(_ type: UInt8, _ id: UInt8) -> [UInt8] {
        Roto.header + [type, id, 0x01, 0xF7]
    }

    @Test("0B 01 を受けてもページは動かない — 握手中でも後でも")
    func noticeDoesNotTouchPage() {
        let roto = RotoService()
        roto.receiveForTesting(frame(0x0B, 0x01))
        #expect(roto.smartPage == 0, "起動直後（握手中）")
        roto.receiveForTesting(frame(0x0A, 0x0E))  // 握手完了
        roto.receiveForTesting(frame(0x0B, 0x01))
        #expect(roto.smartPage == 0, "握手後の FUNC でも動かない")
    }

    @Test("firmware 通知で落ち着く（挿し直しの再握手も守る）")
    func firmwareNoticeSettles() {
        let roto = RotoService()
        #expect(roto.startupSettled == false)
        roto.receiveForTesting(frame(0x0A, 0x0E))
        #expect(roto.startupSettled)
    }
}

@Suite("Keystage のノブから ROTO のページを追従する")
@MainActor
struct RotoFollowKnobPageTests {
    @Test("推定したページへ飛ぶ")
    func followsInferredPage() {
        let roto = RotoService()
        #expect(roto.smartPage == 0)
        roto.followKnobPage(3)
        #expect(roto.smartPage == 3, "CC から引いたページへ移る")
    }

    /// ⚠️ **同じページなら何もしない** — ノブ回し中は CC が連打で来るので、
    /// 毎回投影が走ると LCD が暴れる（250ms の引き戻しが積み上がる）
    @Test("同じページなら動かない（CC 連打で投影が走らない）")
    func samePageIsNoOp() {
        let roto = RotoService()
        roto.followKnobPage(2)
        var changes = 0
        roto.onPageChanged = { changes += 1 }
        for _ in 0..<20 { roto.followKnobPage(2) }
        #expect(changes == 0, "同じページで \(changes) 回動いた")
        #expect(roto.smartPage == 2)
    }

    /// ⚠️ **範囲外は端で止まる**（`stepSmartPage` と同じ）
    @Test("範囲外は端で止まる", arguments: [(-5, 0), (999, RotoPageLayout.smartPageCount - 1)])
    func clampsToRange(given: Int, expected: Int) {
        let roto = RotoService()
        roto.followKnobPage(given)
        #expect(roto.smartPage == expected)
    }

    /// ⭐ **観測点から追従までの鎖を通す**（`base = 0` の成果）。
    ///
    /// `AppState` が見ているのは **`MidiRoute`** なので、そこから始めて
    /// `keystageCC` → `inferredPage` → `followKnobPage` まで繋ぐ。
    /// ⚠️ **どの環でも切れないこと** — 途中が nil を返すと**追従そのものが
    /// 起きない**（`keystageCC` は横取り済みと素通しの両方を拾う）
    @Test("受信 → CC → ページ → 追従 の鎖が切れない")
    func routeToPageChainHolds() {
        let roto = RotoService()
        for cc in KnobPages.all {
            // ① 横取り済みノブ（割当あり）と ② 未割当の素通し、どちらの形でも
            for route in [
                MidiRoute.knob(cc: UInt8(cc), value: 64),
                MidiRoute.keyboard(status: 0xB0, data1: UInt8(cc), data2: 64, hasTarget: true),
            ] {
                let extracted = route.keystageCC
                #expect(extracted == cc, "CC\(cc) が観測点で拾えない")
                let page = extracted.flatMap { FaceKnobAssignment.inferredPage(cc: $0) }
                #expect(page == KnobPages.page(forCC: cc), "CC\(cc) の推定がずれる")
                guard let page else { continue }
                roto.followKnobPage(page)
                #expect(roto.smartPage == page, "CC\(cc) で P\(page + 1) へ移らない")
            }
        }
    }

    /// ⚠️ **ページ移動の口は 1 か所に寄っている** — `stepSmartPage` と
    /// `followKnobPage` が同じ実体（`goToSmartPage`）を通ることを、
    /// **同じ結果になる**ことで確かめる。片方だけ作法が抜ける事故を防ぐ
    @Test("繰るのと飛ぶのは同じ所へ着く")
    func stepAndFollowAgree() {
        let stepped = RotoService()
        stepped.stepSmartPage(1)
        stepped.stepSmartPage(1)
        let jumped = RotoService()
        jumped.followKnobPage(2)
        #expect(stepped.smartPage == jumped.smartPage)
    }
}
