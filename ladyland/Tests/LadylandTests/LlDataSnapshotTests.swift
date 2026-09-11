//! lldata スナップショット（export / 部分ロード）のテスト。
//!
//! 守りたい不変条件:
//!   - 往復して同じ状態が戻る（音色 blob 含む）
//!   - 同じ音色は base64 が 1 回しか現れない（内容アドレスの効き目）
//!   - **部分ロードは選んだ席だけ**を持ち出す（他席を巻き込まない）
//!   - 知らない版・壊れた構文は**黙って無視せず**開かない（半端に適用しない）

import Foundation
import Testing

@testable import Ladyland

@Suite("KDL 最小読み書き")
struct KDLMiniTests {
    @Test("ノード・引数・プロパティ・子の往復")
    func roundTrip() throws {
        let source = """
            // コメントは飛ばす
            rack trackCount=24 selected=11 {
                key root=0 scale="major"
                led feedback=#true
            }
            slot 3 name="Madrid (Bass)" gain=0.8
            """
        let nodes = try KDLMini.parse(source)
        #expect(nodes.count == 2)
        #expect(nodes[0].name == "rack")
        #expect(nodes[0]["trackCount"]?.intValue == 24)
        #expect(nodes[0].child(named: "key")?["scale"]?.stringValue == "major")
        #expect(nodes[0].child(named: "led")?["feedback"]?.boolValue == true)
        #expect(nodes[1].args.first?.intValue == 3)
        #expect(nodes[1]["name"]?.stringValue == "Madrid (Bass)")
        #expect(nodes[1]["gain"]?.doubleValue == 0.8)

        // emit → parse で同じ木に戻る
        let reparsed = try KDLMini.parse(KDLMini.emit(nodes))
        #expect(reparsed == nodes)
    }

    @Test("引用が要る名前・エスケープ・日本語")
    func quotingAndEscapes() throws {
        let node = KDLNode(
            name: "slot",
            props: ["name": .string("改行\nと\"引用\" と 日本語")])
        let nodes = try KDLMini.parse(KDLMini.emit([node]))
        #expect(nodes.first?["name"]?.stringValue == "改行\nと\"引用\" と 日本語")
    }

    @Test("知らない構文は黙って無視せずエラーにする")
    func rejectsUnknownSyntax() {
        // 閉じられていない文字列
        #expect(throws: KDLError.self) { try KDLMini.parse("slot name=\"unclosed") }
        // 対応しない }
        #expect(throws: KDLError.self) { try KDLMini.parse("}") }
        // 閉じられていない子ブロック
        #expect(throws: KDLError.self) { try KDLMini.parse("rack {\n  key root=0\n") }
        // 未対応キーワード
        #expect(throws: KDLError.self) { try KDLMini.parse("led feedback=#maybe") }
    }
}

@Suite("lldata スナップショット")
struct LlDataSnapshotTests {
    private let exportDate = Date(timeIntervalSince1970: 1_785_000_000)

    private func slot(
        index: Int, name: String, gain: Float = 0.8, state: Data? = nil, drafts: [Draft]? = nil
    ) -> SlotSnapshot {
        SlotSnapshot(
            index: index, componentType: 1635085685, componentSubType: 100,
            componentManufacturer: 1263553842, name: name, gain: gain, state: state,
            knobs: [FaceKnobMapping(knob: 16, address: 0xA1, name: "Cutoff")], drafts: drafts)
    }

    private func sample() -> RackSnapshot {
        var snapshot = RackSnapshot(
            slots: [
                slot(index: 0, name: "Salzburg (Piano)", gain: 0.85, state: Data("piano".utf8)),
                slot(
                    index: 3, name: "Madrid (Bass)", gain: 0.42, state: Data("bass".utf8),
                    drafts: [
                        Draft(
                            id: UUID(uuidString: "1D3A0A1E-0000-4000-8000-000000000001")!,
                            componentType: 1635085685, componentSubType: 100,
                            componentManufacturer: 1263553842, name: "Madrid alt", gain: 0.5,
                            state: Data("alt".utf8), knobs: nil,
                            savedAt: Date(timeIntervalSince1970: 1_784_000_000))
                    ]),
            ],
            selected: 3)
        snapshot.trackCount = 24
        snapshot.keyRoot = 5
        snapshot.keyScale = "minor"
        snapshot.ledFeedback = false
        snapshot.outputDeviceUID = "zenith-uid"
        return snapshot
    }

