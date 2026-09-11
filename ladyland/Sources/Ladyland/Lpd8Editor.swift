//! LPD8 mk2 プログラムエディタのモデル + プリセット保存（design/06 §8）。
//!
//! 「今繋いでる機材がどんな設定か目視したい」の実体:
//!   read  = GET (0x03) → 実機の今を deviceCopy として取得（想像ではなく実機バイト）
//!   write = SET (0x01) → 確認ダイアログ → 書き込み → GET-back 照合
//!
//! SET の安全策（8/8 直前にパッド設定を壊さないための多層防御）:
//!   1. GET 済みプログラムしか SET できない（working copy は常に実機由来）
//!   2. codec は実機ゴールデンで byte-exact round-trip 証明済み（Lpd8KitTests）
//!   3. UI の確認ダイアログ
//!   4. SET 後に自動 GET-back して照合（✓ or 不一致エラー）
//!   5. 送受信中は LedBus を suspend（SysEx の混線防止）
//!
//! プリセット層（Profile 構想の層 1）: GET した実機状態に名前を付けて JSON 保存。
//! 「実機だけが設定の保存場所」という怖さを消す — バックアップ・複製・持ち運び。

import CoreMIDI
import Foundation
import Lpd8Kit

/// 名前つきプリセットの保存（~/Library/Application Support/ladyland/profiles/lpd8/）
enum Lpd8PresetStore {
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ladyland/profiles/lpd8")
    }

    static func list(in dir: URL = directory) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.filter { $0.hasSuffix(".json") }
            .map { String($0.dropLast(5)) }
            .sorted()
    }

    static func save(_ program: Lpd8Program, name: String, in dir: URL = directory) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(program)
        try data.write(to: dir.appendingPathComponent("\(name).json"), options: .atomic)
    }

    static func load(name: String, in dir: URL = directory) -> Lpd8Program? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("\(name).json"))
        else { return nil }
        return try? JSONDecoder().decode(Lpd8Program.self, from: data)
    }
}

