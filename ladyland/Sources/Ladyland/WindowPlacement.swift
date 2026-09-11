//! 起動時のウィンドウ配置（mako 裁定 2026-08-01「フルスクリーンか、
//! ウィンドウモード（スクリーン、位置、フォールバックあり）」）。
//!
//! 従来は内蔵ディスプレイへ問答無用でフルスクリーンだった。これを
//! **モード + 画面 + 位置の記憶**に置き換える。既定は従来どおり
//! 内蔵フルスクリーン（保存が無い = 初回起動は今までと同じ絵）。
//!
//! 保存先を rack.json と分ける理由: rack.json は「セット一式の持ち運び =
//! このファイル 1 個」（docs/live-setup §0）。**ウィンドウ配置はマシン固有**で、
//! 別の Mac へラックを持って行ったときに付いて来てはいけない。加えて
//! rack.json は 10MB 級で、起動直後に配置だけのために復号したくない。
//!
//! 画面が消えている（外部モニタを外した / 解像度が変わった）ときの
//! フォールバックは fail-open（design/05 原則 1）: 保存画面 → 内蔵 → 先頭。
//! 枠が画面外に落ちていたら押し戻す — 「起動したのに窓が見えない」を作らない。

import AppKit

enum WindowMode: String, Codable, CaseIterable {
    case fullscreen
    case windowed
}

/// **サイドバーが見せている面**（mako 裁定 2026-08-06 → `Surface` の doc）。
///
/// ⚠️ **raw 値は `window.json` に保存される**。変えると保存済みの設定が
/// 読めなくなり、画面配置ごと既定へ落ちる（`WindowStore.load` は decode 失敗で
/// ファイルを捨てる）。**追加は安全・削除と改名は危険** — テストで固定してある。
///
/// 面ごとに出るものは違う（Keystage / LPD8 は物理像と割り当て、ROTO は
/// デバイスの設定）。**それは面という枠組みでは自然なこと**なので、
/// 見出しで性格を出し分ける必要は無い — タブが機材名を出している
enum SurfaceTab: String, Codable, CaseIterable {
    // 並び = タブの表示順（mako 裁定 2026-08-14「Track, ROTO, Keystage,
    // LPD8 の順」— 席そのものが先頭、機材があと。Jack（結線図）は末尾）
    case track, roto, keystage, lpd8, jack

    /// タブに出す機材名（Track だけ機材ではなく**選択中の席そのもの**）
    var title: String {
        switch self {
        case .keystage: return "Keystage"
        case .lpd8: return "LPD8"
        case .roto: return "ROTO"
        case .track: return "Track"
        case .jack: return "Jack"
        }
    }

    /// **機材の姿を出すアイコン**（mako 要望 2026-08-07
    /// 「GUI の "面" → FontIcon みたいなところからアイコン選んで」）。
    ///
    /// ⚠️ **文字は消さない。** 機材名は演奏中に**確信を持って選ぶ**ための情報で、
    /// アイコンは**探す速さ**のためのもの — 役割が違うので片方では代わりにならない。
    ///
    /// 選定は実寸 13pt でラスタライズして目視（2026-08-07）:
    ///
    /// | | 選んだもの | なぜ |
    /// |---|---|---|
    /// | Keystage | `pianokeys` | **鍵盤そのもの**。13pt でも黒鍵が判別できる。⚠️ `keyboard` は PC のキーボードで、意味も形も違う（点の集合になって潰れる） |
    /// | LPD8 | `square.grid.3x2.fill` | **8 パッドは 4 列 × 2 段**。SF Symbols に 4x2 は無いので、**横長 2 段**という形が一致する 3x2 を採る。`2x2` は正方形で「パッドの列」に見えず、`4x3` は縦長で向きが違う。⚠️ `circle.grid.2x2` は丸なので**ノブに見えて ROTO と紛れる** |
    /// | ROTO | `dial.medium.fill` | **ノブ**。指針と目盛りが 13pt でも残る。⚠️ `dial.low` / `dial.high` は指針が端を向くので「ある値に設定された状態」に見える。中央なら中立。`circle.dotted` は指針が無く、ノブに見えない |
    /// | Track | `tag.fill` | **名札** — 名前と色を付ける面。機材アイコン 3 つ（形の再現）とは役割が違うので、形ではなく行為（ラベリング）で選ぶ。⚠️ `paintpalette` は色専用に見える（名前・gain も編集する） |
    var icon: String {
        switch self {
        case .keystage: return "pianokeys"
        case .lpd8: return "square.grid.3x2.fill"
        case .roto: return "dial.medium.fill"
        case .track: return "tag.fill"
        // Jack = 結線 — ケーブルの差込口そのもの
        case .jack: return "cable.connector"
        }
    }
}

