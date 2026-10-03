//! アプリ全体の状態 — Rack と MIDI 入力の結線点。
//!
//! UI からの操作（選択・ロード・音量）はすべてここを通す。
//! 選択やロードが変わるたびに MIDIRouter の送り先を更新することで、
//! RT スレッドの受信経路（MIDIInput）と MainActor の状態（InstrumentRack）を
//! 安全に橋渡しする。

import AVFoundation
import Combine
import KeystageKit
import Lpd8Kit
import RotoKit
import SwiftUI
import UniformTypeIdentifiers
import notify

@MainActor
final class AppState: ObservableObject {
    let rack = InstrumentRack()
    let router = MIDIRouter()
    let editors = PluginEditorWindows()
    let settings = SettingsWindowController()
    let faceKnobs = FaceKnobController()
    /// LPD8 ノブ → ドラムスロットの顔つまみ（Keystage 側と独立のピックアップ）
    let drumFaceKnobs = FaceKnobController()
    /// 鍵盤 2（NCXse）→ 担当スロットの顔つまみ（ModWheel 席の駆動先。
    /// 固定先が選択と割れても正しい席の割当を見る — `drumFaceKnobs` と同じ作法）
    let secondFaceKnobs = FaceKnobController()
    let thumbnails = PluginThumbnailStore()
    let ledBus = LedBus()
    /// ROTO-CONTROL projector 常駐（push 型。docs/roto-control/protocol.md）
    let roto = RotoService()
    /// Keystage の ARP / CHORD 設定を送り込む常駐（push 型。docs/keystage/README.md）
    let keystage = KeystageService()
    /// Field への供給（design/07 クライアント① — fieldd が居なくても音は無関係）
    let fieldLink = FieldLink()
    let lpd8Editor = Lpd8EditorModel()
    let debugLog = DebugLog()
    let debugWindow = DebugWindowController()
    /// 起動時のウィンドウ配置 + 以後の追従保存（mako 裁定 2026-08-01）
    let windowPlacement = WindowPlacementController()
    /// サイドバーから切り離した面（ポップアウト。置き場は window.json）
    let panes = PaneWindowController()
    private var midi: MIDIInput?
    /// ラック復元中の Task。起動経路が重なっても古い復元を放置しない。
    private var restoreTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    /// 起動時エラー（GUI に表示）
    @Published var startupError: String?

    /// Keystage の ARP / CHORD 設定（**ラック全体で 1 セット** — mako 裁定 2026-08-04）。
    ///
    /// ladyland が SSOT。本体の操作はホストから読めない（Dump は保存済みしか
    /// 返さない）ので、こちらが持って変更のたびに送り込む。
    /// 起動時に実機から一度読んで初期値にする
    @Published var keystageSettings = KeystageSettings() {
        didSet {
            guard keystageSettings != oldValue else { return }
            keystage.apply(keystageSettings)
            scheduleAutosave()  // [常時保存 21] Keystage の ARP / CHORD 設定
        }
    }

