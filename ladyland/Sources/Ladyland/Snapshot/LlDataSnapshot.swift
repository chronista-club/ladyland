//! lldata スナップショット — 状態の書き出しと**部分ロード**
//! （mako 要望 2026-08-02「その状態の export（kdl scheme の載った
//! lldata-snapshot-{date}.kdl）機能と、そこからの部分ロードできたら最高」）。
//!
//! spec/05 に `open "backup"` として残していた「セット一式の持ち運び」への答え。
//! DB（ladyland.sqlite）は**動いている状態の SSOT**、こちらは**持ち出す姿**。
//!
//! 形（自己記述 — schema ノードが読み方を同梱する）:
//! ```kdl
//! schema "lldata-snapshot" version=1 { node "slot" { ... } }
//! rack trackCount=24 selected=11 { key root=0 scale="major" }
//! slot 3 name="Madrid (Bass)" gain=0.8 state="<sha256>" {
//!     knob cc=16 address=12345 name="Cutoff"
//!     draft id="..." name="..." savedAt="..." state="<sha256>"
//! }
//! blob "<sha256>" bytes=532480 { data "<base64>" }
//! ```
//!
//! **部分ロードが主目的**なので、席は 1 ノード = 1 単位で完結させる（席を
//! 選んで適用すれば、その席のプラグイン・音色・音量・割当・棚が丸ごと入る）。
//! 音色は DB と同じ内容アドレスで参照するため、同じ音色を持つ席や棚が
//! 何個あっても base64 は 1 回しか現れない。

import AVFoundation
import CryptoKit
import Foundation

struct LlDataSnapshot {
    static let formatVersion = 1

    /// ラック全体にかかる値（部分ロードでは任意）
    struct Globals: Equatable {
        var trackCount: Int?
        var selected: Int?
        var outputDeviceUID: String?
        var keyRoot: Int?
        var keyScale: String?
        var ledFeedback: Bool?
        /// 画面のテーマ（`"mint/dark"`）
        var theme: String?
        var pedalMode: String? = nil
        var pedalInverted: Bool? = nil
        var synthInput1Slot: Int? = nil
        var secondKeyboardSlot: Int? = nil
        var keystage: String? = nil
        var rotoColors: String? = nil
        var tempoSync: Bool? = nil
    }

    var globals = Globals()
    /// 席（音色 blob は解決済み）
    var slots: [SlotSnapshot] = []
    /// 書き出した時刻（ファイル名と表示用）
    var exportedAt: Date = Date(timeIntervalSince1970: 0)

    // MARK: - 書き出し

    /// `lldata-snapshot-2026-08-02.kdl`
    static func fileName(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return "lldata-snapshot-\(formatter.string(from: date)).kdl"
    }

