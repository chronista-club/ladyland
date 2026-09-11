//! ROTO-CONTROL projector 常駐（docs/roto-control/protocol.md）。
//!
//! ⚠️ **方言は名乗り 1 バイト（`dawType`）で全レイヤーが入れ替わる**。
//! ラベル経路・モーターの CC 配置・入力デコードが連動して変わるので、
//! 片方だけ変えると必ず壊れる（2026-08-03 に実測で確定。protocol.md の
//! 「方言は名乗り 1 バイトで全レイヤーが入れ替わる」節）。
//!
//! 現在の採用: **種別 3（Logic）** — mako 裁定 2026-08-04。
//! セル数は 16 に減るが、**LCD のラベルを自由に書ける**方を取る
//! （Bitwig の PLUGIN 面は 64 セルあるが、表示はデバイスが完全に握っていて
//!  ホストからは変えられない — 4 通り試して全滅）。
//!
//!   SMART 面 = `0B 13` でノブ LCD に直接ラベル（16 セル = 8 × 2 ページ）
//!   MIX 面   = `0A 11` でトラックセルに名前 + 色（16 席まで）
//!   入出力   = ch15 (0xBE) の CC ペアに絶対パラメータ番号
//!
//! ⚠️ **Logic 方言では面の主導権がホストにある**。MODE キーだけでは SMART へ
//! 行けず、ch7 (0xB6) の CC を**押して離す**必要がある（`Roto.selectFace`）。
//! さらに**いる面だけ塗る** — 他の面のセル更新を送るとデバイスがそちらへ
//! 移動してしまい、MODE キーで抜けられなくなる。
//!
//! 種別 2（Bitwig）の経路も残してある（`dawType` を 2 に戻せば切り替わる）—
//! PLUGIN 面 64 セル・8 ページが使える代わりに、LCD の名前は固定になる。
//!
//! LedBus と同じ「アプリ内常駐オブジェクト」— 別プロセスの daemon ではない。
//! CoreMIDI コールバック駆動なのでスレッドは回さない。

import AVFoundation
import CoreMIDI
import Foundation
import Lpd8Kit
import RotoKit

@MainActor
final class RotoService {
    // ── 接続 ──
    private var client: MIDIClientRef?
    private var inputPort = MIDIPortRef()
    private var destination: MIDIEndpointRef?
    private(set) var connected = false

    // ── 投影ソース（AppState が結線）──
    private weak var rack: InstrumentRack?

    /// ROTO からの値変更 = AU パラメータ変更（常時保存のトリガー用）
    var onParamChanged: (() -> Void)?

    /// MIXER 冊のボタン = Track の直接選択（mako 裁定 2026-08-13）。
    /// 選択の波及（ルーティング / LED / 差分焼き / 保存）は AppState.select に
    /// 一本化されているため、ここでは番号を渡すだけ
    var onSelectTrack: ((Int) -> Void)?

    // ── MIDI モードのモーター同期（RotoMidiSync.swift）──
    private var midiSync = RotoMidiSync()
    /// ミキサーレーン（SETUP 01 = LL MIXER、ch2。CC = スロット番号 0-31）
    private var mixerSync = RotoMidiSync(seats: Array(0..<RotoMidiSetupExport.mixerTotalSlots))
    private var midiSyncTimer: Timer?
    private var midiRefreshTimer: Timer?

    /// 配色（設定画面から差し替える）。変えると全面を塗り直す
    var colors = Roto.Colors() {
        didSet {
            guard colors != oldValue else { return }
            invalidateLabels()
            projectFaces()
        }
    }

    // ── 双方向の帳簿 ──

    /// 最後に送った表示内容の影（差分送信の根拠）。中身と破棄の規則は
    /// `RotoShadow` に閉じている — ラベル / トラック / MENU / モーター位置
    private var shadow = RotoShadow()

    /// SMART/PLUGIN ノブの 14bit 値。MIX ノブとは番号が重なるため別帳簿。
    private var parameterValues = RotoValue14()

    /// PLUGIN 面で「起きている」セルの素性。デバイスが CONTROL_MAPPED で
    /// 聞いてきたセルだけがここに載る（＝実際に割当が保存されているセル）。
    ///
    /// **learn を再送するのに paramIndex と hash6 の両方が要る** — どちらも
    /// CONTROL_MAPPED で受けた値をそのまま echo しないとデバイスが受け付けない
    private struct MappedCell {
        let paramIndex: Int
        let hash6: [UInt8]
        let isMacro: Bool
    }
    private var mappedCells: [Int: MappedCell] = [:]

    /// PLUGIN 面のセルに最後に送った名前。**labelShadow とは別勘定** —
    /// 面が違えばラベルの経路も違う（SMART = 0B 13 直書き / PLUGIN = learn 応答）
    private var mappedNames: [Int: String] = [:]

    /// ROTO がいま表示している面（宣言と**面ごとの規則**は `RotoFace.swift`）
    ///
    /// ⚠️ **これは送信を決める値**（`paintsSmartCells` / `paintsTrackCells`）。
    /// 算出を変えると**送るものが変わる**ので、観測のために触ってはいけない。
    /// 「実機が本当にそこに居るか」は下の `faceBelief` が別に持つ
    private var currentFace: Face = .unknown

    /// **実機がどの面に居ると信じているか、そしてそれはどれくらい確かか**
    /// （mako 要望 2026-08-07。設計は `RotoFaceBelief.swift`）。
    ///
    /// ⚠️ **観測専用 — 送信には一切影響しない。** `currentFace` と並行して
    /// 持つのは、あちらが送信を握っていて**触ると送るものが変わる**から。
    /// 型もわざと違えてある（`Face` ではなく `String` を持つ）ので、
    /// 取り違えて代入するとコンパイルが通らない
    private(set) var faceBelief: FaceBelief = .unknown

    /// 信念を**確認**へ（デバイスの通知 `0B 01` / `0C 02` を受けたとき）。
    ///
    /// ⚠️ **ここが警報の発火点**。推定していた面と実機が食い違っていたら
    /// 必ずログを出す — 昨日「実機は PLUGIN、ログは face=SMART」に
    /// 誰も気づけなかったのは、この 1 行が無かったため
    private func confirmFace(_ label: String) {
        if let warning = FaceBelief.contradiction(faceBelief, observed: label) {
            NSLog("roto: %@", warning)
        }
        faceBelief = .confirmed(label, since: Date())
    }

    /// 信念を**推定**へ（こちらが送っただけ = 反証待ち）。
    ///
    /// ⚠️ **SMART はここから出られない** — デバイスが SMART 到着を通知しないので、
    /// 「確認」へ昇格する経路が構造上存在しない（`RotoFaceBelief.swift` の doc）
    private func assumeFace(_ label: String) {
        // 同じ面を推定し直しても「いつから」は動かさない
        // （送り直すたびに時計が戻ると、ズレが何秒続いているか読めなくなる）
        if case .assumed(let current, _) = faceBelief, current == label { return }
        faceBelief = .assumed(label, since: Date())
    }

    /// PLUGIN 面でいま表示しているページ（**← → の受信だけで動かす**）。
    ///
    /// Bitwig 方言のノブ入力は物理 8 本（ch16 CC12-19）に固定で、CC だけでは
    /// どのセルか分からない。デバイスは自分でページを繰って表示も変えるが、
    /// **`CONTROL_MAPPED` の controlIndex はページ内の位置（0-7）**で来るので、
    /// そこからページは逆算できない（実測 2026-08-04: 逆算していたときは
    /// ← → で進めた直後に 0 へ巻き戻り、ページ 2 から先へ行けなかった）
    private var pluginPage = 0

    /// SMART 面でいま出しているページ（**ladyland 側が持つ**）。
    ///
    /// mako 裁定 2026-08-04「Page 単位で 8 つずつ切り替え」。
    /// SMART 面は 2 ページで頭打ちなので、デバイスの ← → には頼らず
    /// **ホストが窓をずらす**。ROTO の枠（`0B 13` の idx）は 0-7 のまま、
    /// 中身だけ P1 → P2 → … と入れ替える
    private(set) var smartPage = 0

    /// 握手（firmware 通知）が返ったか。**保険の遅延投影を撃つかの判定**に使う
    private var handshakeDone = false

    /// **起動が落ち着いたか** — ⭐ `0B 01` を「人が FUNC を押した」と
    /// 読んで良いかの判定（mako 実機 2026-08-07 22:47）。
    ///
    /// ## ⚠️ `0B 01` には意味が 2 つある
    ///
    /// | 場面 | 意味 |
    /// |---|---|
    /// | 落ち着いた後 | ⭐ **FUNC が押された**（ピッカーを開く） |
    /// | **握手中** | ⚠️ **デバイスが面を通知しているだけ**（開いてはいけない） |
    ///
    /// 実機ログでは `ROTO_DAW_CONNECTED` の応答を返した**直後の同じ ms** に
    /// `0B 01` が来ていた。**起動のたびにピッカーが開いた状態で始まる**ので、
    /// mako からは「**FUNC を 2 度押した状態**」に見えていた。
    ///
    /// ## ⚠️ `handshakeDone` と分けてある
    ///
    /// あちらは「**firmware 通知が実際に来た**」という**実測の記録**で、
    /// `inspection` にもそのまま出る。ここを兼用すると、保険で立てた瞬間に
    /// 画面が「握手できた」と嘘をつく（**送ったものを真実として持つ**病）。
    ///
    /// ⭐ **保険（2 秒）でも立てる** — firmware 通知が返らない個体でも
    /// **FUNC が永久に死なない**（通知が来ない場合があるのは実測済みで、
    /// だから遅延投影の保険がある）
    private(set) var startupSettled = false

    /// ページが動いたことを画面へ知らせる（AppState が結線）。
    /// ⚠️ **ROTO のボタンからは繰れない**（実測 2026-08-04: ch16 は 1 通も
    /// 来ず、← → / SEL / MODE は MIDI を一切送っていない）。
    /// 繰るのは ladyland 側（画面 / ⌥←→）だけなので、その表示を合わせる
    var onPageChanged: (@MainActor () -> Void)?

    /// **いま実機がどうなっているか**（影の読み取り専用スナップショット。
    /// mako 要望 2026-08-06「ROTO の状態と一致してる shadow データを表示したい」）。
    ///
    /// ⚠️ **読むだけ**。影は差分抑止の根拠なので、表示のために触ると送信が
    /// 壊れる。ここは値のコピーを返すだけで、影も面も一切変えない
    var inspection: RotoInspection {
        RotoInspection(
            connected: connected,
            face: currentFace.label,
            belief: faceBelief,
            page: smartPage,
            handshakeDone: handshakeDone,
            // 空 = 次の投影で全セル送り直す（状態として重要）
            shadowEmpty: shadow.label.isEmpty,
            cells: RotoInspection.cells(
                shadow: shadow, knobs: RotoParam.physicalKnobs,
                cellForKnob: { RotoPageLayout.smartCell(page: self.smartPage, knob: $0) },
                // ⚠️ **`apply` が見ているのと同じ引き方**にする。ここがずれると
                // 「割当ありと出ているのに動かない」を作る
                isAssigned: { ctrl in
                    self.rack?.selectedSlot.knobMappings.contains { $0.knob == ctrl } ?? false
                }))
    }

    /// ページを繰る（画面 / ⌥←→ / **Keystage の Rec・Loop**
    /// （`KeystageControls.pageStep` = 104/105）から呼ぶ）。
    ///
    /// ⚠️ **ピッカーが開いていれば `▶` を動かすだけ**（mako 裁定 2026-08-07）。
    /// 選んでいる最中に裏でページが動くと、何を選んでいるか分からなくなる。
    ///
    /// **ここ 1 か所で分ける**のが要点 — 入口（`MIDIInput` / 画面 / キー）を
    /// 増やさずに済む。呼ぶ側は「ページを繰りたい」と言うだけでよく、
    /// ピッカー中かどうかを知らなくていい
    func stepSmartPage(_ delta: Int) {
        goToSmartPage(smartPage + delta, why: "繰った")
    }

