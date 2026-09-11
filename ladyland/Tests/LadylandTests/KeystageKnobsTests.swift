//! **Keystage のノブ帯**（mako 裁定 2026-08-07 夜
//! 「ノブ帯を base = 0 / pageCount = 8（CC0-63）へ」）。
//!
//! ⚠️ ここで固定するのは 3 つ:
//!
//! 1. ⭐ **帯の全席が楽器へ届かない**（安全の本体）
//! 2. ⚠️ **番号を直書きしていない** — `base` / `pageCount` から導く
//! 3. ⚠️⚠️ **ペダル帯（CC64〜）へ食い込まない** — ページを 1 つ足すと
//!    実機で **P9 のノブ 1 = CC64 = Sustain** になり、回すと張り付く

import Foundation
import KeystageKit
import Testing

@testable import Ladyland

@Suite("Keystage のノブ帯")
struct KeystageKnobsTests {

    // MARK: - 範囲そのもの

    /// ⚠️ **数字を書かない** — `base` / `perPage` / `pageCount` から導く。
    /// 今日だけで番号が 4 回動いている（0-7 → 24 → 16 → 0）
    @Test("席は base から隙間なく並ぶ")
    func rangeIsContiguous() {
        let count = KnobPages.perPage * KnobPages.pageCount
        #expect(KnobPages.all.count == count)
        #expect(KnobPages.all.first == 0, "帯の先頭 = 0 自体が主張（正典はページ = CC ÷ 8）")
        #expect(KnobPages.all.last == KnobPages.seatCount - 1, "壁の 1 つ手前で止まる")
        #expect(KnobPages.all == Array(0..<KnobPages.seatCount))
    }

    /// ⚠️ **CC64 以降はペダル帯**（Sustain / Portamento / Sostenuto…）。
    /// **踏むと張り付く・音が止まらなくなる**類なので、ノブに割り当てない
    @Test("ペダル帯へ食い込まない")
    func neverReachesPedalRange() {
        #expect(KnobPages.seatCount == FaceKnobAssignment.damperCC, "席の総数 = Sustain の手前")
        for cc in KnobPages.all {
            #expect(cc < FaceKnobAssignment.damperCC, "CC\(cc) がペダル帯")
        }
    }