    @Test("ファイル名は lldata-snapshot-{日付}.kdl")
    func fileName() {
        let name = LlDataSnapshot.fileName(for: exportDate)
        #expect(name.hasPrefix("lldata-snapshot-"))
        #expect(name.hasSuffix(".kdl"))
    }

    @Test("往復 — 席・音量・割当・棚・音色が戻る")
    func roundTrip() throws {
        let text = LlDataSnapshot.export(sample(), at: exportDate)
        let imported = try LlDataSnapshot.import(text)

        #expect(imported.globals.trackCount == 24)
        #expect(imported.globals.selected == 3)
        #expect(imported.globals.keyRoot == 5)
        #expect(imported.globals.keyScale == "minor")
        #expect(imported.globals.ledFeedback == false)
        #expect(imported.globals.outputDeviceUID == "zenith-uid")
        #expect(imported.slots.count == 2)

        let madrid = try #require(imported.slots.first { $0.index == 3 })
        #expect(madrid.name == "Madrid (Bass)")
        #expect(madrid.gain == 0.42)
        #expect(madrid.state == Data("bass".utf8))
        #expect(madrid.knobs?.first?.name == "Cutoff")
        #expect(madrid.knobs?.first?.knob == 16)
        #expect(madrid.drafts?.count == 1)
        #expect(madrid.drafts?.first?.name == "Madrid alt")
        #expect(madrid.drafts?.first?.state == Data("alt".utf8))
    }

    /// 書き出したスナップショットにもテーマが載る（**持ち出しても見た目が戻る**）
    @Test("テーマが KDL を往復する")
    func themeRoundTrip() throws {
        var snapshot = RackSnapshot(slots: [], selected: 0)
        snapshot.theme = "contrast/system"

        let text = LlDataSnapshot.export(snapshot, at: Date(), includeBlobs: false)
        let parsed = try LlDataSnapshot.import(text)
        #expect(parsed.globals.theme == "contrast/system")

        let restored = parsed.partial(slotIndices: [], includeGlobals: true)
        #expect(restored.theme == "contrast/system")
    }

    @Test("自己記述 — schema ノードが載っている")
    func carriesSchema() throws {
        let text = LlDataSnapshot.export(sample(), at: exportDate)
        #expect(text.contains("schema \"lldata-snapshot\""))
        let nodes = try KDLMini.parse(text)
        let schema = try #require(nodes.first { $0.name == "schema" })
        #expect(schema["version"]?.intValue == LlDataSnapshot.formatVersion)
        #expect(schema.children(named: "node").count >= 5, "各ノードの読み方が載ること")
    }

    @Test("同じ音色は base64 が 1 回だけ（内容アドレスの効き目）")
    func blobsAreDeduplicated() throws {
        let same = Data(repeating: 0xAB, count: 300)
        var snapshot = RackSnapshot(
            slots: [
                slot(index: 0, name: "A", state: same),
                slot(index: 1, name: "B", state: same),
            ], selected: 0)
        snapshot.trackCount = 24
        let text = LlDataSnapshot.export(snapshot, at: exportDate)

        let base64 = same.base64EncodedString()
        let occurrences = text.components(separatedBy: base64).count - 1
        #expect(occurrences == 1, "同じ音色は 1 回しか書かれないこと")

        let imported = try LlDataSnapshot.import(text)
        #expect(imported.slots.allSatisfy { $0.state == same })
    }

    @Test("音色を外すと構造だけ（軽い・差分向き）")
    func structureOnly() throws {
        let text = LlDataSnapshot.export(sample(), at: exportDate, includeBlobs: false)
        // 本文（コメントではなく構文木）に blob ノードが無いことを見る
        let nodes = try KDLMini.parse(text)
        #expect(!nodes.contains { $0.name == "blob" }, "blob ノードが無いこと")
        let imported = try LlDataSnapshot.import(text)
        #expect(imported.slots.count == 2)
        #expect(imported.slots.allSatisfy { $0.state == nil })
        #expect(imported.slots.first?.name == "Salzburg (Piano)", "構造は残ること")
    }

