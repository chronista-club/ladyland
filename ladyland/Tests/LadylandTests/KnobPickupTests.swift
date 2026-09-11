//! 顔つまみピックアップのテスト（P4）。
//!
//! Keystage ノブは終点ありポット（docs/keystage/README.md）。スロット切替
//! 直後の物理ノブ位置とパラメータ現在値の食い違いで値が跳ばないこと
//! （ピックアップ = 現在値を「拾う」までは適用しない）を仕様として固定する。

import Testing

@testable import Ladyland

@Suite("KnobPickup")
struct KnobPickupTests {
    @Test("遠い値では engage しない（段差吸収の本体）")
    func farValueIsIgnored() {
        var pickup = KnobPickup()
        // パラメータ現在値 0.8 に対しノブが 0.1 → 適用したら値が跳ぶ
        #expect(pickup.accept(knob: 0, value: 0.1, target: 0.8) == false)
        #expect(pickup.accept(knob: 0, value: 0.2, target: 0.8) == false)
    }

    @Test("現在値に十分近づいたら engage、以後は素通し")
    func engagesWhenNear() {
        var pickup = KnobPickup()
        #expect(pickup.accept(knob: 0, value: 0.79, target: 0.8) == true)
        // engage 後は target から離れても通る（つまみを回している最中）
        #expect(pickup.accept(knob: 0, value: 0.2, target: 0.79) == true)
    }

    @Test("速く回して現在値を跨いだら engage（サンプル疎でも取りこぼさない)")
    func engagesWhenCrossing() {
        var pickup = KnobPickup()
        #expect(pickup.accept(knob: 0, value: 0.3, target: 0.5) == false)
        // 0.3 → 0.8 の跳びで 0.5 を通過した
        #expect(pickup.accept(knob: 0, value: 0.8, target: 0.5) == true)
    }

    @Test("初回タッチ（前回値なし）は近接のみで判定される")
    func firstTouchUsesNearOnly() {
        var pickup = KnobPickup()
        // 前回値がないので跨ぎは判定できない — 遠ければ false
        #expect(pickup.accept(knob: 3, value: 0.9, target: 0.1) == false)
    }

    @Test("reset で全ノブが disengage に戻る（スロット切替の仕切り直し）")
    func resetDisengages() {
        var pickup = KnobPickup()
        #expect(pickup.accept(knob: 0, value: 0.5, target: 0.5) == true)
        pickup.reset()
        #expect(pickup.accept(knob: 0, value: 0.9, target: 0.1) == false)
    }

    @Test("reset は前回値も消す（切替前の動きで偽の跨ぎ判定をしない）")
    func resetClearsHistory() {
        var pickup = KnobPickup()
        #expect(pickup.accept(knob: 0, value: 0.1, target: 0.9) == false)
        pickup.reset()
        // reset 前の 0.1 が残っていると 0.1→0.6 で target 0.5 を「跨いだ」ことに
        // なってしまう。reset 後の初回は近接のみで判定されるべき
        #expect(pickup.accept(knob: 0, value: 0.6, target: 0.5) == false)
    }

    @Test("ノブ番号が範囲外なら常に false")
    func outOfRangeKnob() {
        var pickup = KnobPickup()
        #expect(pickup.accept(knob: -1, value: 0.5, target: 0.5) == false)
        #expect(pickup.accept(knob: 8, value: 0.5, target: 0.5) == false)
    }

    @Test("ノブごとに独立して engage する")
    func knobsAreIndependent() {
        var pickup = KnobPickup()
        #expect(pickup.accept(knob: 0, value: 0.5, target: 0.5) == true)
        // ノブ 0 が engage してもノブ 1 は disengage のまま
        #expect(pickup.accept(knob: 1, value: 0.9, target: 0.1) == false)
    }
}

@Suite("FaceKnobAssignment — パラメータ起点の割当編集")
struct FaceKnobAssignmentTests {
    private let cutoff = FaceKnobMapping(knob: 2, address: 100, name: "Cutoff")
    private let reso = FaceKnobMapping(knob: 3, address: 200, name: "Resonance")

