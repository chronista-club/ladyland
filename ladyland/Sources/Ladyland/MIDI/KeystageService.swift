//! Keystage の ARP / CHORD 設定を送り込む常駐サービス（docs/keystage/README.md）。
//!
//! **push 型 — ladyland が SSOT**。本体で操作した内容はホストから読めない
//! （Dump 要求で返るのは保存済みの値で、作業中の状態は含まれない）ので、
//! 「どちらが正か」の問題が起きない。設定は ladyland が持ち、変わるたびに送る。
//!
//! 送信の手順（Scene / Global 共通）:
//! ```
//!   Dump 要求 → decode7bit → 該当バイトを書き換え → encode7bit → 同じ Func で返す → ACK
//! ```
//! **書いた直後に読み直しても古い値が返る**（二重バッファ）— 失敗ではない。
//! 実機の音は変わっている（2026-08-04 に Transpose で確認）。
//!
//! ⚠️ ARP / CHORD の **on/off は Dump に載らない**ので、ホストからは起こせない。
//! 起動は手で、中身はここから。
//!
//! RotoService と同じ「アプリ内常駐オブジェクト」— 別プロセスの daemon ではない。

import CoreMIDI
import Foundation
import KeystageKit
import Lpd8Kit

@MainActor
final class KeystageService: ObservableObject {
    // ── 接続 ──
    private var client: MIDIClientRef?
    private var inputPort = MIDIPortRef()
    private var destination: MIDIEndpointRef?
    private(set) var connected = false

    /// Device Inquiry で判明する機器の素性
    private var globalChannel: UInt8 = 0
    private var model = Keystage.Model.keys49

    /// **接続手順の切り分けフラグ**（mako 実測 2026-08-07
    /// 「ladyland 起動後に PAGE -/+ も VALUE も反応しなくなる」）。
    ///
    /// ⚠️ **差し直して初めて本当の姿が出た** — Controller Mode は
    /// **アプリを終了しても機材に居座る**ので、⌘Q だけでは
    /// 「ladyland の影響が無い状態」になっていなかった。
    ///
    /// 犯人は接続手順の 2 通のどちらか。**1 つずつ止めて切り分ける**:
    ///
    /// | | doc の主張 | 犯人なら |
    /// |---|---|---|
    /// | `connect`（`0x6F`） | 「ノブの CC 割当を変えないので 16 ページと両立する」 | ⚠️ その主張が**誤り** |
    /// | `controllerModeChange`（`0x49`） | 「Assignable でないと CC が DAW 規約に固定される」 | ⚠️ **Assignable と PAGE は交換条件**（両取りできない） |
    ///
    /// ⚠️ **既定は on**（`=0` で切る。会場の退避路と同じ作法）
    enum Handshake {
        static let sendsConnect =
            ProcessInfo.processInfo.environment["LADYLAND_KEYSTAGE_CONNECT"] != "0"
        static let sendsAssignable =
            ProcessInfo.processInfo.environment["LADYLAND_KEYSTAGE_ASSIGNABLE"] != "0"

        /// ⭐ **握手を済ませてから切断（`0x6F` payload 00）を送る**
        /// （mako 実測 2026-08-07、Creo `mem_1CdoJuszsybz3xU9buFFmT`）:
        ///
        /// > `connect` を送ると Keystage の PAGE が死ぬ。**握手（Dump 取得）を
        /// > 済ませてから切断を送れば、PAGE が生きたまま設定も読める**
        ///
        /// ⭐ **これが「両取り」の答え**。`CONNECT=0` だと Dump が返らない
        /// （Dump は `0x6F` の後でないと来ない、実測 2026-08-04）ので、
        /// **繋いで読んでから離す**しかない。
        ///
        /// ⚠️ **既定を on にした**（mako 判断委任 2026-08-07）。理由:
        /// **PAGE が死ぬのは再現済みの実害**で、8/8 は明日。フラグを
        /// 思い出す必要がある状況を作らない。⚠️ **未確認**（切断後の
        /// OLED 表示 `0x28` / Clock → BPM）は残るが、**`=0` で今日までの
        /// 挙動へ戻せる**ので退避路は確保してある。
        ///
        /// ⚠️ **焼くときだけ繋ぎ直す** — `burnLadylandButtons` は Scene を
        /// 書き戻すので、その前後で接続と切断を挟む（`withConnection`）
        static let releasesAfterHandshake =
            ProcessInfo.processInfo.environment["LADYLAND_KEYSTAGE_RELEASE"] != "0"

