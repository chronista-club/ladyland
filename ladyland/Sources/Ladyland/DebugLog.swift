//! アプリ内デバッグログ（design/06 §8 追補、mako 要望 2026-07-31）。
//!
//! NSLog は stderr に出る — その stderr をパイプで横取りして自前バッファに
//! 取り込む。既存の NSLog 呼び出しは無変更で全部乗り、元の stderr にも
//! 書き戻すので `swift run` のターミナル出力・ログファイル捕捉は死なない。
//!
//! ⚠️ readabilityHandler の中で NSLog を呼ぶと stderr → パイプ → handler の
//! 無限ループになる。ここではログ出力を一切しないこと。

import Foundation

@MainActor
final class DebugLog: ObservableObject {
    /// 行の出所（mako 要望 2026-08-04「常時 MIDI は見れた方がいい」）。
    /// stderr の NSLog と MIDI トレースが同じ川に流れるので、**混ざると
    /// MIDI が埋もれる**。種別を持たせて絞れるようにする
    enum Kind: String, CaseIterable {
        /// stderr 捕捉（NSLog 全般）
        case system
        /// MIDIRouter のルーティング判断（MidiTrace）
        case midi
    }

    struct Line: Identifiable, Equatable {
        let id: Int
        var text: String
        var kind: Kind = .system

        /// collapse（下記 append）で畳まれた回数。1 = 畳みなし
        var count: Int = 1

        /// 表示用テキスト（畳まれていたら ×N を付ける）
        var displayText: String { count > 1 ? "\(text) ×\(count)" : text }
    }

    /// 保持する最大行数（超えたら古い方から捨てるリングバッファ）
    static let capacity = 500

    /// ⚠️ **`@Published` にしない**（mako 要望 2026-08-04「動作コスト抑えめで。
    /// あくまで確認用という目的で」）。
    ///
    /// ノブを 1 回転させると MIDI トレースが数十回来る。1 行ごとに publish
    /// すると SwiftUI がその回数だけ再描画され、**演奏中の負荷になる**。
    /// collapse（×N）は表示行を減らすだけでコストは減らない — `count += 1`
    /// でも publish は起きるため。代わりに `revision` を間引いて流す
    private(set) var lines: [Line] = []

    /// 画面更新の合図。**溜めて `flushInterval` ごとに 1 回だけ**進める。
    /// 見ている側（DebugLogView）はこれを購読するので、再描画は最大 8fps
    @Published private(set) var revision = 0

    /// 間引き間隔（確認用の目なので 120ms で十分に読める）
    static let flushInterval = Duration.milliseconds(120)

    private var flushScheduled = false
    private var nextID = 0

    // MARK: - ファイルへの書き出し