/// window.json の中身 = **マシン固有の画面状態**（すべて optional 相当の
/// 緩い読み — 壊れていたら既定へ）。「再起動後も同じ状態」（mako 裁定
/// 2026-08-01）の対象は、ウィンドウ配置に加えて R Area の開閉・タブまで
struct WindowPreferences: Codable, Equatable {
    var mode: WindowMode
    /// ウィンドウ枠 [x, y, width, height]（グローバル座標）。nil = 画面いっぱい
    var frame: [Double]?
    /// 最後にいた画面の UUID（CGDisplayCreateUUIDFromDisplayID）
    var screenUUID: String?
    /// R Area が sidebar か rail か（nil = 開いている）
    var assignSidebarExpanded: Bool?
    /// R Area のタブ（nil = Keystage）
    var assignTab: SurfaceTab?
    /// R Area 下部のログペインが開いているか（nil = 閉じている）
    var debugLogExpanded: Bool?
    /// Main を縦分割して LPD8 の楽器を並べるか（mako 要望 2026-08-06）
    var drumPaneExpanded: Bool?

    /// R Area の幅（mako 要望 2026-08-06「R sidebar と Main の表示領域を
    /// ドラッグして、比率を変えて、それを離したときに永続化したい」）
    var assignSidebarWidth: Double?

    /// 切り離した面（ポップアウト）の置き場。キーは `PaneID.rawValue`。
    /// optional なので導入前の window.json もそのまま読める（2026-09-12）
    var panes: [String: PanePlacement]?

    static let `default` = WindowPreferences(mode: .fullscreen, frame: nil, screenUUID: nil)
}

/// **サイドバーから切り離せる面**（mako 火花 2026-09-12「別ウィンドウに分けたい
/// Pane あるんだよな。一枚の広い画面で設定したいやつ。機材の繋げる Editor とか」）。
///
/// Track は選択に張り付く面なので対象外。⚠️ raw 値は `window.json` に入る —
/// `SurfaceTab` と同じく**追加は安全・改名は危険**（テストで固定）
enum PaneID: String, Codable, CaseIterable {
    case jack, keystage, lpd8, roto

    init?(surface: SurfaceTab) {
        switch surface {
        case .jack: self = .jack
        case .keystage: self = .keystage
        case .lpd8: self = .lpd8
        case .roto: self = .roto
        case .track: return nil
        }
    }

    var surface: SurfaceTab {
        switch self {
        case .jack: return .jack
        case .keystage: return .keystage
        case .lpd8: return .lpd8
        case .roto: return .roto
        }
    }

    var title: String { surface.title }

    /// 初回に開くときの寸法（Jack は 3 列の結線図が収まる幅）
    var defaultSize: CGSize {
        switch self {
        case .jack: return CGSize(width: 960, height: 560)
        case .keystage, .lpd8, .roto: return CGSize(width: 720, height: 640)
        }
    }

    var minimumSize: CGSize {
        switch self {
        case .jack: return CGSize(width: 720, height: 400)
        case .keystage, .lpd8, .roto: return CGSize(width: 480, height: 400)
        }
    }
}

/// 切り離した面 1 枚の置き場（主ウィンドウの frame / screenUUID と同じ流儀）
struct PanePlacement: Codable, Equatable {
    var frame: [Double]?
    var screenUUID: String?
    /// 終了時に開いていたか（次回起動で開き直す）
    var open: Bool
}

