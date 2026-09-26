//! CoreMIDI 入力（design/06 §3・§5-4）。
//!
//! デバイス名でルーティング先を分ける:
//!   Keystage → 選択中の楽器スロット（keyboard 経路）
//!   LPD8     → ドラムスロット（drums 経路、持ち替えの影響を受けない）
//!
//! 受信は RT 系スレッドで呼ばれるため、MainActor の Rack を直接触らず、
//! ロックで守られた MIDIRouter に現在の送り先 AU を持たせて直接 send する。
//!
//! Realtime フィルタ: Keystage は MIDI Clock (F8) を常時送信し止められない。
//! UMP の MessageType=2（MIDI 1.0 チャンネルボイス）だけを通すことで、
//! System Real-Time / Common は入力段で自然に落ちる。

import AVFoundation
import CoreMIDI
import KeystageKit
import Lpd8Kit

/// UMP（Universal MIDI Packet）の解析 — 純関数（テスト対象）
enum UMP {
    /// UMP 32bit ワードから MIDI 1.0 チャンネルボイスメッセージを取り出す。
    ///
    /// レイアウト: [31:28] MessageType, [27:24] group, [23:16] status, [15:8] data1, [7:0] data2。
    /// MessageType 2（MIDI 1.0 channel voice）以外は nil — System Real-Time
    /// （Keystage が止められず常時送信する MIDI Clock 0xF8 など）や
    /// System Common はここで自然に落ちる（design/06 §5-4 Realtime フィルタ）。
    static func parseChannelVoice(_ word: UInt32) -> (status: UInt8, data1: UInt8, data2: UInt8)? {
        let messageType = UInt8((word >> 28) & 0xF)
        guard messageType == 2 else { return nil }
        // ⚠️ **ステータスバイトでない値を弾く**（実測 2026-08-05: 差し直しの
        // 直後に `status=44` `3A` `72` が届いた — どれも 0x80 未満で、
        // MIDI のステータスにはなり得ない）。
        //
        // 壊れた UMP をそのまま流すと、**楽器へ意味不明なバイト列が届く**。
        // ノート番号やパラメータが化ける類の事故になる
        let status = UInt8((word >> 16) & 0xFF)
        guard status >= 0x80 else { return nil }
        return (
            status: status,
            data1: UInt8((word >> 8) & 0x7F),
            data2: UInt8(word & 0x7F)
        )
    }
}

/// **MIDI Clock から BPM を割り出す**（mako 相談 2026-08-05「Keystage で
/// Tempo を送信してると思うんだけど、これを ladyland が受信できないかな？」）。
///
/// Keystage は BPM を設定できて LED が点滅する = **MIDI Clock (F8) を送っている**。
/// ただし ladyland は入力段で落としていた — `UMP.parseChannelVoice` が
/// MessageType 2 だけを通す作りで、Clock（MessageType 1）はそこで捨てられる。
/// 「Keystage が止められない Clock でログを埋めないため」の意図的な設計だったが、
/// **テンポという情報まで一緒に捨てていた**。
///
/// MIDI Clock は**四分音符あたり 24 個**。24 個ぶんの経過時間が 1 拍なので、
/// `BPM = 60 / 1拍の秒数`。RT スレッドから呼ばれるのでロックで守る。
final class MidiClockTracker: @unchecked Sendable {
    /// 1 拍あたりの clock 数（MIDI 仕様。機種によらず 24）
    static let ticksPerBeat = 24

    /// **測る窓の長さ**（mako 裁定 2026-08-05「4 拍にしよう」）。
    ///
    /// 1 拍（24 tick）だけで測っていたときは、Clock の間隔が数十マイクロ秒
    /// ぶれるだけで **±0.5 BPM の揺れ**になり、120.0 → 119.5 → 120.5 を
    /// 1 秒に 4 回も往復していた。ヒステリシスの幅とちょうど同じだったので
    /// 抑えきれない。
    ///
    /// 4 拍に広げると揺れが 1/4 に均される。テンポ変更への追従は 3 拍ぶん
    /// 遅くなるが、演奏中に刻々と変えるものではないので実害は無い
    static let measureBeats = 4
    private static var windowTicks: Int { ticksPerBeat * measureBeats }

    private let lock = NSLock()
    /// 直近の tick 到着時刻（`windowTicks + 1` 個保つ = 4 拍ぶんの区間）
    private var timestamps: [UInt64] = []
    private var lastReported: Double?

    /// 🧪 **ソース別の tick 数**（観測用。mako 指示 2026-08-05「まずはどんな
    /// 情報がくるかの確認」）。
    ///
    /// `Keystage KBD/CTRL` と `Keystage DAW IN` の**2 本が同じポートに繋がって
    /// いる**ので、両方が F8 を出すと 1 拍 48 tick になり BPM が 2 倍に読める。
    /// どのソースが何個送っているかを数えて、1 秒ごとに 1 行だけ出す
    /// （毎 tick 出すと 1 秒 48 行でログが埋まる）
    private var ticksBySource: [Int: Int] = [:]
    private var lastReportNs: UInt64 = 0

    /// 集計結果（1 秒ぶん）。報告する分だけ返して帳簿を空にする
    struct Census: Sendable {
        /// ソース番号（`connRefCon` の値）→ 1 秒あたりの tick 数
        let ticksBySource: [Int: Int]
        let elapsedSeconds: Double
    }

    /// 1 秒経っていれば集計を返す（それ以外は nil）
    private func censusIfDue(now: UInt64) -> Census? {
        guard lastReportNs != 0 else {
            lastReportNs = now
            return nil
        }
        let elapsed = Double(now &- lastReportNs) / 1_000_000_000
        guard elapsed >= 1.0 else { return nil }
        let census = Census(ticksBySource: ticksBySource, elapsedSeconds: elapsed)
        ticksBySource.removeAll()
        lastReportNs = now
        return census
    }

    /// tick を 1 つ受ける。**1 拍たまるたび**に BPM を返す（それ以外は nil）。
    /// `source` は接続時に渡した識別子（どのエンドポイントから来たか）
    func tick(atNanos now: UInt64, source: Int = 0) -> (bpm: Double?, census: Census?) {
        lock.lock()
        defer { lock.unlock() }
        ticksBySource[source, default: 0] += 1
        let census = censusIfDue(now: now)
        return (bpmLocked(now: now), census)
    }

    /// 旧シグネチャ（テスト用）— BPM だけ返す
    func tick(atNanos now: UInt64) -> Double? {
        lock.lock()
        defer { lock.unlock() }
        return bpmLocked(now: now)
    }

    /// **測り始めの捨て拍**（mako 裁定 2026-08-05）。
    ///
    /// 起動直後の 24 tick には握手・プラグイン復元の負荷が混ざって間隔が伸び、
    /// 実機 102 BPM が 67.1 と読めた。しかもヒステリシス（0.5 BPM）のせいで
    /// **そこから更新されず張り付いた**。
    ///
    /// 最初の数拍は基準作りに使って報告しない — Program Change のトラック移動が
    /// 「初回は基準を作るだけ（いきなり飛ばさない）」でやっているのと同じ手
    static let warmupBeats = 2
    private var beatsSeen = 0

    /// ⚠️ ロックを持ったまま呼ぶこと
    private func bpmLocked(now: UInt64) -> Double? {
        timestamps.append(now)
        guard timestamps.count > Self.windowTicks else { return nil }
        timestamps.removeFirst(timestamps.count - (Self.windowTicks + 1))
        let elapsed = Double(timestamps.last! &- timestamps.first!) / 1_000_000_000
        guard elapsed > 0 else { return nil }
        // 最初の数拍は捨てる（負荷で伸びた間隔を掴まない）
        if beatsSeen < Self.warmupBeats * Self.ticksPerBeat {
            beatsSeen += 1
            return nil
        }
        // 窓は `measureBeats` 拍ぶんなので、1 拍あたりに割り戻す
        let bpm = 60 * Double(Self.measureBeats) / elapsed
        // 現実的な範囲だけ通す（起動直後や取りこぼしで跳ねた値を捨てる）
        guard (20...300).contains(bpm) else { return nil }
        // **1 BPM 以上動いたときだけ報告** — 窓を 4 拍に広げて揺れは
        // 1/4 になったが、念のため幅も広げておく（表示とログを止める）
        if let last = lastReported, abs(last - bpm) < 1.0 { return nil }
        lastReported = bpm
        return bpm
    }

