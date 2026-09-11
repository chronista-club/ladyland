//! ROTO-CONTROL アドミンポートのフレーミング純粋層（docs/roto-control/admin-port.md）。
//!
//! 設定の読み書きは MIDI ではなく **USB CDC シリアル（115200）**を通る —
//! ROTO-SETUP の app.asar 解剖（2026-08-12）で確定した公式実装の写し。
//! ここは**バイト列の組み立てと解釈だけ**を持つ（シリアル I/O は呼び手 —
//! RigBench の roto-admin ベンチ / 将来の RotoAdminPort）。
//!
//! 作法（公式 device.mjs の写し）:
//! - リクエストは**常に 1 本だけ in flight**（詰めて送ると失う）
//! - 設定書き込みは START_CONFIG_UPDATE → 本体 → END_CONFIG_UPDATE の 3 連
//! - 応答 `A5 <rc>` のデータ長は**リクエスト側が知っている**（長さ欄が無い）。
//!   rc ≠ 00 のときデータは続かない
//! - 実機は自発コマンド（`5A …` — SEL 切替や LEARN 完了の通知）も同じ線で
//!   喋るので、パーサは両方を受ける

import Foundation

public enum RotoAdmin {
    // MARK: - 定数（protocol.mjs の写し）

    public static let commandMark: UInt8 = 0x5A
    public static let responseMark: UInt8 = 0xA5
    public static let okCode: UInt8 = 0x00
    /// 未設定の席を GET したときの非致命エラー
    public static let unconfiguredCode: UInt8 = 0xFD

    public static let nameLength = 13

    public enum General {
        public static let family: UInt8 = 0x01
        public static let getFwVersion: UInt8 = 0x01
        public static let startConfigUpdate: UInt8 = 0x04
        public static let endConfigUpdate: UInt8 = 0x05
    }

    public enum Midi {
        public static let family: UInt8 = 0x02
        public static let getCurrentSetup: UInt8 = 0x01
        public static let getSetup: UInt8 = 0x02
        public static let setSetup: UInt8 = 0x03
        public static let setSetupName: UInt8 = 0x04
        public static let getKnobConfig: UInt8 = 0x05
        public static let getSwitchConfig: UInt8 = 0x06
        public static let setKnobConfig: UInt8 = 0x07
        public static let setSwitchConfig: UInt8 = 0x08
        public static let clearControlConfig: UInt8 = 0x09
        /// 実機発の通知（LEARN 完了）
        public static let controlLearned: UInt8 = 0x0B
    }

    // MARK: - リクエスト組み立て

    /// `5A <family> <sub> <size:2BE> <data…>`
    public static func request(family: UInt8, sub: UInt8, data: [UInt8] = []) -> [UInt8] {
        precondition(data.count <= 0xFFFF, "アドミンポートの 1 通は 64KB まで")
        return [commandMark, family, sub, UInt8(data.count >> 8), UInt8(data.count & 0xFF)]
            + data
    }

    /// 応答: 10 バイト（major, minor, patch, commit 7 文字）
    public static func getFwVersion() -> [UInt8] {
        request(family: General.family, sub: General.getFwVersion)
    }

    public static func startConfigUpdate() -> [UInt8] {
        request(family: General.family, sub: General.startConfigUpdate)
    }

    public static func endConfigUpdate() -> [UInt8] {
        request(family: General.family, sub: General.endConfigUpdate)
    }

    /// 応答: 14 バイト（setupIndex + 名前 13）
    public static func getCurrentSetup() -> [UInt8] {
        request(family: Midi.family, sub: Midi.getCurrentSetup)
    }

    /// 応答: 14 バイト（getCurrentSetup と同形）
    public static func getSetup(_ index: Int) -> [UInt8] {
        request(family: Midi.family, sub: Midi.getSetup, data: [UInt8(index)])
    }

    /// **SEL のリモート操作** — 実機の表示ごと指定 setup へ切り替える
    public static func setSetup(_ index: Int) -> [UInt8] {
        request(family: Midi.family, sub: Midi.setSetup, data: [UInt8(index)])
    }

    /// 席 1 個の読み出し。応答は `knobConfigBytes`（237）バイトで、
    /// レイアウトは setKnobConfig のペイロードと同形（SI CI CM … SN:16×13）。
    /// 未設定の席は rc=FD（RESPONSE_UNCONFIGURED）でデータなし
    /// ボタン席 1 個の読み出し（0x06）。応答レイアウトは setSwitchConfig と
    /// 同じ骨格（`SI CI CM CC CP NA:2 MN:2 MX:2 CN:13 CS LN LF HM HS SN:16×13`）
    public static func getSwitchConfig(setup: Int, control: Int) -> [UInt8] {
        request(
            family: Midi.family, sub: Midi.getSwitchConfig,
            data: [UInt8(setup), UInt8(control)])
    }

