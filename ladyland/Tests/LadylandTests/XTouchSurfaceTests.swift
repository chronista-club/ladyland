// mem_1CfpRU9jTnXL4MeK2kfE42 — 8ch + 独立 Master
import Foundation
import Testing
@testable import Ladyland

@Suite("X-Touch Surface")
struct XTouchSurfaceTests {
    @Test("専用面と専用経路を持ち、EXT MIDI入力は鍵盤へ流さない")
    func dedicatedSurface() {
        #expect(SurfaceTab(rawValue: "xtouch") != nil)
        #expect(PaneID(rawValue: "xtouch") != nil)
        let route = MIDIInput.route(forSourceName: "Midistage/ladyland/lease/1|X-Touch INT", hasKeystage: false)
        #expect(route != .genericKeyboard)
        #expect(route != nil)
        #expect(MIDIInput.route(forSourceName: "X-Touch EXT", hasKeystage: true) == nil)
    }

    @Test("Pan/Solo/Masterは軽い保存でも残り、音色blobを保持する")
    func mixPersistence() throws {
        let json = #"{"slots":[{"index":0,"componentType":0,"componentSubType":0,"componentManufacturer":0,"name":"test","gain":0.7,"pan":-0.4,"solo":true}],"selected":0,"masterGain":0.6}"#
        var snapshot = try JSONDecoder().decode(RackSnapshot.self, from: Data(json.utf8))
        snapshot.slots[0].state = Data("saved-tone".utf8)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("xtouch-\(UUID()).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let db = try RackDatabase(path: url)
        try db.save(snapshot, includeBlobs: true)
        snapshot.slots[0].state = nil
        try db.save(snapshot, includeBlobs: false)
        let loaded = try #require(try db.load())
        #expect(loaded.slots.first?.state == Data("saved-tone".utf8))
        let encoded = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(loaded)) as? [String: Any])
        #expect((encoded["masterGain"] as? Double) == 0.6)
        let slot = try #require((encoded["slots"] as? [[String: Any]])?.first)
        #expect((slot["pan"] as? Double) == -0.4)
        #expect((slot["solo"] as? Bool) == true)
    }
}

@Suite("X-Touch MCU / 64 Track")
struct XTouchMCUTests {
    @Test("BANKは8、CHANNELは1、両端で止まる。Masterはindex8")
    func navigation() {
        var bank = XTouchBank()
        bank.move(8, trackCount: 64)
        #expect(bank.start == 8)
        bank.move(1, trackCount: 64)
        #expect(bank.indices(trackCount: 64) == Array(9..<17))
        bank.move(100, trackCount: 64)
        #expect(bank.indices(trackCount: 64) == Array(56..<64))
        bank.move(-100, trackCount: 64)
        #expect(bank.start == 0)
        #expect(XTouchMCU.decode(0xe8, 127, 127) == .fader(8, 1))
    }
    @Test("MCU: 14bit fader / sign-magnitude Pan / pressのみボタン")
    func decode() {
        #expect(XTouchMCU.decode(0xe2, 0, 0) == .fader(2, 0))
        #expect(XTouchMCU.decode(0xb0, 0x10, 0x43) == .pan(0, -3))
        #expect(XTouchMCU.decode(0xb0, 0x17, 2) == .pan(7, 2))
        #expect(XTouchMCU.decode(0x90, 0x08, 127) == .solo(0))
        #expect(XTouchMCU.decode(0x90, 0x10, 127) == .mute(0))
        #expect(XTouchMCU.decode(0x90, 0x1f, 127) == .select(7))
        #expect(XTouchMCU.decode(0x90, 0x2e, 127) == .move(-8))
        #expect(XTouchMCU.decode(0x90, 0x31, 127) == .move(1))
        #expect(XTouchMCU.decode(0x90, 0x70, 127) == .touch(8, true))
        #expect(XTouchMCU.decode(0x80, 0x70, 127) == .touch(8, false))
        #expect(XTouchMCU.decode(0x90, 0x10, 0) == nil)
        #expect(XTouchMCU.decode(0xe9, 0, 0) == nil)
        #expect(XTouchMCU.decode(0xb1, 0x10, 1) == nil)
        #expect(XTouchMCU.decode(0xe0, 255, 0) == nil)
    }
    @Test("出力byte: 全9fader、LCDは7bit・7文字、色は8ch一括")
    func encoding() throws {
        #expect(XTouchMCU.fader(8, 1) == [0xe8, 127, 127])
        #expect(XTouchMCU.fader(0, 0) == [0xe0, 0, 0])
        let lcd = XTouchMCU.lcd(7, line: 1, text: "日本語abcde")
        #expect(lcd.count == 15)
        try #require(lcd.count > 6)
        #expect(lcd[6] == 105)
        #expect(lcd.dropFirst(7).dropLast().allSatisfy { $0 < 128 })
        #expect(XTouchMCU.ring(0, pan: 0) == [0xb0, 0x30, 0x56])
    }
    @Test("タッチ中のBankは保留し、最後のreleaseで反映")
    func touchNavigation() {
        var bank = XTouchBank()
        bank.touch(0, down: true, trackCount: 64)
        bank.move(8, trackCount: 64)
        #expect(bank.start == 0)
        #expect(bank.pending == 8)
        bank.touch(0, down: false, trackCount: 64)
        #expect(bank.start == 8)
        #expect(bank.pending == 0)
    }
}