    /// 最後に算出した BPM（ログ表示用。通知の有無に関わらず読める）
    var latestBPM: Double? {
        lock.lock()
        defer { lock.unlock() }
        return lastReported
    }

    /// 送信が途切れたら忘れる（次に来たときに新しい基準で測り直す）。
    /// **抜き差しで呼ぶ** — 呼ばないと最後の BPM が residual として残る
    func reset() {
        lock.lock()
        timestamps.removeAll()
        lastReported = nil
        ticksBySource.removeAll()
        lastReportNs = 0
        beatsSeen = 0  // 繋ぎ直したら捨て拍からやり直す
        lock.unlock()
    }
}

/// RT スレッドから安全に叩ける MIDI 送り先の切替器
final class MIDIRouter: @unchecked Sendable {
    private let lock = NSLock()
    private var keyboardTarget: AVAudioUnitMIDIInstrument?
    private var drumsTarget: AVAudioUnitMIDIInstrument?

    /// 顔つまみに割当済みの CC 番号（これだけを keyboard 経路から横取りする。
    /// 割当のない CC — Mod ホイール CC1 など — はそのまま楽器へ通す）
    private var knobCCs: Set<UInt8> = []
    private var knobHandler: (@Sendable (UInt8, UInt8) -> Void)?

    /// **PROG 4 のパッド → プラグイン選択**（mako 裁定 2026-08-04）。
    /// LPD8 は切替を通知しないが、プログラムごとに番号をばらしてあるので
    /// **受けたノート番号だけで PROG 4 と分かる**（`Lpd8DefaultPadNotes`）
    private var padSelectHandler: (@Sendable (Int) -> Void)?

    /// **CC120（All Sound Off）の受け口** — Esc と同じ panic を走らせる
    private var panicHandler: (@Sendable () -> Void)?

    /// **トラック移動の受け口**。実機（Assignable）で呼ぶのは VALUE
    /// エンコーダーの Program Change と、焼いたエンコーダー CC117/118
    /// （REW/FF、`Keystage.ladylandEncoderCCs`）。ch16 の Native 通知
    /// （`BF 3E/3F` = turn VALUE KNOB）は Native Mode 専用で、届いたときだけ
    /// 同じ受け口を使う
    private var navHandler: (@Sendable (Int, Bool) -> Void)?

    /// 直前の Program Change 値（差分の基準。初回は飲んで基準にするだけ）
    private var lastProgram: Int?

    /// Program Change の 0-127 環での差分（回した向きと量）。
    /// 127→0 は +1、0→127 は -1 として扱う（環の最短経路）
    static func programDelta(from previous: Int, to current: Int) -> Int? {
        guard previous != current else { return nil }
        let forward = (current - previous + 128) % 128
        return forward <= 64 ? forward : forward - 128
    }

    /// トラック移動の受け口を差す（起動時に一度）
    /// ⚠️ **第 2 引数 = 連打しうる経路か**（実測 2026-08-07）。
    ///
    /// Program Change は **1 メッセージ = 1 クリック**で、しかも差分が
    /// そのまま歩数になる（`programDelta`）ので、**スロットルを噛ませては
    /// いけない** — 速く回すと 150ms のあいだのメッセージが全部落ちて、
    /// 実機で「まったく動かない」ように見えていた。
    ///
    /// CC117/118 は押しっぱなしで連打しうるので、そちらは間引く
    func setNavHandler(_ handler: (@Sendable (Int, Bool) -> Void)?) {
        lock.lock()
        navHandler = handler
        lock.unlock()
    }

    /// MIDI Clock から BPM を測る（Keystage の Tempo）
    private let clock = MidiClockTracker()
    private var tempoHandler: (@Sendable (Double) -> Void)?

    /// MIDI Clock を 1 つ受ける（RT スレッド）。1 拍たまったら BPM を通知。
    /// `source` は接続時に refCon で渡した識別子 — **どのエンドポイントから
    /// 来たか**を数える（2 本繋がっていると BPM が 2 倍に読めるため）
    func receiveClockTick(source: Int) {
        let result = clock.tick(atNanos: DispatchTime.now().uptimeNanoseconds, source: source)
        // **BPM が動いたときだけ出す**（2026-08-05、観測完了後に絞った）。
        //
        // 観測で分かったこと:
        //   - Clock は `Keystage KBD/CTRL`（src#1）1 本だけ。`DAW IN` は 0
        //   - **2 倍問題は実機では起きていない**（両方繋がっているが本線だけが送る）
        //   - 実機で BPM を 80 → 102 に変えると 32/s → 40/s に追従した
        //
        // 毎秒出していると 1 時間で 3600 行になるので、変化時のみに絞る。
        // ソース内訳は残す — 2 本目が送り始めたら BPM が倍に見えるので、
        // そのとき src#2 に数字が立てば一目で分かる
        guard let bpm = result.bpm else { return }
        // ⚠️ **BPM が返ったら必ず出す**。census（1 秒集計）と AND にしていた
        // ときは、両方が揃う瞬間が滅多に無くて 1 行も出なかった —
        // BPM は 0.5 以上動いたときだけ返り、census は 1 秒ごとにしか立たない。
        // ソース内訳は取れたときだけ添える（2 本目が送り始めたら気づけるように）
        let breakdown =
            result.census.map { census in
                census.ticksBySource.sorted { $0.key < $1.key }
                    .map { "src#\($0.key) \(Int(Double($0.value) / census.elapsedSeconds))/s " }
                    .joined()
            } ?? ""
        NSLog("keystage: Clock %@→ BPM %.1f", breakdown, bpm)
        lock.lock()
        let handler = tempoHandler
        lock.unlock()
        handler?(bpm)
    }

    /// 抜き差しで測り直す（`MIDIInput.connectSources` から）。
    /// 呼ばないと最後の BPM が residual として残る
    func resetClock() { clock.reset() }

    /// BPM の通知先を差す（起動時に一度）
    func setTempoHandler(_ handler: (@Sendable (Double) -> Void)?) {
        lock.lock()
        tempoHandler = handler
        lock.unlock()
    }

    /// 最後にページ送りを受けた時刻。**同時に飛んでくる Program Change を
    /// 弾く**ために持つ（VALUE エンコーダーの PC と区別する手がかりが時間しかない）
    private var lastPageStepNs: UInt64 = 0

    /// **ROTO のページ送りの受け口**（Keystage の Rec / Loop ボタン =
    /// `KeystageControls.pageStep` が正典。かつては Track Up/Down →
    /// Play/Stop と渡り歩いた）。VALUE エンコーダー（Program Change）とは別系統
    private var pageStepHandler: (@Sendable (Int) -> Void)?



    /// ノートのキープ（ダンパーペダル CC64。design/06 §8）
    private var latch = NoteLatch()

    /// ペダルの役割（mako 裁定 2026-08-03）。assign のときキープはせず、
    /// CC64 は普通の CC として扱う = 顔つまみに割り当てられる
    private var pedalMode: PedalMode = .keep

    /// ダンパーペダルの極性反転（mako のペダルは逆極性 — 2026-08-14）
    private var pedalInverted = false

    /// キープ状態が変わったときの通知（GUI の表示用。main へホップ）
    private var latchHandler: (@Sendable (Bool, Int) -> Void)?