    public static func getKnobConfig(setup: Int, control: Int) -> [UInt8] {
        request(
            family: Midi.family, sub: Midi.getKnobConfig,
            data: [UInt8(setup), UInt8(control)])
    }

    /// getKnobConfig 応答のデータ長（29 + 16 × 13。公式ハンドラの expectBytes）
    public static let knobConfigBytes = 29 + 16 * nameLength

    /// ⚠️ 書き込み系は START/END の括弧の中で送ること（呼び手の責務）
    public static func setSetupName(index: Int, name: String) -> [UInt8] {
        request(
            family: Midi.family, sub: Midi.setSetupName,
            data: [UInt8(index)] + paddedName(name))
    }

    /// 席 1 個を未設定に戻す（0x09）。ペイロードは `[setup, type, control]` の順
    /// （公式実装で確認 — type 0 = KNOB / 1 = SWITCH。**control が最後**なのに注意）。
    /// 全焼きの「全席 = set XOR clear」の clear 側 — 残骸を構造的に消す
    public static func clearControl(setup: Int, button: Bool, control: Int) -> [UInt8] {
        request(
            family: Midi.family, sub: Midi.clearControlConfig,
            data: [UInt8(setup), button ? 1 : 0, UInt8(control)])
    }

    /// 席 1 個の書き込み。レイアウトは admin-port.md:
    /// `SI CI CM CC CP NA:2 MN:2 MX:2 CN:13 CS HM HI1 HI2 HS SN:16×13`
    /// ⚠️ CC（チャンネル）は **1 始まりのまま書く** — 公式実装は JSON の
    /// controlChannel を無変換で載せており、ch1 で発信する実機の格納値は 1
    /// （実機読み戻しで確認 2026-08-12。プロトコルコメントの「00-0F」は嘘）
    public static func setKnobConfig(
        setup: Int, control: Int, knob: RotoMidiSetup.Knob
    ) -> [UInt8] {
        var data: [UInt8] = []
        data.append(UInt8(setup))
        data.append(UInt8(control))
        data.append(0)  // controlMode: CC 7bit（生成器の既定と同じ）
        data.append(UInt8(knob.channel))
        data.append(UInt8(knob.cc))
        data.append(contentsOf: [0, 0])  // nrpnAddress BE
        data.append(contentsOf: [0, 0])  // minValue BE（7bit は MSB=00）
        data.append(contentsOf: [0, 127])  // maxValue BE
        data.append(contentsOf: paddedName(knob.name))
        data.append(knob.colorScheme)
        data.append(0)  // hapticMode: KNOB_360
        data.append(contentsOf: [0xFF, 0xFF])  // インデントなし
        data.append(0)  // hapticSteps
        for _ in 0..<16 {
            data.append(contentsOf: paddedName(""))
        }
        return request(family: Midi.family, sub: Midi.setKnobConfig, data: data)
    }

    /// `RotoMidiSetup.Button` からの書き込み（burn 経路用の便宜）
    public static func setSwitchConfig(
        setup: Int, button: RotoMidiSetup.Button
    ) -> [UInt8] {
        setSwitchConfig(
            setup: setup, control: button.controlIndex, channel: button.channel,
            cc: button.cc, name: button.name, colorScheme: button.colorScheme,
            ledOn: button.ledOn, ledOff: button.ledOff, toggle: button.toggle)
    }

    /// ボタン 1 個の書き込み。レイアウトは knob と同じ骨格 + LED 2 色:
    /// `SI CI CM CC CP NA:2 MN:2 MX:2 CN:13 CS LN LF HM HS SN:16×13`
    /// - toggle: false = PUSH（押している間 ON 値）/ true = TOGGLE（押すたび交互）
    /// - offValue/onValue = MN/MX（実機はこの 2 値を送る。既定 0/127）
    public static func setSwitchConfig(
        setup: Int, control: Int, channel: Int, cc: Int, name: String,
        colorScheme: UInt8, ledOn: UInt8, ledOff: UInt8, toggle: Bool,
        offValue: Int = 0, onValue: Int = 127
    ) -> [UInt8] {
        var data: [UInt8] = []
        data.append(UInt8(setup))
        data.append(UInt8(control))
        data.append(0)  // controlMode: CC 7bit（4 = ProgramChange / 5 = Note もある）
        data.append(UInt8(channel))  // 1 始まりのまま（knob と同じ掟）
        data.append(UInt8(cc))
        data.append(contentsOf: [0, 0])  // nrpnAddress BE
        data.append(contentsOf: [UInt8(offValue >> 8), UInt8(offValue & 0xFF)])
        data.append(contentsOf: [UInt8(onValue >> 8), UInt8(onValue & 0xFF)])
        data.append(contentsOf: paddedName(name))
        data.append(colorScheme)
        data.append(ledOn)
        data.append(ledOff)
        data.append(toggle ? 1 : 0)  // hapticMode: PUSH(0) / TOGGLE(1)
        data.append(0)  // hapticSteps
        for _ in 0..<16 {
            data.append(contentsOf: paddedName(""))
        }
        return request(family: Midi.family, sub: Midi.setSwitchConfig, data: data)
    }