    private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    /// RackSnapshot → KDL テキスト。
    /// - Parameter includeBlobs: false なら音色を落として構造だけ（軽い・差分向き）
    static func export(_ snapshot: RackSnapshot, at date: Date, includeBlobs: Bool = true)
        -> String
    {
        var nodes: [KDLNode] = [schemaNode(includeBlobs: includeBlobs)]

        var rack = KDLNode(name: "rack")
        rack.props["exportedAt"] = .string(timestampFormatter.string(from: date))
        if let count = snapshot.trackCount { rack.props["trackCount"] = .int(count) }
        rack.props["selected"] = .int(snapshot.selected)
        if let uid = snapshot.outputDeviceUID {
            rack.children.append(KDLNode(name: "output", props: ["uid": .string(uid)]))
        }
        if let root = snapshot.keyRoot, let scale = snapshot.keyScale {
            rack.children.append(
                KDLNode(name: "key", props: ["root": .int(root), "scale": .string(scale)]))
        }
        if let led = snapshot.ledFeedback {
            rack.children.append(KDLNode(name: "led", props: ["feedback": .bool(led)]))
        }
        if let theme = snapshot.theme {
            rack.children.append(KDLNode(name: "theme", props: ["value": .string(theme)]))
        }
        if let value = snapshot.pedalMode {
            rack.children.append(KDLNode(name: "pedal", props: ["mode": .string(value)]))
        }
        if let value = snapshot.pedalInverted {
            rack.children.append(KDLNode(name: "pedalInverted", props: ["value": .bool(value)]))
        }
        if let value = snapshot.synthInput1Slot {
            rack.children.append(KDLNode(name: "synthInput1", props: ["slot": .int(value)]))
        }
        if let value = snapshot.secondKeyboardSlot {
            rack.children.append(KDLNode(name: "secondKeyboard", props: ["slot": .int(value)]))
        }
        if let value = snapshot.keystage {
            rack.children.append(KDLNode(name: "keystage", props: ["json": .string(value)]))
        }
        if let value = snapshot.rotoColors {
            rack.children.append(KDLNode(name: "rotoColors", props: ["json": .string(value)]))
        }
        if let value = snapshot.tempoSync {
            rack.children.append(KDLNode(name: "tempoSync", props: ["enabled": .bool(value)]))
        }
        nodes.append(rack)

        // 音色は内容アドレスで 1 回だけ。席・棚からはハッシュで参照する
        var blobs: [String: Data] = [:]
        func reference(_ data: Data?) -> String? {
            guard includeBlobs, let data, !data.isEmpty else { return nil }
            let hash = RackDatabase.hash(data)
            blobs[hash] = data
            return hash
        }

        for slot in snapshot.slots.sorted(by: { $0.index < $1.index }) {
            var node = KDLNode(name: "slot", args: [.int(slot.index)])
            node.props["name"] = .string(slot.name)
            node.props["gain"] = .double(Double(slot.gain))
            if slot.mute == true { node.props["mute"] = .bool(true) }
            if let color = slot.rotoColor { node.props["rotoColor"] = .int(Int(color)) }
            if let custom = slot.customName { node.props["customName"] = .string(custom) }
            node.props["type"] = .int(Int(slot.componentType))
            node.props["subType"] = .int(Int(slot.componentSubType))
            node.props["manufacturer"] = .int(Int(slot.componentManufacturer))
            if let hash = reference(slot.state) { node.props["state"] = .string(hash) }

            for knob in slot.knobs ?? [] {
                node.children.append(
                    KDLNode(
                        name: "knob",
                        props: [
                            "cc": .int(knob.knob),
                            "address": .int(Int(knob.address)),
                            "name": .string(knob.name),
                            "alias": knob.alias.map(KDLValue.string) ?? .string(""),
                            "color": knob.color.map { .int(Int($0)) } ?? .int(-1),
                        ]))
            }
            for draft in slot.drafts ?? [] {
                var child = KDLNode(name: "draft")
                child.props["id"] = .string(draft.id.uuidString)
                child.props["name"] = .string(draft.name)
                child.props["gain"] = .double(Double(draft.gain))
                child.props["type"] = .int(Int(draft.componentType))
                child.props["subType"] = .int(Int(draft.componentSubType))
                child.props["manufacturer"] = .int(Int(draft.componentManufacturer))
                child.props["savedAt"] = .string(timestampFormatter.string(from: draft.savedAt))
                if let hash = reference(draft.state) { child.props["state"] = .string(hash) }
                for knob in draft.knobs ?? [] {
                    child.children.append(
                        KDLNode(
                            name: "knob",
                            props: [
                                "cc": .int(knob.knob),
                                "address": .int(Int(knob.address)),
                                "name": .string(knob.name),
                                "alias": knob.alias.map(KDLValue.string) ?? .string(""),
                                "color": knob.color.map { .int(Int($0)) } ?? .int(-1),
                            ]))
                }
                node.children.append(child)
            }
            if let defaultSnapshot = slot.defaultSnapshot {
                var defaultNode = KDLNode(name: "default")
                defaultNode.props["id"] = .string(defaultSnapshot.id.uuidString)
                defaultNode.props["name"] = .string(defaultSnapshot.name)
                defaultNode.props["gain"] = .double(Double(defaultSnapshot.gain))
                defaultNode.props["type"] = .int(Int(defaultSnapshot.componentType))
                defaultNode.props["subType"] = .int(Int(defaultSnapshot.componentSubType))
                defaultNode.props["manufacturer"] = .int(Int(defaultSnapshot.componentManufacturer))
                defaultNode.props["savedAt"] = .string(timestampFormatter.string(from: defaultSnapshot.savedAt))
                if let hash = reference(defaultSnapshot.state) { defaultNode.props["state"] = .string(hash) }
                for knob in defaultSnapshot.knobs ?? [] {
                    defaultNode.children.append(KDLNode(name: "knob", props: [
                        "cc": .int(knob.knob), "address": .int(Int(knob.address)),
                        "name": .string(knob.name),
                        "alias": knob.alias.map(KDLValue.string) ?? .string(""),
                        "color": knob.color.map { .int(Int($0)) } ?? .int(-1),
                    ]))
                }
                node.children.append(defaultNode)
            }
            nodes.append(node)
        }

        for hash in blobs.keys.sorted() {
            let data = blobs[hash]!
            var node = KDLNode(name: "blob", args: [.string(hash)])
            node.props["bytes"] = .int(data.count)
            node.props["encoding"] = .string("base64")
            node.children.append(
                KDLNode(name: "data", args: [.string(data.base64EncodedString())]))
            nodes.append(node)
        }

        return header(at: date, includeBlobs: includeBlobs) + KDLMini.emit(nodes)
    }