    /// **いま指が乗っている鍵**が変わったときの通知（和音判定・登録用）。
    /// キープ中の音は含まない — ペダルで溜まった音まで拾うと和音が濁る
    private var heldNotesHandler: (@Sendable ([UInt8]) -> Void)?

    /// 押下集合を main へ流す。**ロックを持ったまま呼んでよい**
    /// （async なので待たず、handler は main で走る）
    private func notifyHeldNotes() {
        guard let handler = heldNotesHandler else { return }
        let held = latch.heldNotes
        DispatchQueue.main.async { handler(held) }
    }

    /// 押下集合の通知先を差す（AppState から）
    func onHeldNotesChanged(_ handler: @escaping @Sendable ([UInt8]) -> Void) {
        lock.lock()
        heldNotesHandler = handler
        lock.unlock()
    }

    /// LPD8 ノブ → ドラムスロット顔つまみの横取り（keyboard 側と同じ作法）
    private var drumKnobCCs: Set<UInt8> = []
    private var drumKnobHandler: (@Sendable (UInt8, UInt8) -> Void)?

    /// ルーティングトレースの受け口（design/06 §8 追補 — Debug ウィンドウ）。
    /// 判断の瞬間に値型 MidiRoute を発行する。整形・名前解決は main 側の仕事
    private var traceHandler: (@Sendable (MidiRoute) -> Void)?

    func setKeyboardTarget(_ unit: AVAudioUnitMIDIInstrument?) {
        lock.lock()
        // **送り先が変わっていないなら帳簿に触らない** — updateRouting は
        // 割当編集・同じタイルの再選択・LPD8 のプログラム読み込みなど
        // 15 箇所から呼ばれる。以前はここで無条件に reset していたため、
        // ペダルを踏んだまま何か操作すると**キープ中の音が宙に浮いて
        // 残った**（実機 2026-08-02「音が一度のこりました」）
        guard unit !== keyboardTarget else {
            lock.unlock()
            return
        }
        let previous = keyboardTarget
        let orphaned = latch.reset()
        keyboardTarget = unit
        let notify = latchHandler
        lock.unlock()

        // 宙に浮くノートは**旧スロットへ自分で消しに行く**（切替作法の
        // All Notes Off に頼らない — AU が honor する保証が無い）
        for note in orphaned {
            previous?.sendMIDIEvent(0x80 | (note.channel & 0x0F), data1: note.note, data2: 0)
        }
        if !orphaned.isEmpty {
            notify?(false, 0)
        }
    }

    // MARK: - 鍵盤 2（NCXse）経路 — 2nd キーボード計画 ①（mako 裁定 2026-08-10
    // 「別々の二つの音源同時に弾きたい」）

    /// 鍵盤 2 の送り先（① は選択スロットと同じ。② で独立した席の選択を足す）
    private var secondKeyboardTarget: AVAudioUnitMIDIInstrument?

    /// 鍵盤 2 で押下中のノート（ch << 8 | note）。
    /// 送り先が替わるとき**旧スロットへ自分で消しに行く**ための帳簿
    private var secondHeld: Set<UInt16> = []

    /// この受信を楽器へ通すか（純関数 — テスト対象）。
    ///
    /// ⚠️ **NCXse の実測（2026-08-10）から引いた通行証**:
    /// - ノート / ポリ AT / チャンネルプレッシャー / ベンド = 演奏そのもの → 通す
    /// - CC は **64（ダンパー、連続値）と 74（スティック 2）だけ** → 通す
    /// - ⚠️ **CC0/32 + PC（音色ボタンの 3 点セット）は飲む** — Bank Select が
    ///   楽器へ届くと音色が飛ぶ。⚠️ **CC121/123（パネル操作の掃除バースト）も
    ///   飲む** — Reset All Controllers / All Notes Off が演奏中の音源を止める
    static func secondKeyboardForwards(status: UInt8, data1: UInt8) -> Bool {
        switch status & 0xF0 {
        case 0x80, 0x90, 0xA0, 0xD0, 0xE0: return true
        case 0xB0:
            return data1 == 64 || data1 == 74
                || data1 == UInt8(FaceKnobAssignment.modWheelCC)
        default: return false
        }
    }

    /// ⭐ **機材の MIDI → 内部モデルへの翻訳**（mako 2026-08-10「MIDI →
    /// 内部モデル操作への変換というか」）。
    ///
    /// NCXse の Mod（CC1）は **ModWheel 席**の操作 — 席の内部 ID は
    /// `FaceKnobAssignment.modWheelCC`（= 116。Keystage は実機側で焼いて
    /// この番号を送るが、NCXse は焼けないのでアダプタが翻訳する）。
    /// ⭐ **どちらの鍵盤のホイールも同じ席に着く** — 割当は 1 か所で済む
    static func secondKeyboardTranslated(status: UInt8, data1: UInt8) -> UInt8 {
        guard status & 0xF0 == 0xB0, data1 == 1 else { return data1 }
        return UInt8(FaceKnobAssignment.modWheelCC)
    }

    /// 鍵盤 2 が届く席の割当（ModWheel 116 / ダンパー 64 / スティック 74）と
    /// 駆動先。担当スロットが選択と割れても正しい割当を見るために keyboard の
    /// `knobCCs` とは別に持つ
    private var secondKnobCCs: Set<UInt8> = []
    private var secondKnobHandler: (@Sendable (UInt8, UInt8) -> Void)?

    func setSecondKnobRouting(ccs: Set<UInt8>, handler: (@Sendable (UInt8, UInt8) -> Void)?) {
        lock.lock(); defer { lock.unlock() }
        secondKnobCCs = ccs
        secondKnobHandler = handler
    }

    func setSecondKeyboardTarget(_ unit: AVAudioUnitMIDIInstrument?) {
        lock.lock()
        guard unit !== secondKeyboardTarget else {
            lock.unlock()
            return
        }
        let previous = secondKeyboardTarget
        let orphaned = secondHeld
        secondHeld = []
        secondKeyboardTarget = unit
        lock.unlock()
        // 宙に浮くノートは旧スロットへ自分で消しに行く（keyboard 経路と同じ作法）
        for key in orphaned {
            previous?.sendMIDIEvent(0x80 | UInt8(key >> 8), data1: UInt8(key & 0x7F), data2: 0)
        }
    }

    func routeSecondKeyboard(_ status: UInt8, _ rawData1: UInt8, _ data2: UInt8) {
        // ⭐ まず内部モデルへ翻訳（CC1 → ModWheel 席）。以降は翻訳後の値だけを扱う
        let data1 = Self.secondKeyboardTranslated(status: status, data1: rawData1)
        lock.lock()
        let target = secondKeyboardTarget
        let trace = traceHandler
        let handler = secondKnobHandler
        let captured = status & 0xF0 == 0xB0 && secondKnobCCs.contains(data1)
        let forwards = Self.secondKeyboardForwards(status: status, data1: data1)
        if forwards, !captured {
            let key = UInt16(status & 0x0F) << 8 | UInt16(data1)
            switch status & 0xF0 {
            case 0x90 where data2 > 0: secondHeld.insert(key)
            case 0x80, 0x90: secondHeld.remove(key)
            default: break
            }
        }
        lock.unlock()
        // trace は翻訳後（ログに CC116 = ModWheel と出る — 席の言葉で読める）
        trace?(.secondKeyboard(status: status, data1: data1, data2: data2, hasTarget: target != nil))
        // ⭐ ModWheel 席などに割当があれば内部モデル操作（= パラメータ駆動）へ。
        // 割当は**担当スロットのもの**（`secondKnobCCs` — 選択と割れても正しい席）
        if captured, let handler {
            handler(data1, data2)
            return
        }
        guard forwards else { return }
        target?.sendMIDIEvent(status, data1: data1, data2: data2)
    }