    /// ログの書き出し先。
    ///
    /// mako 提案 2026-08-04「ライン毎に id が振られてて、それが DB にあったら、
    /// このログってあなたに渡せるね」。**エージェントが直接読めること**が目的 —
    /// NSLog は stderr にしか出ず（`log show` では拾えない）、実機で起きたことを
    /// 人が口頭で伝える往復が発生していた。
    ///
    /// SQLite ではなく素のテキストにしたのは、**壊れた状態でも読める**から。
    /// 追う対象がクラッシュや無反応のとき、DB は開けないことがある
    static var fileURL: URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("ladyland/debug.log")
    }

    private var fileHandle: FileHandle?
    /// ファイルへ書き終えた行の id（collapse 中の最終行は書かない）
    private var writtenUpTo = -1

    /// 起動時に一度だけ。**前回分は `.prev` へ退避**する —
    /// 落ちた直後に前回のセッションを見たいことがある
    func startFileLog() {
        let url = Self.fileURL
        let fm = FileManager.default
        try? fm.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let previous = url.appendingPathExtension("prev")
        try? fm.removeItem(at: previous)
        try? fm.moveItem(at: url, to: previous)
        fm.createFile(atPath: url.path, contents: nil)
        fileHandle = try? FileHandle(forWritingTo: url)
    }

    /// 確定した行を追記する（**最終行は保留** — collapse で ×N が伸びるため）
    private func writeToFile() {
        guard let fileHandle, lines.count > 1 else { return }
        let settled = lines.dropLast().filter { $0.id > writtenUpTo }
        guard !settled.isEmpty else { return }
        let text = settled.map { "[\($0.id)] \($0.kind.rawValue)\t\($0.displayText)" }
            .joined(separator: "\n") + "\n"
        try? fileHandle.write(contentsOf: Data(text.utf8))
        writtenUpTo = settled.last!.id
    }

    /// 直前行の collapse key（連続判定用。stderr 行 = nil が挟まると切れる）
    private var lastCollapseKey: String?

    /// 捕捉パイプの保持（これが無いと ARC が read 端を閉じ、以降の stderr
    /// 書き込みが SIGPIPE でプロセスごと落ちる — 実機で exit 141 を踏んだ）
    private var capturePipe: Pipe?

    /// 行を追加する。collapseKey が直前行と同じなら追記せず最後の行を
    /// 置き換えて ×N を積む — 連続ストリーム（ノブ CC・AT・PB）が
    /// ログを洗い流すのを防ぐ（MidiTrace の設計。nil は常に追記）
    func append(_ text: String, collapseKey: String? = nil, kind: Kind = .system) {
        defer { scheduleFlush() }
        if let collapseKey, collapseKey == lastCollapseKey, !lines.isEmpty {
            lines[lines.count - 1].text = text
            lines[lines.count - 1].count += 1
            return
        }
        lastCollapseKey = collapseKey
        lines.append(Line(id: nextID, text: text, kind: kind))
        nextID += 1
        if lines.count > Self.capacity {
            lines.removeFirst(lines.count - Self.capacity)
        }
    }

    /// 溜まった変更を 1 回の再描画にまとめる。
    /// 予約済みなら何もしない — **何行来ても 120ms に 1 回**
    private func scheduleFlush() {
        guard !flushScheduled else { return }
        flushScheduled = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.flushInterval)
            self?.flushScheduled = false
            self?.revision &+= 1
            self?.writeToFile()
        }
    }

    func clear() {
        lines = []
        lastCollapseKey = nil
        revision &+= 1  // 消したことは即座に見えてよい
        // ⚠️ ファイル側は消さない — **画面を掃除しても記録は残す**のが筋
        // （追っている最中に消してしまうと、それまでの手掛かりが失われる）
    }

    /// フィルタ適用（純関数 — テスト対象）。
    /// `kinds` に絞ってから文字列で当てる（MIDI だけ見たいときに使う）
    static func filter(_ lines: [Line], query: String, kinds: Set<Kind>? = nil) -> [Line] {
        var out = lines
        if let kinds { out = out.filter { kinds.contains($0.kind) } }
        guard !query.isEmpty else { return out }
        return out.filter { $0.text.localizedCaseInsensitiveContains(query) }
    }

    // MARK: - stderr 捕捉

    /// stderr をパイプ経由で横取りする（起動時に一度だけ呼ぶ）
    func startCapture() {
        guard capturePipe == nil else { return }
        let pipe = Pipe()
        capturePipe = pipe
        let original = dup(STDERR_FILENO)
        dup2(pipe.fileHandleForWriting.fileDescriptor, STDERR_FILENO)

        let assembler = LineAssembler()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            // 元の stderr へ書き戻す（ターミナル/ログファイルを殺さない）
            data.withUnsafeBytes { _ = write(original, $0.baseAddress, data.count) }

            // 行単位に切って main へ（部分行は assembler が持ち越す。
            // readabilityHandler は 1 本の fd につき直列なのでロック不要）
            let linesOut = assembler.feed(data)
            guard !linesOut.isEmpty else { return }
            Task { @MainActor [weak self] in
                for line in linesOut {
                    self?.append(line)
                }
            }
        }
    }
}

/// バイト列 → 行の組み立て（部分行の持ち越し。直列コールバック内で使う）
private final class LineAssembler: @unchecked Sendable {
    private var residual = Data()

    func feed(_ data: Data) -> [String] {
        residual.append(data)
        var lines: [String] = []
        while let newline = residual.firstIndex(of: 0x0A) {
            let lineData = residual[residual.startIndex..<newline]
            residual.removeSubrange(residual.startIndex...newline)
            if let text = String(data: lineData, encoding: .utf8), !text.isEmpty {
                lines.append(text)
            }
        }
        return lines
    }
}
