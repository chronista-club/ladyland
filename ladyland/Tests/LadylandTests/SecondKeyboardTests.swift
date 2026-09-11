import Testing

@testable import Ladyland

/// 鍵盤 2（NCXse）経路の通行証（2nd キーボード計画 ①）。
/// 根拠は実測 2026-08-10（Creo `mem_1CdtF7BRVUGwKSkgxSuaaS`）:
/// 音色ボタンが CC0+CC32+PC、パネル操作が CC121/123 の掃除バースト、
/// 音量ノブが CC7 を送る — **どれも楽器へ届いてはいけない**
@Suite("鍵盤 2（NCXse）の経路")
struct SecondKeyboardTests {
    @Test("演奏は通す — ノート / AT / ベンド / ダンパー / スティック 2")
    func forwardsPerformance() {
        #expect(MIDIRouter.secondKeyboardForwards(status: 0x90, data1: 60))
        #expect(MIDIRouter.secondKeyboardForwards(status: 0x80, data1: 60))
        #expect(MIDIRouter.secondKeyboardForwards(status: 0xE0, data1: 0), "ピッチベンド")
        #expect(MIDIRouter.secondKeyboardForwards(status: 0xD0, data1: 64), "チャンネルプレッシャー")
        #expect(MIDIRouter.secondKeyboardForwards(status: 0xA0, data1: 60), "ポリ AT")
        #expect(MIDIRouter.secondKeyboardForwards(status: 0xB0, data1: 64), "ダンパー（連続値 = ハーフペダル）")
        #expect(MIDIRouter.secondKeyboardForwards(status: 0xB0, data1: 74), "スティック 2")
        // ⚠️ ゾーン構成（ch1/ch2）— チャンネルが違っても演奏は演奏
        #expect(MIDIRouter.secondKeyboardForwards(status: 0x91, data1: 60), "ch2 のノートも通す")
    }

    @Test("音色 3 点セットと掃除バーストは飲む — 実測の危険物")
    func swallowsPanelNoise() {
        #expect(!MIDIRouter.secondKeyboardForwards(status: 0xB0, data1: 0), "Bank Select MSB")
        #expect(!MIDIRouter.secondKeyboardForwards(status: 0xB0, data1: 32), "Bank Select LSB")
        #expect(!MIDIRouter.secondKeyboardForwards(status: 0xC0, data1: 89), "Program Change")
        #expect(
            !MIDIRouter.secondKeyboardForwards(status: 0xB0, data1: 121),
            "Reset All Controllers — 素通しすると演奏中の表情が全部リセットされる")
        #expect(
            !MIDIRouter.secondKeyboardForwards(status: 0xB0, data1: 123),
            "All Notes Off — 素通しすると演奏中の音が止まる")
        #expect(
            !MIDIRouter.secondKeyboardForwards(status: 0xB0, data1: 7),
            "音量ノブ — Keystage の席 P1-8 でも Channel Volume でもなく、ただ飲む")
    }

    /// ⭐ **機材の MIDI → 内部モデルへの翻訳**（mako 2026-08-10「MIDI →
    /// 内部モデル操作への変換というか」）。NCXse の Mod（CC1）は
    /// ModWheel 席（内部 ID = `modWheelCC`）の操作 — Keystage は実機で
    /// 焼いてこの番号を送るが、NCXse は焼けないのでアダプタが翻訳する
    @Test("Mod（CC1）は ModWheel 席へ翻訳 — 両鍵盤のホイールが同じ席に着く")
    func translatesModToSeat() {
        let mod = UInt8(FaceKnobAssignment.modWheelCC)
        #expect(MIDIRouter.secondKeyboardTranslated(status: 0xB0, data1: 1) == mod)
        #expect(MIDIRouter.secondKeyboardTranslated(status: 0xB1, data1: 1) == mod, "ch2 のゾーンでも")
        // 翻訳後の番号は通行証を持つ（未割当なら楽器へ素通し = Keystage と同じ）
        #expect(MIDIRouter.secondKeyboardForwards(status: 0xB0, data1: mod))
        // 翻訳しないもの
        #expect(MIDIRouter.secondKeyboardTranslated(status: 0xB0, data1: 64) == 64, "ダンパーはそのまま")
        #expect(MIDIRouter.secondKeyboardTranslated(status: 0x90, data1: 1) == 1, "ノート C#-1 は CC ではない")
    }

    @Test("翻訳が trace に出る — ログは席の言葉（CC116）で読める")
    func traceShowsTranslated() {
        final class Box: @unchecked Sendable { var routes: [MidiRoute] = [] }
        let router = MIDIRouter()
        let box = Box()
        router.setTraceHandler { box.routes.append($0) }
        router.routeSecondKeyboard(0xB0, 1, 80)  // NCXse の Mod
        #expect(
            box.routes == [
                .secondKeyboard(
                    status: 0xB0, data1: UInt8(FaceKnobAssignment.modWheelCC),
                    data2: 80, hasTarget: false)
            ])
    }

    /// ⚠️ **同じ CC 番号でも面が違えば意味が違う** — NCXse の CC0 は
    /// Bank Select であって Keystage の席 P1-1 ではない。帯の横取り
    /// （`.knob` trace）を通らないことが、経路を分けた主張の本体
    @Test("Keystage の帯の解釈を通らない — CC0 を席と誤認しない")
    func doesNotTouchKnobBand() {
        final class Box: @unchecked Sendable { var routes: [MidiRoute] = [] }
        let router = MIDIRouter()
        let box = Box()
        router.setTraceHandler { box.routes.append($0) }
        router.routeSecondKeyboard(0xB0, 0, 127)  // NCXse の Bank Select MSB
        #expect(
            box.routes == [.secondKeyboard(status: 0xB0, data1: 0, data2: 127, hasTarget: false)],
            ".knob（帯の横取り）が出ていない = 席と誤認していない")
    }
}
