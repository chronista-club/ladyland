//! 出力の誤ルート警告のテスト（design/06 §8 追補、2026-08-01 の
//! 「音が出ない（内蔵スピーカーに向いていた）」事故の再発防止）。

import Testing

@testable import Ladyland

@Suite("出力の誤ルート判定")
struct OutputStatusTests {
    @Test("Zenith 2 / L6max は正規出力 — 警告しない")
    func expectedOutputs() {
        #expect(OutputDevice.isExpectedLiveOutput(name: "Zenith 2 32bit Resolution"))
        #expect(OutputDevice.isExpectedLiveOutput(name: "ZOOM L6max"))
        #expect(OutputDevice.isExpectedLiveOutput(name: "L6max"))
    }

    @Test("内蔵スピーカー・その他のデバイスは警告対象")
    func unexpectedOutputs() {
        #expect(!OutputDevice.isExpectedLiveOutput(name: "MacBook Airのスピーカー"))
        #expect(!OutputDevice.isExpectedLiveOutput(name: "DELL U2723QE"))
        #expect(!OutputDevice.isExpectedLiveOutput(name: "Keystage"))
        #expect(!OutputDevice.isExpectedLiveOutput(name: ""))
    }
}
