//! ラック永続化のテスト。
//!
//! 「アプリ再開した時に、自分の楽器がそのまま並んでいる」（design/06 §2）の
//! データ層を固定する: Snapshot の Codable roundtrip、fullState blob の
//! plist ⇄ Data 変換、AudioComponentDescription の再構築。

import Foundation
import Testing

@testable import Ladyland

@Suite("RackStore")
struct RackStoreTests {
    private func makeSnapshot() -> RackSnapshot {
        RackSnapshot(
            slots: [
                SlotSnapshot(
                    index: 0,
                    componentType: 0x6175_6D75,  // 'aumu'
                    componentSubType: 0x4B47_3338,
                    componentManufacturer: 0x4B4F_5247,  // 'KORG'
                    name: "Memphis (MS-20)",
                    gain: 0.75,
                    state: Data([0x01, 0x02, 0x03]),
                    knobs: [
                        FaceKnobMapping(knob: 0, address: 42, name: "Cutoff"),
                        FaceKnobMapping(knob: 1, address: 43, name: "Resonance"),
                    ]
                ),
                SlotSnapshot(
                    index: 8,  // ドラムスロット
                    componentType: 0x6175_6D75,
                    componentSubType: 0x4B47_3130,
                    componentManufacturer: 0x4B4F_5247,
                    name: "London (Drum)",
                    gain: 0.9,
                    state: nil
                ),
            ],
            selected: 3,
            outputDeviceUID: "AppleUSBAudioEngine:Test:Zenith2:UID"
        )
    }

    @Test("save → load の roundtrip で全フィールドが保たれる")
    func roundtrip() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ladyland-test-\(UUID().uuidString)/rack.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let original = makeSnapshot()
        try RackStore.save(original, to: url)
        let loaded = try #require(RackStore.load(from: url))

        #expect(loaded.selected == 3)
        #expect(loaded.slots.count == 2)
        #expect(loaded.slots[0].name == "Memphis (MS-20)")
        #expect(loaded.slots[0].gain == 0.75)
        #expect(loaded.slots[0].state == Data([0x01, 0x02, 0x03]))
        #expect(loaded.slots[1].index == 8)
        #expect(loaded.slots[1].state == nil)
        #expect(loaded.outputDeviceUID == "AppleUSBAudioEngine:Test:Zenith2:UID")

        // 顔つまみ割当（P4）も一緒に往復する
        #expect(
            loaded.slots[0].knobs == [
                FaceKnobMapping(knob: 0, address: 42, name: "Cutoff"),
                FaceKnobMapping(knob: 1, address: 43, name: "Resonance"),
            ])
        #expect(loaded.slots[1].knobs == nil)
    }

    @Test("同一スナップショットの再エンコードはバイト一致（常時保存 dedup の前提）")
    func encodingIsDeterministic() throws {
        // AppState.saveRack は「前回書いたバイト列と同じなら書かない」で
        // 30 秒保険タイマーのアイドル I/O をゼロにしている。素の JSONEncoder は
        // キー順が実行ごとに揺れる（このテストで実際に検出した）ため、
        // RackStore.encode が sortedKeys で正準化していることを固定する
        let snapshot = makeSnapshot()
        let first = try RackStore.encode(snapshot)
        let second = try RackStore.encode(snapshot)
        #expect(first == second)

        let state: [String: Any] = [
            "preset-name": "my lead", "version": 2,
            "data": Data([0xDE, 0xAD, 0xBE, 0xEF]),
        ]
        #expect(RackStore.encodeState(state) == RackStore.encodeState(state))
    }

    @Test("knobs / outputDeviceUID 導入前の旧 rack.json が読める（後方互換）")
    func legacyJSONWithoutNewFields() throws {
        let json = """
            {"selected":0,"slots":[{"index":0,"componentType":1,"componentSubType":2,
            "componentManufacturer":3,"name":"Legacy","gain":0.5}]}
            """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ladyland-legacy-\(UUID().uuidString).json")
        try Data(json.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let loaded = try #require(RackStore.load(from: url))
        #expect(loaded.slots.first?.name == "Legacy")
        #expect(loaded.slots.first?.knobs == nil)
        #expect(loaded.outputDeviceUID == nil)
    }

    @Test("壊れたファイル・存在しないファイルは nil（起動を止めない）")
    func corruptOrMissingFile() throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("ladyland-missing-\(UUID().uuidString).json")
        #expect(RackStore.load(from: missing) == nil)

        let corrupt = FileManager.default.temporaryDirectory
            .appendingPathComponent("ladyland-corrupt-\(UUID().uuidString).json")
        try Data("not json at all".utf8).write(to: corrupt)
        defer { try? FileManager.default.removeItem(at: corrupt) }
        #expect(RackStore.load(from: corrupt) == nil)
    }

    @Test("AudioComponentDescription が識別 3 要素から再構築される")
    func componentDescription() {
        let snap = makeSnapshot().slots[0]
        let desc = snap.description
        #expect(desc.componentType == 0x6175_6D75)
        #expect(desc.componentSubType == 0x4B47_3338)
        #expect(desc.componentManufacturer == 0x4B4F_5247)
    }

    @Test("fullState の plist ⇄ Data 変換が roundtrip する")
    func stateEncoding() {
        let state: [String: Any] = [
            "preset-name": "my lead",
            "version": 2,
            "data": Data([0xDE, 0xAD, 0xBE, 0xEF]),
        ]
        let encoded = RackStore.encodeState(state)
        #expect(encoded != nil)

        let decoded = RackStore.decodeState(encoded)
        #expect(decoded?["preset-name"] as? String == "my lead")
        #expect(decoded?["version"] as? Int == 2)
        #expect(decoded?["data"] as? Data == Data([0xDE, 0xAD, 0xBE, 0xEF]))
    }

    @Test("nil state はどちら向きでも nil のまま")
    func nilState() {
        #expect(RackStore.encodeState(nil) == nil)
        #expect(RackStore.decodeState(nil) == nil)
    }
}
