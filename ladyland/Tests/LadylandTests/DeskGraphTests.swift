//! 机の結線（mako 2026-10-04「画面上のノードグラフを下の新しいビューに
//! マッピング。統一させて一つのビューに情報まとめよう」、裁定 1・2 OK）。
//!
//! 机 = **物理層（動かせない MIDI 機材）の上に仮想層を重ねる場所**
//! （mako 同日「動かせないもの(MIDIコン)を、仮想的に配置して、そこに
//! ヴァーチャルなコンポーネントを重ねる」）。
//!
//! 守りたい不変条件:
//!   - 結線図の行は 1 つ残らず机のどこかのソケットに写る（机の板か、棚）
//!   - ケーブルの行き先は Mixer のストリップ（Jack の箱は無い）
//!   - プラグを落とした場所 → 担当の変更は、結線図の操作と同じ意味

import CoreGraphics
import Testing

@testable import Ladyland

@Suite("机の結線 — ソケット")
struct DeskSocketTests {
    private func rows(_ sources: [MIDIConnectedSource], lpd8: Lpd8KnobJack = .drums)
        -> [JackBoardView.GearRow]
    {
        JackBoardView.gearRows(sources: sources, lpd8KnobJack: lpd8)
    }

    @Test("Keystage + LPD8 — 板ごとのソケット、PC キーボードは鍵盤 1 に畳む、外の鍵盤は棚")
    func keystageRig() {
        let sources = [
            MIDIConnectedSource(name: "Keystage KBD/CTRL", route: .keystage),
            MIDIConnectedSource(name: "LPD8 mk2", route: .drums),
            MIDIConnectedSource(name: "Zenith 2", route: .secondKeyboard),
        ]
        let gears = DeskModel.gears(sources: sources)
        let sockets = DeskGraph.sockets(rows: rows(sources), gears: gears)
        let byID = Dictionary(uniqueKeysWithValues: sockets.map { ($0.id, $0) })

        #expect(byID["keystage.keys"]?.home == .keystage)
        #expect(byID["keystage.keys"]?.jack == .synth1)
        #expect(byID["keystage.knobs"]?.jack == .trackKnobs)
        #expect(byID["lpd8.pads"]?.jack == .drums)
        #expect(byID["lpd8.knobs"]?.jack == .drums)
        #expect(byID["pckb"] == nil, "PC キーボードは鍵盤 1 のソケットに畳む")

        let shelf = sockets.filter { $0.home == nil }
        #expect(shelf.map(\.gear).contains("Zenith 2"))
        #expect(shelf.first { $0.gear == "Zenith 2" }?.connected == true)
        #expect(shelf.first { $0.gear == "Zenith 2" }?.jack == .synth2)
        #expect(shelf.first { $0.gear == "MiniLab mkII" }?.connected == false, "未接続は棚で薄く")
    }

    @Test("Keystage 不在 — 汎用鍵盤は画面の鍵盤の板に畳み、Keystage は棚")
    func genericRig() {
        let sources = [MIDIConnectedSource(name: "Roland A-88", route: .genericKeyboard)]
        let gears = DeskModel.gears(sources: sources)
        let sockets = DeskGraph.sockets(rows: rows(sources), gears: gears)
        let keys = sockets.first { $0.id == "keyboard.keys" }
        #expect(keys?.home == .keyboard)
        #expect(keys?.connected == true)
        #expect(!sockets.contains { $0.gear == "Roland A-88" }, "汎用鍵盤は板に畳む")
        let keystage = sockets.filter { $0.gear == "Keystage" }
        #expect(!keystage.isEmpty && keystage.allSatisfy { $0.home == nil && !$0.connected })
    }

    @Test("刺し替えられるのは鍵盤と LPD8 のノブだけ")
    func repluggable() {
        let sources = [
            MIDIConnectedSource(name: "Keystage KBD/CTRL", route: .keystage),
            MIDIConnectedSource(name: "LPD8 mk2", route: .drums),
        ]
        let sockets = DeskGraph.sockets(
            rows: rows(sources), gears: DeskModel.gears(sources: sources))
        let byID = Dictionary(uniqueKeysWithValues: sockets.map { ($0.id, $0) })
        #expect(byID["keystage.keys"]?.repluggable == true)
        #expect(byID["lpd8.knobs"]?.repluggable == true)
        #expect(byID["keystage.knobs"]?.repluggable == false, "Keystage のノブは常に選択中の Track")
        #expect(byID["lpd8.pads"]?.repluggable == false, "パッドは常にドラム席")
    }
}

@Suite("机の結線 — ケーブルの行き先とプラグ")
struct DeskCableTests {
    private let bindings = DeskGraph.Bindings(synth1: nil, synth2: 27, selected: 2, page: 2)

    @Test("行き先 — 追従は選択中のストリップ、固定はその席、ドラムは DRUMS")
    func targets() {
        #expect(DeskGraph.target(.synth1, bindings) == .strip(2, follows: true))
        #expect(DeskGraph.target(.synth2, bindings) == .strip(27, follows: false))
        #expect(DeskGraph.target(.trackKnobs, bindings) == .strip(2, follows: true))
        #expect(DeskGraph.target(.drums, bindings) == .drums)
    }