    /// キープ状態の通知先（GUI 表示用。起動時に一度）
    func setLatchHandler(_ handler: (@Sendable (Bool, Int) -> Void)?) {
        lock.lock(); defer { lock.unlock() }
        latchHandler = handler
    }

    /// ダンパーペダルの極性反転（逆極性のペダル対応 — routeKeyboard の
    /// 入口で 127-value に写す）
    func setPedalInverted(_ inverted: Bool) {
        lock.lock(); defer { lock.unlock() }
        pedalInverted = inverted
    }

    /// ペダルの役割を切り替える。**キープ中に切り替えたら溜めた音を逃がす** —
    /// 切り替えた瞬間に音が宙に浮くのが一番危ない（ライブで消せなくなる）
    func setPedalMode(_ mode: PedalMode) {
        lock.lock()
        guard mode != pedalMode else {
            lock.unlock()
            return
        }
        pedalMode = mode
        let orphaned = latch.reset()
        let target = keyboardTarget
        let notify = latchHandler
        lock.unlock()

        for note in orphaned {
            target?.sendMIDIEvent(0x80 | (note.channel & 0x0F), data1: note.note, data2: 0)
        }
        notify?(false, 0)
    }

    /// パニック — キープを解いて、溜めている音を今の送り先へ消しに行く。
    /// **ライブの最後の砦**（スタックノートは他のどの不具合より怖い）
    func panic() {
        lock.lock()
        let orphaned = latch.reset()
        let target = keyboardTarget
        let notify = latchHandler
        lock.unlock()
        for note in orphaned {
            target?.sendMIDIEvent(0x80 | (note.channel & 0x0F), data1: note.note, data2: 0)
        }
        notify?(false, 0)
    }

    func setDrumsTarget(_ unit: AVAudioUnitMIDIInstrument?) {
        lock.lock(); defer { lock.unlock() }
        drumsTarget = unit
    }

    /// 顔つまみの横取り対象 CC と受け口を更新する（選択・ロード・割当変更時）
    func setKnobRouting(ccs: Set<UInt8>, handler: (@Sendable (UInt8, UInt8) -> Void)?) {
        lock.lock(); defer { lock.unlock() }
        knobCCs = ccs
        knobHandler = handler
    }

    /// CC120（All Sound Off）→ panic の受け口を差す
    func setPanicHandler(_ handler: (@Sendable () -> Void)?) {
        lock.lock()
        panicHandler = handler
        lock.unlock()
    }

    /// Rec / Loop（`KeystageControls.pageStep`）→ ROTO のページ送りの受け口を差す
    func setPageStepHandler(_ handler: (@Sendable (Int) -> Void)?) {
        lock.lock()
        pageStepHandler = handler
        lock.unlock()
    }

    /// PROG 4 のパッド → プラグイン選択の受け口を差す
    func setPadSelectHandler(_ handler: (@Sendable (Int) -> Void)?) {
        lock.lock()
        padSelectHandler = handler
        lock.unlock()
    }


    /// LPD8 ノブの横取り対象 CC と受け口を更新する（drums 経路）
    func setDrumKnobRouting(ccs: Set<UInt8>, handler: (@Sendable (UInt8, UInt8) -> Void)?) {
        lock.lock(); defer { lock.unlock() }
        drumKnobCCs = ccs
        drumKnobHandler = handler
    }

    /// LPD8 ノブ → **選択 Track の顔つまみ**（`Lpd8KnobJack.face`）。空なら
    /// drums 側（従来）。両方に居る CC は顔つまみが先
    private var lpd8FaceCCs: Set<UInt8> = []
    private var lpd8FaceHandler: (@Sendable (UInt8, UInt8) -> Void)?

    func setLpd8FaceRouting(ccs: Set<UInt8>, handler: (@Sendable (UInt8, UInt8) -> Void)?) {
        lock.lock(); defer { lock.unlock() }
        lpd8FaceCCs = ccs
        lpd8FaceHandler = handler
    }

    /// ルーティングトレースの受け口を設定する（起動時に一度）
    func setTraceHandler(_ handler: (@Sendable (MidiRoute) -> Void)?) {
        lock.lock(); defer { lock.unlock() }
        traceHandler = handler
    }

    /// keyboard 経路に届いた MIDI の出どころ。**演奏の帳簿（latch / 和音）は
    /// 共有**しつつ、Keystage 専用の解釈を汎用鍵盤に当てないための印
    /// （mako 裁定 2026-09-26「スタジオの MIDI 鍵盤を Keystage の代わりに」）
    enum KeyboardOrigin: Sendable {
        /// Keystage（と PC キーボード演奏）— 帯の飲み込み / PC ナビ / 焼きボタン
        case keystage
        /// 名前の分からない鍵盤 — 鍵盤 2 と同じ通行証（ノート・AT・ベンド・
        /// CC64/74、CC1 → ModWheel 席）。それ以外の CC / PC は黙って落とす
        case generic
    }

    /// 汎用鍵盤の通行証（純関数 — テスト対象）。鍵盤 2 と同じ列 + CC120
    /// （All Sound Off = panic。どの鍵盤の EXIT でも止まるべき）
    static func genericKeyboardForwards(status: UInt8, data1: UInt8) -> Bool {
        secondKeyboardForwards(status: status, data1: data1)
            || (status & 0xF0 == 0xB0 && data1 == 120)
    }