    /// ⭐ **ちょうど壁で終わる** — `base + perPage × pageCount == limit`。
    ///
    /// ⚠️⚠️ **ここが「8 ページで打ち止め」の番人**。ページを 1 つ足すと
    /// この等式が破れて落ちる — そして実機では **P9 = CC64-71 = ペダル帯**、
    /// **ノブ 1 を回すとサステインが固まる**（`KeystageKnobs` の冒頭）
    @Test("ペダル帯の壁にぴたり収まる — 端数も食い込みも無い")
    func fillsExactlyUpToPedalRange() {
        // ⚠️ **9 ページ目を足すとここが落ちる** — ペダル帯（CC64〜）へ食い込む
        #expect(
            KnobPages.perPage * KnobPages.pageCount == FaceKnobAssignment.damperCC,
            "ページを増減すると壁とズレる")
    }

    // MARK: - ページの導き方

    /// ⭐ **CC 番号がページを自己申告している** — 状態を持たない
    @Test("ページとページ内位置が CC から引ける")
    func pageAndIndexComeFromCC() {
        let base = 0  // 正典の帯は 0 起点（定義そのもの）
        let perPage = KnobPages.perPage
        #expect(KnobPages.page(forCC: base) == 0)
        #expect(KnobPages.index(forCC: base) == 0)
        #expect(KnobPages.page(forCC: base + perPage - 1) == 0)
        #expect(KnobPages.index(forCC: base + perPage - 1) == perPage - 1)
        #expect(KnobPages.page(forCC: base + perPage) == 1, "8 ずれると次のページ")
        #expect(
            KnobPages.page(forCC: KnobPages.all.last!) == KnobPages.pageCount - 1)
    }

    /// ⚠️ **帯の外は nil** — ペダル帯（CC64〜）や、退かせた演奏席
    /// （Mod 116 / Expression 115）や、焼いたボタン（102-110）は
    /// 今までどおり扱う（壊れない）。
    ///
    /// ⚠️ **番号を直書きしない** — 帯が動くと「外」も動く。
    /// **`all` に無いこと**を条件にして選ぶ
    @Test("帯の外は nil を返す")
    func outsideRangeIsNil() {
        let outside = (0...127).filter { !KnobPages.all.contains($0) }
        #expect(!outside.isEmpty, "帯が 0-127 を食い尽くしている")
        for cc in outside {
            #expect(KnobPages.page(forCC: cc) == nil, "CC\(cc)")
            #expect(KnobPages.index(forCC: cc) == nil, "CC\(cc)")
        }
        // 負数と 128 以上（Pitch Bend の擬似 Ctrl）も材料外
        for cc in [-1, 128, 999] {
            #expect(KnobPages.page(forCC: cc) == nil)
        }
    }

    /// ⭐ **ページの読み方をそのまま固定する**（mako 指定 2026-08-07）。
    /// ⚠️ 直書きせず `base` / `perPage` / `pageCount` から作る
    @Test("CC → ページ（先頭 / 2 ページ目 / 最終 / 壁の外）")
    func pageBoundaries() {
        let base = 0  // 正典の帯は 0 起点（定義そのもの）
        let perPage = KnobPages.perPage
        let last = KnobPages.pageCount - 1
        #expect(KnobPages.page(forCC: base) == 0, "先頭は P1")
        #expect(KnobPages.page(forCC: base + perPage) == 1, "8 ずれて P2")
        #expect(KnobPages.page(forCC: base + perPage * last) == last, "最終ページの先頭")
        #expect(KnobPages.page(forCC: KnobPages.seatCount) == nil, "壁（Damper）は外")
    }

    @Test("どのページも 8 席")
    func everyPageHasEightSeats() {
        let pages = KnobPages.pages
        #expect(pages.count == KnobPages.pageCount)
        for page in pages {
            #expect(page.count == KnobPages.perPage)
        }
        // ⚠️ **数字を書かない** — `base` からの連番であることだけを見る
        #expect(pages.first == Array(0..<8), "P1 = CC0-7（正典は 0 起点）")
        let lastStart = 8 * (KnobPages.pageCount - 1)
        #expect(pages.last == Array(lastStart..<(lastStart + 8)), "最終ページ")
    }

    // MARK: - ⚠️ 他の割当と衝突しない

    /// ⚠️ **焼いたボタン（102-110）と重ならない**
    @Test("焼いたボタンの CC と重ならない")
    func doesNotCollideWithBurnedButtons() {
        let buttons = Set(Keystage.ladylandButtonCCs.map { Int($0.1) })
        #expect(Set(KnobPages.all).isDisjoint(with: buttons))
    }

    /// ⚠️ **Mod / Damper / Expression は横取りしない** — 楽器へ通すのが正しい
    @Test("演奏席は帯に含まれない")
    func performanceControlsAreNotIncluded() {
        for cc in [FaceKnobAssignment.modWheelCC, FaceKnobAssignment.damperCC, FaceKnobAssignment.expressionCC] {
            #expect(!KeystageKnobs.intercepted.contains(cc), "CC\(cc) を横取りしている")
        }
    }

    /// エンコーダー（117/118）とも重ならない
    @Test("エンコーダーの CC と重ならない")
    func doesNotCollideWithEncoders() {
        let encoders = Set(Keystage.ladylandEncoderCCs.map { Int($0.1) })
        #expect(Set(KnobPages.all).isDisjoint(with: encoders))
    }

    /// ⭐⭐ **64 席すべてが生きていること**（`base = 0` にした目的そのもの）。
    ///
    /// 席が死ぬのは **予約や演奏席が帯の中に残っている**とき。
    /// ⚠️ **今日それで 2 回踏んだ** — CC62/63 の役目を終えた予約、
    /// CC11 の直書き。**どちらも「回しても割り当てられない席」を作った**。
    ///
    /// ⚠️ **番号を並べない** — `controllerCCs` / `alwaysReservedCCs` が
    /// **帯と交わらない**ことだけを見る。演奏席がまた動いても正しく落ちる
    @Test("帯の中に死に席が無い — 予約も演奏席も全部が帯の外")
    func everySeatInBandIsAlive() {
        let band = Set(KnobPages.all)
        for cc in FaceKnobAssignment.controllerCCs {
            #expect(!band.contains(cc), "演奏席 CC\(cc) が帯の中 = その席が死ぬ")
        }
        for cc in FaceKnobAssignment.alwaysReservedCCs {
            #expect(!band.contains(cc), "予約 CC\(cc) が帯の中 = その席が死ぬ")
        }
        // ⭐ 帯の席が 1 つ残らず割当プールに居ること（= 実際に割り当てられる）
        let pool = Set(FaceKnobAssignment.assignableCCs)
        #expect(band.isSubset(of: pool), "割当プールに無い席: \(band.subtracting(pool).sorted())")
    }

    /// ⭐ **Mod と Expression を退かせた成果** — CC1 と CC11 が席に戻った
    /// （2026-08-07。Mod → 116 / Expression → 115）。
    /// ⚠️ **番号を直書きしている数少ない場所** — ここは「**ネイティブの
    /// 番号が空いた**」こと自体が主張なので、定数から引くと意味が消える
    @Test("CC1（旧 Mod）と CC11（旧 Expression）は席として生きている")
    func nativePerformanceCCsAreSeatsNow() {
        for (cc, was) in [(1, "Mod ホイール"), (11, "Expression")] {
            #expect(KeystageKnobs.intercepted.contains(cc), "CC\(cc)（旧 \(was)）が帯に無い")
            #expect(
                FaceKnobAssignment.assignableCCs.contains(cc),
                "CC\(cc)（旧 \(was)）が席プールに無い")
        }
        // 退かせた先が別の番号であること（戻っていたら上の 2 つが嘘になる）
        #expect(FaceKnobAssignment.modWheelCC != 1)
        #expect(FaceKnobAssignment.expressionCC != 11)
    }
}