@Suite("X-Touch projection")
struct XTouchProjectionTests {
    @Test("接続演出はLCD/色だけ。同期後は9本、タッチ中のmotorは除外")
    func greetingAndTouch() {
        let strips = (0..<8).map { XTouchStrip(index: $0, name: "T\($0+1)", gain: 0.5, pan: 0, mute: false, solo: false, selected: $0 == 0, color: 3) }
        let greeting = XTouchProjection.frames(strips: strips, master: 0.7, touched: [], greeting: true)
        #expect(greeting.count == 17)
        #expect(greeting.first?.bytes == XTouchMCU.lcd(0, line: 0, text: "Lady"))
        #expect(greeting.dropFirst(2).first?.bytes == XTouchMCU.lcd(1, line: 0, text: "land"))
        #expect(greeting.allSatisfy { $0.bytes.first == 0xf0 })
        let normal = XTouchProjection.frames(strips: strips, master: 0.7, touched: [2, 8], greeting: false)
        #expect(normal.filter { $0.key.hasPrefix("fader.") }.count == 7)
        #expect(!normal.contains { $0.key == "fader.2" || $0.key == "fader.8" })
        #expect(normal.contains { $0.key == "select.0" && $0.bytes == [0x90, 0x18, 127] })
        #expect(normal.contains { $0.key == "lcd.0.1" })
    }
    @MainActor @Test("SoloはMute/Gainを変えず抑制し、Master/Panを音声ノードへ反映")
    func audioMix() {
        let rack = InstrumentRack()
        rack.slots[0].gain = 0.7
        rack.slots[1].mute = true
        rack.slots[0].solo = true
        #expect(rack.slots[0].effectiveGain == 0.7)
        #expect(rack.slots[2].effectiveGain == 0)
        #expect(rack.drumSlot.effectiveGain == 0)
        rack.slots[0].solo = false
        #expect(rack.slots[2].effectiveGain == 0.8)
        #expect(rack.slots[1].mute)
        rack.masterGain = 0.6
        #expect(rack.engine.mainMixerNode.outputVolume == 0.6)
    }
}

@MainActor @Suite("X-Touch mixer actions")
struct XTouchControllerTests {
    @Test("全64TrackでSolo/Mute/Selectの押下とLEDが一致し、releaseは再操作しない")
    func channelButtonsAcrossBanks() throws {
        let rack = InstrumentRack()
        let controller = XTouchController(rack: rack, onSelect: { rack.select($0) }, onChange: {})
        for index in 0..<64 {
            controller.move(index - controller.bank.start)
            let channel = index - controller.bank.start
            for (base, key) in [(0x08, "solo"), (0x10, "mute"), (0x18, "select")] {
                let note = UInt8(base + channel)
                let event = try #require(XTouchMCU.decode(0x90, note, 127))
                controller.handle(event)
                #expect(XTouchMCU.decode(0x90, note, 0) == nil)
                #expect(XTouchMCU.decode(0x80, note, 127) == nil)
                let frames = XTouchProjection.frames(strips: controller.strips, master: rack.masterGain, touched: [], greeting: false)
                #expect(frames.contains { $0.key == "\(key).\(channel)" && $0.bytes == [0x90, note, 127] })
            }
            #expect(rack.slots[index].solo)
            #expect(rack.slots[index].mute)
            #expect(rack.selected == index)
            controller.handle(.solo(channel))
            controller.handle(.mute(channel))
            #expect(!rack.slots[index].solo)
            #expect(!rack.slots[index].mute)
        }
    }