    func routeKeyboard(
        _ status: UInt8, _ rawData1: UInt8, _ rawData2: UInt8, origin: KeyboardOrigin = .keystage
    ) {
        // ⭐ 汎用鍵盤はまず翻訳（CC1 → ModWheel 席。鍵盤 2 と同じアダプタ）、
        // 通行証の無いものはここで落とす — Keystage 専用の解釈（帯 / PC / 焼き
        // ボタン / ch16）に届かせない。⚠️ trace も出さない（落とす量が多く、
        // Debug ログを埋める）
        let data1 =
            origin == .generic ? Self.secondKeyboardTranslated(status: status, data1: rawData1) : rawData1
        if origin == .generic, !Self.genericKeyboardForwards(status: status, data1: data1) {
            return
        }
        lock.lock()
        // ダンパーの極性を**入口で**直す（mako 報告 2026-08-14「キープが逆」—
        // ペダルには踏むと閉じる/開くの 2 種があり、逆極性の個体は踏んで
        // いないのに踏んだ値が来る。ここ 1 箇所で直せば、キープも素通しの
        // ネイティブ sustain も assign モードの割当も全部同じ向きになる）
        let data2 =
            (status & 0xF0 == 0xB0 && data1 == UInt8(FaceKnobAssignment.damperCC)
                && pedalInverted) ? 127 - rawData2 : rawData2
        let trace = traceHandler

        // 🧪 **ボタン類の受信を人が読める形で出す**（mako 要望 2026-08-05
        // 「[受信] ログに CC の情報もあると捗るね」）。
        // ノート（0x8n/0x9n/0xAn）とノブの値ストリーム（ch15 の CC0-63）は除く
        let isNote = status & 0xF0 == 0x80 || status & 0xF0 == 0x90 || status & 0xF0 == 0xA0
        let isKnobStream = status == 0xBE && data1 < 64
        if !isNote, !isKnobStream, origin == .keystage {
            NSLog("keystage: [受信] %@", Self.describe(status, data1, data2))
        }

        // ── CC120 = All Sound Off。**MIDI 仕様どおりに従う**（mako 2026-08-05）──
        //
        // Keystage の EXIT ボタンがこれを送る。仕様上は「全部止めろ」なので、
        // 外の音源（VP / Logic）は素直に受け取って止める。**ladyland だけが
        // 無視するのは筋が通らない** — Esc と同じ panic を走らせる。
        //
        // ⚠️ 席からは外してあるので（`alwaysReservedCCs`）、パラメータには
        // 割り当てられない。ここは純粋に「止める命令」として受ける
        if status & 0xF0 == 0xB0, data1 == 120, let panic = panicHandler {
            lock.unlock()
            trace?(.allSoundOff)
            panic()
            return
        }

        // ── ノートのキープ（ダンパーペダル = CC64。mako 裁定 2026-08-02）──
        // 踏んでいる間は鍵を離しても Note Off を送らない = 両手が空いて
        // ノブをいじれる。
        //
        // **実機確認 2026-08-02**: Keystage の EXPRESSION ジャックに挿しても
        // MIDI が出ず、DAMPER ジャックに挿すと流れた。よってトリガーは CC64。
        // 結果的にこちらの方が筋が良い — CC64 は予約 CC（パラメータへ割り当て
        // られない）なので、Exp (CC11) のようにマトリクスの一級市民を
        // 潰さずに済む。
        //
        // CC64 は**観測するだけで飲み込まない** — 下の経路へそのまま流すので、
        // プラグイン側のネイティブなサスティン（ハーフダンパー・共鳴など）も
        // 従来どおり効く。こちらのキープは「どのプラグインでも確実に持続する」
        // ための保険として重ねる
        // assign モードでは CC64 を特別扱いしない — 下の顔つまみ経路が
        // 拾う（割当があれば横取り、無ければ楽器へ素通しでネイティブ sustain）
        if status & 0xF0 == 0xB0, data1 == 64, pedalMode == .keep {
            let wasEngaged = latch.isEngaged
            let released = latch.pedal(data2)
            let engaged = latch.isEngaged
            let sustaining = latch.sustainedCount
            let target = keyboardTarget
            let notify = latchHandler
            lock.unlock()  // ← ここで手放して以降は取り直さない（一本道）

            // 溜めた音を先に消してから、ペダル自体を楽器へ渡す
            for note in released {
                target?.sendMIDIEvent(0x80 | (note.channel & 0x0F), data1: note.note, data2: 0)
            }
            if wasEngaged != engaged {
                trace?(.latch(engaged: engaged, released: released.count))
            }
            notify?(engaged, sustaining)

            // CC64 は飲み込まない — プラグインのネイティブなサスティンも効かせる
            trace?(
                .keyboard(status: status, data1: data1, data2: data2, hasTarget: target != nil))
            target?.sendMIDIEvent(status, data1: data1, data2: data2)
            return
        }

        // ノートの押下記録（キープの帳簿）
        if status & 0xF0 == 0x90, data2 > 0 {
            latch.noteOn(data1, channel: status & 0x0F)
            notifyHeldNotes()
        } else if status & 0xF0 == 0x80 || (status & 0xF0 == 0x90 && data2 == 0) {
            defer { notifyHeldNotes() }
            if !latch.shouldSendNoteOff(data1) {
                // キープ中 — 楽器へは流さない（鳴らし続ける）
                let sustaining = latch.sustainedCount
                let notify = latchHandler
                lock.unlock()
                trace?(.latchHold(note: data1, sustaining: sustaining))
                notify?(true, sustaining)
                return
            }
        }
        // CC かつ割当済みノブ番号 → 顔つまみ経路（チャンネル不問 — Keystage の
        // ノブ ch は Scene 設定次第なので CC 番号だけで判定する）。
        //
        // ⭐ **Keystage のノブ帯（CC0-63）は割当が無くても飲む**
        // （mako 要望 2026-08-07。`KeystageKnobs`）。
        //
        // ⚠️ **これが安全の本体** — 番号の意味（CC32 = Bank Select LSB など）は、
        // **届かなければ無関係**になる。とくに CC32 は、VALUE エンコーダーが
        // Program Change を出しているので **CC32 + PC でバンクが変わる**
        // 組み合わせが成立する。横取りで消える。
        if status & 0xF0 == 0xB0,
            knobCCs.contains(data1) || KeystageKnobs.intercepted.contains(Int(data1))
        {
            lock.unlock()
            // ⚠️⚠️ **trace は割当の有無に関わらず出す**（監査 2026-08-08 の B-7）。
            //
            // トレースは **keyboard 経路の唯一の main 観測点**で、
            // ノブストリップのページ推定（`AppState` の `activeKnobPage`）は
            // ここだけを見ている。⚠️ **割当が無いときに黙って return していた**
            // ので、**割当ゼロのトラックでは見出しが `P?` のまま固まっていた**
            // （#75 で帯を全部飲むようにした際の回帰）。
            //
            // ⭐ **出しても楽器へは流れない** — `.knob` は横取り済みの印で、
            // 素通し経路（`.keyboard`）とは別物。
            //
            // ⚠️⚠️ **ch16（0xBF）は除く** — あれは Keystage の制御チャンネルで、
            // **VALUE の上下ボタンが CC60/61 = 帯と同じ番号**を使う。trace を
            // 出すと**ボタンを押しただけでページ推定が P8 へ飛ぶ**。帯として
            // 飲む（楽器へ流さない）のは従来どおりで、**材料にしないだけ**
            if status != 0xBF {
                trace?(.knob(cc: data1, value: data2))
            }
            // ⚠️ **割当が無ければ何もしない。ただし楽器へも流さない** —
            // 空きノブを回しても音が変わらないのが正しい
            guard knobCCs.contains(data1), let handler = knobHandler else { return }
            handler(data1, data2)
            return
        }
        // ピッチベンド → 割当があれば顔つまみ経路（擬似 Ctrl 128。MSB を
        // 0-127 値として使う）。未割当なら下の素通しでネイティブのベンドが楽器へ
        if status & 0xF0 == 0xE0, knobCCs.contains(128), let handler = knobHandler {
            lock.unlock()
            trace?(.knob(cc: 128, value: data2))
            handler(128, data2)
            return
        }
        // Keystage VALUE エンコーダー（実機 2026-08-02）→ トラック順移動。
        //
        // 実機は Native Mode の `BF 3E/3F`（docs/keystage §6）ではなく
        // **Program Change を絶対値で増減させて**送ってくる（72→71→70…）。
        // Native Mode にすればチャートどおりになるが、**それをするとノブが
        // CC0-7/ch16 固定になり 16 ページの割当が壊れる**（§8 の排他）ので、
        // 実機の挙動に合わせてこちらで受ける。
        //
        // チャンネルは見ない（グローバル ch 設定で変わるため。顔つまみの
        // CC 判定と同じ作法）。**楽器へは流さない** — 流すとエンコーダーを
        // 回すたびにプラグインのプリセットが変わる（実機で踏んだ事故）
        // **CC117 / 118 = VALUE エンコーダーの回転 → トラック移動**
        // （mako 裁定 2026-08-05「CC117/118 こっちを使おう」）。
        //
        // 実機で REW=117 / FF=118 に焼いた。**Program Change 経由より素直** —
        // PC は 0-127 の絶対値をループさせる方式で、差分を取るのに基準値の
        // 管理が要り、Track ボタンの PC と混ざる問題もあった。
        //
        // ⚠️ チャンネルは見ない（グローバル ch 設定で変わるため。顔つまみの
        // CC 判定と同じ作法）。**楽器へは流さない**。
        //
        // ⚠️ **番号を直書きしない**（監査 2026-08-08 の B-6）— 焼く値
        // （`Keystage.ladylandEncoderCCs`）から引く。焼き直しても追従する
        if status & 0xF0 == 0xB0,
            let encoder = Keystage.ladylandEncoderCCs.first(where: { Int($0.1) == Int(data1) })?.0,
            let nav = navHandler
        {
            lock.unlock()
            let direction = encoder == .forward ? 1 : -1
            trace?(.nav(direction: direction))
            nav(direction, true)  // ⚠️ 押しっぱなしで連打しうる
            return
        }

        // **焼いたボタン → ROTO のページ送り**（現在は Rec/Loop = CC104/105。
        // `KeystageControls.pageStep` が正典）。CC ボタンを使う判断は
        // mako 裁定 2026-08-05「先ほどは CC を動かした値が見えてたんだけど。
        // そっちを使う」— 当時は Play/Stop（当時 CC96/97）に充てていた。
        //
        // **Scene Dump で焼いたボタンは CC を送る**（実測 2026-08-05:
        // ch3 CC96 / ch10 CC97）。
        // ROTO の ← → はホストに何も届かないので、ここを手元のページ送りに使う。
        //
        // ⚠️ 実装チャートの ch16 通知（`BF 3A` NEXT TRACK など）は
        // **Native Mode 専用**で、Assignable では一切来ない。Native に入ると
        // ノブが CC0-7 固定になり 16 ページが壊れるので、そちらは使えない。
        //
        // ⚠️ **番号を直書きしない**（mako 指示 2026-08-07）。割当は
        // `KeystageControls` が正典で、**CC は焼く値から導かれる** —
        // 機材側で番号を変えても、役割を別のボタンへ移しても、
        // **保護が自動で付いてくる**。
        //
        // ⚠️ チャンネルは見ない（実測 2026-08-07: 同じ列でも Play だけ ch3、
        // 他は ch10 という状態が起きていた。揃っている前提で書くと次に黙って死ぬ）。
        //
        // ⭐ **押下も解放も飲む** — ここが実バグだった。`data2 > 0` を条件に
        // 入れていたので**解放だけ楽器へ素通し**していて、実機ログに
        // `CC96 = 0 → slot 22` が出ていた。これらは **MIDI 予約番号**
        // （Data Inc/Dec・NRPN）なので、**素通しは AU のパラメータを書き換えうる**
        if status & 0xF0 == 0xB0, KeystageControls.interceptedCCs.contains(Int(data1)) {
            lock.unlock()
            // ⚠️ **動くのは押下だけ**。両方通すと 1 押しで 2 ページ飛ぶ
            guard data2 > 0, let direction = KeystageControls.pageStep[Int(data1)],
                let page = pageStepHandler
            else { return }
            trace?(.pageStep(direction: direction))
            page(direction)
            return
        }

        // **Program Change = VALUE ノブの回転 → トラック移動**（mako 裁定
        // 2026-08-05「Track 選択移動は、ロータリーの方でトリガーさせる」）。
        //
        // ⚠️ ch16 の Native 通知（`BF 3E/3F` = turn VALUE KNOB）は
        // **Native Mode 専用で来ない**。Assignable では PC しか出ない
        // （実測: 回すと ch1 PC が 1,2,3,4,5,6,7,6,5,4… と連続で届く）。
        //
        // ⚠️ **楽器へは流さない** — 流すと回すたびにプラグインのプリセットが
        // 変わる（実測 2026-08-05: Firenze が勝手に切り替わった）
        if status & 0xF0 == 0xC0 {
            // ⚠️ **受け口が無くても楽器へは流さない** — 素通しすると回すたびに
            // プラグインのプリセットが変わる。PC は ladyland が食い止める
            guard let nav = navHandler else {
                lock.unlock()
                return
            }
            let current = Int(data1)
            let previous = lastProgram
            lastProgram = current
            lock.unlock()
            if let previous, let step = Self.programDelta(from: previous, to: current) {
                trace?(.nav(direction: step))
                // ⚠️ **間引かない** — 差分がそのまま歩数で、1 メッセージ =
                // 1 クリック。間引くと速く回したぶんが丸ごと消える
                nav(step, false)
            } else {
                // 初回は基準を作るだけ（いきなり飛ばさない）
                trace?(.programNavBaseline(value: data1))
            }
            return
        }

        // ch16 CC62/63 は Native Mode でしか来ない（届いたら使う）
        // （mako 裁定 2026-08-05「Track 選択移動は、ロータリーの方でトリガー」）。
        //
        // ⚠️ ここを「VALUE の上下ボタン」と読んで**黙って捨てていた**が、
        // 実装チャート L1078-1083 には **「turn VALUE KNOB left / right」**と
        // 明記されている — 捨てていたものがロータリーそのものだった。
        //
        //   `BF 3E` = 左回し / `BF 3F` = 右回し（127 と 0 を続けて送る）
        //   `BF 3C` / `3D` = VALUE の上下ボタン
        //   `BF 3A` / `3B` = NEXT / PREVIOUS TRACK
        //
        // 127 と 0 が対で来るので**押下（127）だけ拾う**。
        // Program Change 経由をやめられたので、基準値の管理も要らない
        if status == 0xBF, data1 == 0x3E || data1 == 0x3F, data2 > 0,
            let nav = navHandler
        {
            lock.unlock()
            let direction = data1 == 0x3F ? 1 : -1  // 3F = 右回し = 次のトラック
            trace?(.nav(direction: direction))
            nav(direction, true)  // ⚠️ Native の回転は連打で来る
            return
        }
        // 上下ボタン（3C / 3D）は使わない — 黙って捨てる
        if status == 0xBF, data1 == 0x3C || data1 == 0x3D {
            lock.unlock()
            return
        }
        let target = keyboardTarget
        lock.unlock()
        // 旧実装はここで NSLog（P1 デバッグ / ch16 未割当）していたが、
        // RT スレッドの NSLog はブロックしうるため trace 発行に一本化。
        // ch16 の未割当 CC は専用ケース（Value ボタン等の実測特定用）
        if status == 0xBF {
            trace?(.unassignedCh16(cc: data1, value: data2))
        } else {
            trace?(.keyboard(status: status, data1: data1, data2: data2, hasTarget: target != nil))
        }
        target?.sendMIDIEvent(status, data1: data1, data2: data2)
    }