    @Test("空の割当にパラメータ → ノブを結ぶ")
    func assignToEmpty() {
        let result = FaceKnobAssignment.assigning([], knob: 2, address: 100, name: "Cutoff")
        #expect(result == [cutoff])
    }

    @Test("使用中のノブに別パラメータを割り当てると付け替え（1 ノブ 1 パラメータ）")
    func knobConflictNewWins() {
        let result = FaceKnobAssignment.assigning(
            [cutoff, reso], knob: 2, address: 300, name: "EG Attack")
        #expect(result == [reso, FaceKnobMapping(knob: 2, address: 300, name: "EG Attack")])
    }

    @Test("割当済みパラメータに別ノブを選ぶと移動（1 パラメータ 1 ノブ）")
    func parameterMovesToNewKnob() {
        let result = FaceKnobAssignment.assigning(
            [cutoff, reso], knob: 5, address: 100, name: "Cutoff")
        #expect(result == [reso, FaceKnobMapping(knob: 5, address: 100, name: "Cutoff")])
    }

    @Test("同じ組の再割当は重複しない")
    func reassignSamePairIsIdempotent() {
        let result = FaceKnobAssignment.assigning(
            [cutoff], knob: 2, address: 100, name: "Cutoff")
        #expect(result == [cutoff])
    }

    @Test("removing はパラメータ単位で外す")
    func removeByAddress() {
        #expect(FaceKnobAssignment.removing([cutoff, reso], address: 100) == [reso])
        #expect(FaceKnobAssignment.removing([reso], address: 999) == [reso])
    }
}

@Suite("マトリクス座標と予約 CC")
struct CtrlMatrixTests {
    @Test("ctrlLabel は ページ-ノブ 表記（CC 位置固定の写像）")
    func labels() {
        #expect(FaceKnobAssignment.ctrlLabel(0) == "P1-1")
        #expect(FaceKnobAssignment.ctrlLabel(7) == "P1-8")
        #expect(FaceKnobAssignment.ctrlLabel(8) == "P2-1")
        #expect(FaceKnobAssignment.ctrlLabel(62) == "P8-7")
        #expect(FaceKnobAssignment.ctrlLabel(127) == "P16-8")
    }

    /// ⚠️ **CC62/63 は 2026-08-07 に解放した** — ページ送りが Rec/Loop
    /// （104/105）へ移って理由が消え、しかも **Keystage のノブ帯（CC0-63）の
    /// 一部**になったため。予約のままだと「回しても割り当てられない席」になる
    @Test("予約 CC = EXIT + サスティン (64)。CC1 と 62/63 は予約でない")
    func reserved() {
        // 予約は EXIT(120) と、keep モードの Damper(64) だけ。焼いたボタン
        // （102-110）とエンコーダー（117/118）は `burnedControlCCs` が
        // 別枠で席から外す
        #expect(FaceKnobAssignment.reservedCCs == [64, 120])
        #expect(!FaceKnobAssignment.reservedCCs.contains(1), "CC1 はただの帯の席（Mod は 116 へ焼いた）")
    }

    @Test("ピックアップは CC 0-127 全域で動く（8 本固定時代の名残がない）")
    func pickupCoversFullRange() {
        var pickup = KnobPickup(knobCount: 128)
        #expect(pickup.accept(knob: 127, value: 0.5, target: 0.5) == true, "近接で engage")
        #expect(pickup.accept(knob: 128, value: 0.5, target: 0.5) == false, "範囲外は常に不許可")
    }
}

@Suite("全割当デフォルトとセル交換")
struct MatrixDefaultsTests {
    private let params: [(address: UInt64, name: String)] = [
        (10, "Cutoff"), (20, "Reso"), (30, "Attack"),
    ]

    @Test("fillingDefaults は予約 CC を飛ばして順に敷き詰める")
    func fillsSkippingReserved() {
        // CC61 まで埋まっている状態から → 62/63/64 を飛んで 65, 66 へ
        var existing: [FaceKnobMapping] = []
        for cc in 0..<62 {
            existing.append(FaceKnobMapping(knob: cc, address: UInt64(1000 + cc), name: "p\(cc)"))
        }
        let result = FaceKnobAssignment.fillingDefaults(
            existing, parameters: [(10, "Cutoff"), (20, "Reso")])
        #expect(result.first { $0.address == 10 }?.knob == 62)
        #expect(result.first { $0.address == 20 }?.knob == 63)
    }