enum PaneWindowPlacement {
    /// 保存 → 画面の fail-open（保存画面 → 内蔵 → 先頭）→ 枠の押し戻し。
    /// 保存が無ければ面の既定サイズで画面中央
    static func resolve(_ saved: PanePlacement?, pane: PaneID, screens: [ScreenInfo])
        -> WindowLanding?
    {
        guard let screen = WindowPlacement.targetScreen(saved?.screenUUID, screens: screens)
        else { return nil }
        let visible = screen.visibleFrame
        let frame: CGRect
        if let values = saved?.frame, values.count == 4, values[2] > 0, values[3] > 0 {
            frame = fitting(
                CGRect(x: values[0], y: values[1], width: values[2], height: values[3]),
                into: visible, minimum: pane.minimumSize)
        } else {
            let size = pane.defaultSize
            frame = CGRect(
                x: visible.midX - size.width / 2, y: visible.midY - size.height / 2,
                width: size.width, height: size.height)
        }
        return WindowLanding(screenUUID: screen.uuid, frame: frame, fullscreen: false)
    }

    /// `WindowPlacement.fitting` の最小サイズ可変版
    static func fitting(_ frame: CGRect, into visible: CGRect, minimum: CGSize) -> CGRect {
        let size = CGSize(
            width: min(max(frame.width, minimum.width), visible.width),
            height: min(max(frame.height, minimum.height), visible.height))
        let x = min(max(frame.minX, visible.minX), visible.maxX - size.width)
        let y = min(max(frame.minY, visible.minY), visible.maxY - size.height)
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }
}

/// 画面 1 枚の素性（純関数に渡すための値型 — AppKit 非依存でテストできる）
struct ScreenInfo: Equatable {
    let uuid: String
    let isBuiltin: Bool
    let visibleFrame: CGRect
}

/// 着地先（純関数の答え）
struct WindowLanding: Equatable {
    let screenUUID: String
    let frame: CGRect
    let fullscreen: Bool
}

/// 配置の決定 — 純関数（テスト対象）
enum WindowPlacement {
    /// ウィンドウの最小サイズ（ContentView の minWidth/minHeight と対）
    static let minimumSize = CGSize(width: 1280, height: 420)

    /// 保存値 + 現在の画面構成 → 着地先。画面が 1 枚も無ければ nil（fail-open）
    static func resolve(_ prefs: WindowPreferences?, screens: [ScreenInfo]) -> WindowLanding? {
        guard let screen = targetScreen(prefs?.screenUUID, screens: screens) else { return nil }
        let prefs = prefs ?? .default
        guard prefs.mode == .windowed else {
            // フルスクリーンは画面の選択だけが問題 — 枠は画面が決める
            return WindowLanding(
                screenUUID: screen.uuid, frame: screen.visibleFrame, fullscreen: true)
        }
        return WindowLanding(
            screenUUID: screen.uuid,
            frame: fitting(savedFrame(prefs.frame), into: screen.visibleFrame),
            fullscreen: false)
    }

    /// 保存画面 → 内蔵 → 先頭（fail-open の 3 段）
    static func targetScreen(_ uuid: String?, screens: [ScreenInfo]) -> ScreenInfo? {
        if let uuid, let saved = screens.first(where: { $0.uuid == uuid }) { return saved }
        return screens.first(where: \.isBuiltin) ?? screens.first
    }

    private static func savedFrame(_ values: [Double]?) -> CGRect? {
        guard let values, values.count == 4, values[2] > 0, values[3] > 0 else { return nil }
        return CGRect(x: values[0], y: values[1], width: values[2], height: values[3])
    }

    /// 枠を画面に収める。保存が無ければ画面いっぱい（= Air 画面で最大化）。
    /// 画面より大きい / はみ出しているときは縮めて押し戻す —
    /// 外部モニタを外した後に「窓が画面外にいて見えない」を作らないため
    static func fitting(_ frame: CGRect?, into visible: CGRect) -> CGRect {
        guard let frame else { return visible }
        let size = CGSize(
            width: min(max(frame.width, minimumSize.width), visible.width),
            height: min(max(frame.height, minimumSize.height), visible.height))
        let x = min(max(frame.minX, visible.minX), visible.maxX - size.width)
        let y = min(max(frame.minY, visible.minY), visible.maxY - size.height)
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }
}