    /// 受信を人が読める形にする（ログ用）。
    ///
    /// **番号だけ出しても意味が分からない**ので、実装チャートで素性が
    /// 割れているものは名前を添える。ch16 は Native 通知の予約領域で、
    /// 同じ CC 番号でも他チャンネルとは意味が違う
    static func describe(_ status: UInt8, _ data1: UInt8, _ data2: UInt8) -> String {
        let channel = Int(status & 0x0F) + 1
        switch status & 0xF0 {
        case 0xB0:
            let name = knownCCName(channel: channel, cc: data1)
            return "ch\(channel) CC\(data1) = \(data2)\(name.map { "（\($0)）" } ?? "")"
        case 0xC0:
            return "ch\(channel) Program Change \(data1)"
        case 0xD0:
            return "ch\(channel) Channel Pressure \(data1)"
        case 0xE0:
            return "ch\(channel) Pitch Bend \(Int(data2) << 7 | Int(data1))"
        default:
            return String(
                format: "status=%02X data1=%d data2=%d", Int(status), Int(data1), Int(data2))
        }
    }

    /// 素性の割れている CC の名前（実装チャート + 実機で焼いた割当）。
    ///
    /// ⚠️ **焼いた操作子は番号を直書きしない** — 焼く値
    /// （`Keystage.ladylandButtonCCs` / `ladylandEncoderCCs`）から引く。
    /// 2026-08-08 まで旧値（96-101 / 121-123）の名前が直書きで残っていて、
    /// ログが現物と違う素性を名乗っていた
    private static func knownCCName(channel: Int, cc: UInt8) -> String? {
        // ch16 は **Native 通知の予約領域**（チャート L1070-1090）。
        // NEXT/PREV TRACK は Native Mode 専用で、Assignable では来ない
        if channel == 16 {
            switch cc {
            case 0x2B: return "REWIND"
            case 0x2C: return "FORWARD"
            case 0x3A: return "NEXT TRACK（Native 専用・未使用）"
            case 0x3B: return "PREV TRACK（Native 専用・未使用）"
            case 0x3C: return "VALUE ↓ボタン（未使用）"
            case 0x3D: return "VALUE ↑ボタン（未使用）"
            case 0x3E: return "VALUE 左回し → トラック-"
            case 0x3F: return "VALUE 右回し → トラック+"
            default: break
            }
        }
        switch Int(cc) {
        case FaceKnobAssignment.modWheelCC: return "ModWheel"
        case FaceKnobAssignment.expressionCC: return "Expression"
        case FaceKnobAssignment.damperCC: return "Damper"
        case 120: return "EXIT → All Sound Off"
        default: break
        }
        if let button = Keystage.ladylandButtonCCs.first(where: { Int($0.1) == Int(cc) }) {
            return "\(button.0.label)（焼いた）"
        }
        if let encoder = Keystage.ladylandEncoderCCs.first(where: { Int($0.1) == Int(cc) }) {
            return "\(encoder.0.label)（焼いた）"
        }
        return nil
    }