    private static func header(at date: Date, includeBlobs: Bool) -> String {
        """
        // ladyland スナップショット（lldata）— \(timestampFormatter.string(from: date))
        //
        // 動いている状態の SSOT は ladyland.sqlite（spec/05）。これは**持ち出す姿**で、
        // 席ごとに部分ロードできる。schema ノードがこのファイルの読み方を持つ。
        \(includeBlobs ? "// 音色は内容アドレスの blob として同梱（base64）。" : "// 構造のみ（音色 blob なし）。")

        """
    }

    /// 自己記述の schema ノード（人が読んで分かる + 版の判定に使う）
    private static func schemaNode(includeBlobs: Bool) -> KDLNode {
        var schema = KDLNode(name: "schema", args: [.string("lldata-snapshot")])
        schema.props["version"] = .int(formatVersion)
        schema.props["blobs"] = .bool(includeBlobs)
        schema.children = [
            KDLNode(
                name: "node", args: [.string("rack")],
                props: ["doc": .string("ラック全体（総数・選択・出力・キー・LED）")]),
            KDLNode(
                name: "node", args: [.string("slot")],
                props: [
                    "doc": .string(
                        "席 1 つ = 部分ロードの単位。第 1 引数が席番号（0 起点、= トラック総数 はドラム席）")
                ]),
            KDLNode(
                name: "node", args: [.string("knob")],
                props: ["doc": .string("顔つまみ割当（cc = Ctrl 番号 0-127 / 128 = PB）")]),
            KDLNode(
                name: "node", args: [.string("draft")],
                props: ["doc": .string("席の棚の 1 着（工房と舞台の分離。design/06 §8）")]),
            KDLNode(
                name: "node", args: [.string("blob")],
                props: ["doc": .string("音色（AU fullState）。sha256 の内容アドレスで席・棚から参照")]),
        ]
        return schema
    }

    // MARK: - 読み込み

    enum ImportError: Error, CustomStringConvertible {
        case notLlData
        case unsupportedVersion(Int)
        case missingBlob(String)

        var description: String {
            switch self {
            case .notLlData: return "lldata スナップショットではありません"
            case .unsupportedVersion(let version):
                return "未対応の版です（version \(version)。このアプリは \(formatVersion) まで）"
            case .missingBlob(let hash): return "音色 blob が見つかりません（\(hash.prefix(8))…）"
            }
        }
    }

    /// KDL テキスト → スナップショット。**知らない版は開かない**
    /// （半端に読んで席を壊さない）
    static func `import`(_ text: String) throws -> LlDataSnapshot {
        let nodes = try KDLMini.parse(text)
        guard let schema = nodes.first(where: { $0.name == "schema" }),
              schema.args.first?.stringValue == "lldata-snapshot"
        else { throw ImportError.notLlData }
        let version = schema["version"]?.intValue ?? 0
        guard version <= formatVersion else { throw ImportError.unsupportedVersion(version) }

        // 音色を先に集める（席より後ろに置いてあるため）
        var blobs: [String: Data] = [:]
        for node in nodes where node.name == "blob" {
            guard let hash = node.args.first?.stringValue,
                  let base64 = node.child(named: "data")?.args.first?.stringValue,
                  let data = Data(base64Encoded: base64)
            else { continue }
            blobs[hash] = data
        }

        var snapshot = LlDataSnapshot()
        if let rack = nodes.first(where: { $0.name == "rack" }) {
            snapshot.globals = Globals(
                trackCount: rack["trackCount"]?.intValue,
                selected: rack["selected"]?.intValue,
                outputDeviceUID: rack.child(named: "output")?["uid"]?.stringValue,
                keyRoot: rack.child(named: "key")?["root"]?.intValue,
                keyScale: rack.child(named: "key")?["scale"]?.stringValue,
                ledFeedback: rack.child(named: "led")?["feedback"]?.boolValue,
                theme: rack.child(named: "theme")?["value"]?.stringValue,
                pedalMode: rack.child(named: "pedal")?["mode"]?.stringValue,
                pedalInverted: rack.child(named: "pedalInverted")?["value"]?.boolValue,
                synthInput1Slot: rack.child(named: "synthInput1")?["slot"]?.intValue,
                secondKeyboardSlot: rack.child(named: "secondKeyboard")?["slot"]?.intValue,
                keystage: rack.child(named: "keystage")?["json"]?.stringValue,
                rotoColors: rack.child(named: "rotoColors")?["json"]?.stringValue,
                tempoSync: rack.child(named: "tempoSync")?["enabled"]?.boolValue)
            if let stamp = rack["exportedAt"]?.stringValue,
               let date = timestampFormatter.date(from: stamp)
            {
                snapshot.exportedAt = date
            }
        }

        for node in nodes where node.name == "slot" {
            guard let index = node.args.first?.intValue else { continue }
            let drafts = node.children(named: "draft").map { child in
                Draft(
                    id: child["id"]?.stringValue.flatMap(UUID.init(uuidString:)) ?? UUID(),
                    componentType: UInt32(child["type"]?.intValue ?? 0),
                    componentSubType: UInt32(child["subType"]?.intValue ?? 0),
                    componentManufacturer: UInt32(child["manufacturer"]?.intValue ?? 0),
                    name: child["name"]?.stringValue ?? "",
                    gain: Float(child["gain"]?.doubleValue ?? 0.8),
                    state: child["state"]?.stringValue.flatMap { blobs[$0] },
                    knobs: knobs(in: child),
                    savedAt: child["savedAt"]?.stringValue.flatMap(timestampFormatter.date(from:))
                        ?? Date(timeIntervalSince1970: 0))
            }
            let defaultSnapshot = node.child(named: "default").map { child in
                Draft(
                    id: child["id"]?.stringValue.flatMap(UUID.init(uuidString:)) ?? UUID(),
                    componentType: UInt32(child["type"]?.intValue ?? 0),
                    componentSubType: UInt32(child["subType"]?.intValue ?? 0),
                    componentManufacturer: UInt32(child["manufacturer"]?.intValue ?? 0),
                    name: child["name"]?.stringValue ?? "",
                    gain: Float(child["gain"]?.doubleValue ?? 0.8),
                    state: child["state"]?.stringValue.flatMap { blobs[$0] },
                    knobs: knobs(in: child),
                    savedAt: child["savedAt"]?.stringValue.flatMap(timestampFormatter.date(from:))
                        ?? Date(timeIntervalSince1970: 0))
            }
            snapshot.slots.append(
                SlotSnapshot(
                    index: index,
                    componentType: UInt32(node["type"]?.intValue ?? 0),
                    componentSubType: UInt32(node["subType"]?.intValue ?? 0),
                    componentManufacturer: UInt32(node["manufacturer"]?.intValue ?? 0),
                    name: node["name"]?.stringValue ?? "",
                    gain: Float(node["gain"]?.doubleValue ?? 0.8),
                    mute: node["mute"]?.boolValue,
                    rotoColor: node["rotoColor"]?.intValue.map(UInt8.init),
                    customName: node["customName"]?.stringValue,
                    state: node["state"]?.stringValue.flatMap { blobs[$0] },
                    knobs: knobs(in: node),
                    drafts: drafts.isEmpty ? nil : drafts,
                    defaultSnapshot: defaultSnapshot))
        }
        return snapshot
    }

