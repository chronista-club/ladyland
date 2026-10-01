//! 机（2.5D の Jack。mako 赤入れ 2026-10-01 `mem_1CfavSouA1wvZ557nwJRrP`:
//! 奥に 8ch Mixer、中段に LPD8、手前に鍵盤を遠近で描いた机）。
//!
//! 守りたい不変条件:
//!   - 机に乗る機材は**繋がっているもの + 常設（Mixer / 鍵盤）**。抜けば消える
//!   - 既定の配置は赤入れの並び（奥 Mixer / 中 LPD8 / 手前 鍵盤）
//!   - 配置は 0-1 の机座標で持ち、画面サイズに依らない。はみ出しは端に止まる
//!   - 置き場は window.json（マシン固有 = 会場ごと）。raw 値は固定

import Foundation
import Testing

@testable import Ladyland

@Suite("机 — 乗る機材と配置")
struct DeskModelTests {
    @Test("常設は Mixer と鍵盤。繋がった機材だけ増える")
    func gears() {
        #expect(DeskModel.gears(sources: []) == [.mixer, .keyboard])
        let rig = DeskModel.gears(sources: [
            MIDIConnectedSource(name: "LPD8 mk2", route: .drums),
            MIDIConnectedSource(name: "Keystage KBD/CTRL", route: .keystage),
            MIDIConnectedSource(name: "nanoKONTROL2 SLIDER/KNOB", route: .secondKeyboard),
            MIDIConnectedSource(name: "Zenith 2", route: .secondKeyboard),
        ])
        #expect(rig.contains(.lpd8))
        #expect(rig.contains(.keystage))
        #expect(rig.contains(.nanokontrol))
        #expect(!rig.contains(.keyboard), "Keystage が居れば汎用鍵盤の板は出さない")
        #expect(rig.first == .mixer, "奥から並べる — Mixer が先頭")
    }

    @Test("既定の配置 — 奥 Mixer / 中 LPD8 / 手前 鍵盤")
    func defaults() {
        let mixer = DeskModel.defaultPlacement(.mixer)
        let lpd8 = DeskModel.defaultPlacement(.lpd8)
        let keyboard = DeskModel.defaultPlacement(.keyboard)
        #expect(mixer.depth < lpd8.depth)
        #expect(lpd8.depth < keyboard.depth)
        #expect(DeskModel.defaultPlacement(.keystage).depth == keyboard.depth, "鍵盤はどれも手前")
    }

    @Test("配置は 0-1 に止まる")
    func clamp() {
        #expect(DeskModel.clamp(DeskPlacement(x: -0.5, depth: 1.7)) == DeskPlacement(x: 0, depth: 1))
        #expect(DeskModel.clamp(DeskPlacement(x: 0.3, depth: 0.4)) == DeskPlacement(x: 0.3, depth: 0.4))
    }

    @Test("机座標 → 画面の点（x は幅、depth は奥から手前へ）")
    func point() {
        let p = DeskModel.point(DeskPlacement(x: 0.25, depth: 0.5), in: CGSize(width: 800, height: 400))
        #expect(p == CGPoint(x: 200, y: 200))
    }

    @Test("ドラッグの移動量 → 配置（画面サイズで割る）")
    func moved() {
        let moved = DeskModel.moved(
            DeskPlacement(x: 0.5, depth: 0.5), by: CGSize(width: 80, height: -40),
            in: CGSize(width: 800, height: 400))
        #expect(moved == DeskPlacement(x: 0.6, depth: 0.4))
    }

    @Test("保存した配置があればそれ、無ければ既定")
    func resolve() {
        let saved = ["lpd8": DeskPlacement(x: 0.1, depth: 0.2)]
        #expect(DeskModel.placement(.lpd8, saved: saved) == DeskPlacement(x: 0.1, depth: 0.2))
        #expect(DeskModel.placement(.mixer, saved: saved) == DeskModel.defaultPlacement(.mixer))
        #expect(DeskModel.placement(.mixer, saved: nil) == DeskModel.defaultPlacement(.mixer))
    }

    @Test("raw 値は固定（window.json に入る）")
    func rawValues() {
        #expect(DeskGear.mixer.rawValue == "mixer")
        #expect(DeskGear.keyboard.rawValue == "keyboard")
        #expect(DeskGear.lpd8.rawValue == "lpd8")
        #expect(DeskGear.keystage.rawValue == "keystage")
        #expect(DeskGear.nanokontrol.rawValue == "nanokontrol")
    }

    @Test("window.json を往復する（desk が無い旧ファイルも読める）")
    func prefsRoundTrip() throws {
        var prefs = WindowPreferences.default
        prefs.desk = ["lpd8": DeskPlacement(x: 0.4, depth: 0.6)]
        let data = try JSONEncoder().encode(prefs)
        let back = try JSONDecoder().decode(WindowPreferences.self, from: data)
        #expect(back.desk?["lpd8"] == DeskPlacement(x: 0.4, depth: 0.6))
        let old = try JSONDecoder().decode(
            WindowPreferences.self, from: Data(#"{"mode":"windowed"}"#.utf8))
        #expect(old.desk == nil)
    }
}

@Suite("机 — 画面の鍵盤")
struct DeskKeyboardTests {
    @Test("2 オクターブ = 白鍵 14、黒鍵 10。黒鍵は E-F / B-C の間に無い")
    func keys() {
        let keys = DeskKeyboard.keys(baseNote: 60, octaves: 2)
        #expect(keys.filter { !$0.isBlack }.count == 14)
        #expect(keys.filter { $0.isBlack }.count == 10)
        #expect(keys.first?.note == 60)
        #expect(keys.last?.note == 83)
        // 白鍵の位置は 0, 1, 2 … と並び、黒鍵は直前の白鍵の右半分に乗る
        let cSharp = keys.first { $0.note == 61 }
        #expect(cSharp?.isBlack == true)
        #expect(cSharp?.whiteIndex == 0)
        let e = keys.first { $0.note == 64 }
        #expect(e?.whiteIndex == 2)
    }
}