    func routeDrums(_ status: UInt8, _ data1: UInt8, _ data2: UInt8) {
        lock.lock()
        let trace = traceHandler
        // **PROG 4 のパッドは音を出さず、プラグイン選択に使う**。
        //
        // ⚠️ **Note と CC の両方で来る**（mako 2026-08-06「基本は Pad は、CC モードに
        // してる想定で」）。LPD8 は本体ボタンで Note / CC / PC を切り替えるので、
        // 片方しか見ていないとモード次第で沈黙する。押した方（値 > 0）だけ拾う
        if data2 > 0, let handler = padSelectHandler {
            let pad: Int? =
                switch status & 0xF0 {
                case 0x90:
                    Lpd8DefaultPadNotes.program(of: data1) == 4
                        ? Lpd8DefaultPadNotes.index(of: data1) : nil
                case 0xB0:
                    Lpd8DefaultPadCCs.program(of: data1) == 4
                        ? Lpd8DefaultPadCCs.index(of: data1) : nil
                default: nil
                }
            if let pad {
                lock.unlock()
                trace?(.padSelect(pad: pad))
                handler(pad)
                return
            }
        }
        // PROG 4 の離し（Note Off / CC 0）は捨てる（上で音を出していないので）
        if status & 0xF0 == 0x80 || (status & 0xF0 == 0x90 && data2 == 0),
            Lpd8DefaultPadNotes.program(of: data1) == 4
        {
            lock.unlock()
            return
        }
        if status & 0xF0 == 0xB0, data2 == 0, Lpd8DefaultPadCCs.program(of: data1) == 4 {
            lock.unlock()
            return
        }
        // LPD8 ノブ CC → 顔つまみ Jack（`Lpd8KnobJack.face`。割当の有無に
        // 関わらず飲む — ドラム音源へ漏らさない）
        if status & 0xF0 == 0xB0, lpd8FaceCCs.contains(data1) {
            let handler = lpd8FaceHandler
            lock.unlock()
            trace?(.lpd8FaceKnob(cc: data1, value: data2))
            handler?(data1, data2)
            return
        }
        // LPD8 ノブ CC → ドラム顔つまみ（keyboard 側と同じ割当ベース横取り）
        if status & 0xF0 == 0xB0, drumKnobCCs.contains(data1), let handler = drumKnobHandler {
            lock.unlock()
            trace?(.drumKnob(cc: data1, value: data2))
            handler(data1, data2)
            return
        }
        let target = drumsTarget
        lock.unlock()
        trace?(.drums(status: status, data1: data1, data2: data2, hasTarget: target != nil))
        target?.sendMIDIEvent(status, data1: data1, data2: data2)
    }
}

/// ソースが刺さる経路（接続表の答え。spec/09 Jack の「機材セクション → Jack」）
enum MIDISourceRoute: Equatable, Sendable {
    /// Keystage（KBD/CTRL と DAW IN の 2 本）→ keyboard 経路
    case keystage
    /// 名前の分からない鍵盤 → keyboard 経路（`KeyboardOrigin.generic`）
    case genericKeyboard
    /// LPD8 → drums 経路
    case drums
    /// MiniLab / NCXse / （Keystage が居るときの）汎用鍵盤 → 鍵盤 2 経路
    case secondKeyboard
}

/// 繋いだソース（Jack 結線図の表示用）
struct MIDIConnectedSource: Equatable, Sendable {
    let name: String
    let route: MIDISourceRoute
}

/// CoreMIDI クライアント。ソースを名前で識別して 3 経路に接続する
final class MIDIInput {
    private var client = MIDIClientRef()
    private var keyboardPort = MIDIPortRef()
    private var drumsPort = MIDIPortRef()
    /// 鍵盤 2（NCXse）の受信ポート（2nd キーボード計画 ①）
    private var secondKeyboardPort = MIDIPortRef()
    let router: MIDIRouter

    /// Keystage のソースに振った番号（refCon で持たせる。Clock の集計に出る）
    private var keystageSourceCount = 0

    /// 接続済みソースの表示名（ログ用。`connected` の文字列版）
    private(set) var connectedSources: [String] = []

    /// 接続済みソース（Jack 結線図用。結線先つき）
    private(set) var connected: [MIDIConnectedSource] = []

    /// 汎用鍵盤の refCon に立てるビット（Keystage の 1-based 番号と共存。
    /// keyboard ポートのコールバックが origin を読むのに使う）
    private static let genericMarker = 0x100

    /// セットアップ変更（挿抜）の通知先（メインスレッドで呼ばれる。LedBus の再接続用）
    var onSetupChanged: (() -> Void)?

    /// LPD8 からの SysEx（GET 応答など）の中継。ハンドラはメインキューで呼ばれる
    let sysexRelay = SysExRelay()


    init(router: MIDIRouter) {
        self.router = router
    }

    func start() throws {
        let routerRef = router

        var status = MIDIClientCreateWithBlock("ladyland" as CFString, &client) { [weak self] notification in
            // ホットプラグ: セットアップ変更で再接続（design/06 §5-4 由来の原則）
            if notification.pointee.messageID == .msgSetupChanged {
                DispatchQueue.main.async {
                    self?.connectSources()
                    self?.onSetupChanged?()
                }
            }
        }
        guard status == noErr else { throw MIDIError.clientCreate(status) }

        status = MIDIInputPortCreateWithProtocol(
            client, "keyboard" as CFString, ._1_0, &keyboardPort
        ) { eventList, srcConnRefCon in
            // **どのエンドポイントから来たか**を refCon で受ける（接続時に
            // 1-based の番号を渡してある）。渡さないと 2 本の Keystage が
            // 混ざっても区別できず、BPM が 2 倍に読めているのに気づけない
            let marker = Int(bitPattern: srcConnRefCon)
            let origin: MIDIRouter.KeyboardOrigin = marker & Self.genericMarker != 0 ? .generic : .keystage
            let source = marker & ~Self.genericMarker
            Self.handle(
                eventList, route: { routerRef.routeKeyboard($0, $1, $2, origin: origin) },
                word: { word in
                    // MessageType 1 = System Real Time。status 0xF8 = MIDI Clock。
                    // **ここでしか拾えない** — MT2 のフィルタを通らないため
                    guard (word >> 28) & 0xF == 1, (word >> 16) & 0xFF == 0xF8 else { return }
                    routerRef.receiveClockTick(source: source)
                })
        }
        guard status == noErr else { throw MIDIError.portCreate(status) }

        // drums ポートだけ SysEx も拾う（LPD8 の GET 応答。design/06 §8）。
        // assembler はこのクロージャに閉じ込める — CoreMIDI はポート毎に
        // コールバックを直列化するため、ロックなしで安全
        let relay = sysexRelay
        var drumsAssembler = SysEx7Assembler()
        status = MIDIInputPortCreateWithProtocol(client, "drums" as CFString, ._1_0, &drumsPort) { eventList, _ in
            Self.handle(eventList, route: { routerRef.routeDrums($0, $1, $2) }, word: { word in
                if let frame = drumsAssembler.feed(word) {
                    relay.emit(frame)
                }
            })
        }
        guard status == noErr else { throw MIDIError.portCreate(status) }

        // 鍵盤 2（NCXse）— keyboard とは**別ポート**。⚠️ 同じ CC 番号でも
        // 面が違えば意味が違う（NCXse の CC0/32/7 は Bank Select / 音量で
        // あって Keystage の席ではない。実測 2026-08-10）ので、経路ごと分ける
        status = MIDIInputPortCreateWithProtocol(
            client, "secondKeyboard" as CFString, ._1_0, &secondKeyboardPort
        ) { eventList, _ in
            Self.handle(eventList, route: { routerRef.routeSecondKeyboard($0, $1, $2) })
        }
        guard status == noErr else { throw MIDIError.portCreate(status) }

        connectSources()
    }

