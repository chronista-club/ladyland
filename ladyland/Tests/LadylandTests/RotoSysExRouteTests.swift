//! ROTO SysEx の opcode 分類。

import RotoKit
import Testing

@testable import Ladyland

@Suite("ROTO SysEx 入力分類")
struct RotoSysExRouteTests {
    private func frame(_ group: UInt8, _ opcode: UInt8, payload: [UInt8] = []) -> [UInt8] {
        Roto.header + [group, opcode] + payload + [0xF7]
    }

    @Test("握手と面通知を分類する")
    func routesHandshakeAndFaces() {
        #expect(RotoSysExRoute.decode(frame(0x0A, 0x02)) == .hello)
        #expect(RotoSysExRoute.decode(frame(0x0A, 0x0E)) == .firmwareNotice)
        #expect(RotoSysExRoute.decode(frame(0x0A, 0x0C)) == .dawConnected)
        #expect(RotoSysExRoute.decode(frame(0x0B, 0x01)) == .pluginFace)
        #expect(RotoSysExRoute.decode(frame(0x0C, 0x02)) == .mixFace)
    }

    @Test("PLUGIN 操作を分類する")
    func routesPluginCommands() {
        #expect(RotoSysExRoute.decode(frame(0x0B, 0x0B)) == .controlMapped)
        #expect(RotoSysExRoute.decode(frame(0x0A, 0x14)) == .pluginPage(forward: false))
        #expect(RotoSysExRoute.decode(frame(0x0A, 0x15)) == .pluginPage(forward: true))
        #expect(RotoSysExRoute.decode(frame(0x0B, 0x07)) == .pluginSelected)
        #expect(RotoSysExRoute.decode(frame(0x0B, 0x15)) == .selectButton)
    }

    @Test("観測値と MIXER setup の payload を取り出す")
    func decodesPayloads() {
        #expect(
            RotoSysExRoute.decode(frame(0x0A, 0x09, payload: [0, 2]))
                == .observedTrack(index: 2))
        #expect(
            RotoSysExRoute.decode(frame(0x0A, 0x09))
                == .observedTrack(index: nil))
        #expect(
            RotoSysExRoute.decode(frame(0x0C, 0x01, payload: [1, 2, 3, 4]))
                == .mixerSetup(payload: [1, 2, 3, 4]))
    }

    @Test("hello とフラッシュロードの前処理規則を守る")
    func classifiesPreludePolicy() {
        let hello = frame(0x0A, 0x02)
        let setup = frame(0x0C, 0x01)
        #expect(RotoSysExRoute.isHello(hello))
        #expect(RotoSysExRoute.marksDeviceActivity(hello))
        #expect(!RotoSysExRoute.isHello(setup))
        #expect(!RotoSysExRoute.marksDeviceActivity(setup))
    }

    @Test("未知 opcode は残し、ROTO でないフレームは分類しない")
    func preservesUnknownRotoMessages() {
        #expect(RotoSysExRoute.decode(frame(0x7E, 0x55)) == .unknown)
        #expect(RotoSysExRoute.decode([0xF0, 1, 2, 3, 4, 0x0A, 0x0E, 0xF7]) == nil)
        #expect(RotoSysExRoute.decode([0xF0]) == nil)
    }
}