        /// ⚠️⚠️ **切断は「繋いだとき」にしか意味が無い。**
        /// `CONNECT=0` なら `0x6F` を一度も送っていないので、切断も送らない —
        /// **送っていない接続を切る**と実機に何が起きるか分からない。
        ///
        /// ⭐ **この規則を値にしてある**。実装（`withConnection` / 握手の末尾）も
        /// テストもここを引くので、⚠️ **条件を書き写して片方だけ直る事故が起きない**
        static var bracketsWrites: Bool { releasesAfterHandshake && sendsConnect }

        /// ノブ OLED への表示（`KeystageOled`）。⚠️ **既定 off**（mako 裁定
        /// 2026-08-10）— 実機のファームウェア制約で**恒久表示が不可能**
        /// （0x28 は接続中のみ有効・切断約 1 秒後に実機が CCn へ描き直す・
        /// 接続しっぱなしは PAGE が死ぬ）。1 秒で消える表示のために接続
        /// パルスを払う価値なし。`=1` で「切替時 1 回のフラッシュ表示」として
        /// 試せる — ファームウェア更新で制約が変わったらここから復活
        static let sendsOled =
            ProcessInfo.processInfo.environment["LADYLAND_KEYSTAGE_OLED"] == "1"

        /// ⚠️ **起動時に現状を 1 行**（`roto flags:` と同じ作法）。
        /// 会場でフラグを思い出す必要がある状況 = 何かが壊れている状況
        static var describe: String {
            "keystage flags: CONNECT=\(sendsConnect ? "on" : "off")"
                + " / ASSIGNABLE=\(sendsAssignable ? "on" : "off")"
                + " / RELEASE=\(releasesAfterHandshake ? "on" : "off")"
                + " / OLED=\(sendsOled ? "on" : "off")"
                + "（OLED だけ既定 off = `=1` で有効。他は既定 on = `=0` で切る）"
        }
    }

    /// 直近に受け取った Scene Dump（デコード済み 8bit）。
    /// **書き込みは常にこれを土台にする** — ノブ割当やシーン名を巻き添えに
    /// しないため、こちらが知らないバイトはそのまま返す
    private var sceneDump: [UInt8]?

    /// 直近に受け取った Global Dump（デコード済み 8bit）。
    /// **User Chord Set 32 個**がここに入っている（Preset は機器内蔵で含まれない）
    @Published private(set) var globalDump: [UInt8]?

    /// 実機から初期値を読めたときに呼ばれる（AppState が設定を差し替える）
    var onSettingsLoaded: ((KeystageSettings) -> Void)?

    /// Global Dump（User Chord Set）を読めたときに呼ばれる
    var onGlobalLoaded: (([UInt8]) -> Void)?

    /// 最後に送った設定（差分送信用 — 同じものを繰り返し送らない）
    private var lastSent: KeystageSettings?

    /// SysEx は往復があるので専用キューで直列に捌く
    private let queue = DispatchQueue(label: "ladyland.keystage")

    /// 受信箱（CoreMIDI コールバックは直列なのでロックは軽い）
    private final class Inbox: @unchecked Sendable {
        private let lock = NSLock()
        private var frames: [[UInt8]] = []
        func add(_ frame: [UInt8]) {
            lock.lock()
            frames.append(frame)
            // ⚠️ 溜めっぱなしにしない — 握手のあとは誰も drain しないので、
            // 実機が Push を送り続けると際限なく育つ
            if frames.count > 64 { frames.removeFirst(frames.count - 64) }
            lock.unlock()
            // 受信フレームを 1 行ずつ残す。**握手のあと ladyland は drain して
            // いない**ので、ここに出さないと実機が何か送っていても気づけない。
            //
            // ⚠️ 観測で分かったこと（2026-08-05）: **BPM を変えても SysEx は
            // 飛んでこない**。Func 2B/41 が BPM 専用と文書化されているが
            // （KeystageProtocol.swift 冒頭）、Push は来ない — テンポは
            // MIDI Clock でしか取れない。握手時の 3 通で打ち止めなので、
            // 頻度は低くログを埋めない
            NSLog(
                "keystage: [受信SysEx] %@ (%d byte)",
                frame.prefix(12).map { String(format: "%02X", $0) }.joined(separator: " "),
                frame.count)
        }
        func drain() -> [[UInt8]] {
            lock.lock()
            defer { lock.unlock() }
            let out = frames
            frames = []
            return out
        }
    }
    private let inbox = Inbox()

