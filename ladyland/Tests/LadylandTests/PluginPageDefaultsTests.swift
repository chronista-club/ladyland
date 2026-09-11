//! プラグインの Page 既定 — KDL 保存 / ロードの round-trip
//! （mako 要望 2026-08-14「プラグイン自体の default として保存」
//! 「json を kdl（scheme 付き）にしたら、読みやすくなるかな？」）

import Foundation
import Testing

@testable import Ladyland

@Suite("プラグインの Page 既定")
struct PluginPageDefaultsTests {
    private var sample: PluginPageDefaults {
        var store = PluginPageDefaults()
        store.set(
            .init(
                knobs: [
                    FaceKnobMapping(knob: 0, address: 22, name: "VCF Cutoff", color: 71),
                    FaceKnobMapping(knob: 1, address: 23, name: "VCF Resonance", alias: "Reso"),
                ],
                cellColors: [0: 71, 8: 36]),
            for: "Montpellier (Mono/Poly)")
        return store
    }

    /// 保存 → ロードで割当と席色がそのまま戻る（KDL ディスク round-trip）
    @Test func 保存とロードの往復() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("page-defaults-test-\(UUID().uuidString).kdl")
        defer { try? FileManager.default.removeItem(at: url) }

        let store = sample
        store.save(to: url)
        let restored = PluginPageDefaults.load(from: url)
        #expect(restored == store)
        #expect(restored.entry(for: "Firenze (Electric Piano)") == nil)
    }

    /// KDL の見た目 — 人が読める形で並びが決定的（diff が読める控え）
    @Test func KDLの形() {
        let text = sample.kdlText()
        #expect(text.contains("plugin \"Montpellier (Mono/Poly)\" {"))
        // パラメータ色（Option — 無い knob には属性ごと出ない）
        #expect(text.contains("    knob at=0 address=22 name=\"VCF Cutoff\" color=71\n"))
        #expect(text.contains("    knob at=1 address=23 name=\"VCF Resonance\" alias=\"Reso\"\n"))
        #expect(text.contains("    cell 0 color=71\n"))
        #expect(text.contains("    cell 8 color=36\n"))
    }

    /// 名前の中の引用符・バックスラッシュ・改行はエスケープして往復する
    @Test func エスケープの往復() {
        var store = PluginPageDefaults()
        store.set(
            .init(
                knobs: [FaceKnobMapping(knob: 3, address: 7, name: #"Say "\ hi"#)],
                cellColors: [:]),
            for: #"odd "name\"#)
        let restored = PluginPageDefaults.parse(store.kdlText())
        #expect(restored == store)
    }

    /// 旧 JSON（2026-08-14 初版）からの移行 — .kdl が無ければ同名 .json を読む
    @Test func 旧JSONからの移行() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("page-defaults-test-\(UUID().uuidString)")
        let kdlURL = base.appendingPathExtension("kdl")
        let jsonURL = base.appendingPathExtension("json")
        defer {
            try? FileManager.default.removeItem(at: kdlURL)
            try? FileManager.default.removeItem(at: jsonURL)
        }
        let data = try JSONEncoder().encode(sample)
        try data.write(to: jsonURL)
        #expect(PluginPageDefaults.load(from: kdlURL) == sample)
    }

    /// 同じプラグインへの保存は上書き（最後に保存した姿が default）
    @Test func 保存は上書き() {
        var store = PluginPageDefaults()
        store.set(.init(knobs: [], cellColors: [0: 1]), for: "Berlin")
        store.set(.init(knobs: [], cellColors: [0: 2]), for: "Berlin")
        #expect(store.entry(for: "Berlin")?.cellColors == [0: 2])
    }

    /// ファイルが無ければ空で始まる（初回起動）
    @Test func 無ければ空() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("does-not-exist-\(UUID().uuidString).kdl")
        #expect(PluginPageDefaults.load(from: missing) == PluginPageDefaults())
    }
}

/// fieldd の版握手 — --version 出力（「名前 版」）から素の版を取り出す。
/// プレフィクス差で同版を「別版」と誤判定し、30 秒ごとの Shutdown → spawn
/// ループになった実例（2026-08-15）の回帰
@Suite("fieldd の版パース")
struct FieldVersionParseTests {
    @Test func 名前つき出力から版だけ取り出す() {
        #expect(FieldLink.parseVersionOutput("fieldd 0.1.0+1786765142\n") == "0.1.0+1786765142")
    }
    @Test func 素の版はそのまま() {
        #expect(FieldLink.parseVersionOutput("0.1.0+1786765142") == "0.1.0+1786765142")
    }
    @Test func 空は失敗() {
        #expect(FieldLink.parseVersionOutput("  \n") == nil)
    }
}