    /// 保存用の符号化（JSON 1 列。列を 12 個生やさない）
    private var encodedKeystageSettings: String? {
        guard let data = try? JSONEncoder().encode(keystageSettings) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// DB から復元した設定。**実機の Dump より優先する** — ladyland が SSOT
    /// なので、前回送った設定を握手後に送り直す（nil = 保存なし = 実機に従う）
    private var restoredKeystageSettings: KeystageSettings?

    /// Gadget つまみ配置の spec（spec/06-gadget-knob-map.kdl）。
    /// **起動時に一度だけ読む** — 機種名 → P1 に出すパラメータの対応。
    /// spec に無い機種は従来どおり AU の並び順で自動配置される
    private lazy var gadgetKnobMaps = GadgetKnobMapLoader.loadDefault()

    /// ROTO がいま出している SMART ページ（0 始まり。画面の表示用）
    @Published private(set) var rotoPage = 0

    /// **シンセ入力 1（Keystage / PC-KB）の担当スロット**（nil = 選択に追従 =
    /// 従来挙動。spec/09 Jack — mako 裁定 2026-08-25「Keystage は A Track、
    /// MiniLab は B Track、別々にコントロールしたい」。鍵盤 2 の一般化）。
    /// ⚠️ Keystage のノブ帯（顔つまみ）の主語は当面「選択」のまま —
    /// Track 面の編集対象と揃えておく（design/08 §2）
    @Published var synthInput1Slot: Int? {
        didSet {
            guard synthInput1Slot != oldValue else { return }
            updateRouting()
            scheduleAutosave()  // [常時保存 25] シンセ入力 1 の担当スロット
        }
    }

    /// **LPD8 ノブ 8 の刺し先**（spec/09 Jack。mako 裁定 2026-09-26「Keystage の
    /// つまみで出来ていたことを LPD8 で代用したい」）。drums = ドラム席の顔つまみ
    /// （従来）、face = 選択 Track の顔つまみ（位置 → 現ページの席）
    @Published var lpd8KnobJack: Lpd8KnobJack = .drums {
        didSet {
            guard lpd8KnobJack != oldValue else { return }
            updateRouting()
            scheduleAutosave()  // [常時保存 26] LPD8 ノブの刺し先
        }
    }

    /// 鍵盤 2（NCXse / MiniLab）= シンセ入力 2 の担当スロット（**nil = 選択に
    /// 追従**。指定 = その席に固定。2nd キーボード計画 ②、mako 裁定 2026-08-10
    /// 「別々の二つの音源同時に弾きたい」）。タイルの右クリックで固定する
    @Published var secondKeyboardSlot: Int? {
        didSet {
            guard secondKeyboardSlot != oldValue else { return }
            updateRouting()
            scheduleAutosave()  // [常時保存 24] 鍵盤 2 の担当スロット
        }
    }

    /// **Keystage が送っている Tempo**（MIDI Clock から算出。nil = 受信なし）。
    /// 実機で BPM を設定すると LED が点滅し、その拍で Clock が飛んでくる。
    ///
    /// 実測 2026-08-05: `Keystage KBD/CTRL` が 24 tick/拍 で送っていて、
    /// 実機の BPM を変えると追従する（80 → 102 で 32/s → 40/s）。
    /// **SysEx では取れない** — BPM を変えても Push は 1 通も飛ばない
    @Published private(set) var clockBPM: Double? {
        didSet { applyTempoToInstruments() }
    }

    /// **テンポ同期**（mako 裁定 2026-08-05「テンポ同期を切ることもできる」）。
    /// 切ると口が「分からない」と答える = プラグインが自前の既定
    /// （たいてい 120 BPM）で動く。**これがずっと続いていた状態**
    @Published var tempoSyncEnabled = true {
        didSet {
            guard tempoSyncEnabled != oldValue else { return }
            applyTempoToInstruments()
            scheduleAutosave()  // [常時保存 23] テンポ同期の入切
        }
    }

    /// いま AU へ渡しているテンポ（同期が切れていれば nil）
    private func applyTempoToInstruments() {
        let tempo = tempoSyncEnabled ? clockBPM : nil
        rack.setMusicalTempo(tempo)
    }

    /// **セルの色を変える**（割当パネルの行から。mako 要望 2026-08-05
    /// 「小さい色のアイコンをおいて、コンテクストメニューでパレットを開いて、
    /// 即時更新できるように」）。nil = その席のページ既定へ戻す。
    ///
    /// 色は**いま選んでいる席のもの**として持つ（mako 裁定 2026-08-05
    /// 「Page 毎の配色を Track の Page 毎に」）。ROTO の SMART 面が映すのも
    /// 選択中の席なので、**見えている色と保存先が必ず一致する**
    func setCellColor(_ cc: Int, to color: UInt8?) {
        // 割当がある席は**パラメータ色**として書く（mako 要望 2026-08-15 —
        // 色は割当について回る。nil で未設定へ戻すと下位の 席色 > トラック
        // カラー > ページ色 に落ちる）。空きセルだけ従来の席色（trackCells）
        let slot = rack.selectedSlot
        if let index = slot.knobMappings.firstIndex(where: { $0.knob == cc }) {
            slot.knobMappings[index].color = color
            knobMappingsChanged()  // 常時保存（knobs は SlotSnapshot に乗る）
            scheduleRotoLiveBurn()  // 実機の席色が変わる
        } else {
            // didSet で実機へ即時反映 + 保存
            rotoColors.setCellColor(track: slot.index, cell: cc, to: color)
        }
    }

    /// そのセルに実機で出ている色（割当パネルの表示用）。
    /// **セル指定 > 席のページ色 > 席ごとの既定** の順で決まる
    func cellColor(_ cc: Int) -> UInt8 {
        rotoColors.lcdColor(
            track: rack.selectedSlot.index,
            page: FaceKnobAssignment.inferredPage(cc: cc) ?? 0,
            cell: cc)
    }

    // MARK: - Editor Mode（creo-ui editor-mode.md の Swift 最小 runtime。
    // EditorMode.swift 参照 — 実験、育ったら CreoUI へ昇格）

    /// D-7: 手動 toggle のみ（footer のボタン / ⌘E。自動 ON はしない）
    @Published var editorModeOn = false

    /// 編集できる field（D-5 のカスタムルート — bind 先は全部 @Published なので
    /// 変更は即 Content と実機に出る）。ROTO の役割色 6 つは UI に出していない
    /// 4 つも含めて全部並べる — 「UI が無い定数を live で触る」が mode の本領
    private(set) lazy var editorFields: [EditorField] = {
        let colorField: (String, String, WritableKeyPath<Roto.Colors, UInt8>) -> EditorField = {
            [unowned self] id, label, keyPath in
            EditorField(
                id: id, label: label, group: "ROTO 役割色",
                kind: .rotoColor(
                    get: { self.rotoColors[keyPath: keyPath] },
                    set: { self.rotoColors[keyPath: keyPath] = $0 ?? Roto.Colors()[keyPath: keyPath] }))
        }
        return [
            colorField("roto.assigned", "割当席", \.assigned),
            colorField("roto.empty", "空席", \.empty),
            colorField("roto.trackSelected", "選択トラック", \.trackSelected),
            colorField("roto.track", "トラック", \.track),
            colorField("roto.menu", "MAIN LCD 既定", \.menu),
            colorField("roto.selectButton", "選択ボタン", \.selectButton),
            EditorField(
                id: "play.tempoSync", label: "テンポ同期", group: "演奏",
                kind: .toggle(
                    get: { [unowned self] in self.tempoSyncEnabled },
                    set: { [unowned self] in self.tempoSyncEnabled = $0 })),
        ]
    }()

    /// ROTO の配色（設定画面から。83 色の固定パレットから選ぶ）
    @Published var rotoColors = Roto.Colors() {
        didSet {
            guard rotoColors != oldValue else { return }
            roto.colors = rotoColors
            scheduleAutosave()  // [常時保存 22] ROTO の配色
            scheduleRotoLiveBurn()  // 席色（trackCells）は INST 冊の焼き色にも出る
        }
    }

    /// Keystage の Global Dump（**User Chord Set 32 個**）。
    /// Preset は機器内蔵で Dump に含まれないため読めない
    @Published var keystageGlobalDump: [UInt8]?

    /// いま指が乗っている鍵（キープ中の音は含まない）。
    /// 和音の表示と「弾いて登録」に使う
    @Published var heldNotes: [UInt8] = []

    /// いま押さえている和音（判定できなければ nil）
    var heldChord: Chord? {
        ChordDetector.detect(
            notes: heldNotes, keyRoot: keyScale.root, scale: keyScale.scale)
    }

    /// 出力可能デバイスの一覧（設定ウィンドウの Picker 用。挿抜で自動更新）
    @Published var outputDevices: [AudioOutputDeviceInfo] = []

    /// ダンパーペダルの役割（mako 裁定 2026-08-03「ペダルを繋いだので既存機能と
    /// 切り替えながらプラグインにも流す道が欲しい」）。
    /// keep = ノート保持 / assign = マトリクスの一級市民として割当可能
    @Published var pedalMode: PedalMode = .keep {
        didSet {
            guard pedalMode != oldValue else { return }
            router.setPedalMode(pedalMode)
            updateRouting()  // 予約 CC が変わる = 横取り集合と一覧が変わる
            scheduleAutosave()  // [常時保存 20] ペダルの役割
        }
    }

    /// ダンパーペダルの極性反転（mako 報告 2026-08-14「キープが逆」— 踏むと
    /// 閉じる/開くの 2 種があるペダルの逆極性個体対応。入口 1 箇所で反転する
    /// ので、キープ・素通しのネイティブ sustain・assign の割当が全部揃う）
    @Published var pedalInverted = false {
        didSet {
            guard pedalInverted != oldValue else { return }
            router.setPedalInverted(pedalInverted)
            scheduleAutosave()  // [常時保存 23] ペダルの極性
        }
    }

    /// キー/スケール（LED 基本色の源。design/06 §8）
    @Published var keyScale = KeyScale(root: 0, scale: .major) {
        didSet {
            pushBaseColors()
            scheduleAutosave()  // [常時保存 10] キー/スケール変更（設定 UI）
        }
    }

    /// パッド → ノート対応（実機プログラム 1 の観測値。エディタ PR で GET に追従）
    var padNotes: [UInt8] = Lpd8DefaultPadNotes.program1

    /// LPD8 ノブの CC（実機ゴールデンの既定 K1-K8 = CC79-86。GET で追従）
    @Published var lpd8KnobCCs: [UInt8] = Lpd8DefaultKnobCCs.program1

    /// ノートのキープ（ダンパーペダル CC64）— 踏んでいる間と、いま何音
    /// 鳴らし続けているか。**見えないと踏みっぱなしに気づけない**ので GUI に出す
    /// いま繋がっている MIDI ソース（Jack 結線図の接続表示用。
    /// `connectSources` の記録をそのまま映す — 挿抜で更新）
    @Published private(set) var midiConnectedSources: [String] = []

    /// 同じものを結線先つきで（Jack 結線図の行 — 汎用鍵盤は名前で行になる）
    @Published private(set) var midiConnected: [MIDIConnectedSource] = []

    @Published private(set) var latchEngaged = false
    @Published private(set) var latchSustaining = 0

    /// Keystage ノブのページ（0-based、nil = 未確定）。ページ = CC ÷ 8 が正典
    /// （FaceKnobAssignment.inferredPage）— Page +/- 自体は MIDI 無音なので、
    /// 最初のノブ 1 動きまでは未確定のまま。
    /// 機器の電源再投入も検知できないので、セッション内のみ・保存しない
    @Published private(set) var activeKnobPage: Int?

    /// focus pane（画面中央の常設プラグイン view。mako 裁定 2026-08-01）へ
    /// 貸し出されている view。nil = プレースホルダ表示。custody は
    /// PluginEditorWindows（borrow/reclaim）— VC は 1 ユニット 1 回の制約
    @Published private(set) var focusPaneView: NSView?

    /// focus pane が担当中のスロット index（選択変更時に前の借用を返す）
    private var focusPaneIndex: Int?

    /// **Main 右列に並べる LPD8（ドラム席）の画面**（mako 要望 2026-08-06
    /// 「右に LPD8 のビュー（まずはサンプラ）のプラグインを並列で表示したい」）。
    ///
    /// ⚠️ focus pane と**同時に借りられる**。custody（`lentToFocus`）は
    /// index ごとの集合で、`selectedSlot` は `slots[selected]` = **ドラム席を
    /// 含まない**ので、両者が同じ席を取り合うことがない
    @Published private(set) var drumPaneView: NSView?

    /// 選択スクラブ（VALUE エンコーダー連打）中に VC 取得を蹴りまくらない
    /// ためのデバウンス
    private var focusPaneTask: Task<Void, Never>?

    /// VALUE エンコーダーの連打を歩数に落とすスロットル
    private var trackNav = TrackNavThrottle()

    init() {
        // 入れ子 ObservableObject の変更転送: rack.selected 等の変更を
        // AppState の変更として View に届ける（SwiftUI は nested な
        // @Published の変更を自動では観測しない）
        rack.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        // サムネ撮影先の注入 + 変更転送（撮れたらタイルに即反映）
        editors.thumbnails = thumbnails
        // [常時保存 12] プラグイン画面を閉じた（隠した）= 音色エディットの節目。
        // プラグイン UI 内の操作はホストに通知が来ないため、この節目で
        // fullState を再取得する（重い保存 — 数少ない「AU に触ってよい」瞬間）。
        // focus pane はウィンドウが閉じた瞬間に view を借り直す
        editors.onEditorHidden = { [weak self] in
            self?.saveRack(refresh: .all)
            self?.refreshFocusPane(afterDebounce: false)
        }
        // [常時保存 24] **画面を閉じない楽器**の音色エディット（Lady Sampler）。
        // サンプルの差し替えは `onEditorHidden` と同じ「音の節目」だが、
        // focus pane に常設される画面は閉じないので、その節目が永久に来ない。
        // **楽器側から言ってもらう**（実測 2026-08-06: 割り当てが保存されず消えた）
        rack.onInstrumentStateChanged = { [weak self] in
            self?.saveRack(refresh: .all)
        }
        // VC が届いたら focus pane が借りに行く（選択中スロットのみ）
        editors.onViewReady = { [weak self] index in
            guard let self, index == self.rack.selected else { return }
            self.refreshFocusPane(afterDebounce: false)
        }
        thumbnails.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        // 表示モードの変化（設定 UI / 緑ボタン / ⌃⌘F）を設定画面へ届ける
        windowPlacement.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        panes.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        // 終了時: LED を消灯してからラック構成 + 音色 blob を保存（design/06 §2・§8。
        // fullState 再取得 + 同期書き込み — プロセスが死ぬ前に書き切る）
        NotificationCenter.default
            .publisher(for: NSApplication.willTerminateNotification)
            .sink { [weak self] _ in
                self?.ledBus.shutdown()
                self?.saveRack(refresh: .all, synchronous: true)
                // ウィンドウ配置も書き切る（trailing 予約がプロセスの死で
                // 消えて「最後の移動だけ覚えていない」を作らない）
                self?.windowPlacement.flush()
            }
            .store(in: &cancellables)

        installAgentTriggers()
    }

    // MARK: - ROTO の冊焼き（UI ボタンと外部トリガーの共通入口）

    /// ROTO 3 冊焼きの結果（設定画面の表示用。外部トリガー経由でも更新される）
    @Published var rotoBurnResult: String?

    /// notify_register_dispatch の登録 token（保持しないと解除できない）
    private var agentTriggerTokens: [Int32] = []

    /// MIXER 冊の席名 = 焼き時点のスロット名（**トラック名 > プラグイン名**、
    /// 空席は T 番号）。
    /// 番号の遍歴（2026-08-13）: 「{n} {name}」を試したが、下段ボタンが
    /// 番号の最小表現「T{n}」になったので**上段の数字は抜いた**（mako
    /// 「そうすると、１行目の数字を抜いてください」— 上下で番号と名前の分業）
    func rotoMixerSlotNames() -> [String] {
        (0..<RotoMidiSetupExport.mixerTotalSlots).map { index in
            rack.slots.indices.contains(index)
                ? (rack.slots[index].trackName ?? "T\(index + 1)")
                : "T\(index + 1)"
        }
    }

    /// MIXER 冊の席色 = トラックカラー（nil = バンク色の既定に落ちる）
    func rotoMixerSlotColors() -> [UInt8?] {
        (0..<RotoMidiSetupExport.mixerTotalSlots).map { index in
            rack.slots.indices.contains(index) ? rack.slots[index].rotoColor : nil
        }
    }

    /// INST 冊の席色の上書き（焼きと UI の共通材料）。優先順は
    /// **パラメータ色（mapping.color）> 席色（trackCells）> トラックカラー >
    /// ページ色** — パラメータ色は割当の属性なので配置換えについて回る
    /// （mako 要望 2026-08-15。nil なら下位に落ちる）
    func rotoSeatCellColors() -> [Int: UInt8] {
        var colors = rotoColors.trackCells[rack.selected] ?? [:]
        for mapping in rack.selectedSlot.knobMappings {
            if let color = mapping.color { colors[mapping.knob] = color }
        }
        return colors
    }

    /// INST マトリクスのセル表示色 — **焼きと同じ解決**（seatColor）。
    /// ⚠️ `cellColor(_:)`（DAW モードの lcdColor 解決）はトラックカラーを
    /// 知らない — あちらを使うと画面と実機の色がズレる
    func instSeatColor(_ cc: Int) -> UInt8 {
        RotoMidiSetupExport.seatColor(
            cc: cc, cellColors: rotoSeatCellColors(),
            trackColor: rack.selectedSlot.rotoColor)
    }

    /// INST 冊のライブラベル — 選択スロットの割当（CC → 表示名）。
    /// 優先順は SMART 面と同じ: **別名 > AU の現在名 > 控えた名前**
    func rotoSeatLabels() -> [Int: String] {
        let slot = rack.selectedSlot
        var labels: [Int: String] = [:]
        for mapping in slot.knobMappings {
            let live = slot.parameter(at: mapping.address)?.displayName
            if let label = KnobLabel.resolve(
                alias: mapping.alias, live: live, remembered: mapping.name) {
                labels[mapping.knob] = label
            }
        }
        return labels
    }

    /// 3 冊 96 席をアドミンポートへ直接焼く。ブロッキング I/O なので main から
    /// 降ろす — 焼いている数秒は実機の CC が止まる（瞬間芸の掟。RotoAdminPort）。
    /// 結果は `rotoBurnResult` と NSLog の両方へ — 外部トリガーから呼ばれた
    /// ときはログと実機読み戻し（roto-admin info）が観測面になる。
    /// 成功したら差分焼きの影（`rotoDiffShadow`）をここで初期化する —
    /// 以降はライブラベル・カラーの変更が自動で差分焼きされる
    func burnRotoSetups() {
        NSLog("roto: burn 入口")
        rotoBurnResult = "焼き込み中…（数秒。ROTO-SETUP は閉じておく）"
        rotoShadowStatus = .burning("全冊")
        let names = rotoMixerSlotNames()
        let colors = rotoMixerSlotColors()
        let labels = rotoSeatLabels()
        let seatColor = rack.selectedSlot.rotoColor
        let cellColors = rotoSeatCellColors()
        let selectedTrack = rack.selected + 1
        let buttonColor = rotoColors.selectButton
        NSLog("roto: burn 材料そろった — detached へ")
        Task.detached(priority: .userInitiated) {
            NSLog("roto: burn detached 開始")
            let outcome: (summary: String, requests: [(key: RotoMidiSetupExport.SeatKey, request: [UInt8])]?)
            do {
                let burned = try RotoMidiSetupExport.burn(
                    slotNames: names, slotColors: colors,
                    seatLabels: labels, seatColor: seatColor,
                    seatCellColors: cellColors,
                    selectedTrack: selectedTrack,
                    selectButtonColor: buttonColor)
                outcome = (burned.summary, burned.requests)
            } catch {
                outcome = ("焼き込み失敗: \(error)", nil)
            }
            NSLog("roto: burn — %@", outcome.summary)
            await MainActor.run {
                self.rotoBurnResult = outcome.summary
                if let requests = outcome.requests {
                    self.rotoDiffShadow.prime(requests)
                    self.rotoShadowStatus = .synced("全冊 \(Self.shadowClock())")
                } else {
                    self.rotoDiffShadow.invalidate()
                    self.rotoShadowStatus = .unprimed
                }
                self.saveRotoShadow()
            }
        }
    }

    // MARK: - 差分焼き（mako 裁定 2026-08-12「選択変更で自動差分焼き」）

    /// 影の状態（footer に常駐 — mako 要望 2026-08-13「shadow の状態って
    /// そこにリアルタイム表示できる？」）。遷移は影を動かす場所でだけ更新する
    enum RotoShadowStatus: Equatable {
        case unprimed        // 影なし — 差分焼きは沈黙、全焼きが再出発点
        case synced(String)  // 実機と一致（摘要 = 最後の動き）
        case waiting         // デバウンス中 — 変更を束ねている
        case burning(String)  // シリアルへ書き込み中（摘要 = 規模）
        case portBusy        // ポートが取れない — リトライ待ち
    }
    @Published private(set) var rotoShadowStatus: RotoShadowStatus = .unprimed

    /// 摘要に付ける時刻（HH:mm:ss — 「いつの同期か」が動きの証拠になる）
    private static func shadowClock() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: Date())
    }

    /// 差分焼きの影（実機に焼いてある 192 席の姿。全焼きの成功で初期化、
    /// ディスクにも残す — 再起動しても差分焼きが即効く）
    private var rotoDiffShadow = RotoDiffShadow()

    /// 影の保存先。実機の設定はフラッシュに残るのだから影も残す（対称）
    private static var rotoShadowURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ladyland/roto-shadow.json")
    }

    /// 影が変わったら必ず呼ぶ（prime / pending 前進 / invalidate の後）
    private func saveRotoShadow() {
        guard let data = try? JSONEncoder().encode(rotoDiffShadow) else { return }
        try? data.write(to: Self.rotoShadowURL, options: .atomic)
    }

    /// 起動時に影を読み戻す（無ければ未 prime のまま = 全焼きが再出発点）
    private func loadRotoShadow() {
        guard let data = try? Data(contentsOf: Self.rotoShadowURL),
            let restored = try? JSONDecoder().decode(RotoDiffShadow.self, from: data)
        else { return }
        rotoDiffShadow = restored
        if restored.isPrimed {
            rotoShadowStatus = .synced("復元")
            NSLog("roto: 影を復元 — 差分焼きは再起動をまたいで有効")
        }
    }

    /// 予約中の差分焼き（デバウンス — 選択の連打は静まってから 1 発）
    private var rotoLiveBurnTask: Task<Void, Never>?

    /// **席の見た目が変わりうる操作の後に呼ぶ**（`updateRouting` に相乗り +
    /// トラック名・カラー変更）。1 秒のデバウンスで束ね、影との差分だけを
    /// シリアルへ撃つ。焼き中は CC が止まるので、**操作が静まるのを待ってから
    /// 1 発** — 選択を連打しても止まるのは最後の 1 回ぶんだけ。
    /// 影が無い間（全焼き前 / 失敗後）は沈黙 — 「ROTO へ直接焼く」が再出発点
    func scheduleRotoLiveBurn() {
        guard rotoDiffShadow.isPrimed, roto.connected else { return }
        rotoLiveBurnTask?.cancel()
        rotoShadowStatus = .waiting
        rotoLiveBurnTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.rotoLiveBurnTask = nil
            self?.performRotoLiveBurn()
        }
    }

    private func performRotoLiveBurn() {
        let requests = RotoMidiSetupExport.allRequests(
            slotNames: rotoMixerSlotNames(),
            slotColors: rotoMixerSlotColors(),
            seatLabels: rotoSeatLabels(),
            seatColor: rack.selectedSlot.rotoColor,
            seatCellColors: rotoSeatCellColors(),
            selectedTrack: rack.selected + 1,
            selectButtonColor: rotoColors.selectButton)
        let pending = rotoDiffShadow.pending(requests)
        guard !pending.isEmpty else {
            rotoShadowStatus = .synced("差分なし \(Self.shadowClock())")
            return
        }
        rotoShadowStatus = .burning("\(pending.count) 席")
        Task.detached(priority: .userInitiated) {
            do {
                let summary = try RotoMidiSetupExport.burnDiff(pending)
                NSLog("roto: 差分焼き — %@", summary)
                // ⚠️ **ディスク保存は焼きが成功してから**。pending 直後に保存
                // する楽観方式は、焼き完了前の quit（--reinstall）で「影だけ
                // 進んで実機に書かれない」乖離を作った — 影が期待と一致して
                // diff が出ず、実機の古い表示が直らない（実例 2026-08-13:
                // L02 INST #25 / L03 INST2 #2 の冊名割れ）。成功後保存なら
                // quit で焼きが飛んでもディスクは古いまま = 次回起動で自己修復
                await MainActor.run {
                    self.saveRotoShadow()
                    self.rotoShadowStatus = .synced("\(pending.count) 席 \(Self.shadowClock())")
                }
            } catch RotoMidiSetupExport.BurnDiffError.nothingWritten(let underlying) {
                // 1 件も書く前の失敗（ポート使用中 = 読み戻しベンチとの競合、
                // 探索失敗）— **実機は無傷なので影を捨てない**。ディスクの影
                // （前回成功時の姿）をメモリへ読み戻して仕切り直し、少し
                // 待ってから再試行（実例 2026-08-13: 競合タイムアウトで影を
                // 捨てて追従が止まった — 一時的な失敗で死なない設計へ）
                NSLog("roto: 差分焼き — ポートが取れない（%@）。リトライ",
                    String(describing: underlying))
                await MainActor.run {
                    self.rotoShadowStatus = .portBusy
                    self.loadRotoShadow()
                    self.scheduleRotoLiveBurn()  // → .waiting（primed なら）
                }
            } catch {
                // 途中まで書けた — どこまで実機に入ったか分からないので
                // 影ごと捨てて差分焼きを黙らせる（全焼きボタンで信頼を再出発）
                NSLog("roto: 差分焼き失敗 — 影を捨てて停止: %@", String(describing: error))
                await MainActor.run {
                    self.rotoDiffShadow.invalidate()
                    self.saveRotoShadow()
                    self.rotoShadowStatus = .unprimed
                }
            }
        }
    }

    /// エージェントの外部トリガー（mako 要望 2026-08-12「ROTO へ直接焼くの
    /// 経路をそちらで打てたりしないの？」）。ターミナルから
    /// `notifyutil -p club.chronista.ladyland.roto.burn` で UI ボタンと同じ
    /// 焼きが走る。Darwin 通知はローカル専用・引数なしの最小口 —
    /// 引数が要る操作が増えたら unison サーバーへ昇格する
    private func installAgentTriggers() {
        var token: Int32 = 0
        notify_register_dispatch(
            "club.chronista.ladyland.roto.burn", &token, DispatchQueue.main
        ) { [weak self] _ in
            NSLog("roto: 外部トリガー受信 — 冊を焼く")
            self?.burnRotoSetups()
        }
        agentTriggerTokens.append(token)
    }

    // MARK: - 常時保存（design/06 §2 の常時版 — mako 裁定 2026-08-01
    // 「変更があったら、すぐ永続化」。TERM 落ち・クラッシュでも状態が残る）

    /// 復元完了前は自動保存しない — 復元中の中途半端なラック
    /// （スロットがまだ載っていない）を書いて構成を壊さないためのガード
    private var autosaveReady = false

    /// 永続化の SSOT（SQLite / GRDB。mako 裁定 2026-08-02）。
    /// nil = 開けなかった = 保存なしで演奏だけ続ける（fail-open）
    private var database: RackDatabase?

    /// 直近の保存試行時刻（連続ストリームの間引き判定）
    private var lastSaveAttempt: Date = .distantPast

    /// 間引き中に予約された trailing 保存（発火時に最新状態を読むので
    /// 予約は 1 本あれば足りる — 途中の変更も最終値に含まれる）
    private var autosaveTask: Task<Void, Never>?

    /// 変更があったら、すぐ永続化する（leading）。ただし直近 1 秒以内に
    /// 保存済みなら trailing 予約に畳む — ↑↓ 押しっぱなし・ノブ回し中に
    /// fullState 取得 + 書き込みを毎イベント連発しないための間引き。
    /// ⚠️ 30 秒の定期保険は廃止した（mako 裁定 2026-08-03 — main が固まるため）。
    /// **呼び忘れると保存されない**ので、状態を変える経路は必ずここを通すこと
    func scheduleAutosave() {
        guard autosaveReady else { return }
        if Date().timeIntervalSince(lastSaveAttempt) >= 1.0 {
            saveRack()
        } else if autosaveTask == nil {
            autosaveTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(1))
                self?.autosaveTask = nil
                self?.saveRack()
            }
        }
    }

    /// 音色（fullState）を聞き直すか。**AU への問い合わせが main コストの
    /// 主役**（実測 2026-08-03: 24 席で 575ms、1 席 ~21ms とほぼ均等）なので、
    /// 聞く/聞かないをここで分ける
    enum StateRefresh {
        /// 聞かない（軽い保存 — 目録の行だけ。AU にも blob にも触らない）
        case none
        /// 全席に聞く（終了時 / プラグイン画面を閉じた時 / 書き出し）
        case all
    }

    /// ラックの現在状態を保存する（永続化の SSOT = SQLite。mako 裁定 2026-08-02）。
    ///
    /// **二層保存は維持**（2026-08-01「パツパツいう」の解剖から）— fullState を
    /// AU に問い合わせるコストは保存層を変えても安くならないため、聞く/聞かないを
    /// `refresh` で分ける。旧 JSON 時代の回避策（バイト列 dedup / 世代ガード /
    /// detached エンコード）は不要になった: 行単位の upsert は変更点しか触らず、
    /// DatabaseQueue が書き込みを直列化して順序を保証する。
    ///
    /// **main を塞がない 2 つの手当て**（2026-08-03 実測で 30 秒ごとに 575ms
    /// 固まっていた）:
    /// 1. SQLite 書き込みはキューへ預けて即戻る（順序は GRDB が保証）。
    ///    ただし `synchronous` — **終了時だけは書き切ってから死ぬ**（プロセスが
    ///    消えたら預けた書き込みも消える）
    /// 2. AU への問い合わせは main に残すしかない（AU は main 前提の相手）ので、
    ///    **定期保険そのものを廃止**した（mako 裁定 2026-08-03）— 重い保存は
    ///    節目だけになり、定期的に固まることが無くなった
    func saveRack(refresh: StateRefresh = .none, synchronous: Bool = false) {
        // **関数に入った瞬間から測る** — 重い保存の main コストは
        // fullState の問い合わせが主役なので、そこを含めないと意味がない
        let enter = DispatchTime.now().uptimeNanoseconds
        lastSaveAttempt = Date()
        guard let database else { return }
        switch refresh {
        case .none: break
        case .all: rack.refreshAllStateCaches()
        }
        // 控えを取り直したなら blob も書く（書かないと聞いた意味がない）
        let refreshState: Bool
        if case .none = refresh { refreshState = false } else { refreshState = true }
        var snapshot = rack.snapshot()
        snapshot.ledFeedback = ledBus.enabled
        snapshot.keyRoot = keyScale.root
        snapshot.keyScale = keyScale.scale.rawValue
        snapshot.pedalMode = pedalMode.rawValue
        snapshot.pedalInverted = pedalInverted
        snapshot.synthInput1Slot = synthInput1Slot
        snapshot.secondKeyboardSlot = secondKeyboardSlot
        snapshot.lpd8KnobJack = lpd8KnobJack.rawValue
        snapshot.theme = ThemeStore.shared.persistedValue
        snapshot.keystage = encodedKeystageSettings
        snapshot.rotoColors = (try? JSONEncoder().encode(rotoColors))
            .map { String(decoding: $0, as: UTF8.self) }
        snapshot.tempoSync = tempoSyncEnabled

        let slotCount = snapshot.slots.count
        let start = enter

        // **main を何 ms 使ったか**（= 実際の UI の固まり時間）。
        // 非同期化後は総時間にキュー待ちが混ざるので、総時間だけ見ていると
        // 「直ったのか」が判定できない — 分けて出す
        let mainMs = Double(DispatchTime.now().uptimeNanoseconds - enter) / 1_000_000

        // 書き込みキューのスレッドから呼ばれる — 捕まえるのは値型だけにして
        // MainActor を持ち出さない（NSLog はどのスレッドからでも安全）
        let report: @Sendable (Result<Void, Error>) -> Void = { result in
            let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            switch result {
            case .success:
                if refreshState || ms > 5 {
                    NSLog(
                        "rack saved: %d slots%@ (%.1fms, main %.1fms)", slotCount,
                        refreshState ? " + blobs" : "", ms, mainMs)
                }
            case .failure(let error):
                NSLog("rack save failed: %@", String(describing: error))
            }
        }

        guard !synchronous else {
            do {
                try database.save(snapshot, includeBlobs: refreshState)
                report(.success(()))
            } catch {
                report(.failure(error))
            }
            return
        }
        database.saveAsync(snapshot, includeBlobs: refreshState, completion: report)
    }

    func start() {
        startCoreRuntime()
        startFieldProjection()
        observeOutputDevices()
        bindMIDIRouter()
        startLedFeedback()
        startRotoService()
        startKeystageService()
        bindLpd8Editor()
        restoreSession()
        observeThemeChanges()
        startSelfTestIfRequested()
    }

    /// ログを開いてから Audio / MIDI を起動する。ログの取りこぼしを防ぐため、
    /// `start()` の最初に呼ぶ。
    private func startCoreRuntime() {
        // NSLog の出口（stderr）を横取りして Debug ウィンドウに映す（最初に —
        // 以降の起動ログも全部乗る）
        debugLog.startCapture()
        debugLog.startFileLog()

        // 差分焼きの影を読み戻す — 再起動のたびに全焼きしなくて済む
        loadRotoShadow()

        // ⚠️ **rack の init は捕捉より前に走る**ので、そこで出したログは
        // ファイルに残らない。自作シンセが列挙に出たかはここで確かめる
        let hasLadySynth = rack.catalog.contains { $0.name == LadySynth.displayName }
        NSLog(
            "synth: %@ — カタログに%@（全 %d 機種）",
            LadySynth.displayName, hasLadySynth ? "出た" : "**出なかった**", rack.catalog.count)

        // 保存されたウィンドウ配置を適用（既定は従来どおり内蔵フルスクリーン）。
        // ここ = ContentView.onAppear はウィンドウが立った後で、生成の
        // タイミング揺れはコントローラ側のリトライが吸収する
        windowPlacement.applyAtLaunch()
        // 前回開いていた切り離し面は、主ウィンドウの配置（リトライ込み）の後に
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self else { return }
            self.panes.restoreAtLaunch(appState: self)
        }

        do {
            try rack.start()
            let input = MIDIInput(router: router)
            try input.start()
            midi = input
            updateRouting()
        } catch {
            startupError = String(describing: error)
        }
    }

    private func startFieldProjection() {
        // Field への供給を開始（fieldd が居なければ静かに再試行 —
        // 楽器のアイデンティティ + 出音 peak を 10Hz で写す。design/07 §4-2）
        fieldLink.start { [weak self] in
            guard let self else { return [] }
            // 全 64 体（~6KB — Rust server が 2KB 超を zstd 圧縮する。Swift
            // クライアントの展開未実装で一度死んだ実例 2026-08-15 —
            // club-unison の fix(swift): zstd 展開 で根治済み）
            return self.rack.slots.map { slot in
                FieldEntity(
                    id: slot.index + 1,
                    name: slot.trackName ?? "T\(slot.index + 1)",
                    color: slot.rotoColor.map { index in
                        String(format: "#%06X", Roto.Color.palette[Int(index) % Roto.Color.palette.count])
                    },
                    selected: slot.index == self.rack.selected,
                    level: slot.level)
            }
        }
    }

    private func observeOutputDevices() {
        // 出力デバイス一覧の初期化 + 挿抜監視（design/06 §8）
        outputDevices = OutputDevice.all()
        OutputDevice.observeChanges { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.outputDevices = OutputDevice.all()
                // 保存していた出力デバイスが**後から現れたら**切り替える
                // （AirPods 等 — 起動時に不在で「現状維持」になった分の回収。
                // wanted は復元/切替の失敗時にだけ立つので、平時の挿抜で
                // 勝手に切り替わることはない）
                if let wanted = self.rack.wantedOutputUID,
                    self.outputDevices.contains(where: { $0.uid == wanted }),
                    self.rack.switchOutput(toUID: wanted) {
                    NSLog("output: 保存していたデバイスが現れた — 切り替えた")
                }
            }
        }
    }

    private func bindMIDIRouter() {
        // Keystage VALUE エンコーダー → トラック順移動（docs/keystage §6。
        // 連打で送られてくるためスロットルで歩数化。CC はレイテンシ非敏感なので
        // main へホップしてから適用 — 顔つまみと同じ作法）
        // ノートのキープ（ダンパーペダル）の状態を GUI へ
        router.setLatchHandler { [weak self] engaged, sustaining in
            DispatchQueue.main.async {
                guard let self else { return }
                if self.latchEngaged != engaged { self.latchEngaged = engaged }
                if self.latchSustaining != sustaining { self.latchSustaining = sustaining }
            }
        }

        // Program Change 由来のトラック移動（実機の VALUE エンコーダー、
        // 2026-08-02 確定）。差分がそのまま歩数なので**スロットルを噛ませない** —
        // 1 メッセージ = 1 クリックで、速く回せばその分まとめて動く
        // **VALUE エンコーダーの回転 → トラック移動**。
        //
        // ⚠️ 一度 CC117/118 へ移そうとしたが**外れた**（実測 2026-08-05）。
        // KONTROL EDITOR の `Encoder`（REW / FF）は VALUE エンコーダーとは
        // **別のコントロール**で、焼いても VALUE は PC を送り続ける。
        //
        // ⚠️ **2026-08-07 に「同じコントロールだった」と書き換えたが、
        // それが誤りだった** — 実機で **ch1 の Program Change が出続けている**
        // ことを確認して戻した。EDITOR で `Encoder` を選ぶと VALUE が光る、を
        // 根拠にしたのが早合点で、**表示より「実際に何が飛んでいるか」が強い**。
        //
        // ⚠️ **受け口を外してはいけない** — 外すと PC が楽器へ素通しになり、
        // 回すたびにプラグインのプリセットが変わる（以前踏んだ事故）。
        //
        // 速く回すと連続で来るので、スロットルを噛ませる
        router.setNavHandler { [weak self] direction, throttled in
            DispatchQueue.main.async {
                guard let self else { return }
                // ⚠️ **連打しうる経路だけ間引く**（実測 2026-08-07）。
                // Program Change は 1 メッセージ = 1 クリックで差分が歩数なので、
                // 間引くと**速く回したぶんが丸ごと消えて「動かない」**ように見える
                if throttled,
                    !self.trackNav.shouldStep(nowNs: DispatchTime.now().uptimeNanoseconds)
                {
                    return
                }
                self.selectOffset(direction)
            }
        }

        // **PROG 4 のパッド = プラグイン選択**（mako 裁定 2026-08-04）。
        // 数字キー 1-8 と同じ対応 — いる行（バンク）の 8 つを直接選ぶ。
        // LPD8 は 4 プログラム持てるので、1 つを操作面に充てる運用
        router.setPadSelectHandler { [weak self] pad in
            DispatchQueue.main.async {
                guard let self else { return }
                self.select(self.rack.bankStart + pad)
            }
        }

        // **Keystage の Tempo（MIDI Clock）→ BPM**（mako 相談 2026-08-05）。
        // 1 拍（24 tick）たまるたびに来る。0.5 BPM 以上動いたときだけ通知される
        router.setTempoHandler { [weak self] bpm in
            DispatchQueue.main.async { self?.clockBPM = bpm }
        }

        // **CC120 = All Sound Off → パニック**（mako 裁定 2026-08-05）。
        // Keystage の EXIT が送る。外の音源は仕様どおり止まるので、
        // ladyland だけ無視するのは筋が通らない
        router.setPanicHandler { [weak self] in
            DispatchQueue.main.async { self?.panic() }
        }

        // **Rec / Loop → ROTO のページ送り**（`KeystageControls.pageStep` が
        // 正典。ボタンは Track Up/Down → Play/Stop → Rec/Loop と渡り歩いた）。
        // ROTO の ← → はホストに届かないので、鍵盤の手元から繰れるようにする
        router.setPageStepHandler { [weak self] direction in
            DispatchQueue.main.async {
                self?.roto.stepSmartPage(direction)
            }
        }

        // MIDI ルーティングトレース → Debug ウィンドウ（design/06 §8 追補）。
        // RT スレッドで MidiRoute 値型が発行され、ここ（main）で名前を足して
        // 整形する。連続ストリームは collapse key で 1 行に畳まれる
        router.setTraceHandler { [weak self] route in
            DispatchQueue.main.async {
                guard let self else { return }
                let selected =
                    "slot \(self.rack.selected + 1) (\(self.rack.selectedSlot.displayName ?? "empty"))"
                let drums = "drums (\(self.rack.drumSlot.displayName ?? "empty"))"
                let secondIndex = self.secondKeyboardSlot ?? self.rack.selected
                let secondName =
                    "slot \(secondIndex + 1) (\(self.rack.slots.indices.contains(secondIndex) ? (self.rack.slots[secondIndex].displayName ?? "empty") : "?"))"
                let line = MidiTraceFormat.line(
                    route, selectedSlot: selected, drumSlot: drums, secondSlot: secondName)
                self.debugLog.append(line.text, collapseKey: line.key, kind: .midi)

                // ノブページの追従（ノブストリップの見出し）。トレースは
                // keyboard 経路の唯一の main 観測点 — 帯（CC0-63）は割当の
                // 有無に関わらず `.knob` trace を出す（監査 2026-08-08 の B-7）
                // ので、未割当ノブでもページが追従する。値が変わる時だけ
                // publish（ノブ回し中の再描画嵐を避ける）
                if let cc = route.keystageCC,
                   let page = FaceKnobAssignment.inferredPage(cc: cc),
                   page != self.activeKnobPage {
                    self.activeKnobPage = page
                    // ⭐ **ROTO の SMART 面も同じページへ**（mako 依頼 2026-08-08）。
                    // **PAGE +/- キーは MIDI 無音**（実測 2026-08-01）だが、
                    // `base = 0` の今は **CC 番号がページを自己申告する**ので、
                    // **ノブを 1 つ動かせば実機の LCD 8 枚も付いてくる**。
                    self.roto.followKnobPage(page)
                    // Keystage 自身の OLED も新しいページの内容へ
                    self.refreshKeystageDisplay()
                }
            }
        }
    }

    private func startLedFeedback() {
        // LED フィードバック常駐開始（design/06 §8。データ源はドラムスロット =
        // パッドが実際に鳴らす声部のレベル）
        ledBus.configure(levelProvider: { [weak rack] in rack?.drumSlot.level ?? 0 })
        // **実機のパッド LED に再生状態を出す**（mako 要望 2026-08-06
        // 「再生中か再生中じゃないかは、Pad の色も合わせたい」）。
        //
        // ⚠️ サンプラーが載っていなければ**空を返す** — LedBus 側が
        // 基本色のまま出すので、今までどおりの見た目になる。
        // ⚠️ 読みは `padStates()` **1 回**（LED の tick は約 9Hz）
        ledBus.configure(playStateProvider: { [weak rack] in
            guard let sampler = rack?.drumSlot.audioUnit?.auAudioUnit as? LadySampler
            else { return [] }
            return sampler.padStates().map { state in
                if state.isPlaying { return .playing }
                // 位置が残っている = 一時停止（頭で止まっているのは idle）
                return state.loaded && state.position > 0 ? .paused : .idle
            }
        })
        midi?.onSetupChanged = { [weak self] in
            self?.ledBus.reconnect()
            self?.roto.reconnect()
            self?.keystage.reconnect()
            // Jack 結線図の接続表示（挿抜で線の色が変わる）
            self?.midiConnectedSources = self?.midi?.connectedSources ?? []
            self?.midiConnected = self?.midi?.connected ?? []
        }
        midiConnectedSources = midi?.connectedSources ?? []
        midiConnected = midi?.connected ?? []
        ledBus.start()
        pushBaseColors()
    }

    private func startRotoService() {
        // ROTO projector 常駐開始（push 型 — 接続できたら握手して投影。
        // 実機が無ければ何もしない。挿されたら onSetupChanged で再接続）
        roto.attach(rack: rack)
        // ROTO の SMART ページ（画面に出す。**繰れるのは ladyland 側だけ** —
        // ROTO のボタンは MIDI を送っていない。実測 2026-08-04）
        roto.onPageChanged = { [weak self] in
            self?.rotoPage = self?.roto.smartPage ?? 0
        }
        roto.onParamChanged = { [weak self] in
            // [常時保存 19] ROTO knob = AU パラメータ変更（回し中はデバウンスが畳む）
            self?.scheduleAutosave()
        }
        roto.onSelectTrack = { [weak self] index in
            // MIXER 冊のボタン = Track の直接選択（mako 裁定 2026-08-13）。
            // select がルーティング / LED / 差分焼き / 保存まで運ぶ
            self?.select(index)
        }
        roto.start()
    }

    private func startKeystageService() {
        // Keystage の ARP / CHORD（push 型）。握手で現在の Scene Dump を読み、
        // それを初期値にする — **実機とズレた状態から始めない**ため。
        // 以後は GUI の変更が didSet 経由で送られる
        // 押さえている鍵を GUI へ（和音表示 + 「弾いて登録」の入力）
        router.onHeldNotesChanged { [weak self] notes in
            Task { @MainActor in self?.heldNotes = notes }
        }
        keystage.onGlobalLoaded = { [weak self] dump in
            self?.keystageGlobalDump = dump
        }
        keystage.onSettingsLoaded = { [weak self] loaded in
            guard let self else { return }
            // **保存があればそちらが正**（ladyland が SSOT）。実機の Dump は
            // 保存済みシーンしか返さないので、前回 ladyland が送った設定は
            // そこに現れない — 復元した値で上書きして送り直す
            if let restored = self.restoredKeystageSettings {
                self.keystageSettings = restored
            } else {
                // 保存が無い初回だけ実機に従う。didSet で apply が走るが、
                // サービス側が「最後に送った値と同じ」と判断して送り返さない
                self.keystageSettings = loaded
            }
            // ⭐ **握手のたびにノブ OLED を書き直す**（mako 実測 2026-08-09:
            // 表示は切断後も残るが、**Keystage は USB 給電なので挿し直し =
            // 電源断 = 白紙**。影は reconnect で捨ててあるので全行が飛ぶ）
            self.refreshKeystageDisplay()
        }
        keystage.start()
    }

    private func bindLpd8Editor() {
        // LPD8 エディタの配線（design/06 §8）: 送信口 / SysEx 受信 /
        // LedBus の suspend 窓 / GET でパッド → ノート対応を実機に追従
        lpd8Editor.send = { frame in
            guard let dest = try? MIDISysExSender.destination(matching: "LPD8") else {
                return false
            }
            MIDISysExSender.send(frame, to: dest)
            return true
        }
        lpd8Editor.onBeginSysEx = { [weak self] in self?.ledBus.suspend() }
        lpd8Editor.onEndSysEx = { [weak self] in self?.ledBus.resume() }
        lpd8Editor.onProgramRead = { [weak self] program in
            self?.padNotes = program.pads.map(\.note)
            self?.lpd8KnobCCs = program.knobs.map(\.cc)
            self?.pushBaseColors()
            self?.updateRouting()  // ノブ CC が変われば横取り集合も変わる
        }
        midi?.sysexRelay.setHandler { [weak self] frame in
            Task { @MainActor [weak self] in
                self?.lpd8Editor.handleSysEx(frame)
            }
        }
    }

    private func restoreSession() {
        // 永続化の SSOT を開く（mako 裁定 2026-08-02）。初回は rack.json から
        // 取り込む（**rack.json は消さない** — 後戻りできる状態を残す）。
        // DB が開けなければ startupError を出して**保存なしで演奏は続行**
        // させる（fail-open — 音を止めない方が本番では正しい）
        do {
            let db = try RackDatabase()
            try db.importLegacyIfNeeded()
            try db.collectGarbage()  // 参照されない blob の掃除は起動時だけ
            database = db
        } catch {
            startupError = "永続化を開けませんでした（保存なしで続行）: \(error.localizedDescription)"
            NSLog("rack database open failed: %@", String(describing: error))
        }

        // 前回のラック構成を復元（design/06 §2「再起動しても並んでいる」）
        if let snapshot = try? database?.load() ?? nil {
            ledBus.enabled = snapshot.ledFeedback ?? true
            // 画面のテーマ（読めない値は既定へ倒れる — ThemeStore.restore）
            ThemeStore.shared.restore(from: snapshot.theme)
            if let root = snapshot.keyRoot,
               let scale = snapshot.keyScale.flatMap(ScaleKind.init(rawValue:)) {
                keyScale = KeyScale(root: root, scale: scale)
            }
            // Keystage の ARP / CHORD（**保存があれば実機の値より優先**）。
            // ladyland が SSOT なので、前回送った設定を復元して送り直す
            if let sync = snapshot.tempoSync { tempoSyncEnabled = sync }
            if let json = snapshot.rotoColors,
               var decoded = try? JSONDecoder().decode(
                   Roto.Colors.self, from: Data(json.utf8)) {
                // 既定を白→青に変えた分の読み替え（mako 2026-08-04
                // 「白じゃなくて別の青系に」）。**保存が既定より優先される**
                // 仕組みなので、既定だけ変えても白のままだった
                if decoded.assigned == Roto.Color.white {
                    decoded.assigned = Roto.Color.azure
                }
                rotoColors = decoded
            }
            if let json = snapshot.keystage,
               let decoded = try? JSONDecoder().decode(
                   KeystageSettings.self, from: Data(json.utf8)) {
                restoredKeystageSettings = decoded
            }
            // nil = keep（ペダル導入前のデータは従来の挙動のまま）
            pedalMode = snapshot.pedalMode.flatMap(PedalMode.init(rawValue:)) ?? .keep
            // nil = 標準極性（反転導入前のデータはそのまま）
            pedalInverted = snapshot.pedalInverted ?? false
            // 鍵盤 2 の固定（nil = 選択に追従。導入前のデータもそのまま）
            secondKeyboardSlot = snapshot.secondKeyboardSlot
            // シンセ入力 1 の固定（同上）
            synthInput1Slot = snapshot.synthInput1Slot
            // LPD8 ノブの刺し先（nil = drums = 導入前の挙動）
            lpd8KnobJack = snapshot.lpd8KnobJack.flatMap(Lpd8KnobJack.init(rawValue:)) ?? .drums
            restoreTask?.cancel()
            restoreTask = Task { @MainActor [weak self] in
                guard let self else { return }
                await rack.restore(from: snapshot)
                updateRouting()
                // 復元が終わってから常時保存を解禁 — 復元途中の
                // 中途半端なラックを書いて構成を壊さない
                autosaveReady = true
            }
        } else {
            autosaveReady = true
        }
    }

    private func observeThemeChanges() {
        // ⚠️ **復元し終えてから購読する**（初回起動でも通るよう if の外）。
        // 先に繋ぐと復元そのものが保存を呼び、起動のたびに書き込みが 1 回増える。
        // テーマは設営中に決めるもので頻繁には動かないので、変わった瞬間に保存する
        ThemeStore.shared.onChange = { [weak self] in
            // 音色は取り直さない（テーマは音に関係ない）— `.none` で軽く済む
            self?.saveRack(refresh: .none)
        }

        // ⚠️ **定期保険（30 秒タイマー）は廃止**（mako 裁定 2026-08-03）。
        //
        // 全席に fullState を聞くコストが main を 512-590ms 占有しており、
        // 30 秒ごとに UI が固まっていた（実測）。AU は main 前提の相手なので
        // 逃がせず、巡回で薄めても最大 153ms 残る上にカーソル状態という
        // 複雑さを抱える。**定期的に固まらないこと**を取った。
        //
        // 重い保存は節目だけ: プラグイン画面を閉じた時 / 終了時 / 書き出し。
        // 失うのは「プラグイン画面を開けっぱなしでクラッシュ」した場合の
        // 音色エディットだけ（正常終了なら willTerminate が全部書き切る）
    }

    private func startSelfTestIfRequested() {
        // P1 デバッグ: LADYLAND_SELFTEST=1 で MIDI 入力なしの音声グラフ検証。
        // Memphis をスロット 0 にロード → C4 を 2 秒発音。RMS ログが出れば
        // グラフは正常 = 問題は MIDI 入力側、と切り分けられる。
        if ProcessInfo.processInfo.environment["LADYLAND_SELFTEST"] == "1" {
            rack.installDebugRMSTap()
            Task {
                let component = rack.catalog.first { $0.name.contains("Memphis") }
                    ?? rack.catalog.first { $0.manufacturer.contains("KORG") }
                guard let component else {
                    NSLog("selftest: no KORG instrument found")
                    return
                }
                do {
                    try await rack.load(component, into: rack.slots[0])
                    updateRouting()
                    NSLog("selftest: loaded %@ into slot 0", component.name)
                    try await Task.sleep(for: .seconds(2))
                    NSLog("selftest: note on C4")
                    rack.slots[0].sendMIDI([0x90, 60, 100])
                    try await Task.sleep(for: .seconds(2))
                    rack.slots[0].sendMIDI([0x80, 60, 0])
                    NSLog("selftest: note off")
                    saveRack()  // 保存→次回起動の復元でラウンドトリップ検証
                } catch {
                    NSLog("selftest: %@", String(describing: error))
                }
            }
        }
    }

    // MARK: - UI からの操作（すべてここを通す）

    func select(_ index: Int) {
        rack.select(index)
        updateRouting()
        flashSelectionLed()
        scheduleAutosave()  // [常時保存 1] 選択（クリック / 数字キー 1-8）
    }

    func selectNext() {
        rack.selectNext()
        updateRouting()
        flashSelectionLed()
        scheduleAutosave()  // [常時保存 2] 順送り（→ / VALUE エンコーダー）
    }

    func selectPrevious() {
        rack.selectPrevious()
        updateRouting()
        flashSelectionLed()
        scheduleAutosave()  // [常時保存 3] 戻し（← / VALUE エンコーダー）
    }

    /// 選択カーソルの相対移動（Cmd+矢印: ±1 = 左右、±8 = 行ジャンプ）
    func selectOffset(_ delta: Int) {
        rack.selectOffset(delta)
        updateRouting()
        flashSelectionLed()
        scheduleAutosave()  // [常時保存 15] カーソル移動（Cmd+矢印）
    }

    /// LED は物理パッド 8 個 = アクティブバンク（選択のいる行）に対応
    private func flashSelectionLed() {
        ledBus.flashSelection(rack.selected - rack.bankStart)
    }

    func load(_ component: InstrumentComponent, into slot: InstrumentSlot) {
        Task {
            do {
                // 差し替え前に旧プラグインの画面を閉じる（死んだ view を残さない。
                // 閉じ際の撮り納めは willClose 側が旧 desc で行う）。
                // focus pane が借りていたら先に手放す（死んだ view を映さない）
                if focusPaneIndex == slot.index {
                    focusPaneView = nil
                }
                editors.close(for: slot.index)
                try await rack.load(component, into: slot)
                // プラグイン変更時は全パラメータを既定配置する（mako 裁定
                // 2026-08-01 — マトリクスは配置図。draft は自分の配置を持って
                // 旅をするので、着替え・復元はそれぞれの保存済み配置が戻る）。
                // ドラムスロットは LPD8 の K1-K8（現在プログラムの CC）へ
                let parameters = slot.parameterList.map { ($0.address, $0.displayName) }
                // 配置の優先順: **自分の Page 既定 > spec/06 > AU の並び順**
                // （mako 要望 2026-08-14「同楽器なら、すぐその設定で Paging
                // 設定で始められる」— default があるプラグインはロードした
                // 瞬間に自動適用。席色も一緒に戻る）
                if slot === rack.drumSlot {
                    slot.knobMappings = FaceKnobAssignment.fillingDefaults(
                        onto: lpd8KnobCCs.map(Int.init), parameters: parameters)
                } else if let entry = pluginPageDefaults.entry(for: component.name) {
                    slot.knobMappings = entry.knobs
                    rotoColors.trackCells[slot.index] =
                        entry.cellColors.isEmpty ? nil : entry.cellColors
                    NSLog("assign: %@ は自分の Page 既定を使う", component.name)
                } else if let map = gadgetKnobMaps[component.name] {
                    slot.knobMappings = FaceKnobAssignment.applying(map, to: parameters)
                    NSLog("assign: %@ は spec/06 の配置を使う", component.name)
                } else {
                    slot.knobMappings = FaceKnobAssignment.fillingDefaults(
                        [], parameters: parameters)
                }
                updateRouting()
                // 新しい顔を自動で撮りに行く（design/06 §8 追補 — サムネ refresh。
                // VC の所有は editors に一本化 — 二重要求で画面が開けなくなる）
                editors.refreshThumbnail(for: slot)
                scheduleAutosave()  // [常時保存 4] 楽器のロード / 差し替え
            } catch {
                startupError = "ロード失敗: \(component.name) — \(error.localizedDescription)"
            }
        }
    }

    /// 席を空にする（タイルの右クリック。mako 要望 2026-09-23）。
    /// 今の姿は draft として棚に残るので、タイルメニューから着せ直せる。
    /// 席の属性（色・名前・既定・席色）は席に残る
    func unload(_ slot: InstrumentSlot) {
        guard slot.audioUnit != nil else { return }
        // 差し替えと同じ作法: 死んだ view を残さない
        if focusPaneIndex == slot.index {
            focusPaneView = nil
        }
        editors.close(for: slot.index)
        rack.unload(slot)
        updateRouting()  // 割当が消える = 横取り集合も変わる
        scheduleAutosave()  // [常時保存 29] 席を空にする
    }

    /// タイル並び替え（番号バッジのドラッグ&ドロップ）: スロット中身の交換 →
    /// エディタウィンドウの担当替え → ルーティング同期。選択は楽器に追従する
    /// ため keyboard target の AU は変わらず、音は切れない
    func swapTiles(_ a: Int, _ b: Int) {
        rack.swapSlots(a, b)
        editors.swap(a, b)
        updateRouting()
        scheduleAutosave()  // [常時保存 5] タイル並び替え（TERM 落ちで配置消失の実例あり）
    }

    /// 棚の draft を着る（タイルメニューから。design/06 §8 Drafts）
    /// **この席の既定を覚える**（mako 要望 2026-08-06「set default / load default が欲しい」）。
    /// 音色（fullState）と割当をまとめて捕まえるので、**保存の節目**でもある
    func rememberDefault(on slot: InstrumentSlot) {
        slot.rememberAsDefault()
        saveRack(refresh: .all)  // 覚えた瞬間に SSOT へ書く（次の起動でも戻れる）
        NSLog("default: %@ を既定として覚えた", slot.displayName ?? "(empty)")
    }

    /// **この席の既定へ戻す**。draft と違って何度でも戻れる
    func loadDefault(on slot: InstrumentSlot) {
        Task { @MainActor in
            await rack.loadDefault(on: slot)
            updateRouting()  // 割当が変わる = 横取り集合も変わる
            saveRack(refresh: .all)
        }
    }

    func activateDraft(_ draft: Draft, on slot: InstrumentSlot) {
        Task {
            // 差し替えと同じ作法: 旧プラグインの画面を閉じてから
            if focusPaneIndex == slot.index {
                focusPaneView = nil
            }
            editors.close(for: slot.index)
            await rack.activateDraft(withID: draft.id, on: slot)
            updateRouting()
            editors.refreshThumbnail(for: slot)
            scheduleAutosave()  // [常時保存 16] draft 切替
        }
    }

    /// Cmd+Return: アクティブ draft を空きトラックへ昇格して focus 移動。
    /// 音は切れない（AU を席ごと移す）。工房は棚の最新を着せ直す
    func promoteDraft() {
        Task {
            let sourceIndex = rack.selected
            guard let target = await rack.promoteActiveDraft() else { return }
            // プラグイン画面の担当替え（昇格先は空席だったので実質 move）
            editors.swap(sourceIndex, target)
            updateRouting()
            flashSelectionLed()
            // 着せ直した工房の顔を撮り直す（空のままなら no-op）
            if rack.slots[sourceIndex].audioUnit != nil {
                editors.refreshThumbnail(for: rack.slots[sourceIndex])
            }
            scheduleAutosave()  // [常時保存 17] 昇格（Cmd+Return）
        }
    }

    /// 選択中スロットの音量を増減（↑↓ キー）
    func adjustSelectedGain(_ delta: Float) {
        let slot = rack.selectedSlot
        slot.gain = min(1.0, max(0.0, slot.gain + delta))
        scheduleAutosave()  // [常時保存 6] 音量（押しっぱなしはデバウンスが畳む）
    }

    /// スロットのミュートを切り替える（タイルの音量値クリック / Track 面。
    /// ROTO MIXER 冊のボタンからの変更は RotoService 側で保存まで走る）
    func toggleMute(_ slot: InstrumentSlot) {
        slot.mute.toggle()
        scheduleAutosave()  // [常時保存 25] ミュート（UI から）
    }

    /// トラックカラーを設定する（Track 面。nil = 未設定へ戻す）
    func setTrackColor(_ slot: InstrumentSlot, to color: UInt8?) {
        slot.rotoColor = color
        scheduleAutosave()  // [常時保存 26] トラックカラー
        scheduleRotoLiveBurn()  // MIXER 席色 + INST 冊の席色が変わる
    }

    /// トラック名を設定する（Track 面。空・空白だけは nil = プラグイン名へ戻す）
    func setTrackName(_ slot: InstrumentSlot, to name: String?) {
        let trimmed = name?.trimmingCharacters(in: .whitespaces)
        slot.customName = (trimmed?.isEmpty ?? true) ? nil : trimmed
        scheduleAutosave()  // [常時保存 27] トラック名
        scheduleRotoLiveBurn()  // MIXER 冊の席名・ミュートボタン名が変わる
    }

    /// トラックの gain を直接設定する（Track 面のスライダー）
    func setGain(_ slot: InstrumentSlot, to value: Float) {
        slot.gain = min(1.0, max(0.0, value))
        scheduleAutosave()  // [常時保存 28] 音量（ドラッグはデバウンスが畳む）
    }

    /// 顔つまみ割当の変更を反映する（割当 UI から呼ぶ）
    func knobMappingsChanged() {
        updateRouting()
        scheduleAutosave()  // [常時保存 7] 顔つまみ割当の編集
    }

    // MARK: - プラグインの Page 既定（mako 要望 2026-08-14「Track の Page の
    // set / load default。プラグイン自体の default として保存」）

    /// プラグイン名 → Page 既定（起動時に読み、保存のたび書き戻す）。
    /// @Published なのはロードボタンの活性が保存直後に追従するため
    @Published private var pluginPageDefaults = PluginPageDefaults.load()

    /// 選択スロットのプラグインに default があるか（Track 面のロードの活性）
    var selectedPluginHasPageDefault: Bool {
        guard let plugin = rack.selectedSlot.displayName else { return false }
        return pluginPageDefaults.entry(for: plugin) != nil
    }

    /// いまの Page 設計（割当 + 席色）を選択スロットのプラグイン既定として保存
    func savePluginPageDefault() {
        let slot = rack.selectedSlot
        guard let plugin = slot.displayName else { return }
        pluginPageDefaults.set(
            .init(
                knobs: slot.knobMappings,
                cellColors: rotoColors.trackCells[slot.index] ?? [:]),
            for: plugin)
        pluginPageDefaults.save()
    }

    /// プラグイン既定を選択スロットへロード（**上書き**。ページ編集と同じく
    /// 確認ダイアログなし — mako 裁定 2026-08-12 の流儀。事故ったら
    /// もう一度 default を保存し直す側で回復する）
    func loadPluginPageDefault() {
        let slot = rack.selectedSlot
        guard let plugin = slot.displayName,
            let entry = pluginPageDefaults.entry(for: plugin) else { return }
        slot.knobMappings = entry.knobs
        rotoColors.trackCells[slot.index] = entry.cellColors.isEmpty ? nil : entry.cellColors
        knobMappingsChanged()  // ルーティング + 常時保存
        scheduleRotoLiveBurn()  // INST 冊のラベル・席色が変わる
    }

    /// default 一式（page-defaults.kdl）を書き出す（mako 要望 2026-08-14
    /// 「default の load/set が出来れば、環境をコピーできる」— 別マシンへ
    /// このファイルを持っていけば同じ Paging 環境で始められる）
    func exportPluginPageDefaults() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "page-defaults.kdl"
        panel.prompt = "書き出す"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        pluginPageDefaults.save(to: url)
    }

    /// default 一式を読み込む — **丸ごと置き換え**（環境のコピーが目的なので
    /// マージはしない。取り込んだ内容は正規の場所へ写す = 次回起動もこの環境）。
    /// 旧 JSON（2026-08-14 初版）も受ける — 拡張子で読み分ける
    func importPluginPageDefaults() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [UTType(filenameExtension: "kdl") ?? .data, .json]
        panel.prompt = "読み込む"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        pluginPageDefaults = PluginPageDefaults.load(from: url)
        pluginPageDefaults.save()
    }

    /// **全スロットの未割当パラメータを空きセルへ敷き詰める**
    /// （mako 要望 2026-08-04「全部埋めよう」）。
    ///
    /// 既存の割当は動かさない — 位置を覚えている演奏を壊さないため。
    /// 差し替え時の自動割当（`fillingDefaults`）と同じ規則で、後から
    /// 増えたぶんだけを空きへ足す。
    ///
    /// ⚠️ 実測 2026-08-04 で **8 スロットに漏れ**があった（Lisbon は 3/65 しか
    /// 載っていなかった）。プラグイン差し替え時の自動割当より前に組んだ席や、
    /// 途中で外した割当が残っていたのが原因。
    /// - Returns: (埋めた席数, 足した割当の総数)
    /// - SeeAlso: `applySpecLayout()` — 位置ごと組み直す方
    @discardableResult
    func fillMissingAssignments() -> (slots: Int, added: Int) {
        var filledSlots = 0
        var added = 0
        for slot in rack.slots + [rack.drumSlot] {
            let parameters = slot.parameterList.map { ($0.address, $0.displayName) }
            guard !parameters.isEmpty else { continue }
            let before = slot.knobMappings.count
            // ⚠️ **既存の割当は動かさない**（位置を覚えている演奏を壊さない）。
            // spec の配置を適用し直したいときは `applySpecLayout` を使う —
            // ここは「足りないものを足す」だけに徹する
            let filled = FaceKnobAssignment.fillingDefaults(
                slot.knobMappings, parameters: parameters)
            guard filled.count > before else { continue }
            slot.knobMappings = filled
            filledSlots += 1
            added += filled.count - before
            NSLog(
                "assign: %@ に %d 個追加（%d → %d）",
                slot.displayName ?? "slot \(slot.index)", filled.count - before,
                before, filled.count)
        }
        if added > 0 {
            updateRouting()
            scheduleAutosave()  // [常時保存 23] 未割当パラメータの一括補完
        }
        return (filledSlots, added)
    }

    /// **spec/06 の配置を適用し直す**（mako 要望 2026-08-04 の KDL spec）。
    ///
    /// `fillMissingAssignments()` が「足りないものを足す」だけなのに対し、
    /// こちらは **位置ごと組み直す**。spec に載っている機種だけが対象で、
    /// 手で付けた**別名は引き継ぐ**（付け直しはライブ前の時間を溶かす）。
    /// - Returns: (組み直した席数, 配置した割当の総数)
    @discardableResult
    func applySpecLayout() -> (slots: Int, placed: Int) {
        var slots = 0
        var placed = 0
        for slot in rack.slots {
            guard let name = slot.displayName, let map = gadgetKnobMaps[name] else { continue }
            let parameters = slot.parameterList.map { ($0.address, $0.displayName) }
            guard !parameters.isEmpty else { continue }
            slot.knobMappings = FaceKnobAssignment.applying(
                map, to: parameters, keeping: slot.knobMappings)
            slots += 1
            placed += slot.knobMappings.count
            NSLog("assign: %@ に spec/06 の配置を適用（%d 個）", name, slot.knobMappings.count)
        }
        if slots > 0 {
            updateRouting()
            scheduleAutosave()  // [常時保存 24] spec 配置の適用
        }
        return (slots, placed)
    }

    /// スロットのプラグイン画面を開く（音色を作る場所。design/06 §2）。
    /// focus pane が同じスロットの view を借りていたら先に手放す
    /// （editors.open 内の reclaim がウィンドウへ戻す）
    func openEditor(for slot: InstrumentSlot) {
        if focusPaneIndex == slot.index {
            focusPaneView = nil
        }
        editors.open(for: slot)
        // isOpenOnScreen の変化（focus pane のプレースホルダ文言）を描画に反映
        objectWillChange.send()
    }

    // MARK: - focus pane（画面中央の常設プラグイン view）

    /// 選択が落ち着いてから借りる。スクラブ中（VALUE エンコーダー連打）に
    /// 未取得スロットの VC 要求を連発しないためのデバウンス
    func refreshFocusPane(afterDebounce: Bool = true) {
        focusPaneTask?.cancel()
        guard afterDebounce else {
            applyFocusPane()
            return
        }
        focusPaneTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            self?.applyFocusPane()
        }
    }

    /// ドラム席の画面を借りる（Main 右列用）。
    /// 借りられない（VC 未取得 / ウィンドウで編集中）ときは nil のまま —
    /// `borrowFocusPaneView` が駐機取得を蹴るので、届いたら次の呼びで入る
    func refreshDrumPane() {
        let slot = rack.drumSlot
        guard slot.audioUnit != nil else {
            drumPaneView = nil
            return
        }
        let view = editors.borrowFocusPaneView(for: slot)
        if view !== drumPaneView { drumPaneView = view }
    }

    private func applyFocusPane() {
        let slot = rack.selectedSlot
        if let old = focusPaneIndex, old != slot.index {
            focusPaneView = nil
            editors.reclaimFocusPaneView(old)
        }
        focusPaneIndex = slot.index
        guard slot.audioUnit != nil else {
            focusPaneView = nil
            return
        }
        let view = editors.borrowFocusPaneView(for: slot)
        if view !== focusPaneView {
            focusPaneView = view
        }
        // 右列（LPD8）も同じ拍で追う — 別の席なので取り合わない
        refreshDrumPane()
    }

    // MARK: - lldata スナップショット（持ち出す姿。mako 要望 2026-08-02）

    /// いまの状態を KDL で書き出す。**AU から fullState を取り直してから**
    /// 書く（重い保存と同じ節目 — 書き出したのに音色が古い、を作らない）
    func exportSnapshot(to url: URL, includeBlobs: Bool = true) throws {
        rack.refreshAllStateCaches()
        var snapshot = rack.snapshot()
        snapshot.ledFeedback = ledBus.enabled
        snapshot.keyRoot = keyScale.root
        snapshot.keyScale = keyScale.scale.rawValue
        snapshot.pedalMode = pedalMode.rawValue
        snapshot.pedalInverted = pedalInverted
        snapshot.synthInput1Slot = synthInput1Slot
        snapshot.secondKeyboardSlot = secondKeyboardSlot
        snapshot.lpd8KnobJack = lpd8KnobJack.rawValue
        snapshot.theme = ThemeStore.shared.persistedValue
        snapshot.keystage = encodedKeystageSettings
        snapshot.rotoColors = (try? JSONEncoder().encode(rotoColors))
            .map { String(decoding: $0, as: UTF8.self) }
        snapshot.tempoSync = tempoSyncEnabled
        let text = LlDataSnapshot.export(snapshot, at: Date(), includeBlobs: includeBlobs)
        try text.write(to: url, atomically: true, encoding: .utf8)
        NSLog("lldata exported: %@ (%dKB)", url.lastPathComponent, text.utf8.count / 1024)
    }

    /// スナップショットを読む（適用はまだしない — 何を入れるか選ばせる）
    func readSnapshot(at url: URL) throws -> LlDataSnapshot {
        try LlDataSnapshot.import(String(contentsOf: url, encoding: .utf8))
    }

    /// 選んだ席だけを現在のラックへ流し込む（部分ロード）。
    /// 既存の復元経路をそのまま使うので、AU が消えていても fail-open で続く
    func applySnapshot(
        _ snapshot: LlDataSnapshot, slotIndices: Set<Int>, includeGlobals: Bool
    ) {
        let partial = snapshot.partial(slotIndices: slotIndices, includeGlobals: includeGlobals)
        Task {
            // 差し替える席のプラグイン画面は先に閉じる（死んだ view を残さない）
            for slot in partial.slots {
                focusPaneView = nil
                editors.close(for: slot.index)
            }
            await rack.restore(from: partial)
            if includeGlobals {
                ledBus.enabled = partial.ledFeedback ?? ledBus.enabled
                ThemeStore.shared.restore(from: partial.theme)
                if let root = partial.keyRoot,
                   let scale = partial.keyScale.flatMap(ScaleKind.init(rawValue:))
                {
                    keyScale = KeyScale(root: root, scale: scale)
                }
                if let mode = partial.pedalMode.flatMap(PedalMode.init(rawValue:)) {
                    pedalMode = mode
                }
                if let inverted = partial.pedalInverted {
                    pedalInverted = inverted
                }
                if let synth = partial.synthInput1Slot { synthInput1Slot = synth }
                if let second = partial.secondKeyboardSlot { secondKeyboardSlot = second }
                if let jack = partial.lpd8KnobJack.flatMap(Lpd8KnobJack.init(rawValue:)) {
                    lpd8KnobJack = jack
                }
                if let keystage = partial.keystage,
                   let decoded = try? JSONDecoder().decode(
                       KeystageSettings.self, from: Data(keystage.utf8)) {
                    self.keystageSettings = decoded
                }
                if let colors = partial.rotoColors,
                   let decoded = try? JSONDecoder().decode(
                       Roto.Colors.self, from: Data(colors.utf8)) {
                    rotoColors = decoded
                }
                if let tempo = partial.tempoSync { tempoSyncEnabled = tempo }
            }
            updateRouting()
            pushBaseColors()
            saveRack(refresh: .all)  // 入れた音色を SSOT にも書く
            NSLog("lldata applied: %d slots", partial.slots.count)
        }
    }

    /// パニック（Esc）— 全スロットへ All Notes Off + キープの解除。
    /// **ライブの最後の砦**。原因が何であれ、音が残ったらこれで止められる
    func panic() {
        router.panic()
        for slot in rack.slots where slot.audioUnit != nil {
            slot.allNotesOff()
        }
        rack.drumSlot.allNotesOff()
        NSLog("panic: all notes off")
    }

    /// 設定ウィンドウを開く（design/06 §8。非モーダル — 演奏を隠さない）
    func openSettings() {
        settings.open(appState: self)
    }

    /// Debug ウィンドウを開く（ログをアプリ内で直接見る）
    func openDebug() {
        debugWindow.open(appState: self)
    }

    /// LED フィードバックの有効/無効（設定 UI から。ステージの非常口）
    func setLedFeedback(_ on: Bool) {
        ledBus.enabled = on
        objectWillChange.send()
        scheduleAutosave()  // [常時保存 9] LED キルスイッチ
    }

    /// キー/スケールの色を LedBus の基本色レイヤに流す
    private func pushBaseColors() {
        ledBus.setBase(keyScale.baseColors(padNotes: padNotes))
    }

    /// エンジンが実際に出力しているデバイス（footer の誤ルート警告用）。
    /// 再描画は outputDevices（挿抜）と rack.outputDeviceUID（切替）の
    /// @Published が引き金になる
    var currentOutputInfo: AudioOutputDeviceInfo? {
        OutputDevice.currentInfo(engine: rack.engine)
    }

    /// 出力デバイスを切り替える（空 UID = 既定へ戻す）。設定 UI から呼ばれる
    func switchOutput(uid: String) {
        if uid.isEmpty {
            rack.resetOutputToDefault()
        } else {
            rack.switchOutput(toUID: uid)
        }
        scheduleAutosave()  // [常時保存 8] 出力デバイス切替 / 既定へ戻す
    }

    // MARK: - PC キーボード演奏モード（機材ゼロのデモ用。`KeyPlay`）

    /// Tab で切替。⚠️ **実機ノートと同じ `routeKeyboard` を通す** — latch の
    /// 帳簿（和音表示・スロット切替時の orphan 掃除）と trace が全部生きる。
    /// `rack.selectedSlot.sendMIDI` 直叩きだと音が残る（監査 2026-08-09 §2-1）
    @Published private(set) var playModeOn = false

    /// キー → ノートの状態機械（オクターブと押下中ノートを持つ）
    @Published private(set) var keyPlay = KeyPlay()

    func togglePlayMode() {
        if playModeOn {
            // ⚠️ 抜けるときは押しっぱなしを全部消音（cortex と同じ作法）
            for note in keyPlay.releaseAll() { router.routeKeyboard(0x80, note, 0) }
        }
        playModeOn.toggle()
    }

    /// 演奏モードのキー押下。**演奏キーとして飲んだら true**（他の役割へ回さない）
    func playKeyDown(_ keyCode: UInt16) -> Bool {
        guard playModeOn else { return false }
        if keyCode == KeyPlay.octaveDownKey { keyPlay.shiftOctave(-1); return true }
        if keyCode == KeyPlay.octaveUpKey { keyPlay.shiftOctave(+1); return true }
        guard let note = keyPlay.keyDown(keyCode) else {
            // 二重押下（リピートの取りこぼし等）も演奏キーなら飲む — 素通しさせない
            return KeyPlay.semitoneOffsets[keyCode] != nil
        }
        router.routeKeyboard(0x90, note, 100)
        return true
    }

    func playKeyUp(_ keyCode: UInt16) -> Bool {
        guard playModeOn, let note = keyPlay.keyUp(keyCode) else { return false }
        router.routeKeyboard(0x80, note, 0)
        return true
    }

    /// Keystage のノブ OLED を現在ページの内容で書き直す（`KeystageOled`、
    /// mako 依頼 2026-08-09「LCD の更新できたらお願い」）。
    ///
    /// 材料は ROTO の投影と同じ: 名前 = **別名 > AU の現在名 > 控えた名前 >
    /// 座標名**（`KnobLabel.resolve`）、値 = `ParameterFormat`
    /// （⚠️ `AUParameter.string(fromValue:)` は KORG プラグインで落ちる —
    /// `AssignList` の注意書き参照）。
    /// ⚠️ 値は**この瞬間のスナップショット** — ノブを回している間は追わない
    /// （書くたびに接続の往復が要るので、ページ・楽器・割当の変化だけで書く）
    private func refreshKeystageDisplay(force: Bool = false) {
        let page = activeKnobPage ?? rotoPage
        let slot = rack.selectedSlot
        let faces = KnobPages.page(page).map { cc -> KeystageOled.KnobFace in
            let mapping = slot.knobMappings.first { $0.knob == cc }
            let param = mapping.flatMap { slot.parameter(at: $0.address) }
            let name =
                KnobLabel.resolve(
                    alias: mapping?.alias, live: param?.displayName, remembered: mapping?.name)
                ?? FaceKnobAssignment.ctrlLabel(cc)
            let value = param.map { ParameterFormat.text(value: $0.value, unit: $0.unit) } ?? "-"
            return KeystageOled.KnobFace(name: name, value: value)
        }
        keystage.pushOled(page: page, faces: faces, force: force)
    }

    // 「実機の描き直しを追いかけて書き直す」機構（0.8 秒デバウンス → 2 発撃ち）
    // は 2026-08-10 に撤去した — ⚠️ **勝てない勝負だった**。実測で確定した
    // ファームウェア制約: 0x28 は接続中のみ有効 / 切断の約 1 秒後に実機自身が
    // CCn 表示へ描き直す / 接続しっぱなしは PAGE が死ぬ。追いかけるほど
    // 「点いて消える」のチラつきが増えるだけ（mako「２回表示されて、再度
    // 戻るような状況」）。OLED は既定 off、`=1` なら切替時 1 回のフラッシュ

    /// MIDIRouter の送り先を現在の状態に同期する
    private func updateRouting() {
        let slot = rack.selectedSlot
        // シンセ入力 1（Keystage）: **固定があればその席、無ければ選択に追従**
        // （spec/09 Jack。鍵盤 2 と同じ束縛の形）
        let synth1Slot =
            synthInput1Slot.flatMap { rack.slots.indices.contains($0) ? rack.slots[$0] : nil }
            ?? slot
        router.setKeyboardTarget(synth1Slot.audioUnit as? AVAudioUnitMIDIInstrument)
        router.setDrumsTarget(rack.drumSlot.audioUnit as? AVAudioUnitMIDIInstrument)

        // ROTO の面も塗り直す（選択・ロード・割当の変更はすべてここを通る）
        roto.refresh()
        // Keystage のノブ OLED も同じ内容で（mako 依頼 2026-08-09）
        refreshKeystageDisplay()

        // 鍵盤 2（NCXse）の送り先（②）: **固定があればその席、無ければ選択に追従**。
        // 固定 + 選択の 2 本で「別々の二つの音源同時に弾く」が成立する
        let secondSlot =
            secondKeyboardSlot.flatMap { rack.slots.indices.contains($0) ? rack.slots[$0] : nil }
            ?? slot
        router.setSecondKeyboardTarget(secondSlot.audioUnit as? AVAudioUnitMIDIInstrument)
        // ModWheel 席などの駆動先も**担当スロットの割当**を見る（選択と割れて
        // いても正しい席へ。`drumFaceKnobs` と同じ作法）
        secondFaceKnobs.focus(secondSlot)
        let secondReachable: Set<UInt8> = [64, 74, UInt8(FaceKnobAssignment.modWheelCC)]
        let secondCCs = Set(secondSlot.knobMappings.compactMap { UInt8(exactly: $0.knob) })
            .intersection(secondReachable)
        let secondController = secondFaceKnobs
        router.setSecondKnobRouting(ccs: secondCCs) { [weak self] cc, value in
            DispatchQueue.main.async {
                secondController.handle(knob: Int(cc), value127: Int(value))
                self?.scheduleAutosave()  // [常時保存 25] 鍵盤 2 の顔つまみ
            }
        }

        // 顔つまみ: 割当のある CC だけを横取り対象にし、受け口を main へホップ。
        // focus はピックアップを仕切り直す（切替時のノブ段差吸収）
        faceKnobs.focus(slot)
        let ccs = Set(slot.knobMappings.compactMap { UInt8(exactly: $0.knob) })
        let controller = faceKnobs
        router.setKnobRouting(ccs: ccs) { [weak self] cc, value in
            DispatchQueue.main.async {
                controller.handle(knob: Int(cc), value127: Int(value))
                // [常時保存 11] 顔つまみ = AU パラメータ変更 = fullState が変わる
                // （回し中の連発はデバウンスが畳む）
                self?.scheduleAutosave()
            }
        }

        // LPD8 ノブ → ドラムスロットの顔つまみ（keyboard 側と同じ作法）
        drumFaceKnobs.focus(rack.drumSlot)
        let drumCCs = Set(rack.drumSlot.knobMappings.compactMap { UInt8(exactly: $0.knob) })
        let drumController = drumFaceKnobs
        router.setDrumKnobRouting(ccs: drumCCs) { [weak self] cc, value in
            DispatchQueue.main.async {
                drumController.handle(knob: Int(cc), value127: Int(value))
                self?.scheduleAutosave()  // [常時保存 18] LPD8 顔つまみ
            }
        }
        // LPD8 ノブ → **選択 Track の顔つまみ**（`Lpd8KnobJack.face`。Keystage の
        // ノブ帯の代役 — 位置 i → 現ページの席 i、席は `faceKnobs` と共有なので
        // ピックアップも同じ帳簿）。drums なら空集合 = 上の従来経路だけが効く
        let faceCCs = lpd8KnobJack == .face ? Lpd8FaceKnobs.interceptedCCs(current: lpd8KnobCCs) : []
        let currentKnobCCs = lpd8KnobCCs
        router.setLpd8FaceRouting(ccs: faceCCs) { [weak self] cc, value in
            DispatchQueue.main.async {
                guard let self else { return }
                let page = self.activeKnobPage ?? self.rotoPage
                guard let seat = Lpd8FaceKnobs.seat(forCC: cc, current: currentKnobCCs, page: page)
                else { return }
                controller.handle(knob: seat, value127: Int(value))
                self.scheduleAutosave()  // [常時保存 27] LPD8 → 顔つまみ
            }
        }

        NSLog(
            "routing: keyboard → slot %d (%@), drums → %@, knobs: %d mapped",
            rack.selected + 1,
            slot.displayName ?? "empty",
            rack.drumSlot.displayName ?? "empty",
            slot.knobMappings.count
        )

        // focus pane を選択に追従させる（選択・ロード・入替の全経路がここを通る）
        refreshFocusPane()

        // ROTO の差分焼きも相乗り — 選択・ロード・入替・割当変更の全経路が
        // ここを通る = INST 冊のライブラベルが変わりうる節目そのもの
        scheduleRotoLiveBurn()
    }
}
