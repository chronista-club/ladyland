//! Gadget つまみ配置の spec を読む（spec/06-gadget-knob-map.kdl の How 側）。
//!
//! mako 要望 2026-08-04「kdl spec 化して利用出来たら最高」。
//!
//! **spec は「前に出すもの」だけ決める** — P1（ROTO の 1 画面 = 演奏中に手が
//! 届く 8 本）に何を置くかを人が書き、残りは AU の並び順で後ろへ自動的に
//! 敷き詰める（`FaceKnobAssignment.fillingDefaults`）。全パラメータの配置を
//! 書き切る必要は無い。
//!
//! ⚠️ **パーサは spec/06 が使う範囲だけの部分実装**。KDL の完全な文法
//! （型注釈・生文字列・複数行・スラッシュダッシュ等）は扱わない。
//! 読むのは `gadget "名前" { page N { knob at=N param="名前" } }` の形だけで、
//! それ以外のノード（fact / rule / note）は読み飛ばす。

import Foundation

/// 1 機種ぶんの配置
struct GadgetKnobMap: Equatable {
    /// AU の表示名（実機と一致していること）
    let gadget: String
    /// ページ番号（1 始まり）→ ページ内位置（1-8）→ パラメータ名
    let pages: [Int: [Int: String]]

    /// マトリクス座標（0 始まりの CC 番号）→ パラメータ名 に展開する。
    /// P(page)-(at) → CC (page-1)*8 + (at-1)
    var byCell: [Int: String] {
        var out: [Int: String] = [:]
        for (page, knobs) in pages {
            for (at, name) in knobs where (1...8).contains(at) && page >= 1 {
                out[(page - 1) * 8 + (at - 1)] = name
            }
        }
        return out
    }
}

enum GadgetKnobMapLoader {
    /// spec/06 を読んで機種名 → 配置 の辞書にする。
    /// 読めなければ空（spec が無くても ladyland は動く — 自動配置に落ちる）
    static func load(from url: URL) -> [String: GadgetKnobMap] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        return parse(text)
    }

    /// リポジトリ同梱の spec を探す（開発時はソースの隣、配布時はバンドル内）
    static func loadDefault() -> [String: GadgetKnobMap] {
        if let bundled = Bundle.main.url(forResource: "06-gadget-knob-map", withExtension: "kdl"),
            let maps = Optional(load(from: bundled)), !maps.isEmpty {
            return maps
        }
        // 開発時: リポジトリの spec/ を辿る
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<6 {
            let candidate = directory.appendingPathComponent("spec/06-gadget-knob-map.kdl")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return load(from: candidate)
            }
            directory = directory.deletingLastPathComponent()
        }
        return [:]
    }

    /// **部分パーサ** — spec/06 の `gadget` / `page` / `knob` だけを拾う。
    /// 純関数（テスト対象）
    static func parse(_ text: String) -> [String: GadgetKnobMap] {
        var maps: [String: GadgetKnobMap] = [:]
        var gadget: String?
        var page: Int?
        var pages: [Int: [Int: String]] = [:]

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            // 行コメントを落とす（"//" が文字列の中に無い前提 — spec/06 では成立）
            let line = rawLine.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
                .first.map(String.init)?
                .trimmingCharacters(in: .whitespaces) ?? ""
            guard !line.isEmpty else { continue }

            if let name = capture(line, prefix: "gadget ") {
                // 前の機種を閉じる
                if let gadget, !pages.isEmpty {
                    maps[gadget] = GadgetKnobMap(gadget: gadget, pages: pages)
                }
                gadget = name
                pages = [:]
                page = nil
                continue
            }
            if line.hasPrefix("page "), let number = firstInt(after: "page ", in: line) {
                page = number
                pages[number] = pages[number] ?? [:]
                continue
            }
            if line.hasPrefix("knob "), let gadget, let page,
                let at = value(of: "at", in: line).flatMap(Int.init),
                let param = quoted(after: "param=", in: line) {
                _ = gadget
                pages[page, default: [:]][at] = param
                continue
            }
            // 機種ブロックの終わり（インデント 4 の閉じ括弧）
            if rawLine.hasPrefix("    }"), let name = gadget, !pages.isEmpty {
                maps[name] = GadgetKnobMap(gadget: name, pages: pages)
                gadget = nil
                pages = [:]
                page = nil
            }
        }
        if let gadget, !pages.isEmpty {
            maps[gadget] = GadgetKnobMap(gadget: gadget, pages: pages)
        }
        return maps
    }

    // MARK: - 小道具（KDL の部分抽出）

    /// `gadget "Lisbon (Sci-Fi)" au-name=…` → `Lisbon (Sci-Fi)`
    private static func capture(_ line: String, prefix: String) -> String? {
        guard line.hasPrefix(prefix) else { return nil }
        return quoted(after: prefix, in: line)
    }

    /// 先頭の `"…"` を取り出す
    private static func quoted(after marker: String, in line: String) -> String? {
        guard let start = line.range(of: marker) else { return nil }
        let rest = line[start.upperBound...]
        guard let open = rest.firstIndex(of: "\"") else { return nil }
        let afterOpen = rest.index(after: open)
        guard let close = rest[afterOpen...].firstIndex(of: "\"") else { return nil }
        return String(rest[afterOpen..<close])
    }

    /// `at=3` → `3`
    private static func value(of key: String, in line: String) -> String? {
        guard let range = line.range(of: "\(key)=") else { return nil }
        let rest = line[range.upperBound...]
        let token = rest.prefix { !$0.isWhitespace && $0 != "\"" }
        return token.isEmpty ? nil : String(token)
    }

    /// `page 1 {` → `1`
    private static func firstInt(after marker: String, in line: String) -> Int? {
        guard let range = line.range(of: marker) else { return nil }
        let rest = line[range.upperBound...]
        let digits = rest.prefix { $0.isNumber }
        return Int(digits)
    }
}