/// window.json の読み書き（小さいので同期で読む — 起動直後に必要）
enum WindowStore {
    static var url: URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0]
        return base.appendingPathComponent("ladyland/window.json")
    }

    static func load(from source: URL = url) -> WindowPreferences? {
        guard let data = try? Data(contentsOf: source) else { return nil }
        return try? JSONDecoder().decode(WindowPreferences.self, from: data)
    }

    static func save(_ prefs: WindowPreferences, to destination: URL = url) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try encoder.encode(prefs)
        let dir = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try data.write(to: destination, options: .atomic)
    }
}

/// AppKit 側 — 起動時の適用と、以後の追従保存
///
/// **モードは「最後にそうしていた状態」を映す**: 設定 UI で切り替えても、
/// 緑ボタン / Ctrl+Cmd+F で切り替えても同じように記憶される。
@MainActor
final class WindowPlacementController: ObservableObject {
    /// 現在のモード（設定 UI の Picker が読む）
    @Published private(set) var mode: WindowMode

    /// R Area が開いているか（ContentView が読み書き。変更即保存）
    var assignSidebarExpanded: Bool {
        get { prefs.assignSidebarExpanded ?? true }
        set {
            guard newValue != prefs.assignSidebarExpanded else { return }
            objectWillChange.send()
            prefs.assignSidebarExpanded = newValue
            scheduleSave()
        }
    }

    /// R Area のタブ（同上）
    var assignTab: SurfaceTab {
        get { prefs.assignTab ?? .keystage }
        set {
            guard newValue != prefs.assignTab else { return }
            objectWillChange.send()
            prefs.assignTab = newValue
            scheduleSave()
        }
    }

    /// R Area 下部のログペイン（同上）。**既定は閉じ** — 常設だが、
    /// 開いていると割り当てパネルが狭くなるので開くかは都度の判断
    var debugLogExpanded: Bool {
        get { prefs.debugLogExpanded ?? false }
        set {
            guard newValue != prefs.debugLogExpanded else { return }
            objectWillChange.send()
            prefs.debugLogExpanded = newValue
            scheduleSave()
        }
    }

    /// **Main の右列に LPD8（ドラム席）の楽器を並べる**
    /// （mako 要望 2026-08-06「Main の領域を縦分割して、左に既存ビュー。
    /// 右に LPD8 のビュー（まずはサンプラ）のプラグインを並列で表示したい」）。
    ///
    /// 既定は開き。**両手で弾く**（鍵盤 = 左 / LPD8 = 右）のが本番の形なので、
    /// 両方が同時に見えているのが既定であるべき。畳めるのは横幅が足りない
    /// 画面のため（ステージのモニタは選べない）
    var drumPaneExpanded: Bool {
        get { prefs.drumPaneExpanded ?? true }
        set {
            guard newValue != prefs.drumPaneExpanded else { return }
            objectWillChange.send()
            prefs.drumPaneExpanded = newValue
            scheduleSave()
        }
    }

    /// **R Area の幅**（mako 要望 2026-08-06）。
    ///
    /// ⚠️ **離したときだけ保存する** — ドラッグ中は毎フレーム値が変わるので、
    /// そのたびに書くと 1 回のドラッグで数百回のファイル書き込みになる。
    /// ContentView は表示用の `@State` を持ち、**離した瞬間にここへ流す**
    var assignSidebarWidth: CGFloat {
        get { CGFloat(prefs.assignSidebarWidth ?? Self.defaultSidebarWidth) }
        set {
            let clamped = min(max(newValue, Self.minSidebarWidth), Self.maxSidebarWidth)
            guard Double(clamped) != prefs.assignSidebarWidth else { return }
            objectWillChange.send()
            prefs.assignSidebarWidth = Double(clamped)
            scheduleSave()
        }
    }

    /// 既定 356（実装当初の固定値）。狭すぎると割当一覧が読めず、
    /// 広すぎるとトラック列が潰れる
    static let defaultSidebarWidth: Double = 356
    static let minSidebarWidth: CGFloat = 260
    static let maxSidebarWidth: CGFloat = 720

    private var observers: [NSObjectProtocol] = []
    private var saveTask: Task<Void, Never>?
    private var prefs: WindowPreferences

