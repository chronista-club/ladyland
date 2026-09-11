//! LPD8 mk2 プログラム（1-4）の codec — 純関数（テスト対象）。
//!
//! レイアウトは 2026-07-31 の実機ダンプ（RigBench lpd8-program-dump、4 プログラム
//! 全一致）で確定。VP doc 22 §3 の未確定部分はこれで pin 済み:
//!
//!   F0 47 7F 4C <cmd> 01 29 <payload 165B> F7   （計 173 byte）
//!     cmd: 0x03 = GET 応答 / 0x01 = SET
//!     payload[0]     プログラム番号 1-4
//!     payload[1]     グローバルチャンネル - 1（0-15）
//!     payload[2]     プレッシャー（0=off / 1=channel / 2=polyphonic）
//!     payload[3]     NOT full_level（0 = full level ON）
//!     payload[4]     toggle（0/1）
//!     payload[5..]   パッド 8 × 16B: note, cc, pcn, channel-1（0x10 = グローバルに従う）,
//!                    色A 6B（RGB 各 pack7）, 色B 6B
//!     payload[133..] ノブ 8 × 4B: cc, channel-1, min, max
//!
//! 色A/色B の off/on 対応は stephensrmmartin/lpd8mk2 の config 順（off, on）に
//! 従う。⚠️ 未実機確認: パッド押下で色B に変わるかは目視 1 分で確定できる
//! （違ったらここのフィールド名を入れ替えるだけ — ワイヤバイトは不変）。

public struct Lpd8Pad: Equatable, Sendable, Codable {
    public var note: UInt8
    public var cc: UInt8
    public var programChange: UInt8
    /// ワイヤ生値: 0-15 = ch1-16、0x10 = グローバルチャンネルに従う
    public var channel: UInt8
    public var offColor: Rgb8
    public var onColor: Rgb8

    public init(note: UInt8, cc: UInt8, programChange: UInt8, channel: UInt8,
                offColor: Rgb8, onColor: Rgb8) {
        self.note = note
        self.cc = cc
        self.programChange = programChange
        self.channel = channel
        self.offColor = offColor
        self.onColor = onColor
    }
}

public struct Lpd8Knob: Equatable, Sendable, Codable {
    public var cc: UInt8
    /// ワイヤ生値: 0-15 = ch1-16、0x10 = グローバルチャンネルに従う
    public var channel: UInt8
    public var min: UInt8
    public var max: UInt8

    public init(cc: UInt8, channel: UInt8, min: UInt8, max: UInt8) {
        self.cc = cc
        self.channel = channel
        self.min = min
        self.max = max
    }
}

public struct Lpd8Program: Equatable, Sendable, Codable {
    public var program: Int
    /// ワイヤ生値: 0-15 = ch1-16
    public var globalChannel: UInt8
    /// 0 = off / 1 = channel / 2 = polyphonic
    public var pressureMessage: UInt8
    public var fullLevel: Bool
    public var toggle: Bool
    public var pads: [Lpd8Pad]
    public var knobs: [Lpd8Knob]

    static let payloadLength = 165
    static let frameLength = 173

    /// GET 応答（cmd 0x03）または SET フレーム（cmd 0x01）を解読する。
    /// 未知のレイアウトは nil — エディタはエラー表示に落ち、ゴミを書かない
    public static func decode(frame: [UInt8]) -> Lpd8Program? {
        guard frame.count == frameLength,
              Lpd8SysEx.isLpd8Frame(frame),
              frame[4] == 0x03 || frame[4] == 0x01,
              frame[5] == 0x01, frame[6] == 0x29
        else { return nil }

        let payload = Array(frame[7..<(7 + Self.payloadLength)])
        guard (1...4).contains(Int(payload[0])) else { return nil }

        var pads: [Lpd8Pad] = []
        for i in 0..<8 {
            let base = 5 + i * 16
            pads.append(Lpd8Pad(
                note: payload[base],
                cc: payload[base + 1],
                programChange: payload[base + 2],
                channel: payload[base + 3],
                offColor: rgb(payload, at: base + 4),
                onColor: rgb(payload, at: base + 10)
            ))
        }

        var knobs: [Lpd8Knob] = []
        for i in 0..<8 {
            let base = 133 + i * 4
            knobs.append(Lpd8Knob(
                cc: payload[base],
                channel: payload[base + 1],
                min: payload[base + 2],
                max: payload[base + 3]
            ))
        }

        return Lpd8Program(
            program: Int(payload[0]),
            globalChannel: payload[1],
            pressureMessage: payload[2],
            fullLevel: payload[3] == 0,
            toggle: payload[4] != 0,
            pads: pads,
            knobs: knobs
        )
    }

    /// SET フレーム（cmd 0x01）に符号化する。decode との round-trip は
    /// byte-exact（Lpd8ProgramTests のゴールデンで証明 — 誤 SET の安全ゲート）
    public func encodeSetFrame() -> [UInt8] {
        var frame = Lpd8SysEx.header
        frame += [0x01, 0x01, 0x29]
        frame.append(UInt8(program))
        frame.append(globalChannel)
        frame.append(pressureMessage)
        frame.append(fullLevel ? 0 : 1)
        frame.append(toggle ? 1 : 0)
        for pad in pads {
            frame += [pad.note, pad.cc, pad.programChange, pad.channel]
            frame += Lpd8SysEx.pack7(pad.offColor.r) + Lpd8SysEx.pack7(pad.offColor.g)
                + Lpd8SysEx.pack7(pad.offColor.b)
            frame += Lpd8SysEx.pack7(pad.onColor.r) + Lpd8SysEx.pack7(pad.onColor.g)
                + Lpd8SysEx.pack7(pad.onColor.b)
        }
        for knob in knobs {
            frame += [knob.cc, knob.channel, knob.min, knob.max]
        }
        frame.append(0xF7)
        return frame
    }

    private static func rgb(_ payload: [UInt8], at base: Int) -> Rgb8 {
        Rgb8(
            Lpd8SysEx.unpack7(hi: payload[base], lo: payload[base + 1]),
            Lpd8SysEx.unpack7(hi: payload[base + 2], lo: payload[base + 3]),
            Lpd8SysEx.unpack7(hi: payload[base + 4], lo: payload[base + 5])
        )
    }
}