@MainActor
final class Lpd8EditorModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case reading
        case writing
        case verifying
        case verified
        case error(String)
    }

    @Published var selectedProgram = 1
    /// 編集用 working copy（常に GET 由来）
    @Published var program: Lpd8Program?
    /// 実機から最後に読んだ状態（dirty 判定の基準）
    @Published private(set) var deviceCopy: Lpd8Program?
    @Published private(set) var phase: Phase = .idle
    @Published var presets: [String] = Lpd8PresetStore.list()

    var isDirty: Bool { program != deviceCopy }

    /// 送信口（テストは fake を注入。実体は AppState が CoreMIDI を配線）
    var send: ([UInt8]) -> Bool = { _ in false }
    /// SysEx 送受信ウィンドウの開閉（AppState が LedBus suspend/resume を配線）
    var onBeginSysEx: (() -> Void)?
    var onEndSysEx: (() -> Void)?
    /// GET 成功時（AppState が padNotes 追従を配線）
    var onProgramRead: ((Lpd8Program) -> Void)?

    /// タイムアウト世代（古いタイマーの発火を無効化する）
    private var generation = 0
    private var pendingWrite: Lpd8Program?

    // MARK: - read / write

    func read() {
        guard phase != .reading, phase != .writing, phase != .verifying else { return }
        beginSysEx(.reading)
        sendGetWithTimeout(retriesLeft: 1)
    }

    /// **ladyland の番号規約を当てる**（mako 裁定 2026-08-04）。
    ///
    /// LPD8 はプログラム切替を MIDI で通知しないので、番号が重なっていると
    /// どのプログラムから来たか分からない。プログラムごとにばらしておけば
    /// **受けた番号だけで判別できる**（`Lpd8DefaultPadNotes.program(of:)`）。
    ///
    /// GET 済みのプログラムに当てるだけで、SET はしない — 中身を見てから
    /// 書けるように分けてある。当てた後に `write()` で焼く
    func applyLadylandNumbers() {
        guard var updated = program, (1...4).contains(selectedProgram) else { return }
        let notes = Lpd8DefaultPadNotes.byProgram[selectedProgram - 1]
        let padCCs = Lpd8DefaultPadCCs.byProgram[selectedProgram - 1]
        let ccs = Lpd8DefaultKnobCCs.byProgram[selectedProgram - 1]
        for i in updated.pads.indices where i < notes.count {
            updated.pads[i].note = notes[i]
            // ⚠️ **パッドの CC も焼く**（mako 2026-08-06「基本は Pad は、CC モードに
            // してる想定で」）。ここを放置していたので、CC モードで叩くと
            // 実機の工場出荷値が飛んでいて **ladyland からは何番か分からなかった**
            if i < padCCs.count { updated.pads[i].cc = padCCs[i] }
        }
        for i in updated.knobs.indices where i < ccs.count {
            updated.knobs[i].cc = ccs[i]
        }
        program = updated
    }

    /// **4 プログラム全部に ladyland の番号を焼く**（mako 2026-08-04
    /// 「SysEx とかで上書きできないんだっけ？」）。
    ///
    /// GET → 当てる → SET → 照合 を 1 番から 4 番まで。手で 3 手 × 4 回
    /// やる必要はない。**途中で失敗したら止める** — 中途半端な状態のまま
    /// 次へ進むと、どこまで焼けたか分からなくなる。
    ///
    /// ⚠️ 実機の PROG 1-4 が**まるごと書き換わる**。パッドの色や
    /// チャンネル設定は GET したものを引き継ぐが、**ノート番号と CC は
    /// ladyland の規約で上書きされる**
    func burnAllPrograms() {
        guard phase == .idle || phase == .verified else { return }
        // ⚠️ **`generation` で割り込みを見張らない**（実測 2026-08-06）。
        // `beginSysEx` も応答受信も `generation += 1` するので、**正常な進行でも
        // 必ず食い違う** — 1 周目の `read()` で進み、2 周目の頭で「割り込まれた」と
        // 誤判定して中断していた。多重起動は入口の `phase` ガードで防ぐ
        Task { @MainActor in
            for program in 1...4 {
                NSLog("lpd8: PROG %d — 読み込み", program)
                self.selectedProgram = program
                self.read()
                guard await self.waitForSettled() else {
                    NSLog("lpd8: ⚠️ PROG %d の読み込みで止まった（phase=%@）",
                        program, String(describing: self.phase))
                    self.phase = .error("PROG \(program) の読み込みで止まった")
                    return
                }
                self.applyLadylandNumbers()
                NSLog("lpd8: PROG %d — 番号を当てて書き込み（note %@ / CC %@）",
                    program,
                    "\(Lpd8DefaultPadNotes.byProgram[program - 1].first ?? 0)-",
                    "\(Lpd8DefaultKnobCCs.byProgram[program - 1].first ?? 0)-")
                self.write()
                guard await self.waitForSettled() else {
                    NSLog("lpd8: ⚠️ PROG %d の書き込みで止まった（phase=%@）",
                        program, String(describing: self.phase))
                    self.phase = .error("PROG \(program) の書き込みで止まった")
                    return
                }
                if case .error(let message) = self.phase {
                    NSLog("lpd8: ⚠️ PROG %d で失敗 — %@", program, message)
                    return  // 照合が合わなければ中断
                }
                NSLog("lpd8: PROG %d 完了", program)
            }
            NSLog("lpd8: 4 プログラム全部を焼き終えた")
            self.phase = .verified
        }
    }

    /// 通信が落ち着くまで待つ（読み書きの完了 or 失敗）。
    ///
    /// ⚠️ **「始まった」を待ってから「終わった」を待つ**（実測 2026-08-04）。
    /// `read()` / `write()` は非同期に `phase` を進めるので、呼んだ直後は
    /// まだ `.idle` のことがある。それを完了と読んで次へ進み、
    /// `write()` が「GET 済みでない」と弾かれて止まっていた —
    /// ログに同じミリ秒で「読み込み」→「止まった」が並んでいた。
    ///
    /// ⚠️ **`generation` を見てはいけない**（実測 2026-08-06）。`beginSysEx` が
    /// `generation += 1` するので、`read()` を呼んだ**その瞬間に**進む。
    /// 呼ぶ前に取った `gen` と突き合わせると 1 回目のループで必ず食い違い、
    /// **同じミリ秒で「読み込み」→「止まった」**が並ぶ。
    /// 応答受信（`handleSysEx`）でも上がるので、正常な進行と割り込みを
    /// generation では区別できない — **phase だけで判定する**。
    ///
    /// タイムアウトしたら false — 呼ぶ側が中断を決める
    private func waitForSettled(timeoutMs: Int = 5000) async -> Bool {
        var waited = 0
        var started = false
        while waited < timeoutMs {
            switch phase {
            case .reading, .writing, .verifying:
                started = true  // 動き出した
            case .idle, .verified:
                if started { return true }  // 動き出した後の静止 = 完了
            case .error:
                return false
            }
            try? await Task.sleep(for: .milliseconds(50))
            waited += 50
        }
        return false
    }

    func write() {
        // 安全策 1: GET 済み（deviceCopy あり）でなければ書かない
        guard let program, deviceCopy != nil,
              phase != .reading, phase != .writing, phase != .verifying
        else { return }
        beginSysEx(.writing)
        pendingWrite = program
        guard send(program.encodeSetFrame()) else {
            fail("送信できない（LPD8 が見つからない）")
            return
        }
        // SET には応答がない → 少し置いて GET-back 照合
        let gen = generation
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            guard self.generation == gen else { return }
            self.phase = .verifying
            self.sendGetWithTimeout(retriesLeft: 0)
        }
    }

    /// MIDIInput.sysexRelay から（メインキュー経由で）呼ばれる
    func handleSysEx(_ frame: [UInt8]) {
        guard let decoded = Lpd8Program.decode(frame: frame),
              decoded.program == selectedProgram
        else { return }  // 対象外のフレームは黙って無視（LPD8 は不意に喋らない）

        switch phase {
        case .reading:
            generation += 1
            deviceCopy = decoded
            program = decoded
            phase = .idle
            onProgramRead?(decoded)
            onEndSysEx?()
        case .verifying:
            generation += 1
            deviceCopy = decoded
            if let pendingWrite, decoded == pendingWrite {
                phase = .verified
            } else {
                phase = .error("書き込み照合が一致しない — 実機の状態を read で確認して")
            }
            pendingWrite = nil
            onEndSysEx?()
        default:
            break
        }
    }

    // MARK: - プリセット（Profile 層 1）

    func savePreset(name: String) {
        guard let program, !name.isEmpty else { return }
        do {
            try Lpd8PresetStore.save(program, name: name)
            presets = Lpd8PresetStore.list()
        } catch {
            phase = .error("プリセット保存に失敗: \(error.localizedDescription)")
        }
    }

    /// プリセットを working copy に読み込む（実機にはまだ書かない — SET は明示操作）
    func applyPreset(name: String) {
        guard deviceCopy != nil else { return }  // GET 前は編集自体をさせない
        guard var loaded = Lpd8PresetStore.load(name: name) else { return }
        loaded.program = selectedProgram  // 保存元と違う番号にも当てられる
        program = loaded
    }

    // MARK: - 内部

    private func beginSysEx(_ newPhase: Phase) {
        generation += 1
        phase = newPhase
        onBeginSysEx?()
    }

    private func sendGetWithTimeout(retriesLeft: Int) {
        guard send(Lpd8SysEx.programGetRequest(program: selectedProgram)) else {
            fail("送信できない（LPD8 が見つからない）")
            return
        }
        let gen = generation
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            guard self.generation == gen else { return }  // 応答済みなら何もしない
            if retriesLeft > 0 {
                self.sendGetWithTimeout(retriesLeft: retriesLeft - 1)
            } else {
                self.fail("応答なし（タイムアウト）")
            }
        }
    }

    private func fail(_ message: String) {
        generation += 1
        pendingWrite = nil
        phase = .error(message)
        onEndSysEx?()
    }
}