    /// 13 バイトの NULL 終端 ASCII（パディング 00）。
    /// 13 文字ちょうどでも実機側は受ける（公式 util の写し — 終端は
    /// 「入るなら入れる」で、超過は切り詰め）
    public static func paddedName(_ name: String) -> [UInt8] {
        var bytes = Array(name.utf8.prefix(nameLength))
        while bytes.count < nameLength {
            bytes.append(0)
        }
        return bytes
    }

    // MARK: - 応答の解釈

    public struct FwVersion: Equatable {
        public let major: Int
        public let minor: Int
        public let patch: Int
        public let commit: String

        public init?(_ data: [UInt8]) {
            guard data.count >= 10 else { return nil }
            major = Int(data[0])
            minor = Int(data[1])
            patch = Int(data[2])
            commit = String(decoding: data[3..<10], as: UTF8.self)
        }

        public var description: String { "\(major).\(minor).\(patch) (\(commit))" }
    }

    public struct SetupInfo: Equatable {
        public let index: Int
        public let name: String

        public init?(_ data: [UInt8]) {
            guard data.count >= 1 + RotoAdmin.nameLength else { return nil }
            index = Int(data[0])
            let raw = data[1...RotoAdmin.nameLength]
            let terminated = raw.prefix { $0 != 0 }
            name = String(decoding: terminated, as: UTF8.self)
        }
    }

    // MARK: - ストリームパーサ

    /// 受信ストリームの出来事。応答（自分のリクエストへの返事）と、
    /// 実機の自発コマンド（SEL 切替・LEARN 完了の通知）が同じ線に混ざる
    public enum Event: Equatable {
        case response(code: UInt8, data: [UInt8])
        case notification(family: UInt8, sub: UInt8, data: [UInt8])
    }

    /// 公式 device.mjs の状態機械の写し。分割着信・複数イベントの同時着信に耐える。
    /// ⚠️ 応答データ長はリクエスト側しか知らないので、**リクエストを送るたびに
    /// `expectResponse(bytes:)` を呼ぶ**のが契約（rc ≠ 00 ならデータは来ない）
    public struct StreamParser {
        private var buffer: [UInt8] = []
        private var expectedResponseBytes = 0

        public init() {}

        /// 次の応答のデータ長を予約する（リクエスト送信直後に呼ぶ）
        public mutating func expectResponse(bytes: Int) {
            expectedResponseBytes = bytes
        }

        public mutating func feed(_ bytes: [UInt8]) -> [Event] {
            buffer.append(contentsOf: bytes)
            var events: [Event] = []
            while let event = next() {
                events.append(event)
            }
            return events
        }

        private mutating func next() -> Event? {
            // 先頭がマーク以外なら読み飛ばす（公式も ignore する）
            while let head = buffer.first,
                head != RotoAdmin.commandMark, head != RotoAdmin.responseMark {
                buffer.removeFirst()
            }
            guard let head = buffer.first else { return nil }

            if head == RotoAdmin.responseMark {
                guard buffer.count >= 2 else { return nil }
                let code = buffer[1]
                let dataLength = code == RotoAdmin.okCode ? expectedResponseBytes : 0
                guard buffer.count >= 2 + dataLength else { return nil }
                let data = Array(buffer[2..<2 + dataLength])
                buffer.removeFirst(2 + dataLength)
                expectedResponseBytes = 0
                return .response(code: code, data: data)
            }

            // 実機発コマンド: 5A <family> <sub> <size:2BE> <data…>
            guard buffer.count >= 5 else { return nil }
            let length = (Int(buffer[3]) << 8) | Int(buffer[4])
            guard buffer.count >= 5 + length else { return nil }
            let event = Event.notification(
                family: buffer[1], sub: buffer[2], data: Array(buffer[5..<5 + length]))
            buffer.removeFirst(5 + length)
            return event
        }
    }
}
