//! Creo: mem_1CfmRXq8Nq5sL425AS7AnC — nano で Track と入力元を選ぶ。
import Foundation
import Testing
@testable import Ladyland

@Suite("スタジオ — nano の Track 選択")
struct StudioSetupTests {
    @Test("ミキサーを載せると S で対応 Track を選べる")
    func selectButton() {
        let action = SurfaceMapping.action(cc: 34, value: 127,
            docks: ["mixer": "nanokontrol.faders"], bank: Array(8..<16), page: 0)
        #expect(action == .selectInput(slot: 10))
        #expect(SurfaceMapping.action(cc: 34, value: 0,
            docks: ["mixer": "nanokontrol.faders"], bank: Array(8..<16), page: 0) == nil)
    }
    @Test("MiniLab と Numa は別々の入力経路")
    func independentInputs() {
        let mini = MIDIInput.route(forSourceName: "Arturia MiniLab mkII", hasKeystage: true)
        let numa = MIDIInput.route(forSourceName: "NCXse keyboard", hasKeystage: true)
        #expect(mini != numa)
    }
}

@Suite("スタジオ — 入力候補の確定")
struct StudioInputChoiceTests {
    @Test("S は候補を開くだけ、同じ列のノブで候補を選び S で確定")
    func previewThenConfirm() {
        var choice = StudioTrackSelection()
        #expect(choice.press(slot: 10, current: .keystage) == nil)
        #expect(choice.pending == .init(slot: 10, keyboard: .keystage))
        choice.turn(slot: 9, value: 127)
        #expect(choice.pending?.keyboard == .keystage)
        choice.turn(slot: 10, value: 127)
        #expect(choice.pending?.keyboard == .miniLab)
        #expect(choice.press(slot: 10, current: .keystage) == .init(slot: 10, keyboard: .miniLab))
        #expect(choice.pending == nil)
    }
    @Test("別の S は前の候補を破棄する。取消でも確定しない")
    func changeTrackAndCancel() {
        var choice = StudioTrackSelection()
        _ = choice.press(slot: 0, current: .numa)
        choice.turn(slot: 0, value: 127)
        #expect(choice.press(slot: 63, current: nil) == nil)
        #expect(choice.pending == .init(slot: 63, keyboard: .numa))
        choice.cancel()
        #expect(choice.pending == nil)
    }
    @Test("バンクは 8 Track ずつ移動し、両端では現在の Track を保つ")
    func bankEdges() {
        #expect(StudioTrackSelection.bankTarget(selected: 3, trackCount: 64, direction: 1) == 8)
        #expect(StudioTrackSelection.bankTarget(selected: 11, trackCount: 64, direction: -1) == 0)
        #expect(StudioTrackSelection.bankTarget(selected: 63, trackCount: 64, direction: 1) == 63)
        #expect(StudioTrackSelection.bankTarget(selected: 7, trackCount: 64, direction: -1) == 7)
    }

    @Test("MiniLab の固定は JSON と DB を往復する")
    func persistsIndependentMiniLab() throws {
        let data = Data(#"{"slots":[],"selected":0,"secondKeyboardSlot":2,"miniLabSlot":11}"#.utf8)
        let snapshot = try JSONDecoder().decode(RackSnapshot.self, from: data)
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("studio-\(UUID()).sqlite")
        defer { try? FileManager.default.removeItem(at: path) }
        let db = try RackDatabase(path: path)
        try db.save(snapshot, includeBlobs: true)
        let loaded = try #require(try db.load())
        let encoded = try JSONEncoder().encode(loaded)
        let object = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(object["miniLabSlot"] as? Int == 11)
        #expect(object["secondKeyboardSlot"] as? Int == 2)
    }
}

@Suite("スタジオ — 独立した MIDI 入力")
struct StudioMIDIInputTests {
    @Test("同じ ModWheel CC が入力元ごとの担当へ届く")
    func separateParameterTargets() {
        final class Events: @unchecked Sendable { var numa: [UInt8] = []; var mini: [UInt8] = [] }
        let events = Events()
        let router = MIDIRouter()
        let mod = UInt8(FaceKnobAssignment.modWheelCC)
        router.setSecondKnobRouting(ccs: [mod]) { _, value in events.numa.append(value) }
        router.setSecondKnobRouting(input: .miniLab, ccs: [mod]) { _, value in events.mini.append(value) }
        router.routeSecondKeyboard(0xB0, 1, 40)
        router.routeSecondKeyboard(0xB0, 1, 90, input: .miniLab)
        #expect(events.numa == [40])
        #expect(events.mini == [90])
        router.setSecondKnobRouting(input: .miniLab, ccs: [], handler: nil)
        router.routeSecondKeyboard(0xB0, 1, 60)
        #expect(events.numa == [40, 60])
    }
    @Test("持ち出したスナップショットも Numa と MiniLab を分ける")
    func snapshotRoundTrip() throws {
        var snapshot = RackSnapshot(slots: [], selected: 0)
        snapshot.secondKeyboardSlot = 2
        snapshot.miniLabSlot = 63
        let parsed = try LlDataSnapshot.import(LlDataSnapshot.export(snapshot, at: Date()))
        let restored = parsed.partial(slotIndices: [], includeGlobals: true)
        #expect(restored.secondKeyboardSlot == 2)
        #expect(restored.miniLabSlot == 63)
    }
    @Test("接続図の MiniLab は独立した Jack に繋がる")
    func independentJack() {
        let rows = JackBoardView.gearRows(sources: MIDIInput.plan(sourceNames: ["Arturia MiniLab mkII", "NCXse keyboard"]), lpd8KnobJack: .drums)
        #expect(rows.first { $0.id == "minilab" }?.jack == .miniLab)
        #expect(rows.first { $0.id == "minilab" }?.connected == true)
        #expect(rows.first { $0.id == "ncxse" }?.jack == .synth2)
        let bindings = DeskGraph.Bindings(synth1: 1, synth2: 2, selected: 0, page: 0, miniLab: 63)
        #expect(DeskGraph.target(.miniLab, bindings) == .strip(63, follows: false))
    }
}
