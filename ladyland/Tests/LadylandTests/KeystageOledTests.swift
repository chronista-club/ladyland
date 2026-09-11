import KeystageKit
import Testing

@testable import Ladyland

/// Keystage ノブ OLED（Func 0x28）の純関数部。
/// 実機仕様は `docs/keystage/Keystage_MIDIimp.txt` L548-563（実機開通 2026-08-07）
@Suite("Keystage OLED")
struct KeystageOledTests {
    @Test("文字は ASCII に落として 12 字 — 全滅なら座標名へ倒す")
    func textSanitizes() {
        #expect(KeystageOled.text("Filter Cutoff", fallback: "P1-1") == "Filter Cutof")
        #expect(KeystageOled.text("Cutoff", fallback: "P1-1") == "Cutoff")
        // ⚠️ 空文字を送ると前の表示が残る（ROTO 実測 2026-08-06 と同じ罠）。
        // 日本語だけの名前は ASCII で全滅する — 座標名で埋める
        #expect(KeystageOled.text("カットオフ", fallback: "P2-3") == "P2-3")
        #expect(KeystageOled.text("", fallback: "-") == "-")
        // 混在は ASCII 部分が残る
        #expect(KeystageOled.text("Cutoff（低域）", fallback: "P1-1") == "Cutoff")
    }

    @Test("フレームの形 — ヘッダ・長さ LE・address/line・終端")
    func frameShape() {
        let frame = KeystageOled.frame(
            address: 3, line: 1, text: "Hi", channel: 9, model: .keys61)
        // ヘッダ（0x42 = KORG / 0x69 = Keystage / global ch 9）
        #expect(Array(frame.prefix(7)) == [0xF0, 0x42, 0x49, 0x00, 0x01, 0x69, Keystage.Model.keys61.rawValue])
        // 長さ = Func(1) + addr(1) + line(1) + "Hi"(2) = 5、little endian 3 byte
        #expect(Array(frame[7..<10]) == [5, 0, 0])
        #expect(frame[10] == Keystage.Func.displayMessage.rawValue)
        #expect(frame[11] == 3, "Display Address（1-8 = ノブ）")
        #expect(frame[12] == 1, "Line（0 = 上段 / 1 = 下段）")
        #expect(Array(frame[13..<15]) == Array("Hi".utf8))
        #expect(frame.last == 0xF7)
    }

    @Test("ページ 1 枚 = メイン 1 行 + ノブ 8 本 × 2 行、名前が空の席は座標名")
    func linesLayout() {
        let faces =
            [KeystageOled.KnobFace(name: "Cutoff", value: "64 %")]
            + Array(repeating: KeystageOled.KnobFace(name: "", value: ""), count: 7)
        let lines = KeystageOled.lines(page: 1, faces: faces)
        #expect(lines.count == 17)
        #expect(lines[0].address == 0 && lines[0].text == "P2", "メイン上段はページ名")
        #expect(lines[1].address == 1 && lines[1].line == 0 && lines[1].text == "Cutoff")
        #expect(lines[2].address == 1 && lines[2].line == 1 && lines[2].text == "64 %")
        // 未割当（空）の席は座標名で埋まる — P2 の 2 本目 = CC9 = "P2-2"
        #expect(lines[3].text == FaceKnobAssignment.ctrlLabel(9))
        #expect(lines[4].text == "-", "値の無い下段は '-'")
        // 影のキーは address:line で一意
        #expect(Set(lines.map(\.key)).count == lines.count)
    }
}
