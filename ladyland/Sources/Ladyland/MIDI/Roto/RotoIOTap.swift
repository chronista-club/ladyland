//! ROTO の I/O デバッグ環境（mako 依頼 2026-08-11「ROTO からの信号の IO の
//! デバッグ環境整える？であなたもリアルタイムで書けるのも用意する」）。
//!
//! ## 2 つの口
//!
//! 1. **Tap（見る）** — ROTO の送受信全部を
//!    `~/Library/Application Support/ladyland/roto-io.jsonl` へ 1 行 1 通で
//!    追記する（時刻 + 方向 + 生バイト + 解読注釈）。エージェントは
//!    `tail -f` / `rg` でリアルタイムに読める
//! 2. **Inject（書く）** — 仮想 MIDI ポート **「Ladyland RotoInject」**
//!    （`RotoService` が公開）へ送った MIDI/SysEx を、アプリが
//!    **`RotoSendQueue` 経由で** ROTO へ中継する。
//!    ⭐ **送信順序の規律（1 本のキュー）を壊さずに外から書ける** —
//!    アプリを止めて RigBench を立てる往復が要らなくなる。
//!    注入も Tap に `inject` として残る
//!
//! ⚠️ MIDI Clock（F8、毎秒 24×）は受信経路の手前で落ちているので
//! ここには来ない — ログが洗い流される心配はない（実測 2026-08-04 の教訓）
//!
//! ## ⚠️⚠️ 注入の掟（実測 2026-08-11。Creo `mem_1CdvSucMFyzZ4BEpFgJVpX`）
//!
//! **セッション状態を持つメッセージ（`0A 01` dawStart を含む init 再生）を
//! 注入してはいけない** — アプリの握手と二重になり、**実機の MIDI 出力が
//! 全停止する**（表示は生き残るのでタチが悪い。同日 2 周期で再現）。
//! 「LED が消えない」「窓の外では書けない」等の否定測定は全部、この毒で
//! 半死にの実機を相手にした誤測定だった。
//! **状態なしのメッセージ（track 枠 `0A 11` / RK LED の CC / モーター）は
//! 単発注入して安全** — 健全なセッションなら途中でも効く

import Foundation

/// 送受信を JSONL へ落とす小さな帳簿。書き込みは専用キュー（RT を塞がない）
final class RotoIOTap: @unchecked Sendable {
    static let shared = RotoIOTap()

    private let queue = DispatchQueue(label: "ladyland.roto.iotap", qos: .utility)
    private var handle: FileHandle?
    private var written = 0

    /// 1 ファイルの上限（超えたら `.1` へ回して書き直す — 無限に太らせない）
    private static let rotateBytes = 5_000_000

    private static var url: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ladyland/roto-io.jsonl")
    }

    /// 1 行ぶんの JSON（純関数 — テスト対象）。
    /// note には Roto.describe 等の解読を入れる（無ければ省略）
    static func line(t: String, dir: String, bytes: [UInt8], note: String?) -> String {
        let hex = bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
        var out = "{\"t\":\"\(t)\",\"dir\":\"\(dir)\",\"hex\":\"\(hex)\""
        if let note {
            let escaped = note
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            out += ",\"note\":\"\(escaped)\""
        }
        return out + "}\n"
    }

    func log(_ dir: String, _ bytes: [UInt8], note: String? = nil) {
        let now = Date()
        queue.async { [self] in
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm:ss.SSS"
            let text = Self.line(t: formatter.string(from: now), dir: dir, bytes: bytes, note: note)
            append(text)
        }
    }

    private func append(_ text: String) {
        let data = Data(text.utf8)
        if handle == nil { open() }
        guard let handle else { return }
        do {
            try handle.write(contentsOf: data)
            written += data.count
            if written > Self.rotateBytes { rotate() }
        } catch {
            self.handle = nil  // 次の行で開き直す
        }
    }

    private func open() {
        let url = Self.url
        let fm = FileManager.default
        try? fm.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: url)
        _ = try? handle?.seekToEnd()
        written = (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
    }

    private func rotate() {
        try? handle?.close()
        handle = nil
        written = 0
        let url = Self.url
        let old = url.deletingPathExtension().appendingPathExtension("1.jsonl")
        try? FileManager.default.removeItem(at: old)
        try? FileManager.default.moveItem(at: url, to: old)
    }
}