    @Test("プラグの札 — Jack 名、追従、ページ、バンク外の席番号")
    func labels() {
        let bank = Array(0..<8)
        #expect(DeskGraph.plugLabel(.synth1, bindings, bank: bank) == "鍵盤 1 · 追従")
        #expect(DeskGraph.plugLabel(.synth2, bindings, bank: bank) == "鍵盤 2 → T28", "バンク外は席番号")
        #expect(DeskGraph.plugLabel(.trackKnobs, bindings, bank: bank) == "Track ノブ P3")
        #expect(DeskGraph.plugLabel(.drums, bindings, bank: bank) == "ドラム")
        let fixedInBank = DeskGraph.Bindings(synth1: 5, synth2: nil, selected: 2, page: 0)
        #expect(DeskGraph.plugLabel(.synth1, fixedInBank, bank: bank) == "鍵盤 1")
    }

    @Test("落とした場所 — DRUMS / ストリップ / Mixer の隙間 / 外")
    func dropTarget() {
        let strips: [Int: CGRect] = [
            0: CGRect(x: 0, y: 0, width: 50, height: 100),
            1: CGRect(x: 60, y: 0, width: 50, height: 100),
        ]
        let drums = CGRect(x: 120, y: 0, width: 50, height: 100)
        let mixer = CGRect(x: -10, y: -10, width: 200, height: 130)
        let drop = { (p: CGPoint) in
            DeskGraph.dropTarget(at: p, strips: strips, drums: drums, mixer: mixer)
        }
        #expect(drop(CGPoint(x: 70, y: 50)) == .strip(1))
        #expect(drop(CGPoint(x: 130, y: 50)) == .drums)
        #expect(drop(CGPoint(x: 55, y: 50)) == .none, "ストリップの隙間は何もしない")
        #expect(drop(CGPoint(x: 400, y: 400)) == .outside)
    }

    @Test("刺し替え — 結線図の操作と同じ意味")
    func rebind() {
        let keys = DeskSocket(
            id: "keystage.keys", home: .keystage, gear: "Keystage", section: "鍵盤",
            jack: .synth1, connected: true, repluggable: true)
        #expect(DeskGraph.rebind(keys, drop: .strip(4)) == .synth1(4))
        #expect(DeskGraph.rebind(keys, drop: .outside) == .synth1(nil), "Mixer の外 = 選択に追従")
        #expect(DeskGraph.rebind(keys, drop: .drums) == .none, "鍵盤はドラム席に刺さらない")

        let second = DeskSocket(
            id: "minilab", home: nil, gear: "MiniLab mkII", section: "鍵盤",
            jack: .synth2, connected: true, repluggable: true)
        #expect(DeskGraph.rebind(second, drop: .strip(9)) == .synth2(9))

        let lpd8 = DeskSocket(
            id: "lpd8.knobs", home: .lpd8, gear: "LPD8", section: "ノブ 8",
            jack: .drums, connected: true, repluggable: true)
        #expect(DeskGraph.rebind(lpd8, drop: .strip(3)) == .lpd8Knobs(.face))
        #expect(DeskGraph.rebind(lpd8, drop: .drums) == .lpd8Knobs(.drums))
        #expect(DeskGraph.rebind(lpd8, drop: .outside) == .none)

        let pads = DeskSocket(
            id: "lpd8.pads", home: .lpd8, gear: "LPD8", section: "パッド",
            jack: .drums, connected: true, repluggable: false)
        #expect(DeskGraph.rebind(pads, drop: .strip(1)) == .none)
    }
}

@Suite("机の仮想層 — ノブに重ねるパラメータ名")
struct DeskOverlayTests {
    private let selected = [
        FaceKnobMapping(knob: 16, address: 1, name: "Cutoff"),
        FaceKnobMapping(knob: 17, address: 2, name: "Reso"),
    ]
    private let drums = [FaceKnobMapping(knob: 79, address: 9, name: "Kick Vol")]

    @Test("Track ノブのとき — 現ページの席の割当名")
    func trackKnobs() {
        let label = { (i: Int) in
            DeskGraph.lpd8KnobLabel(
                index: i, jack: .face, knobCCs: Lpd8DefaultKnobCCs.program1, page: 2,
                selected: selected, drums: drums)
        }
        #expect(label(0) == "Cutoff", "P3-1 = 席 16")
        #expect(label(1) == "Reso")
        #expect(label(2) == nil, "空きの席は何も出さない")
    }

    @Test("ドラムのとき — ドラム席の割当名（CC そのまま）")
    func drumKnobs() {
        let label = { (i: Int) in
            DeskGraph.lpd8KnobLabel(
                index: i, jack: .drums, knobCCs: Lpd8DefaultKnobCCs.program1, page: 2,
                selected: selected, drums: drums)
        }
        #expect(label(0) == "Kick Vol")
        #expect(label(1) == nil)
    }
}
