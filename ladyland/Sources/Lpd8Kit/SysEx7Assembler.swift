//! UMP MessageType 3（Data 64bit / SysEx7）の再組立 — 純粋状態機械（テスト対象）。
//!
//! CoreMIDI の ._1_0 プロトコル入力ポートは SysEx を 64bit UMP に分割して届ける。
//! 1 パケット = 2 word。F0/F7 は UMP に含まれない（status が開始/終了を運ぶ）ため、
//! 完成時にこちらで付け直し、送信側のフレーム表現（F0…F7）と対称にする。
//!
//! word0: [31:28] mt=3 / [27:24] group / [23:20] status / [19:16] byteCount /
//!        [15:8] byte1 / [7:0] byte2
//! word1: byte3-6（[31:24] [23:16] [15:8] [7:0]）
//! status: 0 = 単独完結 / 1 = 開始 / 2 = 継続 / 3 = 終了

public struct SysEx7Assembler: Sendable {
    private var buffer: [UInt8] = []
    private var active = false
    /// mt=3 パケットの word0（word1 待ちの間だけ保持）
    private var pendingWord0: UInt32?

    public init() {}

    /// UMP word を 1 つずつ食わせる。SysEx が 1 本完成したら F0…F7 で返す
    public mutating func feed(_ word: UInt32) -> [UInt8]? {
        if let word0 = pendingWord0 {
            pendingWord0 = nil
            return consume(word0: word0, word1: word)
        }
        guard (word >> 28) & 0xF == 3 else { return nil }
        pendingWord0 = word
        return nil
    }

    private mutating func consume(word0: UInt32, word1: UInt32) -> [UInt8]? {
        let status = UInt8((word0 >> 20) & 0xF)
        let count = Int((word0 >> 16) & 0xF)
        let raw: [UInt8] = [
            UInt8((word0 >> 8) & 0x7F), UInt8(word0 & 0x7F),
            UInt8((word1 >> 24) & 0x7F), UInt8((word1 >> 16) & 0x7F),
            UInt8((word1 >> 8) & 0x7F), UInt8(word1 & 0x7F),
        ]
        let data = Array(raw.prefix(min(count, 6)))

        switch status {
        case 0: // 単独完結
            buffer = []
            active = false
            return [0xF0] + data + [0xF7]
        case 1: // 開始
            buffer = data
            active = true
            return nil
        case 2: // 継続（開始なしは捨てる）
            if active { buffer += data }
            return nil
        case 3: // 終了
            guard active else { return nil }
            let frame = [0xF0] + buffer + data + [0xF7]
            buffer = []
            active = false
            return frame
        default:
            return nil
        }
    }
}
