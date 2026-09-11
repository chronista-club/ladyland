//! UMP 解析のテスト。
//!
//! ここがバグると「無言で音が出ない」ため、ladyland で最も価値の高いユニット。
//! Realtime フィルタ（Keystage の MIDI Clock 対策。design/06 §5-4）が
//! MessageType 判定で実現されていることも固定する。

import Testing

@testable import Ladyland

@Suite("UMP 解析")
struct UMPTests {
    @Test("ノートオンを取り出せる")
    func noteOn() {
        // MT=2, group=0, status=0x90 (note on ch0), note=60, velocity=100
        let word: UInt32 = 0x20_90_3C_64
        let message = UMP.parseChannelVoice(word)
        #expect(message?.status == 0x90)
        #expect(message?.data1 == 60)
        #expect(message?.data2 == 100)
    }

    @Test("ノートオフ・CC・ピッチベンドの status が保たれる")
    func channelVoiceKinds() {
        #expect(UMP.parseChannelVoice(0x20_80_3C_00)?.status == 0x80)  // note off
        #expect(UMP.parseChannelVoice(0x20_B0_40_00)?.status == 0xB0)  // CC
        #expect(UMP.parseChannelVoice(0x20_E0_00_40)?.status == 0xE0)  // pitch bend
    }

    @Test("チャンネル番号が status に残る")
    func channelNumber() {
        // note on ch9 (0x99)
        #expect(UMP.parseChannelVoice(0x20_99_24_7F)?.status == 0x99)
    }

    @Test("MIDI Clock (F8) は落ちる — Keystage は Clock を止められない",
          arguments: [
            UInt32(0x10_F8_00_00),  // MT=1 (system): MIDI Clock
            UInt32(0x10_FA_00_00),  // MT=1: Start
            UInt32(0x10_F1_00_00),  // MT=1: MTC quarter frame
          ])
    func systemMessagesAreFiltered(word: UInt32) {
        #expect(UMP.parseChannelVoice(word) == nil)
    }

    @Test("他の MessageType も落ちる（utility / SysEx / MIDI 2.0）",
          arguments: [
            UInt32(0x00_00_00_00),  // MT=0: utility
            UInt32(0x30_00_00_00),  // MT=3: data 64bit (SysEx)
            UInt32(0x40_90_3C_64),  // MT=4: MIDI 2.0 channel voice（別形式なので通さない）
          ])
    func otherMessageTypesAreFiltered(word: UInt32) {
        #expect(UMP.parseChannelVoice(word) == nil)
    }

    @Test("data バイトは 7bit にマスクされる")
    func dataBytesAreMasked() {
        // data1/data2 の最上位ビットが立っていても 7bit に落とす
        let message = UMP.parseChannelVoice(0x20_90_FF_FF)
        #expect(message?.data1 == 0x7F)
        #expect(message?.data2 == 0x7F)
    }
}