    @Test("既存の割当は動かさず、未割当だけ埋める")
    func preservesExisting() {
        let existing = [FaceKnobMapping(knob: 5, address: 20, name: "Reso")]
        let result = FaceKnobAssignment.fillingDefaults(existing, parameters: params)
        #expect(result.first { $0.address == 20 }?.knob == 5, "既存は不動")
        #expect(result.first { $0.address == 10 }?.knob == 0, "空きの先頭から")
        #expect(result.first { $0.address == 30 }?.knob == 1)
    }

    @Test("セルが尽きたら残りは未割当のまま（数百パラメータ > 64 席）")
    func capsAtMatrixSize() {
        let many = (0..<200).map { (address: UInt64($0), name: "p\($0)") }
        let result = FaceKnobAssignment.fillingDefaults([], parameters: many)
        // ⚠️ **配るのは席プール（= 帯、64 席）だけ**（mako 裁定 2026-08-09）。
        // かつては 0..<128 を歩いて帯の外やホイールにまで席を作っていた
        #expect(result.count == FaceKnobAssignment.assignableCCs.count)
        #expect(result.count < many.count, "尽きた残りは未割当のまま")
    }

    @Test("swapping は 2 セルの中身を交換（空セルへは移動、予約セルは no-op）")
    func swapAndMove() {
        let mappings = [
            FaceKnobMapping(knob: 0, address: 10, name: "Cutoff"),
            FaceKnobMapping(knob: 1, address: 20, name: "Reso"),
        ]
        let swapped = FaceKnobAssignment.swapping(mappings, 0, 1)
        #expect(swapped.first { $0.address == 10 }?.knob == 1)
        #expect(swapped.first { $0.address == 20 }?.knob == 0)

        let moved = FaceKnobAssignment.swapping(mappings, 1, 9)  // 9 は空セル
        #expect(moved.first { $0.address == 20 }?.knob == 9)

        #expect(FaceKnobAssignment.swapping(mappings, 0, 120) == mappings, "予約セルは拒否")
    }
}

@Suite("演奏系コントローラのマトリクス参加")
struct PerformanceControllerTests {
    @Test("PB は擬似 Ctrl 128 で、ラベルとバッジを持つ")
    func pitchBendIdentity() {
        #expect(FaceKnobAssignment.pitchBendControl == 128)
        #expect(FaceKnobAssignment.ctrlLabel(128) == "PB")
        #expect(FaceKnobAssignment.controllerBadge(128) == "PB")
    }

    @Test("Mod (CC116) / Exp (CC115) は予約されず、バッジ付きの一級市民")
    func modAndExpressionAreAssignable() {
        #expect(!FaceKnobAssignment.reservedCCs.contains(1))
        #expect(!FaceKnobAssignment.reservedCCs.contains(FaceKnobAssignment.expressionCC))
        #expect(FaceKnobAssignment.controllerBadge(FaceKnobAssignment.modWheelCC) == "M")
        #expect(FaceKnobAssignment.controllerBadge(FaceKnobAssignment.expressionCC) == "E")
        #expect(FaceKnobAssignment.controllerBadge(0) == nil)
    }

    /// ⚠️ **8/5 の「自動で割り当てたい」を 2026-08-09 に上書き**（mako 裁定
    /// 「Mod は自動では配らない」）。64 席時代は溢れたときだけ運任せの
    /// パラメータがホイールに載る形になるため。手での割当は今までどおり
    @Test("全割当デフォルトはホイールに配らない — Mod/Exp/PB は手で選ぶ")
    func defaultsExcludeWheels() {
        let many = (0..<200).map { (address: UInt64($0), name: "p\($0)") }
        let result = FaceKnobAssignment.fillingDefaults([], parameters: many)
        #expect(result.contains { $0.knob == 1 }, "CC1 はただの帯の席（Mod ではない）")
        #expect(!result.contains { $0.knob == FaceKnobAssignment.modWheelCC }, "Mod は手で選ぶ")
        #expect(!result.contains { $0.knob == FaceKnobAssignment.expressionCC }, "Exp は手で選ぶ")
        #expect(!result.contains { $0.knob == 128 }, "PB はネイティブベンドが既定 — 手動でのみ割当")
    }
}

