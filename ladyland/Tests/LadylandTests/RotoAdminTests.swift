//! アドミンポートのフレーミング（RotoAdmin）。
//!
//! 正解は ROTO-SETUP の公式実装（app.asar 解剖 → docs/roto-control/admin-port.md）。
//! バイト列のスナップショットで固定する — ここがズレると実機は黙って無視するか、
//! 別の席を書き換える。

import Foundation
import RotoKit
import Testing

@Suite("ROTO アドミンポートのフレーミング")
struct RotoAdminFramingTests {
    @Test func 引数なしリクエスト() {
        #expect(RotoAdmin.getFwVersion() == [0x5A, 0x01, 0x01, 0x00, 0x00])
        #expect(RotoAdmin.startConfigUpdate() == [0x5A, 0x01, 0x04, 0x00, 0x00])
        #expect(RotoAdmin.endConfigUpdate() == [0x5A, 0x01, 0x05, 0x00, 0x00])
        #expect(RotoAdmin.getCurrentSetup() == [0x5A, 0x02, 0x01, 0x00, 0x00])
    }

    @Test func SEL遠隔切替のリクエスト() {
        #expect(RotoAdmin.setSetup(3) == [0x5A, 0x02, 0x03, 0x00, 0x01, 0x03])
    }

    @Test func 名前は13バイトNULL詰め() {
        let padded = RotoAdmin.paddedName("P1-1 CC0")
        #expect(padded.count == 13)
        #expect(String(decoding: padded.prefix(8), as: UTF8.self) == "P1-1 CC0")
        #expect(padded.suffix(5).allSatisfy { $0 == 0 })
        // 超過は切り詰め（実機のバッファを溢れさせない）
        #expect(RotoAdmin.paddedName("1234567890ABCDEF").count == 13)
    }

    @Test func 席書き込みのレイアウト() {
        let knob = RotoMidiSetup.Knob(
            controlIndex: 9, channel: 1, cc: 42, name: "P6-3 CC42", colorScheme: 33)
        let message = RotoAdmin.setKnobConfig(setup: 1, control: 9, knob: knob)
        // ヘッダ: 5A 02 07 + データ長 237（= 0x00ED）
        #expect(Array(message.prefix(5)) == [0x5A, 0x02, 0x07, 0x00, 0xED])
        // SI CI CM CC CP — チャンネルは 1 始まりのまま（公式実装の写し。
        // 実機の格納値も 1 = ch1 と読み戻しで確認済み）
        #expect(Array(message[5..<10]) == [1, 9, 0, 1, 42])
        // NA:2 MN:2 MX:2
        #expect(Array(message[10..<16]) == [0, 0, 0, 0, 0, 127])
        // CN:13
        #expect(String(decoding: message[16..<25], as: UTF8.self) == "P6-3 CC42")
        // CS HM HI1 HI2 HS
        #expect(Array(message[29..<34]) == [33, 0, 0xFF, 0xFF, 0])
        // SN: 16 × 13 の空文字列で締め
        #expect(message.count == 5 + 237)
        #expect(message[34...].allSatisfy { $0 == 0 })
    }
}

@Suite("ROTO アドミンポートの応答解釈")
struct RotoAdminResponseTests {
    @Test func ボタン書き込みのレイアウト() {
        let message = RotoAdmin.setSwitchConfig(
            setup: 0, control: 7, channel: 3, cc: 0, name: "> L02 INST",
            colorScheme: 69, ledOn: 13, ledOff: 70, toggle: false)
        // ヘッダ: 5A 02 08 + データ長 237（knob と同じ骨格 + LED 2 色）
        #expect(Array(message.prefix(5)) == [0x5A, 0x02, 0x08, 0x00, 0xED])
        // SI CI CM CC CP — チャンネルは 1 始まりのまま
        #expect(Array(message[5..<10]) == [0, 7, 0, 3, 0])
        // NA:2 MN:2 MX:2（OFF=0 / ON=127）
        #expect(Array(message[10..<16]) == [0, 0, 0, 0, 0, 127])
        // CN:13 の先頭
        #expect(String(decoding: message[16..<26], as: UTF8.self) == "> L02 INST")
        // CS LN LF HM HS
        #expect(Array(message[29..<34]) == [69, 13, 70, 0, 0])
        #expect(message.count == 5 + 237)
    }

    @Test func FW版数() {
        let version = RotoAdmin.FwVersion([3, 2, 0] + Array("dcf8018".utf8))
        #expect(version?.major == 3)
        #expect(version?.patch == 0)
        #expect(version?.commit == "dcf8018")
    }

    @Test func setup情報() {
        let info = RotoAdmin.SetupInfo([1] + RotoAdmin.paddedName("LL P1-P4"))
        #expect(info?.index == 1)
        #expect(info?.name == "LL P1-P4")
    }

    @Test func 応答の分割着信() {
        var parser = RotoAdmin.StreamParser()
        parser.expectResponse(bytes: 10)
        #expect(parser.feed([0xA5]).isEmpty)
        #expect(parser.feed([0x00, 3, 2, 0]).isEmpty)
        let events = parser.feed(Array("dcf8018".utf8))
        #expect(events == [.response(code: 0, data: [3, 2, 0] + Array("dcf8018".utf8))])
    }

    @Test func エラー応答にデータは続かない() {
        var parser = RotoAdmin.StreamParser()
        parser.expectResponse(bytes: 14)
        // FD = 未設定。直後に次の応答が来ても混ざらない
        let events = parser.feed([0xA5, 0xFD, 0xA5])
        #expect(events == [.response(code: 0xFD, data: [])])
    }

    @Test func 実機発コマンドが混ざっても拾える() {
        var parser = RotoAdmin.StreamParser()
        parser.expectResponse(bytes: 0)
        // SEL 切替通知（5A 02 03 size=1 data=[2]）→ 自リクエストの応答、の順
        let events = parser.feed([0x5A, 0x02, 0x03, 0x00, 0x01, 0x02, 0xA5, 0x00])
        #expect(events == [
            .notification(family: 0x02, sub: 0x03, data: [2]),
            .response(code: 0, data: []),
        ])
    }

    @Test func マーク以外のゴミは読み飛ばす() {
        var parser = RotoAdmin.StreamParser()
        parser.expectResponse(bytes: 0)
        let events = parser.feed([0x00, 0x13, 0xA5, 0x00])
        #expect(events == [.response(code: 0, data: [])])
    }
}
