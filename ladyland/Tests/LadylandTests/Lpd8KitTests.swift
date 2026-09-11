//! Lpd8Kit のテスト — フレーム構築・UMP 再組立・プログラム codec。
//!
//! ゴールデンは 2026-07-31 の実機ダンプ（swift run RigBench lpd8-program-dump、
//! LPD8 mk2 実機のプログラム 1）。byte-exact round-trip が SET の安全ゲート。

import Testing

import Lpd8Kit

@Suite("Lpd8SysEx フレーム構築")
struct Lpd8SysExTests {
    @Test("LED フレームは 56 byte・ヘッダ 06 00 30・フル RGB pack7")
    func ledFrame() {
        let frame = Lpd8SysEx.ledFrame(Array(repeating: Rgb8(255, 255, 255), count: 8))
        #expect(frame.count == 56)
        #expect(Array(frame[0..<7]) == [0xF0, 0x47, 0x7F, 0x4C, 0x06, 0x00, 0x30])
        // 白 255 = 01 7F（doc 22 §2 の実機検証値）
        #expect(Array(frame[7..<13]) == [0x01, 0x7F, 0x01, 0x7F, 0x01, 0x7F])
        #expect(frame.last == 0xF7)
    }

    @Test("pack7 / unpack7 が全 256 値で round-trip する")
    func pack7RoundTrip() {
        for v in 0...255 {
            let packed = Lpd8SysEx.pack7(UInt8(v))
            #expect(packed[0] <= 1 && packed[1] <= 0x7F, "7bit 安全")
            #expect(Lpd8SysEx.unpack7(hi: packed[0], lo: packed[1]) == UInt8(v))
        }
    }

    @Test("プログラム GET 要求のバイト列")
    func getRequest() {
        #expect(Lpd8SysEx.programGetRequest(program: 3)
            == [0xF0, 0x47, 0x7F, 0x4C, 0x03, 0x00, 0x01, 0x03, 0xF7])
    }
}

@Suite("SysEx7Assembler")
struct SysEx7AssemblerTests {
    private func word0(status: UInt8, count: Int, _ b1: UInt8 = 0, _ b2: UInt8 = 0) -> UInt32 {
        (3 << 28) | (UInt32(status) << 20) | (UInt32(count) << 16)
            | (UInt32(b1) << 8) | UInt32(b2)
    }

    private func word1(_ b3: UInt8 = 0, _ b4: UInt8 = 0, _ b5: UInt8 = 0, _ b6: UInt8 = 0)
        -> UInt32 {
        (UInt32(b3) << 24) | (UInt32(b4) << 16) | (UInt32(b5) << 8) | UInt32(b6)
    }

    @Test("単独完結パケット → F0/F7 付きで返る")
    func singlePacket() {
        var assembler = SysEx7Assembler()
        #expect(assembler.feed(word0(status: 0, count: 3, 0x47, 0x7F)) == nil)
        let frame = assembler.feed(word1(0x4C))
        #expect(frame == [0xF0, 0x47, 0x7F, 0x4C, 0xF7])
    }

    @Test("開始 → 継続 → 終了の分割再組立")
    func multiPacket() {
        var assembler = SysEx7Assembler()
        _ = assembler.feed(word0(status: 1, count: 6, 0x47, 0x7F))
        #expect(assembler.feed(word1(0x4C, 0x03, 0x01, 0x29)) == nil)
        _ = assembler.feed(word0(status: 2, count: 6, 0x01, 0x02))
        #expect(assembler.feed(word1(0x03, 0x04, 0x05, 0x06)) == nil)
        _ = assembler.feed(word0(status: 3, count: 2, 0x07, 0x08))
        let frame = assembler.feed(word1())
        #expect(frame == [
            0xF0, 0x47, 0x7F, 0x4C, 0x03, 0x01, 0x29,
            0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0xF7,
        ])
    }

    @Test("MessageType 3 以外の word は素通し（ノート入力と共存できる）")
    func ignoresOtherTypes() {
        var assembler = SysEx7Assembler()
        let noteOn: UInt32 = 0x2090_3C64  // mt=2 の Note On
        #expect(assembler.feed(noteOn) == nil)
        // その後の SysEx は普通に組み上がる
        _ = assembler.feed(word0(status: 0, count: 2, 0x47, 0x7F))
        #expect(assembler.feed(word1()) == [0xF0, 0x47, 0x7F, 0xF7])
    }

    @Test("開始なしの継続・終了は捨てる（途中参加しても壊れない）")
    func orphanPackets() {
        var assembler = SysEx7Assembler()
        _ = assembler.feed(word0(status: 2, count: 2, 0x01, 0x02))
        #expect(assembler.feed(word1()) == nil)
        _ = assembler.feed(word0(status: 3, count: 2, 0x03, 0x04))
        #expect(assembler.feed(word1()) == nil)
    }
}