    @Test("64 Trackを移動してもMasterは独立。echoは無視しtouch中だけ入力")
    func fadersAndBank() async {
        let rack = InstrumentRack()
        let controller = XTouchController(rack: rack, onSelect: { rack.select($0) }, onChange: {})
        controller.handle(.fader(0, 0.2))
        #expect(rack.slots[0].gain == 0.8)
        controller.move(8)
        controller.handle(.touch(0, true))
        controller.handle(.fader(0, 0.2))
        #expect(rack.slots[8].gain == 0.2)
        #expect(rack.slots[0].gain == 0.8)
        controller.move(1)
        #expect(controller.bank.start == 8)
        controller.handle(.touch(0, false))
        #expect(controller.bank.start == 9)
        controller.handle(.select(7))
        #expect(rack.selected == 16)
        controller.handle(.touch(8, true))
        controller.handle(.fader(8, 0.4))
        #expect(rack.masterGain == 0.4)
        controller.handle(.touch(8, false))
        controller.handle(.pan(0, -3))
        #expect(abs(rack.slots[9].pan + 0.06) < 0.001)
        controller.handle(.mute(0))
        controller.handle(.solo(1))
        #expect(rack.slots[9].mute)
        #expect(rack.slots[10].solo)
        await controller.stop()
        #expect(controller.bank.touched.isEmpty)
    }
}

@MainActor @Suite("X-Touch connection lifecycle")
struct XTouchLifecycleTests {
    @Test("再接続は全表示を送り直し、切断後は送信しない")
    func reconnect() async throws {
        let rack = InstrumentRack()
        let controller = XTouchController(rack: rack, onSelect: { _ in }, onChange: {})
        var frames: [[UInt8]] = []
        controller.start(ready: {}, greetingDuration: 0) { frames.append($0) }
        for _ in 0..<100 where frames.count < 58 { try await Task.sleep(for: .milliseconds(5)) }
        try #require(frames.contains([0xe8, 127, 127]))
        await controller.stop()
        let firstCount = frames.count
        try await Task.sleep(for: .milliseconds(100))
        #expect(frames.count == firstCount)
        #expect(!controller.connected)
        controller.start(ready: {}, greetingDuration: 0) { frames.append($0) }
        for _ in 0..<100 where frames.count == firstCount { try await Task.sleep(for: .milliseconds(5)) }
        await controller.stop()
        #expect(frames.count > firstCount)
    }

    @Test("送信失敗は成功キャッシュに入らず再試行される")
    func retries() async throws {
        let rack = InstrumentRack()
        let controller = XTouchController(rack: rack, onSelect: { _ in }, onChange: {})
        var attempts = 0
        var frames: [[UInt8]] = []
        controller.start(ready: {}, greetingDuration: 0) { bytes in
            attempts += 1
            if attempts == 1 { throw MIDIUseError.unavailable }
            frames.append(bytes)
        }
        for _ in 0..<100 where frames.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        await controller.stop()
        #expect(attempts > 1)
        #expect(frames.first == XTouchMCU.lcd(0, line: 0, text: "T1"))
    }

    @Test("終了は送信中の完了を待ち、後続frameを送らない")
    func stopWaitsForPendingSend() async throws {
        let rack = InstrumentRack()
        let controller = XTouchController(rack: rack, onSelect: { _ in }, onChange: {})
        var pending: CheckedContinuation<Void, Never>?
        var calls = 0
        controller.start(ready: {}, greetingDuration: 0) { _ in
            calls += 1
            await withCheckedContinuation { pending = $0 }
        }
        for _ in 0..<100 where pending == nil { try await Task.sleep(for: .milliseconds(5)) }
        let completion = try #require(pending)
        var stopped = false
        let stop = Task { await controller.stop(); stopped = true }
        await Task.yield()
        #expect(!stopped)
        completion.resume()
        await stop.value
        #expect(stopped)
        #expect(calls == 1)
    }
}