    func start() {
        connect()
    }

    /// 挿抜時（MIDIInput.onSetupChanged から）
    func reconnect() {
        // ⭐ 挿抜通知（msgSetupChanged）= 新しい合図なので、再列挙の予算を戻す。
        // ⚠️ 再試行側からここを呼ぶな（予算が戻って無限ループ。`MIDIRescan`）
        rescanAttempt = 0
        connected = false
        destination = nil
        sceneDump = nil
        lastSent = nil
        // ⚠️ 影は送信記録であって実機の状態ではない — 挿し直したら白紙
        // （ROTO の `RotoShadow.invalidate` と同じ作法）
        oledShadow.removeAll()
        connect()
    }

    // MARK: - ノブ OLED（Func 0x28。`KeystageOled` 参照）

    /// 最後に**送った**表示（キー = "a{address}l{line}"）。
    /// ⚠️ **実機がそう表示している保証ではない**（送ったものを真実として
    /// 持たない — 表示専用の差分抑止キャッシュ）
    private var oledShadow: [String: String] = [:]

    /// ページ 1 枚ぶんをノブ OLED へ書く（変わった行だけ）。
    ///
    /// ⚠️ **書く間だけ繋ぎ直す**（`withConnection` — ボタン焼きと同じ作法。
    /// 繋ぎっぱなしは PAGE を殺す）。**切断後に表示が残るかは未検証** —
    /// 消えるようなら `KeystageOled` 冒頭の設計メモを見て選び直す
    /// force = 影を捨てて全行書く。⚠️ **実機が自分で再描画したあとに使う** —
    /// VALUE 操作やノブ回しで実機はネイティブの CCn 表示へ戻るが、影は
    /// 「送った文字がまだ出ている」と信じて再送を間引く（mako 実測 2026-08-10
    /// 「一瞬書き換わるんだけど元の CCn の表示に戻る」— ROTO で 3 度踏んだ
    /// 「送ったものを真実として持つ」病の Keystage 版）
    func pushOled(page: Int, faces: [KeystageOled.KnobFace], force: Bool = false) {
        guard Handshake.sendsOled, connected, let destination else { return }
        if force { oledShadow.removeAll() }
        let lines = KeystageOled.lines(page: page, faces: faces)
        let changed = lines.filter { oledShadow[$0.key] != $0.text }
        guard !changed.isEmpty else { return }
        // ⚠️ 影は main 側で前進させる（送信記録であって実機の保証ではない）。
        // queue 側へは値だけ渡す — isolated な自分を跨がせない
        for line in changed { oledShadow[line.key] = line.text }
        let channel = globalChannel
        let model = self.model
        queue.async {
            Self.withConnection(channel: channel, model: model, destination: destination) {
                for line in changed {
                    MIDISysExSender.send(
                        KeystageOled.frame(
                            address: line.address, line: line.line, text: line.text,
                            channel: channel, model: model),
                        to: destination)
                    Thread.sleep(forTimeInterval: 0.005)
                }
            }
            NSLog("keystage: OLED %d 行を書いた（P%d）", changed.count, page + 1)
        }
    }

    /// 起動レースの再列挙（`MIDIRescan` 参照。実測 2026-08-09 — 実機が
    /// 繋がっているのに列挙が空で、通知も来ないので永遠に盲目だった）
    private var rescanAttempt = 0

