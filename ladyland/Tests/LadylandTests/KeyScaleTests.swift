//! KeyScale のテスト — 役割分類（純関数）と LED 基本色写像。

import Testing

import Lpd8Kit

@testable import Ladyland

@Suite("KeyScale")
struct KeyScaleTests {
    @Test("C メジャー: ルート / 内 / 外の分類")
    func cMajorRoles() {
        let key = KeyScale(root: 0, scale: .major)
        #expect(key.role(ofNote: 60) == .root)  // C4
        #expect(key.role(ofNote: 62) == .inScale)  // D
        #expect(key.role(ofNote: 61) == .outOfScale)  // C#
        #expect(key.role(ofNote: 71) == .inScale)  // B
    }

    @Test("オクターブ非依存 — どの高さの同音も同じ役割")
    func octaveIndependence() {
        let key = KeyScale(root: 9, scale: .minorPentatonic)  // A minor penta
        for octave in 0..<8 {
            #expect(key.role(ofNote: 9 + octave * 12) == .root)  // A
            #expect(key.role(ofNote: 12 + octave * 12) == .inScale)  // C
            #expect(key.role(ofNote: 11 + octave * 12) == .outOfScale)  // B
        }
    }

    @Test("マイナーペンタは 5 音 + ルート以外が外れる")
    func minorPentatonic() {
        let key = KeyScale(root: 0, scale: .minorPentatonic)  // C minor penta
        let inNotes = [0, 3, 5, 7, 10]
        for pc in 0..<12 {
            let role = key.role(ofNote: 60 + pc)
            if pc == 0 {
                #expect(role == .root)
            } else if inNotes.contains(pc) {
                #expect(role == .inScale)
            } else {
                #expect(role == .outOfScale)
            }
        }
    }

    @Test("クロマチックは全音スケール内（ルート以外）")
    func chromatic() {
        let key = KeyScale(root: 4, scale: .chromatic)
        for pc in 0..<12 {
            let expected: NoteRole = pc == 4 ? .root : .inScale
            #expect(key.role(ofNote: 60 + pc) == expected)
        }
    }

    @Test("LED 基本色: ルート = 暖色 / 内 = 寒色 / 外 = 消灯")
    func baseColors() {
        // 実機プログラム 1 のパッド配列（note 44-47, 40-43）で A minor penta
        let key = KeyScale(root: 9, scale: .minorPentatonic)
        let colors = key.baseColors(padNotes: Lpd8DefaultPadNotes.program1)
        #expect(colors.count == 8)

        // note 45 (A) = ルート → 暖色（pad index 1）
        #expect(colors[1] == Rgb8(255, 120, 0))
        // note 40 (E) = A minor penta 内 → 寒色（pad index 4）
        #expect(colors[4] == Rgb8(0, 60, 140))
        // note 46 (A#) = 外 → 消灯（pad index 2）
        #expect(colors[2] == .off)
    }
}

@Suite("LPD8 の番号規約 — 帯が重なると何も気づかずに壊れる")
struct Lpd8NumberingTests {
    @Test("パッド CC / ノブ CC / 危険牌が互いに重ならない")
    func bandsDoNotOverlap() {
        // ⚠️ Int に揃える — `controllerCCs` には Pitch Bend の擬似番号 128 が
        // 混ざっていて、UInt8 側へ寄せると変換で落ちる
        let padCCs = Set(Lpd8DefaultPadCCs.byProgram.flatMap { $0 }.map(Int.init))
        let knobCCs = Set(Lpd8DefaultKnobCCs.byProgram.flatMap { $0 }.map(Int.init))

        #expect(padCCs.count == 32, "4 PROG × 8 パッドが全部別番号")
        #expect(knobCCs.count == 32, "4 PROG × 8 ノブが全部別番号")
        #expect(padCCs.isDisjoint(with: knobCCs), "パッドとノブが同じ CC を使うと区別できない")

        // ⚠️ 危険牌を踏むと**叩いた瞬間に音が全部切れる**（120 = All Sound Off）
        // り、機器内部の別パラメータが書き換わる（96-101 = NRPN/RPN）
        #expect(padCCs.isDisjoint(with: FaceKnobAssignment.unsafeCCs))
        #expect(knobCCs.isDisjoint(with: FaceKnobAssignment.unsafeCCs))

        // Keystage の固定席（Mod / Exp / Damper）とも重ならない
        #expect(padCCs.isDisjoint(with: Set(FaceKnobAssignment.controllerCCs)))
    }

    @Test("番号だけでプログラムと位置を逆算できる — LPD8 は切替を通知しない")
    func numbersCarryTheirOrigin() {
        for program in 1...4 {
            for position in 0..<8 {
                let cc = Lpd8DefaultPadCCs.byProgram[program - 1][position]
                #expect(Lpd8DefaultPadCCs.program(of: cc) == program)
                #expect(Lpd8DefaultPadCCs.index(of: cc) == position)

                let knob = Lpd8DefaultKnobCCs.byProgram[program - 1][position]
                #expect(Lpd8DefaultKnobCCs.index(of: knob) == position)
            }
        }
        #expect(Lpd8DefaultPadCCs.index(of: 127) == nil)
    }

    @Test("サンプラーの音量はノブの位置で引く — どの PROG でも K1 が pad 1")
    func volumeFollowsKnobPosition() {
        // 当初は CC57-64 固定にしていて、**どの PROG のノブとも一致しなかった**
        // （PROG 1 = 79-86 / PROG 3 = 102-109）ので音量が動かなかった
        #expect(Lpd8DefaultKnobCCs.index(of: 79) == 0, "PROG1 K1")
        #expect(Lpd8DefaultKnobCCs.index(of: 102) == 0, "PROG3 K1")
        #expect(Lpd8DefaultKnobCCs.index(of: 109) == 7, "PROG3 K8")
        #expect(Lpd8DefaultKnobCCs.index(of: 57) == nil, "旧 volumeCCs はノブではない")
    }
}
