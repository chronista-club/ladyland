//! LPD8 mk2 SysEx フレームの構築 — 純関数（テスト対象）。
//!
//! ヘッダ: F0 47 7F 4C（Akai / broadcast / mk2。初代 LPD8 は model 0x75 で別物）。
//! command の後に 14bit 長（hi 7bit / lo 7bit）、ペイロード、F7。
//!
//! 出典: VP doc 22（Wireshark 逆解析 3 repo の独立一致、LED は実機検証済）
//!   0x06 = LED 一括更新（56 byte、部分更新なし）
//!   0x03 = プログラム GET（len 1、payload = prog# 1-4）
//!   0x01 = プログラム SET（len 0x0129 = 297... 実測で確定。Lpd8Program 参照）

/// フル RGB 1 色（0-255。mk2 は艦隊唯一の量子化なし色表示 pad）
public struct Rgb8: Equatable, Sendable, Codable {
    public var r: UInt8
    public var g: UInt8
    public var b: UInt8

    public init(_ r: UInt8, _ g: UInt8, _ b: UInt8) {
        self.r = r
        self.g = g
        self.b = b
    }

    public static let off = Rgb8(0, 0, 0)
}

public enum Lpd8SysEx {
    /// F0 47 7F 4C
    public static let header: [UInt8] = [0xF0, 0x47, 0x7F, 0x4C]

    /// 8bit 値を MIDI 7bit ×2 に分割（MSB→LSB。白 255 = 01 7F）
    public static func pack7(_ v: UInt8) -> [UInt8] {
        [v >> 7, v & 0x7F]
    }

    /// pack7 の逆変換
    public static func unpack7(hi: UInt8, lo: UInt8) -> UInt8 {
        (hi & 0x01) << 7 | (lo & 0x7F)
    }

    /// **論理席（上段が先）と実機の LED セル（下段が先）の並び替え**
    /// （mako 実機報告 2026-08-06「ついてるかついてないかの Pad が上下逆ですね」）。
    ///
    /// ホスト側は**上段を先に**数える:
    /// - `Lpd8DefaultPadNotes.program1 = [44,45,46,47, 40,41,42,43]`
    ///   （実機ダンプ。「上段 4 → 下段 4 の並び。44-47 が上段」）
    /// - `LadySampler.padIndex(forNote:)` も `offset >= 4 ? offset - 4 : offset + 4` で
    ///   **上段を 0-3 に寄せている**（実測 2026-08-06「Note の方が上下逆だね」）
    ///
    /// 一方 **LED フレームは下段が先**。素通しで並べると上下が入れ替わって点く。
    ///
    /// ⚠️ **この変換は自分自身が逆変換**（前半と後半を入れ替えるだけ = involution）。
    /// だから席 → セルにも セル → 席 にも同じ関数が使える
    public static func swapPadRows<T>(_ items: [T]) -> [T] {
        guard items.count == 8 else { return items }
        return Array(items[4..<8]) + Array(items[0..<4])
    }

    /// LED 一括更新フレーム（計 56 byte）: 06 00 30 + 8 pad × (R,G,B 各 pack7)。
    ///
    /// ⚠️ **渡すのは実機セル順**（下段が先）。論理席順で持っているなら
    /// `swapPadRows` を通すこと
    public static func ledFrame(_ colors: [Rgb8]) -> [UInt8] {
        precondition(colors.count == 8, "LED フレームは常に 8 パッド一括（部分更新なし）")
        var bytes = header
        bytes += [0x06, 0x00, 0x30]
        for c in colors {
            bytes += pack7(c.r) + pack7(c.g) + pack7(c.b)
        }
        bytes.append(0xF7)
        return bytes
    }

    /// プログラム GET 要求: 03 00 01 <prog 1-4>
    public static func programGetRequest(program: Int) -> [UInt8] {
        precondition((1...4).contains(program))
        return header + [0x03, 0x00, 0x01, UInt8(program), 0xF7]
    }

    /// 任意 command のフレーム（len は payload 数から 14bit で自動算出）
    public static func frame(command: UInt8, payload: [UInt8]) -> [UInt8] {
        let len = payload.count
        precondition(len < 0x4000)
        return header + [command, UInt8((len >> 7) & 0x7F), UInt8(len & 0x7F)] + payload + [0xF7]
    }

    /// LPD8 mk2 のフレームか（ヘッダ一致 + 終端）
    public static func isLpd8Frame(_ bytes: [UInt8]) -> Bool {
        bytes.count >= 6 && bytes[0] == 0xF0 && bytes[1] == 0x47 && bytes[3] == 0x4C
            && bytes.last == 0xF7
    }
}