@Suite("Lpd8Program codec")
struct Lpd8ProgramTests {
    /// 実機ゴールデン: LPD8 mk2 プログラム 1 の GET 応答（2026-07-31 採取、173 byte）
    static let golden: [UInt8] = [
        0xF0, 0x47, 0x7F, 0x4C, 0x03, 0x01, 0x29, 0x01, 0x07, 0x02, 0x00, 0x00, 0x2C, 0x25, 0x00, 0x10,
        0x01, 0x7F, 0x01, 0x7F, 0x00, 0x00, 0x00, 0x00, 0x01, 0x7F, 0x01, 0x7F, 0x2D, 0x26, 0x01, 0x10,
        0x00, 0x33, 0x00, 0x33, 0x00, 0x33, 0x00, 0x0B, 0x00, 0x64, 0x01, 0x34, 0x2E, 0x27, 0x02, 0x10,
        0x00, 0x33, 0x00, 0x33, 0x00, 0x33, 0x01, 0x7F, 0x00, 0x69, 0x01, 0x34, 0x2F, 0x28, 0x03, 0x10,
        0x00, 0x33, 0x00, 0x33, 0x00, 0x33, 0x01, 0x00, 0x00, 0x00, 0x01, 0x00, 0x28, 0x21, 0x04, 0x10,
        0x01, 0x45, 0x01, 0x34, 0x01, 0x63, 0x00, 0x00, 0x01, 0x7F, 0x01, 0x7F, 0x29, 0x22, 0x05, 0x10,
        0x01, 0x45, 0x01, 0x34, 0x01, 0x63, 0x00, 0x0B, 0x00, 0x64, 0x01, 0x34, 0x2A, 0x23, 0x06, 0x10,
        0x01, 0x45, 0x01, 0x34, 0x01, 0x63, 0x01, 0x7F, 0x00, 0x69, 0x01, 0x34, 0x2B, 0x24, 0x07, 0x10,
        0x01, 0x45, 0x01, 0x34, 0x01, 0x63, 0x01, 0x00, 0x00, 0x00, 0x01, 0x00, 0x4F, 0x10, 0x00, 0x7F,
        0x50, 0x10, 0x00, 0x7F, 0x51, 0x10, 0x00, 0x7F, 0x52, 0x10, 0x00, 0x7F, 0x53, 0x10, 0x00, 0x7F,
        0x54, 0x10, 0x00, 0x7F, 0x55, 0x10, 0x00, 0x7F, 0x56, 0x10, 0x00, 0x7F, 0xF7,
    ]

    @Test("実機ゴールデンが正しく decode される")
    func decodeGolden() throws {
        let program = try #require(Lpd8Program.decode(frame: Self.golden))
        #expect(program.program == 1)
        #expect(program.globalChannel == 7)  // ワイヤ生値（= ch8）
        #expect(program.pressureMessage == 2)  // polyphonic
        #expect(program.fullLevel == true)  // ワイヤ 0 = full level ON
        #expect(program.toggle == false)
        #expect(program.pads.count == 8)
        #expect(program.knobs.count == 8)

        let pad1 = program.pads[0]
        #expect(pad1.note == 44)
        #expect(pad1.cc == 37)
        #expect(pad1.programChange == 0)
        #expect(pad1.channel == 0x10)  // グローバルに従う
        #expect(pad1.offColor == Rgb8(255, 255, 0))  // 黄
        #expect(pad1.onColor == Rgb8(0, 255, 255))  // シアン

        // 後半 4 パッドは note 40-43（実機の物理配列）
        #expect(program.pads[4].note == 40)
        #expect(program.pads[7].note == 43)

        let knob1 = program.knobs[0]
        #expect(knob1.cc == 79)
        #expect(knob1.channel == 0x10)
        #expect(knob1.min == 0)
        #expect(knob1.max == 127)
        #expect(program.knobs[7].cc == 86)
    }

    @Test("encode(decode(golden)) が byte-exact（SET の安全ゲート）")
    func roundTrip() throws {
        let program = try #require(Lpd8Program.decode(frame: Self.golden))
        var expected = Self.golden
        expected[4] = 0x01  // GET 応答 (0x03) → SET (0x01) は command byte だけ違う
        #expect(program.encodeSetFrame() == expected)
    }

    @Test("壊れたフレームは nil（ゴミを書かない）")
    func rejectsMalformed() {
        #expect(Lpd8Program.decode(frame: []) == nil)
        #expect(Lpd8Program.decode(frame: Array(Self.golden.dropLast())) == nil)

        var wrongModel = Self.golden
        wrongModel[3] = 0x75  // 初代 LPD8
        #expect(Lpd8Program.decode(frame: wrongModel) == nil)

        var wrongSpacer = Self.golden
        wrongSpacer[5] = 0x00
        #expect(Lpd8Program.decode(frame: wrongSpacer) == nil)
    }
}