    /// 直近に書いた内容（変化が無ければ書かない — rack 側の dedup と同じ作法）
    private var lastSaved: WindowPreferences?

    /// 直近の書き込み時刻（連続ストリームの間引き判定）
    private var lastSaveAttempt: Date = .distantPast

    /// ウィンドウのタイトル（WindowGroup("ladyland") と対）
    private let windowTitle = "ladyland"

    init() {
        prefs = WindowStore.load() ?? .default
        lastSaved = prefs  // 読んだ直後は書く必要がない
        mode = prefs.mode
    }

    /// 現在の画面構成を値型で拾う（内蔵判定はロケール非依存の
    /// CGDisplayIsBuiltin — 「内蔵Retinaディスプレイ」等の文字列比較はしない）
    static func currentScreens() -> [ScreenInfo] {
        NSScreen.screens.compactMap { screen in
            guard
                let number = screen.deviceDescription[
                    NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            else { return nil }
            let id = CGDirectDisplayID(number.uint32Value)
            return ScreenInfo(
                uuid: Self.uuid(of: id),
                isBuiltin: CGDisplayIsBuiltin(id) != 0,
                visibleFrame: screen.visibleFrame)
        }
    }

    private static func uuid(of id: CGDirectDisplayID) -> String {
        guard let cf = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else {
            // UUID が取れない環境では display ID を代用（同一機なら安定）
            return "display-\(id)"
        }
        return CFUUIDCreateString(nil, cf) as String
    }

    private func screen(for uuid: String) -> NSScreen? {
        NSScreen.screens.first { screen in
            guard
                let number = screen.deviceDescription[
                    NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            else { return false }
            return Self.uuid(of: CGDirectDisplayID(number.uint32Value)) == uuid
        }
    }

    private var mainWindow: NSWindow? {
        NSApp.windows.first { $0.title == windowTitle && $0.isVisible }
    }

    // MARK: - 起動時の適用

    /// 保存された配置を適用する。ウィンドウ生成のタイミング揺れは
    /// リトライで吸収する（didFinishLaunching 同期文脈の toggleFullScreen は
    /// 黙って無視される — 実機で確認済み。design/06 §8）
    func applyAtLaunch(retriesLeft: Int = 10) {
        guard retriesLeft > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            guard let window = self.mainWindow else {
                self.applyAtLaunch(retriesLeft: retriesLeft - 1)
                return
            }
            guard let landing = WindowPlacement.resolve(self.prefs, screens: Self.currentScreens())
            else {
                self.settle(window)  // 画面が拾えなくても追従保存だけは繋ぐ
                return
            }

            if landing.fullscreen {
                // 効いたかを次の周回で検証して再試行（styleMask に .fullScreen が
                // 付けば成功 — 遷移アニメ開始時点で付く）
                if window.styleMask.contains(.fullScreen) {
                    self.settle(window)
                    return
                }
                if let target = self.screen(for: landing.screenUUID), window.screen !== target {
                    window.setFrame(target.visibleFrame, display: true)
                }
                window.toggleFullScreen(nil)
                self.applyAtLaunch(retriesLeft: retriesLeft - 1)
                return
            }

            if window.styleMask.contains(.fullScreen) {
                window.toggleFullScreen(nil)  // 前回フルスクリーンで終わった場合
                self.applyAtLaunch(retriesLeft: retriesLeft - 1)
                return
            }
            window.setFrame(landing.frame, display: true)
            self.settle(window)
        }
    }

    /// 適用が済んだ状態を記録して以後の追従に入る。
    /// **ここで一度書くのが要**: 観測を張るのは自前の setFrame の後なので、
    /// その通知は拾えない — 窓を一度も動かさないまま終了すると
    /// 画面・位置が空のままになる（実機で確認、2026-08-01）
    private func settle(_ window: NSWindow) {
        observe(window)
        capture(window, mode: nil)
    }

    // MARK: - 追従保存

    /// 移動・リサイズ・フルスクリーン切替を拾って記憶する（1 回だけ登録）
    private func observe(_ window: NSWindow) {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        let events: [(Notification.Name, WindowMode?)] = [
            (NSWindow.didMoveNotification, nil),
            (NSWindow.didResizeNotification, nil),
            (NSWindow.didEnterFullScreenNotification, .fullscreen),
            (NSWindow.didExitFullScreenNotification, .windowed),
        ]
        for (name, newMode) in events {
            observers.append(
                center.addObserver(forName: name, object: window, queue: .main) {
                    [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.capture(window, mode: newMode)
                    }
                })
        }
    }

    /// 現在の姿を prefs に取り込み、静止後に書く（ドラッグ中の連続 I/O を畳む）
    private func capture(_ window: NSWindow, mode newMode: WindowMode?) {
        if let newMode {
            prefs.mode = newMode
            mode = newMode
        }
        // フルスクリーン中の frame は画面全体 — ウィンドウ位置として覚えない
        if !window.styleMask.contains(.fullScreen) {
            let frame = window.frame
            prefs.frame = [frame.minX, frame.minY, frame.width, frame.height]
        }
        if let screen = window.screen,
           let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
            as? NSNumber
        {
            prefs.screenUUID = Self.uuid(of: CGDirectDisplayID(number.uint32Value))
        }
        scheduleSave()
    }

    /// 変更があったら、すぐ永続化する（rack 常時保存と同じ leading + trailing。
    /// mako 裁定 2026-08-01「これを変更のたび、永続記憶して」）。
    /// ドラッグ中は didMove が毎フレーム飛ぶので、直近 1 秒以内なら
    /// trailing 予約に畳む — 最終位置は必ず書かれる
    private func scheduleSave() {
        if Date().timeIntervalSince(lastSaveAttempt) >= 1.0 {
            flush()
        } else if saveTask == nil {
            saveTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self else { return }
                self.saveTask = nil
                self.flush()
            }
        }
    }