@Suite("LPD8 面の割当")
struct Lpd8SurfaceTests {
    @Test("fillingDefaults(onto:) は指定セル列へ先頭から敷き詰め、溢れは未割当")
    func fillsOntoGivenCells() {
        let ccs = [79, 80, 81]
        let params = (0..<5).map { (address: UInt64($0), name: "p\($0)") }
        let result = FaceKnobAssignment.fillingDefaults(onto: ccs, parameters: params)
        #expect(result.map(\.knob) == [79, 80, 81], "セル数でキャップ")
        #expect(result.map(\.address) == [0, 1, 2])
    }
}

/// ダンパーペダルの役割切替（mako 裁定 2026-08-03「ペダルを繋いだので既存機能と
/// 切り替えながらプラグインにも流す道が欲しい」）。
///
/// ペダルは 1 本しかないのに用途が 2 つある — 「両手を空けるキープ」と
/// 「足で音色を動かす表情付け」は同時に成立しないので、曲ごとに選ぶ
@Suite("ペダルの役割")
struct PedalModeTests {
    @Test("keep では CC64 は予約 — 割当セルにならない")
    func keepReservesDamper() {
        let reserved = FaceKnobAssignment.reservedCCs(pedal: .keep)
        #expect(reserved.contains(FaceKnobAssignment.damperCC))
        // VALUE エンコーダーはモードに関係なく常に予約
        #expect(reserved.contains(120), "EXIT は予約のまま")
    }

    @Test("assign では CC64 が一級市民になる（VALUE は予約のまま）")
    func assignFreesDamper() {
        let reserved = FaceKnobAssignment.reservedCCs(pedal: .assign)
        #expect(!reserved.contains(FaceKnobAssignment.damperCC))
        #expect(reserved.contains(120), "EXIT は予約のまま")
    }

    @Test("assign なら CC64 のセルに割り当てられる")
    func damperIsAssignableInAssignMode() {
        let parameters = [
            ParameterInfo(address: 10, name: "Filter Cutoff", group: nil, writable: true)
        ]
        let mappings = FaceKnobAssignment.assigning(
            [], knob: FaceKnobAssignment.damperCC, address: 10, name: "Filter Cutoff")

        let assignRows = AssignList.sections(
            mappings: mappings, parameters: parameters, surface: .keystage, pedal: .assign)
            .flatMap(\.rows)
        let cell = assignRows.first { $0.cc == FaceKnobAssignment.damperCC }
        #expect(cell?.reserved == false)
        #expect(cell?.name == "Filter Cutoff")

        // keep に戻すと同じセルが予約表示になる（割当自体は消さない —
        // モードを戻せばまた使えるべきで、切替が破壊的だと怖くて触れない）
        let keepRows = AssignList.sections(
            mappings: mappings, parameters: parameters, surface: .keystage, pedal: .keep)
            .flatMap(\.rows)
        #expect(keepRows.first { $0.cc == FaceKnobAssignment.damperCC }?.reserved == true)
    }

    @Test("全割当デフォルトは keep のとき CC64 を飛ばす")
    func defaultsSkipDamperInKeepMode() {
        // 既定の敷き詰めは reservedCCs（keep 相当）を避ける
        let parameters = (0..<70).map {
            (address: UInt64($0), name: "P\($0)")
        }
        let filled = FaceKnobAssignment.fillingDefaults([], parameters: parameters)
        #expect(!filled.contains { $0.knob == FaceKnobAssignment.damperCC })
    }

    @Test("保存形に載る — 旧データは keep として読める")
    func pedalModeRoundTrips() {
        #expect(PedalMode(rawValue: "assign") == .assign)
        #expect(PedalMode(rawValue: "keep") == .keep)
        // 未知・欠損は keep（従来の挙動）に倒す
        #expect(PedalMode(rawValue: "unknown") == nil)
    }
}