/// ⭐ **帯の全席が楽器へ届かないこと**（安全の本体）
@Suite("ノブ帯の横取り")
struct KeystageKnobInterceptTests {
    private final class Sink: @unchecked Sendable {
        var toInstrument: [(UInt8, UInt8)] = []
        var knobs: [(UInt8, UInt8)] = []
    }

    private func router(_ sink: Sink, assigned: Set<UInt8> = []) -> MIDIRouter {
        let router = MIDIRouter()
        router.setKnobRouting(ccs: assigned) { sink.knobs.append((cc: $0, value: $1)) }
        router.setTraceHandler { route in
            if case .keyboard(_, let data1, let data2, _) = route {
                sink.toInstrument.append((data1, data2))
            }
        }
        return router
    }

    /// ⭐ **割当が無くても飲む** — 番号の意味は届かなければ無関係になる
    @Test("帯の全席が楽器へ届かない（割当なしでも）")
    func allKnobCCsAreSwallowed() {
        let sink = Sink()
        let midi = router(sink)  // ⚠️ 割当は 1 つも無い
        for cc in KnobPages.all {
            midi.routeKeyboard(0xB0, UInt8(cc), 64)
        }
        #expect(sink.toInstrument.isEmpty, "楽器へ流れた: \(sink.toInstrument)")
        #expect(sink.knobs.isEmpty, "割当が無いので顔つまみも動かない")
    }

    /// ⭐ **実害が出た番号を名指しで固定する**（実測 2026-08-07）。
    ///
    /// `base = 16` の頃、**PAGE − で下へ降りると CC0-15 が帯の外**になり、
    /// 未割当 CC は楽器へ素通しするので **CC7 で楽器の音量が直接動いた**。
    /// ⚠️ **番号の意味は「届かなければ無関係」** — 横取りで消える
    @Test(
        "予約帯の番号が楽器へ届かない（CC0 Bank Select / CC7 Volume / CC32 / CC6）",
        arguments: [
            (0, "Bank Select MSB"), (6, "Data Entry MSB"), (7, "Channel Volume"),
            (10, "Pan"), (32, "Bank Select LSB"), (38, "Data Entry LSB"),
        ])
    func reservedNumbersAreSwallowed(cc: Int, meaning: String) {
        let sink = Sink()
        let midi = router(sink)
        midi.routeKeyboard(0xB0, UInt8(cc), 100)
        #expect(sink.toInstrument.isEmpty, "CC\(cc)（\(meaning)）が楽器へ届いた")
    }

    /// 割当があれば顔つまみへ届く（既存の振る舞いを壊していない）
    @Test("割当があれば顔つまみへ届く")
    func assignedKnobsStillReachHandler() {
        let sink = Sink()
        let seats = [KnobPages.page(0)[0], KnobPages.page(2)[0]]
        let midi = router(sink, assigned: Set(seats.map { UInt8($0) }))
        midi.routeKeyboard(0xB0, UInt8(seats[0]), 100)
        midi.routeKeyboard(0xB0, UInt8(seats[1]), 20)
        #expect(sink.knobs.count == 2)
        #expect(sink.toInstrument.isEmpty)
    }