    /// 名前 1 つの結線先（純関数 — テスト対象）。nil = 繋がない。
    ///
    /// ⭐ **未知の鍵盤は捨てない**（mako 裁定 2026-09-26「スタジオにある MIDI
    /// 鍵盤を Keystage の代わりに」）: Keystage 不在ならシンセ入力 1（keyboard
    /// 経路、汎用の通行証）、居れば鍵盤 2。ROTO（`RotoService` が自前で繋ぐ）と
    /// 仮想ポート（IAC / Network）は鍵盤ではないので繋がない
    static func route(forSourceName name: String, hasKeystage: Bool) -> MIDISourceRoute? {
        if name.contains("Keystage") { return .keystage }
        if name.contains("LPD8") { return .drums }
        // Arturia MiniLab mkII = **鍵盤 2**（mako 裁定 2026-08-22
        // 「NCXse と同じで、別の楽器にしたい」）。担当はタイル右クリック
        // 「鍵盤 2 をこの席に固定」（nil = 選択に追従）。
        // 全 25 鍵の健全性は実測済み（2026-08-22 スニファ 2 周 —
        // 「鍵盤 2 つ壊れてそう」は配線されていなかっただけ）
        if name.contains("MiniLab") { return .secondKeyboard }
        if name.contains("NCXse") {
            // ⚠️ `-controller` は**意図的に繋がない** — スティックとベンドが
            // ch1/ch2 へ複製されて二重に届くうえ、音量ノブ（CC7）と掃除
            // バースト（CC121/123）の発生源（実測 2026-08-10）。
            // 演奏に要るものは全部 `-keyboard` 側に揃っている
            return name.contains("keyboard") ? .secondKeyboard : nil
        }
        let lowered = name.lowercased()
        if lowered.contains("roto") || lowered.contains("iac") || lowered.contains("network") {
            return nil
        }
        return hasKeystage ? .secondKeyboard : .genericKeyboard
    }

    /// 名前の一覧 → 結線（Keystage の有無は一覧全体で決める）
    static func plan(sourceNames: [String]) -> [MIDIConnectedSource] {
        let hasKeystage = sourceNames.contains { $0.contains("Keystage") }
        return sourceNames.compactMap { name in
            route(forSourceName: name, hasKeystage: hasKeystage).map {
                MIDIConnectedSource(name: name, route: $0)
            }
        }
    }

    /// ソースを列挙し、名前で経路に接続する
    private func connectSources() {
        connectedSources = []
        connected = []
        keystageSourceCount = 0
        // 繋ぎ直したら測り直す — 呼ばないと抜いても最後の BPM が残る
        router.resetClock()
        let sources = (0..<MIDIGetNumberOfSources()).map { MIDIGetSource($0) }
        let names = sources.map { Self.displayName(of: $0) ?? "(unknown)" }
        // ⚠️ **いったん全部抜く** — 汎用鍵盤は Keystage の挿抜で刺し先が
        // 変わる（鍵盤 1 ⇄ 鍵盤 2）ので、前回の接続が残ると 2 経路に届く。
        // 未接続のソースを抜いてもエラーが返るだけで害はない
        for source in sources {
            for port in [keyboardPort, drumsPort, secondKeyboardPort] {
                MIDIPortDisconnectSource(port, source)
            }
        }
        let planned = Self.plan(sourceNames: names)
        for (source, name) in zip(sources, names) {
            guard let entry = planned.first(where: { $0.name == name }) else { continue }
            switch entry.route {
            case .keystage:
                // Keystage は KBD/CTRL の 2 ポートを持つ。両方 keyboard 経路。
                // **1-based の番号を refCon で持たせる**（0 は「不明」に使う）。
                // Clock の集計にこの番号が出るので、下のログと突き合わせれば
                // どのエンドポイントが送っているか分かる
                keystageSourceCount += 1
                let marker = UnsafeMutableRawPointer(bitPattern: keystageSourceCount)
                MIDIPortConnectSource(keyboardPort, source, marker)
                connectedSources.append("\(name) → keyboard(src#\(keystageSourceCount))")
            case .genericKeyboard:
                // 汎用鍵盤 = シンセ入力 1（Keystage 不在）。番号は Keystage と
                // 同じ列で振る（Clock の集計用）、origin は上位ビットで印す
                keystageSourceCount += 1
                let marker = UnsafeMutableRawPointer(
                    bitPattern: keystageSourceCount | Self.genericMarker)
                MIDIPortConnectSource(keyboardPort, source, marker)
                connectedSources.append("\(name) → keyboard(汎用 src#\(keystageSourceCount))")
            case .drums:
                MIDIPortConnectSource(drumsPort, source, nil)
                connectedSources.append("\(name) → drums")
            case .secondKeyboard:
                MIDIPortConnectSource(secondKeyboardPort, source, nil)
                connectedSources.append("\(name) → 鍵盤2")
            }
            connected.append(entry)
        }
        NSLog("MIDI sources: %@", connectedSources.isEmpty ? "(none)" : connectedSources.joined(separator: ", "))
    }

    /// UMP イベントリストから MIDI 1.0 チャンネルボイスを取り出す。
    /// word を渡すと生 UMP word も全通し（SysEx 再組立用 — MT2 経路は不変）
    private static func handle(
        _ eventList: UnsafePointer<MIDIEventList>,
        route: (UInt8, UInt8, UInt8) -> Void,
        word: ((UInt32) -> Void)? = nil
    ) {
        for packet in eventList.unsafeSequence() {
            let wordCount = Int(packet.pointee.wordCount)
            withUnsafePointer(to: packet.pointee.words) { tuplePtr in
                tuplePtr.withMemoryRebound(to: UInt32.self, capacity: 64) { words in
                    for i in 0..<min(wordCount, 64) {
                        if let message = UMP.parseChannelVoice(words[i]) {
                            route(message.status, message.data1, message.data2)
                        }
                        word?(words[i])
                    }
                }
            }
        }
    }

    private static func displayName(of endpoint: MIDIEndpointRef) -> String? {
        var name: Unmanaged<CFString>?
        guard MIDIObjectGetStringProperty(endpoint, kMIDIPropertyDisplayName, &name) == noErr else {
            return nil
        }
        return name?.takeRetainedValue() as String?
    }
}

enum MIDIError: Error {
    case clientCreate(OSStatus)
    case portCreate(OSStatus)
}

/// RT スレッド（ポートコールバック）からメインへ SysEx フレームを渡す中継器。
/// ハンドラの差し替えはロックで守る（設定はメイン、emit は RT から来る）
final class SysExRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable ([UInt8]) -> Void)?

    func setHandler(_ handler: (@Sendable ([UInt8]) -> Void)?) {
        lock.lock()
        defer { lock.unlock() }
        self.handler = handler
    }

    func emit(_ frame: [UInt8]) {
        lock.lock()
        let handler = handler
        lock.unlock()
        guard let handler else { return }
        DispatchQueue.main.async { handler(frame) }
    }
}