    /// **ページ n へ直に飛ぶ**（Keystage のノブが送った CC からの推定）。
    ///
    /// ⭐ **PAGE +/- キーは MIDI 無音**（実測 2026-08-01）だが、`base = 0` の
    /// 今は **ノブが動いた瞬間に CC 番号がページを自己申告する**
    /// （`KeystageKnobs`）。その推定をここへ流すと、**PAGE キーが
    /// 全面のページ送りになる** — 遅延は「最初のノブ 1 動き」分だけ。
    ///
    /// ⚠️ **ピッカー中は飛ばさない** — 選んでいる最中に下が動くと、
    /// 何を選んでいるか分からなくなる（`stepSmartPage` と同じ規律）。
    ///
    /// ⚠️ **逆向き（ROTO/画面 → Keystage）は無い**。デバイスのページは
    /// 外から動かせないが、**CC が真実**なので**ノブの効き先は常に正しい** —
    /// ズレても見出しの話で済む
    func followKnobPage(_ page: Int) {
        goToSmartPage(page, why: "Keystage のノブから追従")
    }

    /// **ページ移動はここ 1 か所**（`stepSmartPage` / `followKnobPage` の実体）。
    ///
    /// ⚠️ **入口を増やしても効果は増やさない** — 影を捨てる / 250ms 待って
    /// 塗り直す、という作法をコピーすると片方だけ直す事故になる
    private func goToSmartPage(_ page: Int, why: String) {
        let moved = RotoPageLayout.clampedSmartPage(page)
        // ⚠️ **同じページなら何もしない** — ノブ回し中の CC 連打で毎回
        // 投影が走ると LCD が暴れる
        guard moved != smartPage else { return }
        smartPage = moved
        NSLog(
            "roto: SMART ページ %d へ（P%d-1〜P%d-8・%@）",
            moved + 1, moved + 1, moved + 1, why)
        onPageChanged?()
        pushPageLights()  // RK ライト = ページインジケータ（即時 — 手応え）
        shadow.invalidateSmartPage()  // 中身が総入れ替えになるので影を捨てる
        // ⚠️ **すぐ塗らない**（実測 2026-08-04「ページを繰ると LCD が消える」）。
        // ← → を受けたデバイスは自分でもページ送りを処理していて、その最中に
        // 届いた `0B 13` を落としているらしい。面切替（`0B 01`）でも同じ理由で
        // 0.3 秒待っている。連打しても最後の 1 回が正しい内容を塗る
        // （`smartPage` は最新、`shadow.label` が重複を抑える）
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            self?.projectFaces()
        }
    }

    /// ⭐ **RK ライト = ページインジケータ**（毎回 8 キー全塗り）。
    ///
    /// 実機ネイティブでは RK = MIX のミュートトグルで、LED はその状態表示。
    /// Transform 方針でボタンの意味はページ直選に乗っ取ったので、**LED も
    /// 「現在ページ」の意味で上書きする**。
    ///
    /// 7F = 点灯 / 00 = 消灯が**押下なしでも完全に効く**（実測 2026-08-11。
    /// 同日午前の「消せない」は注入毒で半死にの実機を相手にした誤測定 —
    /// Creo `mem_1CdvSucMFyzZ4BEpFgJVpX`）。差分方式（litPageKey）は廃止し
    /// **毎回 8 個を置き直す** — 実機保存のミュート染みがいつ復活しても、
    /// 次の一塗りで現在ページだけの形に均される（堆積の嘘が構造的に出ない）。
    /// ⚠️ MIX 面では点灯枠の LCD 下段「MUTE」が反転して見えるが、これは
    /// 実機の家具（ページ跳躍裁定 2026-08-11 の織り込み済み）
    private func pushPageLights() {
        guard !Self.quiet else { return }
        guard connected, let destination else { return }
        sender.sendRaw(Roto.pageLights(current: smartPage), to: destination, gap: 1_000)
    }

    /// 最後に SMART 面へ寄せた時刻（引き戻しの連打を防ぐ）
    private var lastFaceNudge: Date = .distantPast

    /// 最後に投影した firmware 通知の時刻（連投 2〜4 通の重複投影を防ぐ）
    private var lastFirmwareNotice: Date = .distantPast

    /// **SMART 面へ引き戻す**。Logic 方言でホストが表示を握れる唯一の面なので、
    /// 他の面へ移されたら戻す。
    ///
    /// ⚠️ 押し合いを避けるため **2 秒に 1 回まで**。デバイスが `0B 01` を
    /// 連投することがあり（実測 2026-08-04: 5 秒間隔で 2 通）、毎回応じると
    /// 面切替の往復でデバイスが固まりかねない
    /// ⚠️ **これは投影ではなく応答義務** — Logic 方言では面切替もホストの
    /// 仕事で、実機は MODE を押すと `0B 01`（PLUGIN 面にして）を**要求**して
    /// くるだけ。ここで面を選び返さないと表示が変わらず、**実機が固まった
    /// ように見える**（実測 2026-08-11 夜: ミニマムで止めていた間の「進行
    /// 不能」の正体。帳簿には 0B 01 が届き続けていた）。よって QUIET 以外は
    /// ミニマムでも送る
    private func returnToSmartFace() {
        guard !Self.quiet else { return }
        guard Self.dialect.hostSelectsFace, let destination else { return }
        guard Date().timeIntervalSince(lastFaceNudge) > 2.0 else {
            NSLog("roto: PLUGIN 面へ移されたが、引き戻しは 2 秒待つ")
            return
        }
        lastFaceNudge = Date()
        NSLog("roto: ⤴ SMART 面へ引き戻す")
        sender.sendRaw(Roto.selectFace(.smart), to: destination, gap: 20_000, after: 0.2)
        currentFace = .smart
        // ⚠️ **送っただけ** — SMART は通知が無いので推定のまま
        assumeFace("SMART")
        shadow.invalidateSmartPage()
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            self?.projectFaces()
        }
    }

    // ページピッカー（FUNC で開く 2 段構え）は 2026-08-11 に全撤去した
    // （mako「引っかかるのがいやなので、全部オミットして、RK1-8 使う方式に」）。
    // ⚠️ 撤去理由の記録: FUNC の実体は `0B 01`（実機が PLUGIN 面へ飛ぶ通知）で、
    // ピッカーは面の引き戻し合戦を内蔵していた — `0B 01` を 350ms 間隔で
    // 連投し合うループ（実測 2026-08-11 05:43）まで起こしていた。
    // 現在のページ選択は **RK1-8 の直選**（`decodeButton` — MIX 面で ch16
    // CC20-27 が届く、実測 2026-08-11）+ 画面 ‹›・⌥キー・Keystage Rec/Loop。

    /// 選択宣言（`0B 08`）— PLUGIN 面を起こす引き金。
    ///
    /// ⚠️ **これを送るとデバイスのページが 1 へ戻る**（実測 2026-08-04）。
    /// pages に現在ページを添えても戻ったので、ページを繰った後には送らない。
    /// 面に入るとき（0B 01）と選択通知への応答だけに使う
    private func selectCurrentPlugin(force: Bool = false) -> [UInt8] {
        Roto.selectPlugin(0, pages: UInt8(pluginPage), force: force)
    }

    /// 観測中のパラメータ（選択スロットの割当 8 本。切替時に張り替える）
    private var observed: [(param: AUParameter, token: AUParameterObserverToken)] = []

    /// ROTO へ出ていく**唯一の口**（順序 + ペーシングは `RotoSendQueue` の領分）。
    /// SysEx は 5ms ペーシングで直列送信（公式 Ableton スクリプト準拠 —
    /// main をブロックしないよう専用キューで usleep する）
    private let sender = RotoSendQueue()

    /// I/O デバッグ環境（mako 依頼 2026-08-11）: 仮想ポート「Ladyland RotoInject」。
    /// ここへ届いた MIDI/SysEx を **RotoSendQueue 経由で** ROTO へ中継する —
    /// エージェント（Claude）がアプリを止めず・順序を壊さずに実機へ書ける口
    private var injectPort = MIDIEndpointRef()

    func attach(rack: InstrumentRack) {
        self.rack = rack
    }

    func start() {
        connect()
    }

    /// 挿抜時（MIDIInput.onSetupChanged から）。宛先を引き直して握手からやり直す
    func reconnect() {
        lastFirmwareNotice = .distantPast  // 差し直し直後の握手は必ず投影する
        projectedThisPlug = false  // 新しい周期 — 初回投影（宣言つき）をやり直す
        // ⭐ 挿抜通知 = 新しい合図なので、再列挙の予算を戻す。
        // ⚠️ 再試行側からここを呼ぶな（予算が戻って無限ループ。`MIDIRescan`）
        rescanAttempt = 0
        connected = false
        handshakeDone = false  // 繋ぎ直したら保険をもう一度使えるようにする
        // ⚠️ **挿し直しでも握手からやり直す** — その最中の `0B 01` も
        // デバイスの面通知なので、ここを戻さないと差し直すたびにピッカーが開く
        startupSettled = false
        destination = nil
        invalidateLabels()
        invalidateMappedCells()
        midiSync.reset()  // 差し直し = 実機側の値が信用できない。全席送り直し
        mixerSync.reset()
        connect()
    }

    /// 起動レースの再列挙（`MIDIRescan` 参照。実測 2026-08-09 — 実機が
    /// 繋がっているのに列挙が空で、通知も来ないので永遠に盲目だった）
    private var rescanAttempt = 0

    private func scheduleRescan() {
        guard let delay = MIDIRescan.delay(afterAttempt: rescanAttempt) else { return }
        rescanAttempt += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.connected else { return }
            NSLog("roto: 再列挙 %d 回目（起動レースの救済）", self.rescanAttempt)
            self.connect()
        }
    }

    /// 採用している方言。**能力表は `RotoDialect`（RotoDialect.swift）に集約**
    /// してある — ここを `.bitwig` に変えれば投影・入力・モーターが一斉に
    /// 入れ替わる（片方だけ変えると必ず壊れる、が方言の性質）
    private static let dialect: RotoDialect = .logic

    /// 名乗る DAW 種別（1 = Ableton, 2 = Bitwig, 3 = Logic）。**方言が変わる**
    private static var dawType: UInt8 { dialect.dawType }

    /// デバイスに保存させておく架空プラグインの名前。
    /// **生涯 1 回**、ROTO-SETUP で `docs/roto-control/Ladyland.json`（128 セル）を
    /// import しておけば、以後 ladyland が中身を書き替えて使い回せる
    static let pluginIdentity = "Ladyland"

    /// セルの表示名 — **別名 > AU の現在名 > 割当時に控えた名前 > Ctrl 番号**。
    /// 3 つの面すべてがこれを通るので、実機と画面で必ず同じ呼び名になる。
    /// 割当が無いセルは Ctrl 番号（P2-3 形式）— 空文字だと LCD が消えず、
    /// 前の表示が残ってしまう（実測）
    private func knobLabel(_ ctrl: Int, in slot: InstrumentSlot) -> String {
        let mapping = slot.knobMappings.first(where: { $0.knob == ctrl })
        let live = mapping.flatMap { slot.parameter(at: $0.address)?.displayName }
        return KnobLabel.resolve(alias: mapping?.alias, live: live, remembered: mapping?.name)
            ?? FaceKnobAssignment.ctrlLabel(ctrl)
    }

    /// セルの現在値（0-1）。割当が無い / レンジが無いなら nil。
    /// learn の pos14 とモーター位置で共有する
    private func normalizedValue(_ ctrl: Int, in slot: InstrumentSlot) -> Double? {
        guard let mapping = slot.knobMappings.first(where: { $0.knob == ctrl }),
            let param = slot.parameter(at: mapping.address)
        else { return nil }
        let minValue = Double(param.minValue)
        let range = Double(param.maxValue) - minValue
        guard range > 0 else { return nil }
        return (Double(param.value) - minValue) / range
    }

    /// CONTROL_MAPPED に learn で答える。セル番号 = controlIndex を
    /// ladyland の Ctrl 番号（割当一覧の P×-× と同じ）として扱う
    private func answerControlMapped(_ mapped: Roto.ControlMapped) {
        guard let rack else { return }
        let slot = rack.selectedSlot
        // controlIndex は**ページ内の位置**なので、表示中のページと合わせて
        // 絶対セル番号にする（ページ 2 のノブ 1 = ctrl 8）
        let ctrl = mapped.isSwitch
            ? mapped.controlIndex
            : RotoPageLayout.pluginCell(page: pluginPage, knob: mapped.controlIndex)
        let name = knobLabel(ctrl, in: slot)

        // このセルは「起きている」— 以後、割当や選択が変わったら 0B 0F で
        // 名前を追従させる（learn はもう送れないので、ここで控えるのが唯一の機会）
        mappedCells[ctrl] = MappedCell(
            paramIndex: mapped.paramIndex, hash6: mapped.hash6, isMacro: mapped.isMacro)
        mappedNames[ctrl] = name

        // ⚠️ **CONTROL_MAPPED の controlIndex はページ内の位置（0-7）**で、
        // 絶対セル番号ではない（実測 2026-08-04: ページを繰っても 0-7 で来る）。
        // ここから pluginPage を逆算していたときは、← → で進めた直後に
        // 毎回 0 へ巻き戻され、**ページ 2 から先へ進めなかった**。
        // ページの追跡は ← → の受信（0A 14/15）だけで行う

        let value = normalizedValue(ctrl, in: slot) ?? 0
        send([
            Roto.learn(
                paramIndex: mapped.paramIndex, name: name, value: value,
                hash: mapped.hash6, isMacro: mapped.isMacro)
        ])
    }

    /// 影を捨てる = 次の投影で全セルを送り直す。
    ///
    /// PLUGIN 面の帳簿（mappedCells / mappedNames）も一緒に捨てる —
    /// 面に入り直せば CONTROL_MAPPED が来て learn で名前が付き、帳簿は
    /// そこで組み直される。**残すと learn 直後に同じ名前を 0B 0F で
    /// 送り直す無駄が出る**
    private func invalidateLabels() {
        shadow.invalidate()
    }

    /// PLUGIN 面の帳簿を捨てる。**面に入り直すときだけ**呼ぶ —
    /// 入れば CONTROL_MAPPED が来て learn で組み直される。
    ///
    /// ⚠️ 表示の影（invalidateLabels）と寿命が違う。一緒に捨てていたときは、
    /// PLUGIN 面にいる最中に届く `0C 01`（MIXER 更新）で帳簿が消え、
    /// **名前の追従が一度も走らなかった**（実測 2026-08-04）
    private func invalidateMappedCells() {
        mappedCells.removeAll()
        mappedNames.removeAll()
    }

    /// 選択・ロード・割当が変わった（AppState.updateRouting から）
    func refresh() {
        guard connected else { return }
        projectFaces()
    }

    // MARK: - MIDI モードのモーター同期

    /// 0.1 秒ごとに 64 席の現在値を diff して、変化バイトだけ送る
    /// （設計と帳簿は `RotoMidiSync.swift`）。タイマーは一度張ったら
    /// 回しっぱなし — 接続断は tick 側の guard が黙らせる
    private func startMidiSync() {
        guard midiSyncTimer == nil else { return }
        midiSyncTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) {
            [weak self] _ in
            Task { @MainActor [weak self] in self?.syncMidiMotors() }
        }
        // 定期リフレッシュ: SEL 切替は無音で、実機は表示中の冊のノブにしか
        // 受信 CC を適用しない可能性が高い。送信済みの記憶だけ捨てて全値を
        // 撒き直す（≤96 通/25 秒 — 表示中でない冊への分は実機が無視するだけ）。
        // hold は残るので回し中の席とは喧嘩しない。
        // 間隔は mako 裁定 2026-08-12「もうちょっと長くて良い。25 秒に一度で」
        // — 冊切替直後のモーター揃いは多少待つが、バスを静かに保つ方を取る
        midiRefreshTimer = Timer.scheduledTimer(withTimeInterval: 25.0, repeats: true) {
            [weak self] _ in
            Task { @MainActor [weak self] in
                self?.midiSync.forgetSent()
                self?.mixerSync.forgetSent()
            }
        }
    }

    private func syncMidiMotors() {
        guard connected, let destination, let rack else { return }
        let slot = rack.selectedSlot
        // 席レーン（ch1）= 選択スロットのパラメータ / ミキサーレーン（ch2）=
        // スロット 1-32 の gain。ステータスバイトがレーンの名前空間
        let seatSends = midiSync.pendingSends { self.normalizedValue($0, in: slot) }
            .map { [0xB0, UInt8($0.cc), $0.byte] }
        let mixerSends = mixerSync.pendingSends { index in
            rack.slots.indices.contains(index) ? Double(rack.slots[index].gain) : nil
        }
        .map { [0xB1, UInt8($0.cc), $0.byte] }
        let sends = seatSends + mixerSends
        guard !sends.isEmpty else { return }
        // 素の CC。冊の焼き直し直後は最大 96 通のバーストになるが、
        // 1ms 間合いなら USB MIDI に余裕で収まる（SysEx の追い越しも
        // キュー共有で構造的に起きない）
        sender.sendRaw(sends, to: destination, gap: 1_000)
    }

    // RK 冊切替（コマンドレーン ch3 + SET_SETUP 往復）は 2026-08-13 に
    // 実装ごとオミット（mako「テストで Page を辿れるかの残骸」）。
    // 冊の移動は実機の SEL と、選択ボタンの**長押し**（下）で

    // MARK: - 選択ボタンの長押し（MIXER 冊 → INST 冊へ移動）

    /// 長押し検出（押下で武装、離しで解除。1 本だけ — 同時押しは最後が勝つ）
    private var buttonHold: (slot: Int, task: Task<Void, Never>)?

    /// 長押しの判定時間（mako 裁定 2026-08-13「長押し（一秒）」）
    static let buttonHoldSeconds: TimeInterval = 1.0

    private func armButtonHold(slot: Int) {
        buttonHold?.task.cancel()
        let task = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.buttonHoldSeconds))
            guard !Task.isCancelled else { return }
            self?.buttonHold = nil
            self?.jumpToInstBook()
        }
        buttonHold = (slot, task)
    }

    private func disarmButtonHold(slot: Int) {
        guard let hold = buttonHold, hold.slot == slot else { return }
        hold.task.cancel()
        buttonHold = nil
    }

    /// **長押し = その INST へ移動**（SEL リモートで INST 冊 1 を表示 — 選択は
    /// 押下時に済んでいるので、INST 冊にはそのトラックのライブラベルが出ている）。
    /// シリアル往復（数百 ms）の間は実機の CC が止まる — 冊の移動時なので無害
    private func jumpToInstBook() {
        Task.detached(priority: .userInitiated) {
            do {
                try RotoAdminPort.withPort { session in
                    _ = try session.transact(
                        RotoAdmin.setSetup(RotoMidiSetupExport.instSetup1), expecting: 0)
                }
                NSLog("roto: 長押し — INST 冊へ移動")
            } catch {
                NSLog("roto: INST 冊への移動失敗 — %@", "\(error)")
            }
        }
    }

    // MARK: - 接続と受信

    private func connect() {
        if client == nil {
            guard let created = try? MIDISysExSender.makeClient("ladyland-roto") else { return }
            client = created
            makeInputPort(created)
            sender.tap = { RotoIOTap.shared.log($1, $0) }
            makeInjectPort(created)
        }
        guard let dest = try? MIDISysExSender.destination(matching: "Roto"),
            let source = try? MIDISysExSender.source(matching: "Roto")
        else {
            NSLog("roto: 実機なし（挿されたら再接続）")
            scheduleRescan()
            return
        }
        destination = dest
        MIDIPortConnectSource(inputPort, source, nil)
        connected = true
        startMidiSync()
        NSLog("roto: 接続 — 握手開始（DAW 種別 %d を名乗る）", Int(Self.dawType))
        send([Roto.dawStart])
        // 握手完了（firmware 通知）で projectAll が走る。保険として遅延投影も
        // ⚠️ **握手が済んでいたら走らせない**（実測 2026-08-04）。
        // firmware 通知が ~1 秒で来るので、2 秒後の保険が**必ず二度目の
        // 全投影と面切替を撃っていた** — ログに `SMART 面へ切り替える` が
        // 2 行、`smart → smart` の無駄な切替が残っていた
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self else { return }
            // ⭐ **握手が返っていなくても、2 秒経てば「起動は落ち着いた」**
            // とみなす。⚠️ これが無いと、firmware 通知が来ない個体で
            // **FUNC が永久に効かない**（`startupSettled` の doc）
            self.startupSettled = true
            guard !self.handshakeDone else { return }
            NSLog("roto: ⚠️ 握手が返らないので保険の投影を走らせる")
            self.projectAll()
        }
    }

    private func makeInputPort(_ client: MIDIClientRef) {
        var assembler = SysEx7Assembler()
        let status = MIDIInputPortCreateWithProtocol(
            client, "roto-in" as CFString, ._1_0, &inputPort
        ) { [weak self] eventList, _ in
            // RT スレッド — 値だけ集めて main へホップ（MIDIInput と同じ作法）
            var frames: [[UInt8]] = []
            var shorts: [(UInt8, UInt8, UInt8)] = []
            // 🧪 **組み立て前の生ワード**（2026-08-04）。
            // SysEx のログを緩めても ← → が出てこなかったので、
            // `SysEx7Assembler` が組み立てられずに落としている線を見る。
            // Channel Voice（type 2 = つまみ）だけ除く — それ以外は全部
            var rawWords: [UInt32] = []
            for packet in eventList.unsafeSequence() {
                let count = Int(packet.pointee.wordCount)
                withUnsafePointer(to: packet.pointee.words) { tuple in
                    tuple.withMemoryRebound(to: UInt32.self, capacity: 64) { words in
                        for i in 0..<min(count, 64) {
                            // type 2 = Channel Voice（つまみ）
                            // type 1 = System Real Time — **ROTO は MIDI Clock
                            //   (F8) を垂れ流している**（実測 2026-08-04:
                            //   3403 個 / 全ログの 97%）。これがログを洗い流し、
                            //   ボタンの手掛かりを埋めていた
                            // type 0 = Utility（NOOP / ジッタ補正）
                            let messageType = (words[i] >> 28) & 0xF
                            if messageType != 2, messageType != 1, messageType != 0 {
                                rawWords.append(words[i])
                            }
                            if let frame = assembler.feed(words[i]) {
                                frames.append(frame)
                            }
                            if let message = UMP.parseChannelVoice(words[i]) {
                                shorts.append(message)
                            }
                        }
                    }
                }
            }
            guard !frames.isEmpty || !shorts.isEmpty || !rawWords.isEmpty else { return }
            DispatchQueue.main.async {
                guard let self else { return }
                for word in rawWords {
                    // type 3 = SysEx7 のデータワード。status は上位ニブルの次
                    NSLog("roto: [生UMP] %08X (type=%d)", word, Int((word >> 28) & 0xF))
                }
                for frame in frames { self.handleSysEx(frame) }
                for short in shorts { self.handleShort(short.0, short.1, short.2) }
            }
        }
        if status != noErr {
            NSLog("roto: 入力ポート作成に失敗 (%d)", status)
        }
    }

    /// 仮想ポート「Ladyland RotoInject」を公開する（I/O デバッグ環境）。
    /// 受けた SysEx / 短 MIDI をそのまま **同じ送信キュー**で ROTO へ中継 —
    /// 第 2 経路を作らない規律（`RotoSendQueue` の doc）を注入にも守らせる
    private func makeInjectPort(_ client: MIDIClientRef) {
        var assembler = SysEx7Assembler()
        let status = MIDIDestinationCreateWithProtocol(
            client, "Ladyland RotoInject" as CFString, ._1_0, &injectPort
        ) { [weak self] eventList, _ in
            var frames: [[UInt8]] = []
            var shorts: [(UInt8, UInt8, UInt8)] = []
            for packet in eventList.unsafeSequence() {
                let count = Int(packet.pointee.wordCount)
                withUnsafePointer(to: packet.pointee.words) { tuple in
                    tuple.withMemoryRebound(to: UInt32.self, capacity: 64) { words in
                        for i in 0..<min(count, 64) {
                            if let frame = assembler.feed(words[i]) { frames.append(frame) }
                            if let message = UMP.parseChannelVoice(words[i]) {
                                shorts.append(message)
                            }
                        }
                    }
                }
            }
            guard !frames.isEmpty || !shorts.isEmpty else { return }
            DispatchQueue.main.async {
                guard let self, let destination = self.destination else { return }
                for frame in frames {
                    RotoIOTap.shared.log("inject", frame, note: Roto.describe(frame))
                    self.sender.send([frame], to: destination)
                }
                for short in shorts {
                    RotoIOTap.shared.log("inject", [short.0, short.1, short.2])
                    self.sender.sendRaw(
                        [[short.0, short.1, short.2]], to: destination, gap: 1_000)
                }
            }
        }
        if status != noErr {
            NSLog("roto: inject ポート作成に失敗 (%d)", status)
        } else {
            NSLog("roto: inject ポート公開 — 「Ladyland RotoInject」へ送ると ROTO へ中継")
        }
    }

    // MARK: - 受信処理（main）

    private func handleSysEx(_ frame: [UInt8]) {
        // 🧪 **SysEx を全部出す**（2026-08-04、条件を緩めた）。
        //
        // ⚠️ 以前は `frame.count > 6` を掛けていて、**7 バイト未満のフレームが
        // 見えていなかった**。分岐の入口も `guard frame.count >= 7` で捨てるので、
        // 短い SysEx は完全に無かったことになっていた —
        // ← → がそこに居た可能性がある（mako 指摘 2026-08-04）。
        // hello（`0A 02`、毎秒）だけは除く
        let isHello = RotoSysExRoute.isHello(frame)
        if !isHello {
            RotoIOTap.shared.log("in", frame, note: Roto.describe(frame))
            NSLog("roto: [受信SysEx] %@ (%d byte)",
                frame.prefix(12).map { String(format: "%02X", $0) }.joined(separator: " "),
                frame.count)
        }
        // 0C 01（フラッシュロード）以外の受信は「実機が喋った」= settle の材料
        // （0C 01 自体はロードの開始なので除外 — anchor は 0C 01 側が張り直す）
        if RotoSysExRoute.marksDeviceActivity(frame) {
            noteDeviceActivity()
        }
        // hello / ROTO_DAW_CONNECTED への定型応答。DAW 種別 3 = Logic Pro を
        // 名乗ることで SMART モードと直接 setter 群が解禁される（実測）
        // hello / 問い合わせへの応答も**即時**（止めると切断扱い。protocol.md）
        let replies = Roto.autoResponse(to: frame, dawType: Self.dawType)
        if !replies.isEmpty {
            send(replies)
        }
        guard let route = RotoSysExRoute.decode(frame) else { return }
        switch route {
        case .firmwareNotice:
            // firmware 通知 = 握手完了の合図
            NSLog("roto: %@", Roto.describe(frame))
            handshakeDone = true
            // ⭐ **ここから先の `0B 01` は人の FUNC**（`startupSettled` の doc）
            startupSettled = true
            // ⚠️ **firmware 通知は毎回 2〜4 連で届く**（実測 2026-08-11 の帳簿。
            // mako 指摘「まだ 2 つの処理が初期化処理のどこかに残ってる」）。
            // 1 通ごとに projectAll すると宣言〜枠書きの一本の流れが二重に
            // 走るので、2 秒以内の再通知は握手情報の更新だけで投影しない
            guard Date().timeIntervalSince(lastFirmwareNotice) > 2.0 else {
                NSLog("roto: firmware 通知の連投 — 投影は 1 回だけ")
                return
            }
            lastFirmwareNotice = Date()
            invalidateLabels()
            // 初回投影の引き金は 0A 0C（下の case）— ここは握手情報の更新だけ
        case .dawConnected:
            // ROTO_DAW_CONNECTED（門）。定型応答（0A 0D）は autoResponse 済み。
            // ⚠️ ここで投影**しない** — 実機は ~4.5 秒後の 0C 01 でフラッシュの
            // 保存セットをロードし、**それ以前に書いた枠を上書きする**
            // （実測 2026-08-11 夜: 門 +500ms の投影は 3/3 生存したが 3/3 表示されず）
            NSLog("roto: ROTO_DAW_CONNECTED — 投影は 0C 01 後の settle 待ち")
        case .controlMapped:
            // PLUGIN 面の心臓部: デバイスが保存済みセルを 1 つずつ聞いてくる。
            // paramIndex と hash6 は**そのまま echo** し、名前と値だけ
            // ladyland の割当から埋める（セル = controlIndex）
            if let mapped = Roto.parseControlMapped(frame) {
                NSLog("roto: CONTROL_MAPPED ctrl %d ← learn で応答", mapped.controlIndex)
                answerControlMapped(mapped)
            }
        case .pluginFace:
            // PLUGIN 面へ。**pull 型の面は塗るだけでは起きない** — 告知バッチと
            // 選択宣言（0B 08）を送り直して CONTROL_MAPPED を呼び戻す。
            // ⚠️ ここで告知を省くと、デバイスは「プラグインを選べ」の状態で
            // DAW の確定を待ち、こちらは黙ったまま = **進行不能**になる
            //（実機 2026-08-03: MODE で出て戻ると面が死ぬ）
            NSLog("roto: PLUGIN 面へ")
            currentFace = .plugin
            // **デバイスが通知した** = 確認できる遷移
            confirmFace("PLUGIN")
            // ⭐ **面の情報は本物なので捨てない** — 上の `currentFace` も
            // `confirmFace("PLUGIN")` もそのまま通す。反応は **SMART 面への
            // 引き戻しだけ**（Transform 方針 2026-08-11: 相手のモードと戦わない。
            // 引き戻しは 2 秒スロットル付き — `0B 01` 連投と押し合わない）
            returnToSmartFace()
            invalidateLabels()
            invalidateMappedCells()  // 入り直せば CONTROL_MAPPED で組み直される
            // 告知は **Bitwig 方言のときだけ**（Logic 方言に PLUGIN 面は無い）
            if Self.dialect.announcesPlugins { announcePlugins() }
            projectFaces()
            // ⚠️ **SMART 面へ引き戻す**（実測 2026-08-04）。
            //
            // Logic 方言では PLUGIN 面の LCD をホストから変えられない
            // （4 通り試して全滅）。そこに居られると `0B 13` を送り続けても
            // 何も見えない — ログに `SMART ラベル 16 通（P3, face=plugin）` が
            // 並ぶのに実機は無反応、という形で出ていた。
            //
            // デバイスは MODE キーだけでなく**自発的にも**戻ってくる
            // （20:53 に一度、20:58 にも 2 通続けて `0B 01` が来た）
            returnToSmartFace()
        case .pluginPage(let forward):
            // **Bitwig 方言ではホストがページを管理する**（実測 2026-08-04）。
            // デバイスは ← → で「繰りたい」と言ってくるだけで、何を表示するかは
            // こちらが決める。Logic 方言は逆で、デバイスが自分で繰って絶対番号で
            // 喋ってきた（protocol.md「ページはデバイスが持つ」はあちらの話）。
            //
            // ここを無視していたので **ページ 1（ctrl 0-7）しか動かなかった**
            let lastPage = RotoParam.pluginCells / RotoParam.physicalKnobs - 1
            let moved = max(0, min(lastPage, pluginPage + (forward ? 1 : -1)))
            guard moved != pluginPage else { break }
            pluginPage = moved
            NSLog("roto: ページ %d へ（ctrl %d-%d）", moved + 1, moved * 8, moved * 8 + 7)
            // ⚠️ **ここで選択宣言（0B 08）を送ってはいけない**。デバイスは
            // 自分でページを繰って表示も変えており、こちらから選び直しを
            // 送ると **1 ページ目へ引き戻される**（実測 2026-08-04: pages を
            // 正しく添えても戻った）。ホストは番号を覚えるだけでよく、
            // ノブ入力は RotoPageLayout が現在ページで解決する
        case .pluginSelected:
            // デバイス上でプラグインを選んだ → 0B 08 で確定を返す
            //（ROTO_CONTROL.py `_send_selected_device_update`）。
            //
            // ⚠️ **受けた index を echo してはいけない**。告知しているのは
            // "Ladyland" 1 台だけなので、echo すると告知していない index を
            // 「それを選べ」と言い返すことになる。必ず告知した範囲に収める
            NSLog("roto: %@ → 0B 08 で 0 番を確定", Roto.describe(frame))
            send([selectCurrentPlugin()])
        case .mixFace:
            // **MIX 面へ**（SET_MIXER_SELECTED_MODE）。デバイスは表示を捨てるので
            // 影も捨てて全部送り直す（差分送信のままだと「変わっていない」と
            // 判断して何も送らず、空の面が残る）
            NSLog("roto: MIX 面へ")
            currentFace = .mix
            // **デバイスが通知した** = 確認できる遷移
            confirmFace("MIX")
            invalidateLabels()
            projectFaces()
        case .selectButton:
            // **SEL ボタン → ページ送り**（mako 要望 2026-08-04
            // 「ROTO の左右キーで内容が切り替われば良い」）。
            //
            // ← → は**ホストに何も届かない** — デバイス内部で完結していて、
            // MIDI にも SysEx にも出ない（実測 2026-08-04: 受信 1877 行のうち
            // ch16 は 0 件）。届くボタンは MODE（`0B 01`）と SEL（`0B 15`）
            // だけなので、SEL をページ送りに充てる。
            //
            // ⚠️ **ページ送りには使えない**（実測 2026-08-04）。
            // 押すと 1.25 秒後に `0B 01` が続き、**デバイスが PLUGIN 面へ
            // 移動する** — ページを進めて塗り直しても、表示が別の面へ行くので
            // 見えない。SEL は「プラグイン選択」の意味らしい。
            //
            // ログには残す（何が起きたか追えるように）。ページを繰るのは
            // ⌥← / ⌥→ と画面の ‹P1› に一本化する
            NSLog("roto: SEL（0B 15）— この後 PLUGIN 面へ飛ぶ。ページ送りには使わない")
        case .observedTrack(let index):
            // ⚠️ **観測のみ — 選択には繋がない**（2026-08-11 実測で配線を撤回）。
            // 当初「knob タッチ → トラック選択」と読んで `rack.select` に繋いだが、
            // 実機は **← → を押している最中や無関係の場面でも `0A 09 (track 0)` を
            // ほぼ毎秒送ってくる**ことが帳簿で判明した — タッチ由来とは限らない。
            // 窓越しに選択へ写すと、スライド中に LL の選択（= 鳴る楽器）が
            // 勝手に飛ぶ実害が出た。意味（いつ・何の index が来るのか）を
            // 実測で確定させるまで、ここはログだけにする
            if let index {
                NSLog("roto: selectTrack 枠%d（観測のみ — 配線は保留）", index + 1)
            }
        case .mixerSetup(let payload):
            // MIXER 更新（SET_MIXER_ALL_MODE = 初期化の引き金）。
            // ⚠️ **これは面切替ではない** — PLUGIN 面にいる最中にも来る。
            // ここで currentFace を .mix にすると、面ガードがノブ入力を止め、
            // PLUGIN 面の帳簿まで捨ててしまう（実測 2026-08-04: learn の
            // 再送が一度も走らなかった原因）。表示の塗り直しだけ行う
            //
            // 🧪 **無言だった経路にログを入れる**（Purple Haze 2026-08-04）。
            // ここは `invalidateLabels()` で trackShadow まで捨てるので、
            // 次の `projectFaces` が **`0A 11` を 16 通、`0B 13` より先に**
            // 送る。SMART 面に居る最中にこれが来ていたら表示が壊れるが、
            // ログが 1 行も無いので**起きているかどうか自体が不明**だった
            // MIX 投影の撤去（2026-08-11）に伴い、ここは観測のみ。
            // ⚠️ payload 4 bytes には意味がある（公式地図 §opcode 表）:
            // [ch種, ノブ機能(0=VOL/1=PAN/2=SEND), ボタン機能(0=MUTE/1=SOLO/2=ARM/3=MON), send#]
            // — 作り直しではここでノブ機能を検出して gain 直結をガードする
            NSLog("roto: 0C 01 payload=%@",
                payload.map { String(format: "%02X", $0) }.joined(separator: " "))
            // ⭐ **初回投影の照準はここから**（実測 2026-08-11 夜）: 実機は
            // この 0C 01 でフラッシュの保存セットをロードして表示する —
            // これ以前に書いた枠は上書きされ（門 +500ms は 3/3 生存 3/3 不表示）、
            // 直後 400ms の宣言は実機を殺す（390/394）。ready の合図は
            // 「0C 01 の後、実機が**最初の自発メッセージ**を発したとき」
            // （mako 発案「その ready って API で出来ない？」— `noteDeviceActivity`）。
            // 自発メッセージが来ない静かな個体への保険は 5 秒
            if Self.mixProjectionEnabled, !projectedThisPlug {
                mixSettleAnchor = Date()
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(5))
                    guard let self, self.connected, !self.projectedThisPlug else { return }
                    NSLog("roto: settle の自発メッセージが来ない — 保険で初回投影")
                    self.projectMixOnceOfficial()
                }
            }
        case .hello:
            break  // 毎秒届く。autoResponse 済みで、通常ログからも除外する
        case .unknown:
            // **未知は黙って捨てない**（RotoProtocol.describe と同じ思想）—
            // Logic 方言では面の通知 ID が違う可能性があり、捨てると
            // 「なぜ面が起きないか」に永久に気づけない。
            NSLog("roto: %@", Roto.describe(frame))
        }
    }

    private func handleShort(_ status: UInt8, _ data1: UInt8, _ data2: UInt8) {
        RotoIOTap.shared.log("in", [status, data1, data2])
        noteDeviceActivity()  // 短メッセージも「実機が喋った」= settle の材料
        let route = RotoShortRoute.decode(
            status: status, data1: data1, data2: data2,
            dialect: Self.dialect, smartPage: smartPage, pluginPage: pluginPage)

        // MIDI モードは applyToMapping / 同期帳簿側のログだけにする。
        // DAW ノブの値ストリームも洪水を避け、1 秒に 1 行へ絞る。
        // 2026-08-06: 値の受信ログを全廃すると「届かない」と「届いて弾かれた」を
        // 区別できなかった。入口と適用側のログを対に残す（毎イベントは重い）。
        // 実測の条件: docs/roto-control/refactor-invariants.md「受信の観測」。
        if !route.isMidiMode {
            let isKnobStream = status == 0xBE && data1 < 64
            if !isKnobStream {
                NSLog("roto: [受信] status=%02X data1=%d data2=%d",
                    Int(status), Int(data1), Int(data2))
            } else {
                logKnobStream(cc: Int(data1), value: Int(data2))
            }
        }

        switch route {
        case .midiSeat(let cc, let value):
            // 回している席への送り返しを同期帳簿の hold で黙らせる。
            midiSync.noteReceived(cc: cc, value: value)
            applySeat(cc: cc, value: value)
            return
        case .mixerGain(let slot, let value):
            mixerSync.noteReceived(cc: slot, value: value)
            if let rack, rack.slots.indices.contains(slot) {
                rack.slots[slot].gain = Float(value) / 127
                onParamChanged?()
            }
            return
        case .mixerButton(let slot, let pressed):
            // 短押し = 選択、長押し 1 秒 = 選択 + INST 冊へ移動。
            if pressed {
                if let rack, rack.slots.indices.contains(slot) {
                    onSelectTrack?(slot)
                    armButtonHold(slot: slot)
                }
            } else {
                disarmButtonHold(slot: slot)
            }
            return
        case .midiModeIgnored:
            return
        default:
            break
        }

        // ⭐ **← → = MIX のトラック窓スライド**（mako 依頼 2026-08-11
        // 「MIX モードでトラックを 8 ずつスライドって ROTO の左右キーで出来る？」）。
        //
        // ← → は **MIX 面でだけ ch16 CC60/61（値 2）として届く**
        // （実測 2026-08-11）。⚠️ 2026-08-04/07 の「← → は何も送らない」は
        // SMART/PLUGIN 面で測った否定だった — RK（`decodeButton` の doc）と
        // まったく同じ「否定測定は条件ごと記録せよ」の実例。
        // 実機の表示は矢印では動かない（16 席宣言でも不動、実測 2026-08-11）
        // ので、**窓をずらして 8 枠を書き直すのはこちらの仕事**
        if case .mixArrow(let forward, let value) = route {
            // MIX 投影の撤去（2026-08-11）に伴い観測のみ — 窓スライドの
            // 作り直しは公式地図の応答義務レイヤーとセットで
            NSLog("roto: [観測] %@ キー（値 %d）— MIX 窓は撤去済み",
                forward ? "→" : "←", Int(value))
            return
        }

        // **LCD の真下の 8 ボタンでページを直に選ぶ**（mako 案 2026-08-07
        // 「Page 選択に使うのって、鍵盤じゃなくて ROTO の 8 つのキーのこと」）。
        //
        // ボタンは **8 枚の LCD の真下**にあるので、ピッカーが出している
        // `#1`…`#8` と**位置がそのまま一致する**。見たまま押せば決まる —
        // ← → で寄せてから確定する 2 手が 1 手になる。
        //
        // ⚠️ **押下だけを見る**（`data2 > 0`）。離した 0 まで拾うと
        // **1 押しで 2 回**通る。ここは閉じてから 0 が来るので下の
        // 「ピッカー外」へ落ちるが、順序に依存させない
        if case .smartPage(let key, let pressed) = route {
            // ⭐ **RK1-8 = ページ直選**（mako 裁定 2026-08-11「全部オミットして、
            // RK1-8 使う方式に」）。RK は **MIX 面でだけ喋る**（ch16 CC20-27、
            // 実測 2026-08-11）が、Transform 方針により**来た面を問わず**
            // ページジャンプへ翻訳する — 実機側は RK でページを繰り、選択中
            // ページのキーをトラック色で光らせる（実機ネイティブの挙動）。
            // こちらは信号を読んで内部ページを追従させるだけ
            guard pressed else { return }  // 押下のみ（解放 0 で 2 度動かさない）
            NSLog("roto: RK%d → P%d へ直選", key + 1, key + 1)
            goToSmartPage(key, why: "RK 直選")
            // mako スケッチ（2026-08-11）の「(モード切り替わって)」— MIX で
            // 押した RK の跳躍先を見せるため SMART 面へも寄せる。同じページの
            // RK でも面は切り替える（goToSmartPage は同ページ no-op のため外に置く）。
            // 連打の押し合いは returnToSmartFace 側の 2 秒スロットルが受ける
            returnToSmartFace()
            return
        }

        // ⭐ **MIX ノブ = 窓 8 トラックの音量**（mako 裁定 2026-08-11
        // 「Track 自体って Volume 持ってる？割り当てるならそれだよね」）。
        // ch16 の 14bit ペア（CC12-19 MSB + CC44-51 LSB）を `slots[窓+n].gain`
        // へ写す。実機の dB ポップアップは向こうの演出でタダで付いてくる。
        // ⚠️ Logic 方言のときだけ — Bitwig 方言では同じ CC が PLUGIN 面の
        // 物理ノブなので、`RotoShortRoute` が `.parameter` に分類する
        if case .mixKnob(let knob, let kind, let value) = route {
            handleMixKnob(knob: knob, kind: kind, value: value)
            return
        }

        // SMART/PLUGIN の方言差とページ座標は分類済み。ここでは完成した
        // コントロール番号の14bit値だけを組み立て、パラメータへ適用する。
        guard case .parameter(let param, let kind, let value) = route else { return }
        guard let raw = parameterValues.receive(control: param, kind: kind, value: value) else {
            return  // MSB 待ち / touch は v1 では使わない
        }
        // 自分の耳に自分の声: この値の echo は不要（モーターは既にそこ）
        shadow.motorRaw[param] = raw
        // ⚠️ **受信で裏が取れた** — ここだけが「実機がそこに居る」と言える
        shadow.motorObserved.insert(param)
        apply(ctrl: param, normalized: RotoValue14.normalized(raw))
    }

    /// **MAIN LCD の投影を切る**（切り分け用。mako 報告 2026-08-06
    /// 「ノブの値が連動しなくなった。LCD は期待通り」）。
    ///
    /// ⚠️ `0A 16` は 8/4 に「**SMART 面に居る最中に送ると面を殴る**」と記録した
    /// コマンド。今日 payload の誤りが分かって送るようにしたが、**LCD には出る
    /// のに knob が死ぬ**という別の副作用が残っている疑いがある。
    /// **履歴**: 2026-08-06 の切り分け中は既定 off にしていた（「LCD には出るのに
    /// knob が死ぬ」疑いのため）。**切り分けが済んで疑いは晴れた**ので
    /// 2026-08-06 に既定 on へ。⚠️ `=0` は**会場での退避路** — MAIN LCD が
    /// 面を殴っている疑いが再燃したらここを切る
    static let projectsMainLcd =
        ProcessInfo.processInfo.environment["LADYLAND_MAIN_LCD"] != "0"

    /// **空セルにも `0B 13` を送る**（= 「グレー地 + `-`」を出す）。
    ///
    /// **履歴**: `af653d6` で公式 `config.lua` L1592 に合わせて**送らない**形に
    /// したが（「割当の無いセルまで『ある』と告げて knob の活性を壊す」疑い）、
    /// 2026-08-06 の実機確認で **ページ切替の残像が消え、活性も壊れなかった**。
    /// mako 確認済みなので既定 on へ。
    ///
    /// ⚠️ 変数名を否定形（`skips…`）から**肯定形**に直した。環境変数が
    /// `FILL_EMPTY` なのに変数が `skips` だと、既定を反転するときに
    /// **二重否定を読み違える** — 名前と意味を揃えておく。
    ///
    /// ⚠️ `=0` は**会場での退避路**（残像が戻る代わりに送信を減らす）
    static let fillsEmptySmartCells =
        ProcessInfo.processInfo.environment["LADYLAND_FILL_EMPTY"] != "0"

    /// **空きノブへモーター値を送らない**（mako 要望 2026-08-06
    /// 「空きのノブをさわっても動かないように固定とかできる？」）。
    ///
    /// ## 根拠（`docs/roto-control/protocol.md`）
    ///
    /// > knob は learn で active になるまで CC を送らない（ccInsBlocked ガード）。
    /// > **モーターも同じ門の内側**（実測 2026-08-03: 割当ありの knob 0 だけ動き、
    /// > **不活性の 7 本は無反応**）
    ///
    /// > 値が届くとデバイスが**物理的な端 stop（haptic）を張る** —
    /// > フリースピンではなくポテンショメータの手応えになる。
    ///
    /// つまり **値を送ること自体が knob を活性化させている**。送らなければ
    /// 不活性のまま = 触っても何も起きない、はず。
    ///
    /// ⚠️ **ただし「不活性 = 回らない」とは書いていない**。書いてあるのは
    /// 「**CC を返さない**」と「端 stop が張られない（フリースピン）」まで。
    /// **空転するが無反応**になる可能性がある — 実機で確かめるまで断定できない。
    ///
    /// ⚠️ `LADYLAND_FILL_EMPTY`（LCD の空セル表示）とは**別の門**。
    /// あちらは `0B 13`（表示）、こちらは `smartMotor`（値）で経路が違う。
    ///
    /// **履歴**: 2026-08-06 に検証用の既定 off で入れ、mako 実機確認
    /// 「これで OK」で既定 on へ。⚠️ `=0` は**会場での退避路**
    /// （空きノブが再び手応えを持つ代わりに、従来の挙動へ戻る）
    static let parksEmptyKnobs =
        ProcessInfo.processInfo.environment["LADYLAND_PARK_EMPTY_KNOBS"] != "0"

    /// **どのフラグで動いているかを起動時に 1 行**（`BusFollowing.describe` と同じ作法）。
    ///
    /// ⚠️ 会場でフラグを思い出す必要がある状況 = 何かが壊れている状況。
    /// **ログに現状が書いてあれば探し回らずに済む**
    static var describeFlags: String {
        func mark(_ on: Bool, _ name: String) -> String { "\(name)=\(on ? "on" : "off")" }
        return "roto flags: "
            + [
                mark(projectsMainLcd, "MAIN_LCD"),
                mark(fillsEmptySmartCells, "FILL_EMPTY"),
                mark(parksEmptyKnobs, "PARK_EMPTY_KNOBS"),
                mark(!Self.quiet, "書き込み（QUIET=1 で静音）"),
                mark(fullProjection, "全投影（既定 off の厳格ミニマム。ROTO_FULL=1 で全部）"),
            ].joined(separator: " / ")
            + "（既定は全部 on。`LADYLAND_<名前>=0` で切る）"
    }

    func receiveForTesting(_ frame: [UInt8]) {
        handleSysEx(frame)
    }

    /// 短い MIDI（CC 等）をテストから流す口（`receiveForTesting` の生 MIDI 版。
    /// RK 直選 = `decodeButton` の配線を実経路で守るため）
    func receiveShortForTesting(_ status: UInt8, _ data1: UInt8, _ data2: UInt8) {
        handleShort(status, data1, data2)
    }

    /// ノブが効かなかった理由（**1 秒に 1 行**。値ストリームは毎フレーム来る）
    private var lastKnobLog = Date.distantPast

    /// 値ストリームが届いていること自体を示す（1 秒に 1 行）。
    /// CC 0-31 = MSB / 32-63 = LSB（`protocol.md` の多チャンネル配置）
    private var lastStreamLog = Date.distantPast

    private func logKnobStream(cc: Int, value: Int) {
        guard Date().timeIntervalSince(lastStreamLog) > 1 else { return }
        lastStreamLog = Date()
        NSLog(
            "roto: 値ストリーム CC%d=%d（%@ param %d）",
            cc, value, cc < 32 ? "MSB" : "LSB", cc % 32)
    }

    private func logKnobMiss(_ reason: String) {
        guard Date().timeIntervalSince(lastKnobLog) > 1 else { return }
        lastKnobLog = Date()
        NSLog("roto: ⚠️ ノブが効かない — %@", reason)
    }

    private func logKnobHit(_ name: String, _ value: Double) {
        guard Date().timeIntervalSince(lastKnobLog) > 1 else { return }
        lastKnobLog = Date()
        NSLog("roto: ノブ → %@ = %.0f%%", name, value * 100)
    }

    /// **MIDI モードの席 CC**（ch1・7bit）→ 選択スロットの割当パラメータ。
    /// DAW 方言の面ガードは通らない — MIDI モードに面は無く、席 = CC 番号 =
    /// `knobMappings.knob` の同じ空間（KnobPages 正典）。
    /// ⚠️ 2026-08-12 mako 報告「ノブの LCD を回しても、反映しない」の修正 —
    /// ch1 受信はモーター同期の帳簿に記録するだけで、適用経路が無かった
    private func applySeat(cc: Int, value: UInt8) {
        applyToMapping(ctrl: cc, normalized: Double(value) / 127)
    }

    /// ROTO knob → 選択スロットの割当パラメータ（DAW 方言経路。モーター機
    /// なのでピックアップ不要 — ノブは常にパラメータ位置に居る）
    private func apply(ctrl: Int, normalized: Double) {
        // ⚠️ **PLUGIN 面のノブだけが AU パラメータを動かす**。Bitwig 方言では
        // MIX 面も同じ ch16 CC12-19 を使うので、面を見ないとトラックボリューム
        // 操作が音色の書き換えになる（Logic 方言は ch15 で面が分離しているため
        // このガードは要らない）
        guard !Self.dialect.knobInputSharedAcrossFaces || currentFace.drivesPluginKnobs else {
            logKnobMiss("面ガード（いま \(currentFace)）")
            return
        }
        applyToMapping(ctrl: ctrl, normalized: normalized)
    }

    /// 割当検索から setValue までの共通部（MIDI モード席 CC / DAW 方言の両経路）。
    /// ⚠️ **落ちた理由を言う**（mako 報告 2026-08-06「ノブを回しても音が変わらない」）。
    /// ガードのどれで弾かれても症状は同じ「無音」なので、1 秒に 1 行で理由を出す
    private func applyToMapping(ctrl: Int, normalized: Double) {
        guard let rack else {
            logKnobMiss("rack が繋がっていない")
            return
        }
        guard let mapping = rack.selectedSlot.knobMappings.first(where: { $0.knob == ctrl })
        else {
            logKnobMiss(
                "ctrl \(ctrl) に割当が無い（slot \(rack.selected + 1) "
                    + "\(rack.selectedSlot.displayName ?? "empty")）")
            return
        }
        guard let param = rack.selectedSlot.parameter(at: mapping.address) else {
            logKnobMiss("address \(mapping.address)（\(mapping.name)）が AU に無い")
            return
        }
        let minValue = Double(param.minValue)
        let range = Double(param.maxValue) - minValue
        guard range > 0 else {
            logKnobMiss("\(param.displayName) の可動域が 0")
            return
        }
        param.setValue(AUValue(minValue + range * normalized), originator: nil)
        logKnobHit(param.displayName, normalized)
        onParamChanged?()
    }

    // MARK: - 投影（push 型の心臓部）

    /// 握手直後のフル投影（init シーケンス込み）
    /// ⚠️ **切り分け用の静音モード**（既定 off。`LADYLAND_ROTO_QUIET=1` で on）。
    /// 握手の定型応答（hello 等 — 止めると切断扱い）以外、**ROTO へ何も書かない**。
    /// Inject（`Ladyland RotoInject`）から部品を 1 つずつ手で書いて、
    /// どの書き込みが実機を固めるかを実測で確定するための土俵
    /// （2026-08-11: MIX 入場や再接続の書き込みバーストで実機が固まった）
    static let quiet = ProcessInfo.processInfo.environment["LADYLAND_ROTO_QUIET"] == "1"

    /// ⭐ **厳格ミニマム**（mako 裁定 2026-08-11「一旦ミニマムから厳格に
    /// 始めてもいいかもしれないね」）。1 日の切り分けで「全部乗せの投影」が
    /// 固まりの温床だと分かったので、**既定は MIX 面の土台だけ**:
    /// 握手応答 + 宣言 1 回 + track 枠 + RK ライト + 受信系（矢印/RK/ノブ）。
    /// SMART ラベル・MAIN LCD・モーター・面切替の送出は `=1` で戻す —
    /// 復帰は 1 つずつ、実測を添えて
    static let fullProjection =
        ProcessInfo.processInfo.environment["LADYLAND_ROTO_FULL"] == "1"

    /// この差し込み周期でもう初回投影（宣言つき）を済ませたか。
    /// ⚠️ 再宣言は実機の出力を殺すので、宣言はどの経路からでも 1 回だけ
    private var projectedThisPlug = false

    private func projectAll() {
        guard !Self.quiet else { NSLog("roto: QUIET — projectAll を抑止"); return }
        guard connected else { return }
        projectedThisPlug = true
        pushPageLights()  // 接続直後に現在ページのキーだけ点灯（実測で完全制御 ✓）
        // ⭐ 厳格ミニマム: ここから先（モデル宣言・SMART ラベル・MAIN LCD・
        // モーター・面切替）は既定で送らない。MIX モデル投影はコードごと撤去
        // 済み（`handleMixKnob` 上の墓標コメント参照）— 作り直しは公式地図から
        guard Self.fullProjection else { return }
        // 旧リグ（8/8 稼働実績）の投影一式。logicInit の NUM_TRACKS は
        // min(スロット数, 16) — MIX 面は器だけ宣言し、枠の中身は持たない
        send(
            Roto.logicInit(
                tracks: min(rack?.slots.count ?? 8, RotoParam.mixCells), devices: 1))
        // PLUGIN 面の告知（`0B 02`〜`0B 08`）は **Bitwig 方言のときだけ**。
        // Logic 方言では PLUGIN 面を使わないのに選択宣言まで送っていて、
        // デバイスを PLUGIN 系の状態に押し込んでいた疑いがある
        if Self.dialect.announcesPlugins { announcePlugins() }
        projectFaces()

        // Logic 方言は **ホストが面を選ぶ**（MODE キーでは動かない）。
        // 投影を済ませてから SMART 面へ寄せる — ラベルが載る前に切り替えると
        // 空の面が見える
        if Self.dialect.hostSelectsFace, let destination {
            NSLog("roto: SMART 面へ切り替える（ch7 CC100 押下 → 解放）")
            sender.sendRaw(
                Roto.selectFace(.smart), to: destination, gap: 20_000, after: 0.3)
            // **面を立てる**（2026-08-04）。デバイスからの通知を待たない —
            // SMART 面への切替は**ホストが起こしている**ので、送った時点で
            // こちらが知っている。通知（`0C 02`）は MIX 面のものしか来ない
            NSLog("roto: SMART 面へ切替を送出（%@ → smart）",
                String(describing: currentFace))
            currentFace = .smart
            // ⚠️ **送っただけ** — SMART は通知が無いので推定のまま
            assumeFace("SMART")
            // ⚠️ **面に入った直後に塗り直す**（実測 2026-08-04）。
            //
            // ログにこう出ていた:
            //   SMART ラベル 16 通（P1, face=plugin）   ← 面に入る前に 3 回
            //   SMART ラベル 0 通（P1, face=smart）     ← 本命が 0 通
            //
            // 影が埋まりきっていて、**本命の「面に入った直後」に 1 通も
            // 送らなかった**。デバイスが `0B 13` を受け付けるのが面に入った
            // 直後だけなら、唯一のチャンスを面に入る前の送信で使い潰していた
            shadow.invalidateSmartPage()
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(400))
                self?.projectFaces()
            }
        }
    }

    /// PLUGIN 面を起こす（pull 型の引き金）。デバイスに保存された "Ladyland" の
    /// セルを recall させると CONTROL_MAPPED で 1 つずつ聞いてくるので learn で
    /// 答える。**保存された割当は骨組みで、中身は毎回こちらが決める**。
    ///
    /// 告知バッチ（0B 02〜06）だけでは沈黙する — **0B 08 の選択宣言が引き金**
    /// （protocol.md、実測）。握手直後だけでなく、**PLUGIN 面に入り直すたび**に
    /// 送る必要がある
    private func announcePlugins() {
        send(Roto.pluginBatch([Roto.PluginInfo(name: Self.pluginIdentity)]))
        send([selectCurrentPlugin()])
    }

    // ── MIX モデル投影（宣言 + 0A 11 枠塗り + 窓スライド + MIX モーター）は
    // 2026-08-11 に**コードごと削除した**（mako 裁定「その実装ごと削除しよう」）。
    // 同一バイト列で成功と不発が分かれる**非決定的な受け入れ**に一日を溶かした —
    // 真因の有力候補は応答義務の欠落（0A 0A → 0A 0B / RK 解放の LED 再表明 /
    // 0A 09 → 0C 0A エコー / 0C 01 payload 対応）。作り直しは公式スクリプト地図
    // `docs/roto-control/official-scripts-map.md` を写経元に、応答義務レイヤー
    // から立てること。当日の全実測は protocol.md（2026-08-11 節）と
    // Creo `mem_1CdvSucMFyzZ4BEpFgJVpX` に残してある。

    /// ⚠️⚠️ **MIX モデル投影は実験フラグ（既定 off）**（2026-08-11 深夜の結論）。
    ///
    /// 同一レシピ（宣言 + 16 枠）が夕方は 3/3 生存・深夜は即死 — アプリ差・
    /// オペコード・タイミングの全変数を潰しても結果が割れた。犯人は
    /// **観測できない実機側の隠れ状態**（数十回の抜き差しと十数回のフリーズを
    /// 経た実機の劣化を含む）。次の一手は ① ROTO-SETUP でファームウェア
    /// 再書き込み → ② それでも不安定なら Ableton 方言（dawType 1）の評価。
    /// 今夜の全プローブは protocol.md 2026-08-11 節と official-scripts-map.md
    static let mixProjectionEnabled =
        ProcessInfo.processInfo.environment["LADYLAND_ROTO_MIX"] == "1"

    /// 最初の 0C 01（フラッシュロード）の時刻。この後の**最初の自発
    /// メッセージ**が「メインループ復帰 = ready」の合図（`noteDeviceActivity`）
    private var mixSettleAnchor: Date?

    /// 実機が自発的に喋った（= 0C 01 のロード処理を抜けた）ことを観測して
    /// 初回投影を流す。⚠️ 0C 01 から 1.5 秒未満のメッセージはロードの
    /// 振り付けの一部かもしれないので数えない（0C 01 +400ms 宣言の死 390/394
    /// を避ける安全帯）
    private func noteDeviceActivity() {
        guard let anchor = mixSettleAnchor, !projectedThisPlug else { return }
        guard Date().timeIntervalSince(anchor) > 1.5 else { return }
        mixSettleAnchor = nil
        projectedThisPlug = true  // 二重予約の防止
        NSLog("roto: 0C 01 後の初発話を確認 — 500ms 置いて初回投影")
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard let self, self.connected else { return }
            self.projectMixOnceOfficial()
        }
    }

    /// ⭐ **公式忠実の初回投影**（probe 395 の正しい再評価 — 2026-08-11 夜）。
    ///
    /// 公式地図（official-scripts-map.md）の Logic init を、実測で確定した
    /// 差分だけ変えて写す:
    /// - 引き金: **0A 0C（門）+ 500ms**（公式の dawStart 後の間合いと同じ帯）
    /// - 正値: NUM_SENDS **12** / NUM_DEVICES **8** / VU **[106,120]**
    ///   （旧 logicInit の 2 / 1 / [87,113] は公式と食い違っていた）
    /// - NUM_TRACKS は **16 を下位バイト先**（公式は MSB 先だが、この実機は
    ///   MSB 先を受けると**即死する** — 同夜 probe A-1、clock 監視で確定）
    /// - 16 枠 @50ms → RK ライト。**差し込みごとに 1 回だけ**（再宣言は毒）
    /// - `0A 08` END は付けない（Ableton 方言のオペコード — 混ぜると即死、
    ///   probe A-2。Logic 方言は 0A 11 が 1 枠ずつ独立コミット）
    private func projectMixOnceOfficial() {
        guard !Self.quiet else { return }
        guard connected, let destination else { return }
        projectedThisPlug = true
        var messages: [[UInt8]] = [
            Roto.frame(0x0C, 0x03, [12]),  // NUM_SENDS（公式値）
            Roto.numTracks(RotoParam.mixCells),  // 16、下位先
            Roto.firstTrack,
            Roto.frame(0x0B, 0x02, [8]),  // NUM_DEVICES（公式値）
            Roto.frame(0x0B, 0x03, [0]),  // FIRST_DEVICE
            Roto.meterPoints(yellow: 106, red: 120),  // VU（公式値）
        ]
        paintTrackCells(into: &messages)
        NSLog("roto: 公式忠実の初回投影 — init 6 通 + 枠 %d 通 @50ms", messages.count - 6)
        sender.send(messages, to: destination, gap: 50_000)
        pushPageLights()
    }

    /// 16 枠ぶんの track セル（スロット 1-16 固定 — 窓は撤去済み）。
    /// 初回投影専用なので影の差分は取らない（毎差し込み 1 回だけ）
    private func paintTrackCells(into messages: inout [[UInt8]]) {
        guard let rack else { return }
        for cell in 0..<RotoParam.mixCells {
            let name: String
            if cell < rack.slots.count {
                name = rack.slots[cell].displayName ?? "T\(cell + 1)"
            } else {
                name = "-"  // 空文字は LCD が消えず前の表示が残る（実測 2026-08-03）
            }
            let color: UInt8 = cell == rack.selected ? colors.trackSelected : colors.track
            messages.append(Roto.setTrackDetails(UInt8(cell), name: name, color: color))
        }
    }

    /// MIX ノブの 14bit 値。SMART/PLUGIN の param 0-7 とは別帳簿。
    private var mixValues = RotoValue14()

    /// MIX ノブ → `slots[knob].gain`（`didSet` が即 `applyGain`）。
    /// 窓スライド撤去後は**固定でスロット 1-8** — 見えない窓状態を
    /// ノブの効き先に持たない。touch（CC52-59）は今は使わない
    private func handleMixKnob(knob: Int, kind: RotoParam.Kind, value: UInt8) {
        guard let raw = mixValues.receive(control: knob, kind: kind, value: value),
            let rack, knob < rack.slots.count
        else { return }
        // 自分の耳に自分の声: 実機のノブは既にその位置 — エコーは不要
        rack.slots[knob].gain = Float(raw) / Float(RotoValue14.maximum)
    }

    private func projectFaces() {
        guard !Self.quiet, Self.fullProjection else { return }
        guard connected, let rack else { return }
        let slot = rack.selectedSlot
        var messages: [[UInt8]] = []

        // PLUGIN 面: **起きているセルの名前を追従させる**（mako 要望 2026-08-03
        //「割り当てがあるものはパラメータ名が連動するように」）。
        //
        // ⚠️ `0B 0F`（SET_MAPPED_CTL_NAME）は効かなかった（実機 2026-08-04:
        // 名前が追従しない）。カタログ上は DAW→機器だが、実トラフィックでは
        // **機器から来ている**のが観測されており（protocol.md）、DAW から
        // 送っても無視される側らしい。
        //
        // 代わりに **learn を再送する**。CONTROL_MAPPED は面に入ったときしか
        // 来ないが、そのとき控えた paramIndex と hash6 があれば、こちらから
        // 同じ learn を組み立て直せる。名前と値をまとめて運べるので本筋でもある
        // ⚠️ **押し込みでは名前を変えられない**（実測 2026-08-04）:
        //   - `0B 0F`（SET_MAPPED_CTL_NAME）→ 効かない。カタログは DAW→機器と
        //     書くが、実トラフィックでは機器から来ている側のコマンド
        //   - learn（`0B 0A`）の再送 → これも効かない。デバイスは
        //     **自分が CONTROL_MAPPED で聞いたときの答え**しか受け取らない
        //
        // なので**聞き直させる**。`0B 08`（選択宣言）が CONTROL_MAPPED の
        // 引き金だと分かっているので、名前が変わったセルがあればそれを送り、
        // 返ってきた問い合わせに新しい名前で答える
        // ⚠️ **PLUGIN 面の LCD はデバイスが完全に握っている**。
        // ホストが表示に触れるのは `CONTROL_MAPPED` に答える一瞬だけ。
        // 2026-08-04 に 4 通り試して全滅（VP 同席を排除した状態で確認）:
        //
        //   `0B 0F` SET_MAPPED_CTL_NAME  → 効かない（実際は機器→DAW のコマンド）
        //   learn（`0B 0A`）の再送        → 効かない（聞かれたときの答えしか受けない）
        //   `0B 08` で聞き直させる        → 名前は更新されるが**ページが 1 に戻る**
        //   `0B 13` SET_PLUGIN_CTL_DETAILS → **色すら変わらない**（コマンドごと無視）
        //
        // よって LCD には保存名（`Ladyland.json` の `P1-1` 形式）が出る前提で
        // 設計する。これは弱点ではなく**座標系として強い** —
        // ROTO の LCD・画面の割当一覧・Keystage のノブが同じ番号で同じ
        // パラメータを指すので、実機を見ただけで位置が確定する。
        // 割当を変えたら MODE で面を出入りすれば新しい内容で learn される

        // ⚠️ **ここから下は Logic 方言（dawType 3）専用**。
        //
        // 0A 11（track 直接）/ 0B 13（knob 直接）/ smartMotor（ch15 CC）は
        // config.lua 由来のコマンドで、Bitwig を名乗っている間は**未定義**になる。
        // 実測 2026-08-03: まったく同じ learn を送っても、RigBench（投影なし）は
        // LCD が変わり、ladyland（投影 32 通）は変わらなかった —
        // **未定義コマンドが PLUGIN 面の応答を巻き添えにしている**。
        // Bitwig 方言で MIX 面を出すなら 0A 07 の枠付きバッチ（trackBatch）を使う
        guard Self.dawType == 3 else {
            // MIX 面（Bitwig 方言）: **枠付きバッチ**で配る。
            // ⚠️ 0A 07 単発では表示されない — 総数 → offset → 更新×N →
            // コミット（0A 08）の枠が要る（実機検証済）。Logic 方言の直接
            // setter と違って**個別セルの色は指定できない**ので、選択の強調は
            // 0C 04（DAW_SELECT_TRACK）で別に伝える
            let trackCount = min(rack.slots.count, RotoParam.mixCells)
            let names = (0..<trackCount).map { rack.slots[$0].displayName ?? "T\($0 + 1)" }
            let selected = rack.selected
            messages.append(
                contentsOf: RotoProjection.trackMessages(
                    names: names, selected: selected, shadow: &shadow))
            send(messages)
            observeParams(of: slot)
            pushMotors(force: true)  // ch16 の物理 8 本へ（表示中のページ）
            return
        }

        // ⚠️ **いる面だけ塗る** — 規則そのものは `Face.paintsTrackCells` /
        // `Face.paintsSmartCells` に集約した（実測の経緯もそちらに移してある）

        // MIX 面の track 枠塗りは撤去済み（2026-08-11 — `handleMixKnob` 上の
        // 墓標コメント参照）。ここは SMART/MAIN LCD/モーターだけを扱う

        // SMART 面: **全ページぶんの地図を一度に配る**。ページを繰るのは
        // デバイスなので、ホストは番号 0..N の対応表を渡しておけばよい
        // （実測 2026-08-03: 矢印を押すとデバイスが勝手に param 8-15 を
        // 喋り始めた。こちらが 0-7 しか教えていないと空白のページに見える）。
        //
        // ⚠️ **空セルにも必ず何か書く** — 空文字だと LCD が消えず前の表示が
        // 残る。割当が無いセルは Ctrl 番号（P2-3 形式）を出す。画面の一覧と
        // 同じ呼び名なので、**いま何ページ目に居るかが実機だけで分かる**
        // 🧪 **送ったか / 送らなかったか**を残す（2026-08-04）。
        // 「LCD が変わらない」の切り分けが推測の積み重ねになったので、
        // ホスト側の事実（面ガードを通ったか、何通積んだか）を必ず記録する
        let smartCellsBefore = messages.count
        defer {
            if currentFace.paintsSmartCells {
                NSLog("roto: SMART ラベル %d 通（P%d, face=%@）",
                    messages.count - smartCellsBefore, smartPage + 1,
                    String(describing: currentFace))
            } else {
                NSLog("roto: ⚠️ SMART 面を塗らなかった（face=%@ — MIX 面と判定）",
                    String(describing: currentFace))
            }
        }

        if currentFace.paintsSmartCells {
            // **K1-8 = P1-1〜P1-8 の座標そのまま**（mako 裁定 2026-08-04
            // 「8 本は P1 のレイアウトで、詰めなくて良い」）。
            // 画面の割当一覧・Keystage のノブと同じ位置を指すので、
            // 実機を見ただけでどのセルか分かる
            // **空きは空きと分かるように出す**（mako 裁定 2026-08-04）。
            // 割当があれば名前 + 通常色、無ければ「—」+ 暗色。
            // ⚠️ 空文字にはしない — LCD が消えず前の表示が残る（実測）
            let cells = (0..<RotoParam.smartCells).map { cell in
                let ctrl = RotoPageLayout.smartCell(page: smartPage, deviceCell: cell)
                let mapping = ctrl.flatMap { c in
                    slot.knobMappings.first(where: { $0.knob == c })
                }
                let name = mapping.flatMap { m -> String? in
                    let live = slot.parameter(at: m.address)?.displayName
                    return KnobLabel.resolve(
                        alias: m.alias, live: live, remembered: m.name)
                }
                // 🧪 **ページ番号を名前の後ろに詰めてみる**（mako 案 2026-08-05
                // 「P1 とか P2 と、入れられる？二行目」）。
                //
                // `0B 13` の名前欄は **12 文字 + ゼロ埋め + 終端の 13 バイト固定**で、
                // 改行を入れる余地は仕様上どこにも無い（公式 `string_pad` は
                // `\0` で埋めるだけ）。**実機が折り返すかどうか**に賭ける。
                //
                // 12 文字ちょうどに詰めて、右端にページ番号を置く。
                // 折り返せば 2 行目に出る。折り返さなければ名前が切れるだけ
                // **表記は MAIN LCD と揃える**（`#n`、mako 裁定 2026-08-06）—
                // 2 か所に別の書き方が出ていると、どちらを見ているか一瞬迷う
                let pageTag = "#\(smartPage + 1)"
                // **地はダーク、割当ありは明るく**（mako 2026-08-04）。
                // 空き＝黒に沈め、使えるノブだけが浮かび上がる
                // **色でページを示す**（ページ番号は LCD に出せない —
                // `0A 16` は track 系で使えないと判明）。
                //
                // ⚠️ 上下 2 色を試したが**効かなかった**（実測 2026-08-05:
                // `0B 13` は色を 1 つしか受けない）。1 色で兼ねるので、
                // **既定を「席ごとに色相をずらしたページ色」にして、
                // 席ごとに上書きできる**形にした（mako 裁定 2026-08-05）。
                // トラックを移れば同じ P1 でも色が変わる
                // **未割り当ては「グレーの地 + `-`」**（`smartCellFace` の説明）
                let face = RotoDisplay.smartCellFace(
                    name: name, pageTag: pageTag, emptyColor: colors.empty,
                    assignedColor: colors.lcdColor(
                        track: slot.index, page: smartPage, cell: ctrl))
                return RotoProjection.SmartCell(
                    deviceCell: cell, isMapped: mapping != nil,
                    label: face.label, color: face.color)
            }
            // 既定では空セルにも送って残像を消す（2026-08-06 実機確認済み）。
            // `LADYLAND_FILL_EMPTY=0` で空セルへの送信を止める退避路。
            // 経緯とモーター側との区別は `fillsEmptySmartCells` の定義を参照。
            messages.append(
                contentsOf: RotoProjection.smartMessages(
                    cells: cells, fillsEmpty: Self.fillsEmptySmartCells,
                    shadow: &shadow))

            // ✅ **MAIN LCD（左の大窓）の 2 行目に「今どこか」を出す**
            // （実測開通 2026-08-06。8/4-05 の 2 度の失敗をここで回収した）。
            //
            // 1 行目は面の名前（`SMART`）でデバイスが握っているが、
            // **2 行目はホストが書ける**。knob LCD は 12 文字が名前で埋まって
            // ページ番号を添えられないことが多いので、**ページはここに出す**。
            //
            // 過去 2 回外した原因（`config.lua` L1508-1540, L2092-2101 で判明）:
            //   ① `0A 16` に `<0> <0>` を 2 バイト余計に付けていた（正は名前 13 だけ）
            //   ② 据える前に差分を送っていた（公式は `0C 0A` で名前と色を据えてから）
            let mainText = RotoDisplay.mainLcdText(page: smartPage, track: slot.displayName)
            // **地の色は席ごと**（mako 要望 2026-08-06「MAIN LCD の色ページカラー
            // 同様に、プラグイン側に持たせて」）。決めていない席は設定の既定に落ちる
            let mainColor = colors.mainLcdColor(track: slot.index)
            messages.append(
                contentsOf: RotoProjection.mainLcdMessages(
                    track: slot.index, text: mainText, color: mainColor,
                    enabled: Self.projectsMainLcd, shadow: &shadow))
        }
        send(messages)

        observeParams(of: slot)
        pushMotors(force: true)
    }

    /// 選択スロットの割当 8 本に値観測を張る（GUI / プラグイン画面 /
    /// Keystage からの変更もモーターに映すため）
    private func observeParams(of slot: InstrumentSlot) {
        for (param, token) in observed {
            param.removeParameterObserver(token)
        }
        observed = []
        // 全割当を観測する（どのページが表示中かはデバイス任せなので、
        // どれが動いてもモーターへ返せるようにしておく）
        for mapping in slot.knobMappings {
            guard let param = slot.parameter(at: mapping.address) else { continue }
            let token = param.token(byAddingParameterObserver: { [weak self] _, _ in
                DispatchQueue.main.async {
                    self?.pushMotors()
                }
            })
            observed.append((param, token))
        }
    }

    /// 割当パラメータの現在値をモーターへ（差分のみ。force = 全送信）
    private func pushMotors(force: Bool = false) {
        guard !Self.quiet else { return }
        guard connected, let rack, let destination else {
            NSLog("roto: モーター送出を諦めた（connected=%@）", connected ? "yes" : "no")
            return
        }
        let slot = rack.selectedSlot
        var pairs: [[UInt8]] = []

        /// 差分判定（14bit raw で比べる — 丸めた後で同じなら送らない。
        /// 実体は `RotoShadow.motorChanged`）
        func changed(_ ctrl: Int, _ value: Double) -> Bool {
            shadow.motorChanged(ctrl, value, force: force)
        }

        if Self.dawType == 3 {
            // Logic 方言: ch15 に**絶対セル番号**で送る — 全ページぶんを
            // 一度に置ける（表示していないページも先に正しい位置にしておける）
            // **現在ページの 8 セル**を物理ノブ 0-7 へ流す。
            // 値が届かないと knob が活性化せず、回しても CC を返さない
            // （protocol.md「値が届くとデバイスが端 stop を張る」）
            for cell in 0..<RotoParam.smartCells {
                guard let ctrl = RotoPageLayout.smartCell(page: smartPage, deviceCell: cell),
                    let value = normalizedValue(ctrl, in: slot)
                else {
                    // 割当なし → 0 位置へ寝かせる（force のときだけ）。
                    // ⚠️ 席が無いので Ctrl 番号が無い — **負のキー**で帳簿を
                    // 分ける（Ctrl 番号は 0 以上なので衝突しない）
                    //
                    // ⚠️ **`LADYLAND_PARK_EMPTY_KNOBS`（既定 on）なら送らない**
                    // （`parksEmptyKnobs` の説明）。値を送ること自体が knob を
                    // 活性化させているので、送らなければ触っても動かない**はず**
                    if Self.parksEmptyKnobs { continue }
                    if force, shadow.motorRaw[-1 - cell] != 0 {
                        shadow.motorRaw[-1 - cell] = 0
                        pairs.append(contentsOf: Roto.smartMotor(param: cell, value: 0))
                    }
                    continue
                }
                // ⚠️ 帳簿のキーは **Ctrl 番号**（セル番号ではない）。入力側
                // （`handleShort` の `.lsb`）が Ctrl 番号で書いているので、
                // ここをセル番号で読むと**混線する** — P1 では ctrl {2,3,4,5,6}
                // がセル {0,1,2,3,4} の記録を汚し、「自分の声のこだま」抑止が
                // 効かずモーターが往復していた（Purple Haze 2026-08-04）
                guard changed(ctrl, value) else { continue }
                pairs.append(contentsOf: Roto.smartMotor(param: cell, value: value))
            }
        } else {
            // ⚠️ **PLUGIN 面のときだけ送る** — MIX 面では同じ CC が
            // トラックボリュームなので、パラメータ値を流し込むと音量が飛ぶ
            guard currentFace.drivesPluginKnobs else { return }

            // Bitwig 方言: ch16 CC12-19 の**物理 8 本**しかない。
            // 送れるのは表示中のページだけで、ページを繰ると同じ CC が
            // 別のセルを指す（`RotoPageLayout` が今の対応を持っている）。
            // 割当が無いセルには送らない — learn で起きた knob しか動かない
            for knob in 0..<RotoParam.physicalKnobs {
                let ctrl = RotoPageLayout.pluginCell(page: pluginPage, knob: knob)
                guard let value = normalizedValue(ctrl, in: slot), changed(ctrl, value) else { continue }
                pairs.append(contentsOf: Roto.motor(knob: knob, value: value))
            }
        }
        guard !pairs.isEmpty else {
            if force { NSLog("roto: モーター送出 0 通（全セルが既に同じ位置）") }
            return
        }
        if force { NSLog("roto: モーター送出 %d 通（force）", pairs.count) }
        sender.sendRaw(pairs, to: destination, gap: 1_000)
    }

    // MARK: - 送信

    /// **送信経路はこの 1 本だけ**（5ms ペーシング）。
    ///
    /// ⚠️ 応答（learn / hello）を「遅らせないため」に即時送信の第 2 経路を
    /// 作ってはいけない。**順序が壊れる** — 告知バッチ（0B 02〜08）がキューに
    /// 並んでいる間に learn が追い越すと、デバイスは告知処理中の learn を捨て、
    /// LCD は保存名のまま残る（実測 2026-08-03、これで半日溶かした）。
    ///
    /// 遅延が問題になるなら**キューを軽くする**のが正解で、追い越し車線を
    /// 作るのは間違い。投影は方言ガードと面ごとの上限で軽く保つこと。
    ///
    /// 実体は `RotoSendQueue`（同じ警告をキュー側にも置いてある）—
    /// ここは「宛先が居るときだけ流す」ぶんの薄い皮
    private func send(_ messages: [[UInt8]]) {
        guard let destination else { return }
        sender.send(messages, to: destination)
    }
}