    private static func knobs(in node: KDLNode) -> [FaceKnobMapping]? {
        let mappings = node.children(named: "knob").compactMap { child -> FaceKnobMapping? in
            guard let cc = child["cc"]?.intValue, let address = child["address"]?.intValue
            else { return nil }
            return FaceKnobMapping(
                knob: cc, address: UInt64(address), name: child["name"]?.stringValue ?? "",
                alias: child["alias"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 },
                color: child["color"]?.intValue.flatMap { $0 >= 0 ? UInt8(exactly: $0) : nil })
        }
        return mappings.isEmpty ? nil : mappings
    }

    // MARK: - 部分ロード

    /// 選んだ席だけを取り出して RackSnapshot に仕立てる（部分ロードの本体）。
    /// 席番号は**書き出し時の番号**で選ぶ。globals を含めるかは別途選べる
    func partial(slotIndices: Set<Int>, includeGlobals: Bool) -> RackSnapshot {
        var snapshot = RackSnapshot(
            slots: slots.filter { slotIndices.contains($0.index) },
            selected: includeGlobals ? (globals.selected ?? 0) : 0)
        // ドラム席の解決規約（index = 保存時のトラック総数）に必要なので
        // trackCount は部分ロードでも必ず載せる
        snapshot.trackCount = globals.trackCount
        if includeGlobals {
            snapshot.outputDeviceUID = globals.outputDeviceUID
            snapshot.keyRoot = globals.keyRoot
            snapshot.keyScale = globals.keyScale
            snapshot.ledFeedback = globals.ledFeedback
            snapshot.theme = globals.theme
            snapshot.pedalMode = globals.pedalMode
            snapshot.pedalInverted = globals.pedalInverted
            snapshot.synthInput1Slot = globals.synthInput1Slot
            snapshot.secondKeyboardSlot = globals.secondKeyboardSlot
            snapshot.keystage = globals.keystage
            snapshot.rotoColors = globals.rotoColors
            snapshot.tempoSync = globals.tempoSync
        }
        return snapshot
    }

    /// 選択 UI に出す一覧（席番号・名前・音色の有無・棚の数）
    var contents: [(index: Int, name: String, hasState: Bool, drafts: Int)] {
        slots.sorted { $0.index < $1.index }.map {
            ($0.index, $0.name, $0.state != nil, $0.drafts?.count ?? 0)
        }
    }
}
