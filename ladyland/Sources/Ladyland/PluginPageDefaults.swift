//! プラグインごとの Page 既定（mako 要望 2026-08-14「Track の Page の
//! set / load default。プラグイン自体の default として保存」）。
//!
//! 作り込んだ配置（顔つまみ割当 + 席色）を**プラグイン名キー**で控え、
//! 同じプラグインを積んだ別トラック（や後日の自分・別マシン）にロードする。
//! spec/06（リポジトリ同梱の出荷既定）に対し、こちらは**手元で育てた
//! 自分の既定** — Application Support に住み、保存のたび丸ごと上書き。
//!
//! ## 形式は KDL（mako 要望 2026-08-14「json を kdl（scheme 付き）にしたら、
//! 読みやすくなるかな？」）
//!
//! スキーマは `spec/07-page-defaults.schema.kdl`（club-kdl-codegen の
//! data dialect）。読み書きは**自前の部分実装** — kdl-swift は KDL v1 のみで
//! club-kdl（v2 系）と文法が食い違うため、依存は足さず spec/06 の
//! `GadgetKnobMapLoader` と同じ流儀で page-defaults が使う範囲だけを扱う。
//! 旧 JSON（page-defaults.json、2026-08-14 の初版）は読み込みだけ残し、
//! 次の保存で KDL へ移行する。
//!
//! ```kdl
//! plugin "Montpellier (Mono/Poly)" {
//!     knob at=0 address=22 name="VCF Cutoff"
//!     knob at=1 address=23 name="VCF Resonance" alias="Reso"
//!     cell 0 color=71
//! }
//! ```

import Foundation

struct PluginPageDefaults: Codable, Equatable {
    /// 1 プラグインぶんの Page 設計（Track 面で編集できるものの写し）
    struct Entry: Codable, Equatable {
        var knobs: [FaceKnobMapping]
        /// 席色（`Roto.Colors.trackCells` の 1 トラックぶん。cc → 色 index）
        var cellColors: [Int: UInt8]
    }

    private var entries: [String: Entry] = [:]

    func entry(for plugin: String) -> Entry? { entries[plugin] }

    mutating func set(_ entry: Entry, for plugin: String) {
        entries[plugin] = entry
    }

    // MARK: - 置き場所（差分焼きの影 roto-shadow.json と同じ作法）

    static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ladyland/page-defaults.kdl")
    }

    /// KDL を読む。無ければ旧 JSON（同名 .json）を読んで移行の入口にする。
    /// どちらも無ければ空（初回起動）
    static func load(from url: URL = defaultURL) -> PluginPageDefaults {
        if let text = try? String(contentsOf: url, encoding: .utf8) {
            return url.pathExtension == "json" ? loadJSON(text) : parse(text)
        }
        let legacy = url.deletingPathExtension().appendingPathExtension("json")
        if let text = try? String(contentsOf: legacy, encoding: .utf8) {
            return loadJSON(text)
        }
        return PluginPageDefaults()
    }

    private static func loadJSON(_ text: String) -> PluginPageDefaults {
        (try? JSONDecoder().decode(PluginPageDefaults.self, from: Data(text.utf8)))
            ?? PluginPageDefaults()
    }

    func save(to url: URL = Self.defaultURL) {
        try? kdlText().write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - KDL 書き出し（決定的な並び — diff が読める控えにする）

    func kdlText() -> String {
        var lines = ["// ladyland page defaults — spec/07-page-defaults.schema.kdl"]
        for (plugin, entry) in entries.sorted(by: { $0.key < $1.key }) {
            lines.append("plugin \(Self.quoted(plugin)) {")
            for knob in entry.knobs.sorted(by: { $0.knob < $1.knob }) {
                var line = "    knob at=\(knob.knob) address=\(knob.address)"
                    + " name=\(Self.quoted(knob.name))"
                if let alias = knob.alias { line += " alias=\(Self.quoted(alias))" }
                if let color = knob.color { line += " color=\(color)" }
                lines.append(line)
            }
            for (cc, color) in entry.cellColors.sorted(by: { $0.key < $1.key }) {
                lines.append("    cell \(cc) color=\(color)")
            }
            lines.append("}")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func quoted(_ text: String) -> String {
        var escaped = ""
        for character in text {
            switch character {
            case "\\": escaped += "\\\\"
            case "\"": escaped += "\\\""
            case "\n": escaped += "\\n"
            default: escaped.append(character)
            }
        }
        return "\"\(escaped)\""
    }

    // MARK: - KDL 部分パーサ（plugin / knob / cell だけ。純関数 — テスト対象）

    static func parse(_ text: String) -> PluginPageDefaults {
        var store = PluginPageDefaults()
        var plugin: String?
        var knobs: [FaceKnobMapping] = []
        var cells: [Int: UInt8] = [:]

        func close() {
            if let plugin { store.entries[plugin] = Entry(knobs: knobs, cellColors: cells) }
            plugin = nil
            knobs = []
            cells = [:]
        }

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("//") else { continue }

            if line.hasPrefix("plugin "), let name = firstQuoted(in: line) {
                close()
                plugin = name
                continue
            }
            if line.hasPrefix("knob "), plugin != nil,
                let at = intValue(of: "at", in: line),
                let address = intValue(of: "address", in: line),
                let name = quotedValue(of: "name", in: line) {
                knobs.append(
                    FaceKnobMapping(
                        knob: at, address: UInt64(address), name: name,
                        alias: quotedValue(of: "alias", in: line),
                        color: intValue(of: "color", in: line)
                            .flatMap { UInt8(exactly: $0) }))
                continue
            }
            if line.hasPrefix("cell "), plugin != nil,
                let cc = Int(line.split(separator: " ").dropFirst().first ?? ""),
                let color = intValue(of: "color", in: line), let byte = UInt8(exactly: color) {
                cells[cc] = byte
                continue
            }
            if line == "}" { close() }
        }
        close()
        return store
    }

    /// 行の最初の `"…"`（エスケープ復元つき）
    private static func firstQuoted(in line: String) -> String? {
        guard let open = line.firstIndex(of: "\"") else { return nil }
        return unescapedString(from: line[line.index(after: open)...])
    }

    /// `key="…"` の値（エスケープ復元つき）
    private static func quotedValue(of key: String, in line: String) -> String? {
        guard let range = line.range(of: "\(key)=\"") else { return nil }
        return unescapedString(from: line[range.upperBound...])
    }

    /// `key=123` の値
    private static func intValue(of key: String, in line: String) -> Int? {
        guard let range = line.range(of: "\(key)=") else { return nil }
        let token = line[range.upperBound...].prefix { $0.isNumber }
        return Int(token)
    }

    /// 開き `"` の直後から閉じ `"` までを、エスケープを解しながら読む
    private static func unescapedString(from rest: Substring) -> String? {
        var result = ""
        var escaping = false
        for character in rest {
            if escaping {
                switch character {
                case "n": result.append("\n")
                default: result.append(character)  // \\ と \" はそのまま実体へ
                }
                escaping = false
            } else if character == "\\" {
                escaping = true
            } else if character == "\"" {
                return result
            } else {
                result.append(character)
            }
        }
        return nil  // 閉じ引用符が無い — 壊れた行は読まない
    }
}
