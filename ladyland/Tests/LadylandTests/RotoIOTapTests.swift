import Testing

@testable import Ladyland

/// I/O デバッグ帳簿の行形式（`roto-io.jsonl`）。壊れた JSON を書くと
/// エージェント側の rg / jq が黙って空振りする — 形式をテストで固定する
@Suite("ROTO I/O タップ")
struct RotoIOTapTests {
    @Test("1 行 = 有効な JSON — hex は大文字 2 桁区切り")
    func lineShape() {
        let line = RotoIOTap.line(t: "06:31:02.123", dir: "in", bytes: [0xBF, 61, 2], note: nil)
        #expect(line == "{\"t\":\"06:31:02.123\",\"dir\":\"in\",\"hex\":\"BF 3D 02\"}\n")
    }

    @Test("note の引用符とバックスラッシュはエスケープされる")
    func escapesNote() {
        let line = RotoIOTap.line(
            t: "0", dir: "out", bytes: [0xF7], note: "say \"hi\" \\ done")
        #expect(line.contains("\\\"hi\\\""))
        #expect(line.contains("\\\\ done"))
        #expect(line.hasSuffix("}\n"))
    }
}