    /// ⚠️ **横取りしすぎていない** — 演奏席は今までどおり楽器へ。
    ///
    /// ⭐ **帯が 0-63 まで広がった今こそ効くテスト** — 「全部飲む」を
    /// 素直に広げると **Damper を踏んでも音が伸びない / ホイールが死ぬ**
    @Test("Mod / Damper / Expression は今までどおり楽器へ届く")
    func performanceControlsStillPassThrough() {
        let sink = Sink()
        let midi = router(sink)
        let seats = [
            FaceKnobAssignment.modWheelCC,
            FaceKnobAssignment.damperCC,
            FaceKnobAssignment.expressionCC,
        ]
        for cc in seats {
            midi.routeKeyboard(0xB0, UInt8(cc), 64)
        }
        #expect(
            sink.toInstrument.count == seats.count,
            "演奏席が届かない = 横取りしすぎ（届いた: \(sink.toInstrument.map(\.0))）")
    }

    /// ⚠️ **チャンネル不問**（Keystage のノブ ch は Scene 設定次第）
    @Test("チャンネルが違っても横取りする")
    func channelAgnostic() {
        let sink = Sink()
        let midi = router(sink)
        let seat = UInt8(KnobPages.all.first!)
        midi.routeKeyboard(0xB0, seat, 64)  // ch1
        midi.routeKeyboard(0xB9, seat, 64)  // ch10
        #expect(sink.toInstrument.isEmpty)
    }
}

/// ⚠️⚠️ **割当が無くてもページが推定されること**（監査 2026-08-08 の B-7）。
///
/// トレースは **keyboard 経路の唯一の main 観測点**で、ノブストリップの
/// ページ推定（`AppState` の `activeKnobPage`）はここだけを見ている。
///
/// ⚠️ **割当が無いときに黙って return していた**ので、#75 で帯を全部飲む
/// ようにしてから **割当ゼロのトラックでは見出しが `P?` のまま固まっていた**。
@Suite("未割当ノブでもページが追従する")
struct KnobTracePageFollowTests {
    private final class Sink: @unchecked Sendable {
        var traced: [(cc: UInt8, value: UInt8)] = []
        var toInstrument: [UInt8] = []
        var knobs: [UInt8] = []
    }

    private func router(_ sink: Sink, assigned: Set<UInt8> = []) -> MIDIRouter {
        let router = MIDIRouter()
        router.setKnobRouting(ccs: assigned) { cc, _ in sink.knobs.append(cc) }
        router.setTraceHandler { route in
            switch route {
            case .knob(let cc, let value):
                sink.traced.append((cc, value))
            case .keyboard(_, let data1, _, _):
                sink.toInstrument.append(data1)
            default:
                break
            }
        }
        return router
    }

    /// ⭐ **本題** — 割当ゼロでも帯の全席でページが引ける
    @Test("割当が 1 つも無くても帯の全席が trace に出る")
    func unassignedKnobsStillTrace() {
        let sink = Sink()
        let midi = router(sink)  // ⚠️ 割当なし
        for cc in KnobPages.all {
            midi.routeKeyboard(0xB0, UInt8(cc), 64)
        }
        #expect(sink.traced.count == KnobPages.all.count, "trace が落ちている")
        // ⭐ 推定まで通ること（ここが nil だと HUD が P? のまま）
        for (cc, _) in sink.traced {
            #expect(
                FaceKnobAssignment.inferredPage(cc: Int(cc)) == KnobPages.page(forCC: Int(cc)),
                "CC\(cc) からページが引けない")
        }
    }

    /// ⚠️ **trace を出しても楽器へは流れない** — 安全の本体を壊していない
    @Test("trace を出しても楽器へは届かない")
    func tracingDoesNotLeakToInstrument() {
        let sink = Sink()
        let midi = router(sink)
        for cc in KnobPages.all {
            midi.routeKeyboard(0xB0, UInt8(cc), 100)
        }
        #expect(sink.toInstrument.isEmpty, "楽器へ流れた: \(sink.toInstrument)")
        #expect(sink.knobs.isEmpty, "割当が無いので顔つまみも動かない")
    }

    /// 割当があるときの振る舞いは変わっていない（trace + handler の両方）
    @Test("割当があれば trace も handler も動く")
    func assignedKnobsStillWork() {
        let sink = Sink()
        let seat = KnobPages.page(1)[0]
        let midi = router(sink, assigned: [UInt8(seat)])
        midi.routeKeyboard(0xB0, UInt8(seat), 40)
        #expect(sink.traced.map(\.cc) == [UInt8(seat)])
        #expect(sink.knobs == [UInt8(seat)])
        #expect(sink.toInstrument.isEmpty)
    }
}