    /// 今の内容を書き切る（終了時にも呼ぶ — 保留中の trailing 予約が
    /// プロセスの死で消えて「最後の移動だけ覚えていない」を作らないため）
    func flush() {
        lastSaveAttempt = Date()
        guard prefs != lastSaved else { return }
        do {
            try WindowStore.save(prefs)
            lastSaved = prefs
        } catch {
            NSLog("window prefs save failed: %@", String(describing: error))
        }
    }

    // MARK: - 切り離した面

    func panePlacement(_ pane: PaneID) -> PanePlacement? {
        prefs.panes?[pane.rawValue]
    }

    /// 面のウィンドウの姿を取り込む（移動・リサイズ・開閉）。主ウィンドウと同じく
    /// 静止後に書く
    func capturePane(_ pane: PaneID, window: NSWindow, open: Bool) {
        var placement = prefs.panes?[pane.rawValue] ?? PanePlacement(frame: nil, screenUUID: nil, open: open)
        let frame = window.frame
        placement.frame = [frame.minX, frame.minY, frame.width, frame.height]
        if let screen = window.screen,
           let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
            as? NSNumber
        {
            placement.screenUUID = Self.uuid(of: CGDirectDisplayID(number.uint32Value))
        }
        placement.open = open
        setPane(pane, placement)
    }

    func setPaneOpen(_ pane: PaneID, _ open: Bool) {
        var placement = prefs.panes?[pane.rawValue] ?? PanePlacement(frame: nil, screenUUID: nil, open: open)
        placement.open = open
        setPane(pane, placement)
    }

    private func setPane(_ pane: PaneID, _ placement: PanePlacement) {
        var panes = prefs.panes ?? [:]
        guard panes[pane.rawValue] != placement else { return }
        panes[pane.rawValue] = placement
        prefs.panes = panes
        scheduleSave()
    }

    // MARK: - 設定 UI から

    /// モードを切り替えて即座に適用する（次回起動にも効く）
    func setMode(_ newMode: WindowMode) {
        guard newMode != mode else { return }
        mode = newMode
        prefs.mode = newMode
        scheduleSave()
        guard let window = mainWindow else { return }
        let isFullScreen = window.styleMask.contains(.fullScreen)
        if newMode == .fullscreen, !isFullScreen {
            // ウィンドウ位置は既に prefs に入っている（戻るときに使う）
            window.toggleFullScreen(nil)
        } else if newMode == .windowed, isFullScreen {
            window.toggleFullScreen(nil)
        }
    }
}
