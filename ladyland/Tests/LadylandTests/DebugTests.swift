//! Debug ログ機構のテスト（design/06 §8 追補）。
//!
//! DebugLog（リングバッファ・フィルタ・collapse ×N）、MidiTraceFormat
//! （整形の純関数）、MIDIRouter のトレース発行（同期呼び出しで検証可能）。

import Testing

@testable import Ladyland

@Suite("DebugLog")
@MainActor
struct DebugLogTests {
    @Test("リングバッファは容量を超えたら古い行から捨てる")
    func ringBuffer() {
        let log = DebugLog()
        for i in 0..<(DebugLog.capacity + 20) {
            log.append("line \(i)")
        }
        #expect(log.lines.count == DebugLog.capacity)
        #expect(log.lines.first?.text == "line 20", "古い 20 行が消えている")
        #expect(log.lines.last?.text == "line \(DebugLog.capacity + 19)")
    }

    @Test("フィルタは大文字小文字を無視した部分一致")
    func filtering() {
        let log = DebugLog()
        log.append("keystage ch16 CC40 = 127")
        log.append("thumbnail: 保存")
        log.append("routing: keyboard → slot 1")
        let hits = DebugLog.filter(log.lines, query: "KEYSTAGE")
        #expect(hits.count == 1)
        #expect(DebugLog.filter(log.lines, query: "").count == 3, "空クエリは全件")
    }

    @Test("同じ collapse key の連続は 1 行に畳まれ、最新値 + ×N になる")
    func collapseFoldsConsecutiveSameKey() {
        let log = DebugLog()
        log.append("CC1 = 10", collapseKey: "cc-1")
        log.append("CC1 = 55", collapseKey: "cc-1")
        log.append("CC1 = 99", collapseKey: "cc-1")
        #expect(log.lines.count == 1)
        #expect(log.lines.last?.text == "CC1 = 99", "表示は最新値")
        #expect(log.lines.last?.count == 3)
        #expect(log.lines.last?.displayText == "CC1 = 99 ×3")
    }

    @Test("別の key・nil（stderr 行）が挟まると collapse は切れる")
    func collapseBreaksOnInterleave() {
        let log = DebugLog()
        log.append("CC1 = 10", collapseKey: "cc-1")
        log.append("note on 60", collapseKey: nil)  // ノート/stderr 行は常に追記
        log.append("CC1 = 20", collapseKey: "cc-1")
        log.append("PB", collapseKey: "pb")
        #expect(log.lines.count == 4)
        #expect(log.lines.allSatisfy { $0.count == 1 })
    }

    @Test("clear は collapse の連続判定もリセットする")
    func clearResetsCollapse() {
        let log = DebugLog()
        log.append("CC1 = 10", collapseKey: "cc-1")
        log.clear()
        log.append("CC1 = 20", collapseKey: "cc-1")
        #expect(log.lines.count == 1)
        #expect(log.lines.last?.count == 1, "clear 前の行と畳まれない")
    }
}

@Suite("MidiTraceFormat")
struct MidiTraceFormatTests {
    @Test("ノブ横取りは CC 番号ごとの collapse key を持つ")
    func knobLine() {
        let line = MidiTraceFormat.line(
            .knob(cc: 3, value: 90), selectedSlot: "slot 1 (A)", drumSlot: "drums (B)")
        #expect(line.key == "knob-3")
        #expect(line.text.contains("CC3"))
        #expect(line.text.contains("顔つまみ"))
    }

    @Test("ノートオンは畳まれない（key = nil）・送り先名が入る")
    func noteOnLine() {
        let line = MidiTraceFormat.line(
            .keyboard(status: 0x90, data1: 60, data2: 100, hasTarget: true),
            selectedSlot: "slot 3 (Serum)", drumSlot: "drums (London)")
        #expect(line.key == nil)
        #expect(line.text == "Keystage note on 60 vel 100 (ch1) → slot 3 (Serum)")
    }

    @Test("vel 0 の 0x90 と 0x80 はどちらもノートオフ")
    func noteOffVariants() {
        let off1 = MidiTraceFormat.line(
            .keyboard(status: 0x80, data1: 60, data2: 0, hasTarget: true),
            selectedSlot: "s", drumSlot: "d")
        let off2 = MidiTraceFormat.line(
            .keyboard(status: 0x90, data1: 60, data2: 0, hasTarget: true),
            selectedSlot: "s", drumSlot: "d")
        #expect(off1.text.contains("note off 60"))
        #expect(off2.text.contains("note off 60"))
    }

    @Test("送り先なしは (送り先なし) と明示する")
    func noTarget() {
        let line = MidiTraceFormat.line(
            .keyboard(status: 0x90, data1: 60, data2: 100, hasTarget: false),
            selectedSlot: "slot 1 (A)", drumSlot: "d")
        #expect(line.text.hasSuffix("(送り先なし)"))
    }

    @Test("連続ストリーム（CC / AT / PB）は種別ごとの collapse key")
    func streamKeys() {
        let cc = MidiTraceFormat.line(
            .keyboard(status: 0xB0, data1: 1, data2: 64, hasTarget: true),
            selectedSlot: "s", drumSlot: "d")
        #expect(cc.key == "cc-Keystage-1")
        let at = MidiTraceFormat.line(
            .keyboard(status: 0xD0, data1: 80, data2: 0, hasTarget: true),
            selectedSlot: "s", drumSlot: "d")
        #expect(at.key == "at-Keystage")
        let pb = MidiTraceFormat.line(
            .keyboard(status: 0xE0, data1: 0, data2: 96, hasTarget: true),
            selectedSlot: "s", drumSlot: "d")
        #expect(pb.key == "pb-Keystage")
    }

