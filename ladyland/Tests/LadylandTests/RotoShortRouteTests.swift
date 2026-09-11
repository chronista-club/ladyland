//! ROTO の短い MIDI メッセージ分類。

import Testing

@testable import Ladyland

@Suite("ROTO の短い MIDI 入力分類")
struct RotoShortRouteTests {
    private func decode(
        _ status: UInt8, _ data1: UInt8, _ data2: UInt8,
        dialect: RotoDialect = .logic, smartPage: Int = 0, pluginPage: Int = 0
    ) -> RotoShortRoute {
        RotoShortRoute.decode(
            status: status, data1: data1, data2: data2,
            dialect: dialect, smartPage: smartPage, pluginPage: pluginPage)
    }

    @Test("MIDI モードの ch1/ch2 は DAW 方言より先に受け止める")
    func routesMidiModeFirst() {
        #expect(decode(0xB0, 5, 127) == .midiSeat(cc: 5, value: 127))
        #expect(decode(0xB1, 3, 64) == .mixerGain(slot: 3, value: 64))
        #expect(decode(0xB1, 66, 127) == .mixerButton(slot: 2, pressed: true))
        #expect(decode(0xB1, 66, 0) == .mixerButton(slot: 2, pressed: false))
        // 現行は64トラック: CC63までgain、CC64から選択。ch2に隙間はない。
        #expect(decode(0xB1, 63, 127) == .mixerGain(slot: 63, value: 127))
        #expect(decode(0xB1, 64, 127) == .mixerButton(slot: 0, pressed: true))
        #expect(decode(0xB1, 127, 0) == .mixerButton(slot: 63, pressed: false))
    }

    @Test("MIX の左右キーと RK をパラメータより先に分類する")
    func routesMixButtonsFirst() {
        #expect(decode(0xBF, 60, 2) == .mixArrow(forward: false, value: 2))
        #expect(decode(0xBF, 61, 2) == .mixArrow(forward: true, value: 2))
        #expect(decode(0xBF, 20, 127) == .smartPage(page: 0, pressed: true))
        #expect(decode(0xBF, 27, 0) == .smartPage(page: 7, pressed: false))
    }

    @Test("Logic の ch16 ノブは MIX 入力になる")
    func routesLogicMixKnob() {
        #expect(decode(0xBF, 12, 100) == .mixKnob(knob: 0, kind: .msb, value: 100))
        #expect(decode(0xBF, 44, 20) == .mixKnob(knob: 0, kind: .lsb, value: 20))
    }

    @Test("Bitwig の同じ ch16 ノブは PLUGIN ページから解く")
    func routesBitwigPluginKnob() {
        #expect(
            decode(0xBF, 12, 100, dialect: .bitwig, pluginPage: 3)
                == .parameter(control: 24, kind: .msb, value: 100))
    }

    @Test("Logic の絶対デバイスセルを現在の SMART ページへ写す")
    func routesLogicSmartCell() {
        #expect(
            decode(0xBE, 0, 64, smartPage: 2)
                == .parameter(control: 16, kind: .msb, value: 64))
        #expect(
            decode(0xBE, 8, 64, smartPage: 2)
                == .parameter(control: 16, kind: .msb, value: 64))
        #expect(
            decode(0xBE, 32, 1, smartPage: 2)
                == .parameter(control: 16, kind: .lsb, value: 1))
    }

    @Test("対象外メッセージは無視する")
    func ignoresUnknownMessage() {
        #expect(decode(0x90, 60, 127) == .ignored)
    }
}