    private func scheduleRescan() {
        guard let delay = MIDIRescan.delay(afterAttempt: rescanAttempt) else { return }
        rescanAttempt += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.connected else { return }
            NSLog("keystage: 再列挙 %d 回目（起動レースの救済）", self.rescanAttempt)
            self.connect()
        }
    }

    // MARK: - 接続

    private func connect() {
        if client == nil {
            guard let created = try? MIDISysExSender.makeClient("ladyland-keystage") else {
                return
            }
            client = created
            makeInputPort(created)
        }
        // DAW ポートを優先（公式スクリプトの実証と同じ）
        var candidates: [(String, MIDIEndpointRef)] = []
        for i in 0..<MIDIGetNumberOfDestinations() {
            let dest = MIDIGetDestination(i)
            if let name = Self.displayName(of: dest), name.contains("Keystage") {
                candidates.append((name, dest))
            }
        }
        guard let target = candidates.first(where: { $0.0.contains("DAW") }) ?? candidates.first
        else {
            NSLog("keystage: 実機なし（挿されたら再接続）")
            scheduleRescan()
            return
        }
        destination = target.1
        connected = true
        NSLog("keystage: 接続 — %@", target.0)

        // Device Inquiry → 0x6F 接続 → Scene Dump 要求、の順に往復する。
        // **Dump は 0x6F 接続の後でないと返ってこない**（実測 2026-08-04）
        handshakeAndLoad()
    }

    private func makeInputPort(_ client: MIDIClientRef) {
        // ⚠️ **アセンブラはコールバックの外**で作る。中で作ると呼ばれるたびに
        // 状態がリセットされ、複数コールバックに跨る長い Dump（584 byte）が
        // 永久に組み上がらない（短い ACK だけ届いて Dump が来ない、という
        // 切り分けの難しい症状になる）
        var assembler = SysEx7Assembler()
        let status = MIDIInputPortCreateWithProtocol(
            client, "keystage-in" as CFString, ._1_0, &inputPort
        ) { [inbox] eventList, _ in
            for packet in eventList.unsafeSequence() {
                let count = Int(packet.pointee.wordCount)
                withUnsafePointer(to: packet.pointee.words) { tuple in
                    tuple.withMemoryRebound(to: UInt32.self, capacity: 64) { words in
                        for i in 0..<min(count, 64) {
                            if let frame = assembler.feed(words[i]) { inbox.add(frame) }
                        }
                    }
                }
            }
        }
        guard status == noErr else {
            NSLog("keystage: 入力ポート作成に失敗 (%d)", status)
            return
        }
        for i in 0..<MIDIGetNumberOfSources() {
            let source = MIDIGetSource(i)
            if (Self.displayName(of: source) ?? "").contains("Keystage") {
                MIDIPortConnectSource(inputPort, source, nil)
            }
        }
    }

    /// 握手して現在の Scene Dump を読む（起動時 1 回）
    private func handshakeAndLoad() {
        guard let destination else { return }
        queue.async { [weak self] in
            guard let self else { return }
            // 1. Device Inquiry で global ch と機種を判別
            _ = self.inbox.drain()
            MIDISysExSender.send([0xF0, 0x7E, 0x7F, 0x06, 0x01, 0xF7], to: destination)
            Thread.sleep(forTimeInterval: 0.8)
            var channel: UInt8 = 0
            var detected = Keystage.Model.keys49
            for frame in self.inbox.drain()
            where frame.count >= 10 && frame[1] == 0x7E && frame[5] == 0x42 {
                channel = frame[2] & 0x0F
                detected = frame[8] == 0x09 ? .keys61 : .keys49
            }

            // 2. 0x6F 接続（Ableton 方式）。
            // ⚠️ **`=0` で止められる**（`Handshake`）— PAGE ページ送りを
            // 殺している疑いのある 2 通のうちの 1 つ
            if Handshake.sendsConnect {
                MIDISysExSender.send(
                    Keystage.frame(
                        .connect, data: [0x01], globalChannel: channel, model: detected),
                    to: destination)
                Thread.sleep(forTimeInterval: 0.3)
            }

            // 2b. **Controller Mode を Assignable に固定**（mako 2026-08-05
            // 「Receive したら Live になった」）。
            //
            // ⚠️ Assignable 以外だと**ノブの CC がその DAW の規約に固定される**。
            // ladyland は独自ホストなので 16 ページの割当が丸ごと壊れる。
            //
            // 上の `0x6F` は Ableton 公式スクリプトの方式なので、**実機が
            // 「Live で繋がれた」と解釈して切り替えている疑い**がある
            // （未確定 — 実機が勝手に戻る現象の説明として最有力）。
            // 害が無いので毎回送って固定する
            // ⚠️ **`=0` で止められる**（`Handshake`）— こちらがもう 1 つの疑い
            if Handshake.sendsAssignable {
                MIDISysExSender.send(
                    Keystage.frame(
                        .controllerModeChange,
                        data: [Keystage.ControllerMode.assignable.rawValue],
                        globalChannel: channel, model: detected),
                    to: destination)
                Thread.sleep(forTimeInterval: 0.2)
            }
            for received in self.inbox.drain()
            where Keystage.function(of: received) == .controllerModeChanged {
                let mode = Keystage.payload(of: received)?.first
                    .flatMap { Keystage.ControllerMode(rawValue: $0) }
                NSLog(
                    "keystage: Controller Mode = %@",
                    mode?.label ?? "不明（応答を解釈できない）")
            }

            // 3. Scene Dump を吸う
            _ = self.inbox.drain()
            MIDISysExSender.send(
                Keystage.frame(.sceneDumpRequest, globalChannel: channel, model: detected),
                to: destination)
            Thread.sleep(forTimeInterval: 1.2)
            var dump: [UInt8]?
            for frame in self.inbox.drain() {
                guard Keystage.function(of: frame) == .sceneDump,
                    let payload = Keystage.payload(of: frame)
                else { continue }
                dump = Keystage.decode7bit(payload)
            }

            // 4. ⭐ **読み終えたら離す**（`RELEASE`）。
            // **PAGE を返してもらうのが目的** — 繋ぎっぱなしだと実機の
            // PAGE -/+ が死ぬ（実測 2026-08-07）。⚠️ **順番が本体**:
            // 握手 → Dump 取得 → 切断。先に切ると Dump が返らない
            if Handshake.bracketsWrites {
                MIDISysExSender.send(
                    Keystage.frame(
                        .connect, data: [0x00], globalChannel: channel, model: detected),
                    to: destination)
                Thread.sleep(forTimeInterval: 0.2)
                NSLog("keystage: 切断を送った（PAGE を返す。LADYLAND_KEYSTAGE_RELEASE=0 で止まる）")
            }

            Task { @MainActor [weak self] in
                guard let self else { return }
                self.globalChannel = channel
                self.model = detected
                guard let dump else {
                    NSLog("keystage: Scene Dump が返ってこなかった（設定の送信はできない）")
                    return
                }
                self.sceneDump = dump
                NSLog(
                    "keystage: 握手完了 — global ch %d / %@ / Dump %d byte",
                    Int(channel) + 1, detected == .keys61 ? "61鍵" : "49鍵", dump.count)
                if let loaded = Keystage.settings(from: dump) {
                    self.onSettingsLoaded?(loaded)
                    self.lastSent = loaded
                }
            }
        }
    }

    // MARK: - 送信

    /// **ボタンの CC を ladyland の規約で焼く**（mako 裁定 2026-08-05
    /// 「こっちで上書きして、Editor で receive します」）。
    ///
    /// ノブは CC 番号を持てない（位置で固定）が、**ボタンは自由**。
    /// 実用領域のど真ん中に散らばっているのを危険牌の領域へ寄せると、
    /// 安全な席が 9 個返ってくる。
    ///
    /// ⚠️ Scene Dump ごと送り返すので、**いま実機にある他の設定も一緒に書き戻る**。
    /// 握手で読んだ Dump が古いと、その間の実機側の変更を巻き戻してしまう
    func burnLadylandButtons() {
        guard connected, let destination, let base = sceneDump else {
            NSLog("keystage: ⚠️ ボタンを焼けない（未接続か Dump 未取得）")
            return
        }
        let before =
            (Keystage.ButtonOffset.Button.allCases.map {
                "\($0.label)=\(Keystage.buttonCC(base, $0).map(String.init) ?? "—")"
            }
            + Keystage.EncoderOffset.Encoder.allCases.map {
                "\($0.label)=\(Keystage.encoderCC(base, $0).map(String.init) ?? "—")"
            }).joined(separator: " ")
        let dump = Keystage.applyingLadylandButtons(base)
        sceneDump = dump
        // ⚠️ **書き換えた dump を読み直して検算する**（実測 2026-08-05:
        // ログには「後: CC96…」と出たのに EDITOR で Receive すると古いままだった）。
        // 定義値をそのまま出していては、書き換えが効いたか分からない
        let after =
            (Keystage.ButtonOffset.Button.allCases.map {
                "\($0.label)=\(Keystage.buttonCC(dump, $0).map(String.init) ?? "—")"
            }
            + Keystage.EncoderOffset.Encoder.allCases.map {
                "\($0.label)=\(Keystage.encoderCC(dump, $0).map(String.init) ?? "—")"
            }).joined(separator: " ")
        NSLog("keystage: ボタンを焼く\n  前: %@\n  後: %@（dump から読み直した値）",
            before, after)

        let frame = Keystage.frame(
            .sceneDump, data: Keystage.encode7bit(dump),
            globalChannel: globalChannel, model: model)
        let channel = globalChannel
        let detected = model
        queue.async { [weak self] in
            guard let self else { return }
            Self.withConnection(channel: channel, model: detected, destination: destination) {
            _ = self.inbox.drain()
            MIDISysExSender.send(frame, to: destination)
            Thread.sleep(forTimeInterval: 0.5)
            for received in self.inbox.drain() where Keystage.function(of: received) == .nak {
                NSLog("keystage: ⚠️ NAK — ボタンの書き込みが拒否された")
                return
            }

            // ⚠️ **ここまでは current scene（揮発）にしか書けていない**
            // （実測 2026-08-05: mako が Receive しても古い CC のままだった）。
            //
            // Keystage の Dump は二重構造で、書き込み先は `current scene data`、
            // KONTROL EDITOR が読むのは `internal memory`。
            // **Write Request（Func 11）を送って初めて保存される**
            // （実装チャート L379-393）。応答は Func 21（完了）か 22（失敗）。
            NSLog("keystage: Scene %d へ保存する（Write Request）", Self.ladylandScene)
            MIDISysExSender.send(
                Keystage.frame(
                    .sceneWriteRequest, data: [UInt8(Self.ladylandScene)],
                    globalChannel: channel, model: detected),
                to: destination)
            Thread.sleep(forTimeInterval: 1.0)
            var saved = false
            for received in self.inbox.drain() {
                switch Keystage.function(of: received) {
                case .writeComplete:
                    saved = true
                case .writeError:
                    NSLog("keystage: ⚠️ 保存に失敗した（Write Error）")
                    return
                default:
                    break
                }
            }
            NSLog(
                "keystage: ボタンを焼き終えた — %@",
                saved
                    ? "保存済み（KONTROL EDITOR の Receive で読める）"
                    : "⚠️ 保存の応答が返らなかった（current scene には載っている）")
            }
        }
    }

    /// **ladyland が使う Scene 番号**（0-7）。
    /// KONTROL EDITOR の左上に並ぶシーンのうち、先頭（`LadyLand`）を使う
    nonisolated static let ladylandScene = 0

    /// 設定を実機へ送り込む。**変わっていなければ何もしない**
    func apply(_ settings: KeystageSettings) {
        guard connected, let destination, let base = sceneDump else { return }
        guard settings != lastSent else { return }
        lastSent = settings

        let dump = Keystage.applying(settings, to: base)
        sceneDump = dump
        let frame = Keystage.frame(
            .sceneDump, data: Keystage.encode7bit(dump),
            globalChannel: globalChannel, model: model)
        let channel = globalChannel
        let detected = model

        queue.async { [weak self] in
            guard let self else { return }
            Self.withConnection(channel: channel, model: detected, destination: destination) {
                _ = self.inbox.drain()
                MIDISysExSender.send(frame, to: destination)
                Thread.sleep(forTimeInterval: 0.5)
                for received in self.inbox.drain() {
                    if Keystage.function(of: received) == .nak {
                        NSLog("keystage: NAK — 設定が拒否された")
                        return
                    }
                }
            }
        }
    }

    // MARK: - User Chord Set（Global Dump）

    /// Global Dump を吸う。**User Chord Set の中身を見るのに要る**
    /// （Preset は機器内蔵なので Dump に含まれない）
    func loadGlobalDump() {
        guard connected, let destination else { return }
        let channel = globalChannel
        let detected = model
        queue.async { [weak self] in
            guard let self else { return }
            var dump: [UInt8]?
            Self.withConnection(channel: channel, model: detected, destination: destination) {
                _ = self.inbox.drain()
                MIDISysExSender.send(
                    Keystage.frame(.globalDumpRequest, globalChannel: channel, model: detected),
                    to: destination)
                Thread.sleep(forTimeInterval: 2.0)  // Global は Scene より大きい
                for frame in self.inbox.drain() {
                    guard Keystage.function(of: frame) == .globalDump,
                        let payload = Keystage.payload(of: frame)
                    else { continue }
                    dump = Keystage.decode7bit(payload)
                }
            }
            Task { @MainActor [weak self] in
                guard let dump else {
                    NSLog("keystage: Global Dump が返ってこなかった")
                    return
                }
                NSLog("keystage: Global Dump %d byte", dump.count)
                self?.globalDump = dump
                self?.onGlobalLoaded?(dump)
            }
        }
    }

    /// User セットを別の User セットへ写して実機へ送る（12 キー + 名前）
    func copyChordSet(from source: Int, to target: Int) {
        guard let base = globalDump else { return }
        sendGlobal(Keystage.copyingChordSet(base, from: source, to: target))
    }

    /// User セット（0-31）に名前を付けて実機へ送る（6 字まで）
    func writeChordSetName(set: Int, name: String) {
        guard let base = globalDump else { return }
        sendGlobal(Keystage.settingChordSetName(base, set: set, name: name))
    }

    /// User セット（0-31）の 1 キーに和音を書いて実機へ送る。
    /// **Global Dump を土台にする**ので、他のセットや設定は巻き添えにしない
    func writeChord(set: Int, key: Int, notes: [UInt8]) {
        guard let base = globalDump else { return }
        sendGlobal(Keystage.settingChord(base, set: set, key: key, notes: notes))
    }

    /// 書き換えた Global Dump を実機へ送る（和音・セット名で共通）
    private func sendGlobal(_ updated: [UInt8]) {
        guard connected, let destination else { return }
        globalDump = updated
        onGlobalLoaded?(updated)
        let frame = Keystage.frame(
            .globalDump, data: Keystage.encode7bit(updated),
            globalChannel: globalChannel, model: model)
        let channel = globalChannel
        let detected = model
        queue.async { [weak self] in
            guard let self else { return }
            Self.withConnection(channel: channel, model: detected, destination: destination) {
                _ = self.inbox.drain()
                MIDISysExSender.send(frame, to: destination)
                Thread.sleep(forTimeInterval: 0.8)
                for received in self.inbox.drain()
                where Keystage.function(of: received) == .nak {
                    NSLog("keystage: NAK — 和音の書き込みが拒否された")
                    return
                }
            }
        }
    }

    /// ⭐ **書き込みの間だけ繋ぎ直して、終わったら必ず離す**（`RELEASE`）。
    ///
    /// 起動時に切断（`0x6F` payload 00）を送って **PAGE を実機へ返している**
    /// ので、Scene / Global を書き戻すときはその間だけ繋ぐ。
    ///
    /// ⚠️ **`defer` で離すのが本体** — NAK や Write Error の**早期 return でも
    /// 必ず離れる**。離し忘れると **PAGE が死んだまま**になり、しかも症状が
    /// 「焼いた後から PAGE が効かない」になって**原因が起動手順に見えなくなる**。
    ///
    /// ⚠️ `RELEASE=0`（退避路）のときは何も挟まない — 繋ぎっぱなしが正
    nonisolated static func withConnection(
        channel: UInt8, model: Keystage.Model, destination: MIDIEndpointRef,
        _ body: () -> Void
    ) {
        let brackets = Handshake.bracketsWrites
        if brackets {
            MIDISysExSender.send(
                Keystage.frame(.connect, data: [0x01], globalChannel: channel, model: model),
                to: destination)
            Thread.sleep(forTimeInterval: 0.3)
        }
        defer {
            if brackets {
                MIDISysExSender.send(
                    Keystage.frame(
                        .connect, data: [0x00], globalChannel: channel, model: model),
                    to: destination)
            }
        }
        body()
    }

    private static func displayName(of endpoint: MIDIEndpointRef) -> String? {
        var name: Unmanaged<CFString>?
        guard MIDIObjectGetStringProperty(endpoint, kMIDIPropertyDisplayName, &name) == noErr
        else { return nil }
        return name?.takeRetainedValue() as String?
    }
}