    @Test("drums 経路は LPD8 発でドラムスロット行き")
    func drumsLine() {
        let line = MidiTraceFormat.line(
            .drums(status: 0x99, data1: 44, data2: 120, hasTarget: true),
            selectedSlot: "slot 1 (A)", drumSlot: "drums (London)")
        #expect(line.text == "LPD8 note on 44 vel 120 (ch10) → drums (London)")
    }

    @Test("ch16 未割当 CC はトラックナビ候補として区別される")
    func unassignedCh16Line() {
        let line = MidiTraceFormat.line(
            .unassignedCh16(cc: 0x28, value: 127), selectedSlot: "s", drumSlot: "d")
        #expect(line.key == "ch16-40")
        #expect(line.text.contains("未割当"))
    }

    @Test("VALUE エンコーダーのナビは方向が読める")
    func navLine() {
        let plus = MidiTraceFormat.line(.nav(direction: +1), selectedSlot: "s", drumSlot: "d")
        let minus = MidiTraceFormat.line(.nav(direction: -1), selectedSlot: "s", drumSlot: "d")
        #expect(plus.key == "nav" && plus.text.contains("+1"))
        #expect(minus.key == "nav" && minus.text.contains("-1"))
    }
}

/// トレース発行の記録箱（route* は同期呼び出しなのでロック不要）
private final class TraceBox: @unchecked Sendable {
    var routes: [MidiRoute] = []
}

@Suite("MIDIRouter トレース発行")
struct MidiRouterTraceTests {
    @Test("ノブ横取りは .knob を発行し、楽器経路の trace は出ない")
    func knobEmits() {
        let router = MIDIRouter()
        let box = TraceBox()
        router.setTraceHandler { box.routes.append($0) }
        router.setKnobRouting(ccs: [3]) { _, _ in }

        router.routeKeyboard(0xB0, 3, 100)

        #expect(box.routes == [.knob(cc: 3, value: 100)])
    }

    @Test("VALUE の上下ボタンは捨て、未知の ch16 CC は .unassignedCh16")
    func unassignedCh16Emits() {
        let router = MIDIRouter()
        let box = TraceBox()
        router.setTraceHandler { box.routes.append($0) }
        router.setPageStepHandler { _ in }

        router.routeKeyboard(0xBF, 0x3C, 0x7F)  // VALUE の上ボタン — 捨てる
        // ⚠️ **ノブ帯の外**を選ぶ（2026-08-07）。あの帯は `KeystageKnobs` が
        // **チャンネル不問で飲む**ので、帯の中を使うと「未知の ch16 CC」の
        // 経路まで届かない。⚠️ **番号を直書きしない** — 帯は 4 回動いている
        let unknown = (0...127).first {
            !KeystageKnobs.intercepted.contains($0)
                && !KeystageControls.interceptedCCs.contains($0)
                && !FaceKnobAssignment.controllerCCs.contains($0)
        }!
        router.routeKeyboard(0xBF, UInt8(unknown), 0x7F)

        // 上下ボタン（3C/3D）はトレースにも出さない（黙って捨てる）
        #expect(box.routes == [.unassignedCh16(cc: UInt8(unknown), value: 0x7F)])
    }

    @Test("keyboard / drums 経路は送り先の有無つきで発行される（無ターゲット）")
    func routesEmitWithTargetFlag() {
        let router = MIDIRouter()
        let box = TraceBox()
        router.setTraceHandler { box.routes.append($0) }

        router.routeKeyboard(0x90, 60, 100)
        router.routeDrums(0x99, 44, 120)

        #expect(box.routes == [
            .keyboard(status: 0x90, data1: 60, data2: 100, hasTarget: false),
            .drums(status: 0x99, data1: 44, data2: 120, hasTarget: false),
        ])
    }
}

@Suite("MIDIRouter ピッチベンド横取り")
struct PitchBendRoutingTests {
    @Test("割当（擬似 Ctrl 128）があるときだけ PB を横取りし、無ければ素通し")
    func interceptOnlyWhenMapped() {
        let router = MIDIRouter()
        let box = TraceBox()
        router.setTraceHandler { box.routes.append($0) }

        router.setKnobRouting(ccs: [128]) { _, _ in }
        router.routeKeyboard(0xE0, 0, 96)
        #expect(box.routes == [.knob(cc: 128, value: 96)], "割当あり → 顔つまみ経路")

        router.setKnobRouting(ccs: [], handler: nil)
        router.routeKeyboard(0xE0, 0, 96)
        #expect(
            box.routes.last == .keyboard(status: 0xE0, data1: 0, data2: 96, hasTarget: false),
            "割当なし → ネイティブベンドとして素通し")
    }
}

@Suite("MIDIRouter LPD8 ノブ横取り")
struct DrumKnobRoutingTests {
    @Test("割当のある CC はドラム顔つまみへ、無い CC はドラム楽器へ素通し")
    func drumKnobInterception() {
        let router = MIDIRouter()
        let box = TraceBox()
        router.setTraceHandler { box.routes.append($0) }
        router.setDrumKnobRouting(ccs: [79]) { _, _ in }

        router.routeDrums(0xB0, 79, 100)  // K1（割当あり）
        router.routeDrums(0xB0, 80, 50)  // K2（割当なし）
        router.routeDrums(0x99, 44, 120)  // パッドは常に素通し

        #expect(box.routes == [
            .drumKnob(cc: 79, value: 100),
            .drums(status: 0xB0, data1: 80, data2: 50, hasTarget: false),
            .drums(status: 0x99, data1: 44, data2: 120, hasTarget: false),
        ])
    }
}