    @Test("部分ロード — 選んだ席だけを持ち出す")
    func partialLoad() throws {
        let imported = try LlDataSnapshot.import(LlDataSnapshot.export(sample(), at: exportDate))

        let only3 = imported.partial(slotIndices: [3], includeGlobals: false)
        #expect(only3.slots.map(\.index) == [3], "選んだ席だけ")
        #expect(only3.slots.first?.state == Data("bass".utf8), "音色も付いてくる")
        #expect(only3.trackCount == 24, "ドラム席の解決に必要なので総数は必ず載る")
        // globals を含めなければキーや出力は持ち込まない
        #expect(only3.keyRoot == nil)
        #expect(only3.outputDeviceUID == nil)

        let withGlobals = imported.partial(slotIndices: [0], includeGlobals: true)
        #expect(withGlobals.keyRoot == 5)
        #expect(withGlobals.outputDeviceUID == "zenith-uid")
        #expect(withGlobals.selected == 3)
    }

    @Test("選択 UI 用の一覧（席番号・名前・音色の有無・棚の数）")
    func contentsListing() throws {
        let imported = try LlDataSnapshot.import(LlDataSnapshot.export(sample(), at: exportDate))
        let contents = imported.contents
        #expect(contents.map(\.index) == [0, 3])
        #expect(contents[1].name == "Madrid (Bass)")
        #expect(contents[1].hasState)
        #expect(contents[1].drafts == 1)
    }

    /// 実機の本物のラック（21MB / 22 席、AU の実 fullState）で往復する。
    /// 手元に rack.json が無い環境では黙ってスキップ（KORG 統合テストと同じ作法）
    @Test("実データでの往復 — 本物の音色 blob を base64 で通す")
    func realDataRoundTrip() throws {
        guard let legacy = RackStore.load() else { return }
        let text = LlDataSnapshot.export(legacy, at: exportDate)
        let imported = try LlDataSnapshot.import(text)

        #expect(imported.slots.count == legacy.slots.count)
        for original in legacy.slots {
            let restored = try #require(imported.slots.first { $0.index == original.index })
            #expect(restored.name == original.name)
            #expect(restored.gain == original.gain)
            #expect(restored.state == original.state, "席 \(original.index + 1) の音色が一致すること")
            #expect(restored.knobs?.count == original.knobs?.count)
            #expect((restored.drafts ?? []).count == (original.drafts ?? []).count)
        }
    }

    @Test("lldata でないファイル・未対応の版は開かない")
    func refusesForeignAndNewer() throws {
        #expect(throws: LlDataSnapshot.ImportError.self) {
            try LlDataSnapshot.import("rack trackCount=24\n")
        }
        let future = """
            schema "lldata-snapshot" version=99
            rack trackCount=24 selected=0
            """
        #expect(throws: LlDataSnapshot.ImportError.self) {
            try LlDataSnapshot.import(future)
        }
    }

    @Test("追加された globals とノブ属性・defaultSnapshot が KDL 往復する")
    func extendedStateRoundTrip() throws {
        let mapping = FaceKnobMapping(
            knob: 16, address: 0x123, name: "Cutoff", alias: "Cut", color: 42)
        let defaultDraft = Draft(
            id: UUID(uuidString: "1D3A0A1E-0000-4000-8000-000000000002")!,
            componentType: 1635085685, componentSubType: 100,
            componentManufacturer: 1263553842, name: "Default", gain: 0.7,
            state: Data("default".utf8), knobs: [mapping],
            savedAt: Date(timeIntervalSince1970: 1_785_000_001))

        var snapshot = RackSnapshot(slots: [slot(index: 2, name: "Extended")], selected: 2)
        snapshot.slots[0].knobs = [mapping]
        snapshot.slots[0].defaultSnapshot = defaultDraft
        snapshot.pedalMode = "assign"
        snapshot.pedalInverted = true
        snapshot.synthInput1Slot = 3
        snapshot.secondKeyboardSlot = 5
        snapshot.keystage = "{}"
        snapshot.rotoColors = "{}"
        snapshot.tempoSync = false

        let imported = try LlDataSnapshot.import(LlDataSnapshot.export(snapshot, at: exportDate))

        #expect(imported.globals.pedalMode == "assign")
        #expect(imported.globals.pedalInverted == true)
        #expect(imported.globals.synthInput1Slot == 3)
        #expect(imported.globals.secondKeyboardSlot == 5)
        #expect(imported.globals.keystage == "{}")
        #expect(imported.globals.rotoColors == "{}")
        #expect(imported.globals.tempoSync == false)
        let restored = try #require(imported.slots.first)
        #expect(restored.knobs == [mapping])
        #expect(restored.defaultSnapshot == defaultDraft)
    }
}
