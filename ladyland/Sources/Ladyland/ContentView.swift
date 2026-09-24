//! ミキサー画面（P3: creo-ui の視覚言語に統一）。
//!
//! GUI は制御面の一級市民（design/06 §3）: スロット一覧・選択中・音量を
//! 常時表示する。操作は十字キーだけで「持ち替えて整える」が完結する:
//!   クリック / 数字キー 1-8 = ダイレクト選択
//!   ← → = スロットの順送り / 戻し
//!   ↑ ↓ = 選択中スロットのマスター音量の増減
//!
//! 視覚は creo-ui トークンに統一（Creo エコシステム共通のアイデンティティ）:
//! - 選択中 = brand primary
//! - 選択中なのに空 = semantic warning（弾いても音が出ない事故の視覚警告）
//! - エラー = CreoToast

import AppKit
import CreoUI
import SwiftUI

struct ContentView: View {
    @Environment(\.creoTheme) private var theme
    @EnvironmentObject private var appState: AppState

    /// ↑↓ 一回あたりの音量ステップ
    private let gainStep: Float = 0.05

    /// R Area の状態（mako 裁定 2026-08-01）: sidebar モード時に選択中トラックの
    /// 面（Keystage / LPD8 / ROTO）が常時見える。rail に畳むと細いストリップだけ残る。
    /// 開閉とタブは window.json に永続化（「再起動後も同じ状態にしたい」）
    private var assignSidebarExpanded: Bool {
        get { appState.windowPlacement.assignSidebarExpanded }
        nonmutating set { appState.windowPlacement.assignSidebarExpanded = newValue }
    }

    private var assignTab: SurfaceTab {
        get { appState.windowPlacement.assignTab }
        nonmutating set { appState.windowPlacement.assignTab = newValue }
    }

    /// R Area 下段のログペイン（mako 要望 2026-08-04「デバッグログウィンドウを
    /// R sidebar に常設＋開閉付き＋下付き」）。開閉は window.json に永続化
    private var debugLogExpanded: Bool {
        get { appState.windowPlacement.debugLogExpanded }
        nonmutating set { appState.windowPlacement.debugLogExpanded = newValue }
    }

    /// Main 右列に LPD8（ドラム席）の楽器を並べるか（mako 要望 2026-08-06）
    private var drumPaneExpanded: Bool {
        get { appState.windowPlacement.drumPaneExpanded }
        nonmutating set { appState.windowPlacement.drumPaneExpanded = newValue }
    }

    // タイル並び替え（design/06 §8 追補）: バッジを掴むと Lane 上に
    // Layout Grid Frame が浮かび、リリースでスワップ確定
    @State private var drag: TileDragState?

    /// キーモニタの保持（⚠️ 捨てると多重登録の余地 — 監査 2026-08-09 D-2）
    @State private var keyMonitors: [Any] = []
    /// 着地アニメ中（完了時に swapTiles を確定して offset を即リセット）
    @State private var settle: (source: Int, target: Int)?
    /// 各セル枠の Lane 座標（PreferenceKey で収集。ヒットテストとガイドの基準）
    @State private var tileFrames: [Int: CGRect] = [:]

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                mainArea
                assignArea
            }
            // Editor Mode の overlay（D-6 非侵襲 — Content の layout を変えず
            // 最上段に浮かぶ。OFF で完全不可視 = D-8）
            if appState.editorModeOn {
                EditorOverlay()
            }
        }
        // 右列（470pt）を開くぶん最小幅を広げる — 開いたまま 1280 だと
        // 左列が潰れる。畳めば従来どおり
        .frame(minWidth: drumPaneExpanded ? 1760 : 1280, minHeight: 420)
        // 背景はウィンドウサイズに常に追随させる（mako 裁定 2026-08-01 —
        // フルスクリーン時に上下へ素のウィンドウ背景が見えていた）
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.surfaceBgBase)
        .onAppear {
            appState.start()
            installKeyMonitor()
            // 起動直後は SwiftUI がフィルタ等の TextField へ firstResponder を
            // 渡すことがあり、「編集中は奪わない」ガードが**全キーを飲む**
            // （mako 2026-08-08「機材繋いでないと ⌥←→ が効かない」の正体 —
            // 機材を触ればフォーカスが外れるので機材の有無に見えた）。
            // **誰も打っていない起動時フォーカスだけ**外す。空でない＝
            // 意図した内容が残っている場合とクリックした後は触らない
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                if let text = NSApp.keyWindow?.firstResponder as? NSTextView,
                    text.isEditable, text.string.isEmpty {
                    NSApp.keyWindow?.makeFirstResponder(nil)
                }
            }
        }
    }

    /// R Area（rail ⇄ sidebar）— sidebar モード時に選択中トラックの
    /// 面が現れ、選択に常時追従する（`Surface` の doc — surface / assignment /
    /// mapping の 3 層）

    /// ドラッグ中の幅（**離すまで永続化しない** — 毎フレーム書くと
    /// 1 回のドラッグで数百回のファイル書き込みになる）
    @State private var draggingWidth: CGFloat?

    /// **分割線** — 掴んで R Area の幅を変える（mako 要望 2026-08-06）。
    ///
    /// ドラッグ中は **BPM に合わせて点滅**する。テンポが目に入る場所が
    /// 増えるほど、演奏中に「今どのくらいか」を確かめる手間が減る
    /// **面のタブ**（mako 要望 2026-08-07「FontIcon みたいなところから
    /// アイコン選んで、Surface っぽいのに置き換えできる？」）。
    ///
    /// ⚠️ **`Picker(.segmented)` をやめて自前で組んでいる。**
    /// macOS の segmented control は `Label` を渡しても**アイコンを落として
    /// 文字だけ描く**（実測 2026-08-07: 210pt で `Label` 版と `Text` 版を並べて
    /// 撮り、完全に同一だった）。SwiftUI 側の指定では変えられないので、
    /// アイコンを出すには自前で並べるしかない。
    ///
    /// 選択中は `surfaceBgEmphasis` で塗る — 割当パネルの行選択
    /// （`RotoSettingsView.slotRow`）と**同じ表現**にして、面の中で
    /// 「選ばれているもの」の見え方を 1 つにする
    private var surfaceTabs: some View {
        HStack(spacing: 2) {
            ForEach(SurfaceTab.allCases, id: \.self) { tab in
                let selected = assignTab == tab
                HStack(spacing: 4) {
                    Image(systemName: tab.icon)
                        .font(.system(size: 11))
                        // ⚠️ **アイコンの幅を固定する** — `pianokeys` は横長、
                        // `dial` は正方形なので、素のままだと文字の開始位置が
                        // タブごとにずれて「揃っていない」ように見える
                        .frame(width: 14)
                    Text(tab.title)
                        .font(LadylandFont.deskCaption)
                }
                .foregroundColor(selected ? theme.textPrimary : theme.textSecondary)
                .padding(.vertical, 3)
                .padding(.horizontal, CreoUITokens.spacingS)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(selected ? theme.surfaceBgEmphasis : Color.clear)
                )
                .contentShape(Rectangle())
                .onTapGesture { assignTab = tab }
                .help(tab.title)
            }
        }
    }

    private var splitter: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: draggingWidth == nil)) {
            context in
            Rectangle()
                .fill(splitterColor(at: context.date))
                .frame(width: draggingWidth != nil ? 3 : 1)
                .contentShape(Rectangle().inset(by: -4))  // 掴める幅は見た目より広く
                .onHover { _ in NSCursor.resizeLeftRight.set() }
                .gesture(splitterDrag)
        }
    }

    /// 分割線の色。**掴んでいる間だけ BPM で点滅**する。
    /// BPM が未受信なら 120 とみなす — 点滅を止めるより、掴んでいることが
    /// 分かる方が大事
    private func splitterColor(at date: Date) -> Color {
        // 掴んでいないときは Divider と同じ控えめな線に見せる
        guard draggingWidth != nil else { return Color.colorTextTertiary.opacity(0.3) }
        let bpm = max(appState.clockBPM ?? 120, 1)
        let beat = date.timeIntervalSince1970 / (60.0 / bpm)
        let onBeat = beat - beat.rounded(.down) < 0.5
        return onBeat ? Color.colorBrandPrimary : Color.colorBrandPrimarySubtle
    }

    private var splitterDrag: some Gesture {
        DragGesture(coordinateSpace: .global)
            .onChanged { value in
                // **右へ引くと狭くなる**（R Area は右端にあるので）
                let base = draggingWidth ?? appState.windowPlacement.assignSidebarWidth
                let width = base - value.translation.width
                draggingWidth = min(
                    max(width, WindowPlacementController.minSidebarWidth),
                    WindowPlacementController.maxSidebarWidth)
            }
            .onEnded { _ in
                // **離した瞬間だけ書く**
                if let width = draggingWidth {
                    appState.windowPlacement.assignSidebarWidth = width
                }
                draggingWidth = nil
            }
    }
    @ViewBuilder
    private var assignArea: some View {
        HStack(spacing: 0) {
            if assignSidebarExpanded {
                splitter
            } else {
                Divider()
            }
            if assignSidebarExpanded {
                // **上 = 割り当て（伸びる） / 下 = ログ（畳める）**。
                // ログは常設だが既定は閉じ — 開くと割り当てが狭くなるので
                VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: CreoUITokens.spacingS) {
                    HStack {
                        // **面**（mako 裁定 2026-08-06）。タブが機材名を出して
                        // いるので、見出しで性格を出し分ける必要は無い
                        Text("面")
                            .font(LadylandFont.bodyBold)
                        surfaceTabs
                        // 面を別ウィンドウへ（広い画面で設定する。mako 火花 2026-09-12）
                        if let pane = PaneID(surface: assignTab) {
                            Button { appState.panes.open(pane, appState: appState) } label: {
                                Image(systemName: "macwindow.badge.plus")
                                    .foregroundColor(theme.textSecondary)
                            }
                            .buttonStyle(.borderless)
                            .help("別ウィンドウで開く")
                        }
                        Spacer()
                        // ROTO の SMART ページ（⌥←→ と同じ。ROTO 本体の
                        // ボタンは MIDI を送らないので、繰れるのはここだけ）
                        if appState.roto.connected {
                            HStack(spacing: 2) {
                                Button { appState.roto.stepSmartPage(-1) } label: {
                                    Image(systemName: "chevron.left")
                                }
                                .buttonStyle(.borderless)
                                .disabled(appState.rotoPage == 0)
                                Text("P\(appState.rotoPage + 1)")
                                    .font(LadylandFont.caption)
                                    .monospacedDigit()
                                Button { appState.roto.stepSmartPage(+1) } label: {
                                    Image(systemName: "chevron.right")
                                }
                                .buttonStyle(.borderless)
                                .disabled(appState.rotoPage >= RotoPageLayout.smartPageCount - 1)
                            }
                            .help("ROTO のページを繰る（⌥← / ⌥→、⌥< / ⌥>）")
                        }
                        Button {
                            assignSidebarExpanded = false
                        } label: {
                            Image(systemName: "sidebar.right")
                                .foregroundColor(theme.textSecondary)
                        }
                        .buttonStyle(.borderless)
                        .help("rail に畳む")
                    }
                    switch assignTab {
                    case .keystage, .lpd8, .roto, .jack:
                        // 機材 3 面 + Jack は**切り離せる**（PaneWindows）。中身は
                        // SurfaceContent に 1 か所 — サイドバーと別ウィンドウで同じ View
                        if let pane = PaneID(surface: assignTab) {
                            if appState.panes.isOpen(pane) {
                                DetachedPaneStub(pane: pane)
                            } else {
                                SurfaceContent(pane: pane)
                            }
                        }
                    case .track:
                        // 席そのもの（名前・カラー・ミュート・gain）— 機材 3 面と
                        // 違い、選択中のトラックのアイデンティティを編集する
                        TrackEditPanel(
                            slot: appState.rack.selectedSlot,
                            onColorChanged: {
                                appState.setTrackColor(appState.rack.selectedSlot, to: $0)
                            },
                            onNameChanged: {
                                appState.setTrackName(appState.rack.selectedSlot, to: $0)
                            },
                            onMuteToggled: {
                                appState.toggleMute(appState.rack.selectedSlot)
                            },
                            onGainChanged: {
                                appState.setGain(appState.rack.selectedSlot, to: $0)
                            },
                            cellColor: { appState.instSeatColor($0) },
                            explicitCellColor: { appState.rotoSeatCellColors()[$0] },
                            setCellColor: { appState.setCellColor($0, to: $1) },
                            onMappingsChanged: { appState.knobMappingsChanged() },
                            hasPageDefault: appState.selectedPluginHasPageDefault,
                            onSavePageDefault: { appState.savePluginPageDefault() },
                            onLoadPageDefault: { appState.loadPluginPageDefault() },
                            onExportDefaults: { appState.exportPluginPageDefaults() },
                            onImportDefaults: { appState.importPluginPageDefaults() }
                        )
                        // トラックを移ったら下書き（名前）を仕切り直す
                        .id(appState.rack.selected)
                    }
                }
                .padding(CreoUITokens.spacingM)
                .frame(maxHeight: .infinity, alignment: .top)

                debugLogPane
                }
                // ドラッグ中は仮の幅、離したら永続化された幅
                .frame(width: draggingWidth ?? appState.windowPlacement.assignSidebarWidth)
            } else {
                VStack {
                    Button {
                        assignSidebarExpanded = true
                    } label: {
                        Image(systemName: "sidebar.left")
                            .foregroundColor(theme.textSecondary)
                    }
                    .buttonStyle(.borderless)
                    .help("面を開く（Keystage / LPD8 / ROTO — 選択トラックに追従）")
                    Spacer()
                }
                .padding(.vertical, CreoUITokens.spacingM)
                .frame(width: 28)
            }
        }
    }

    /// R Area 下段のログ — ヘッダをクリックで開閉。
    /// 閉じているときは 1 行の帯だけが残り、**ログが在ることは常に見えている**
    private var debugLogPane: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: CreoUITokens.spacingS) {
                Image(systemName: debugLogExpanded ? "chevron.down" : "chevron.right")
                    .font(LadylandFont.caption)
                    .foregroundColor(theme.textSecondary)
                Text("ログ")
                    .font(LadylandFont.caption)
                Spacer()
            }
            .padding(.horizontal, CreoUITokens.spacingM)
            .padding(.vertical, CreoUITokens.spacingS)
            .contentShape(Rectangle())
            .onTapGesture { debugLogExpanded.toggle() }
            .help(debugLogExpanded ? "ログを畳む" : "ログを開く")

            if debugLogExpanded {
                Divider()
                DebugLogView(log: appState.debugLog, compact: true)
                    .frame(height: 240)
            }
        }
    }

    private var mainArea: some View {
        // ⚠️ **Main を縦分割する**（mako 要望 2026-08-06「左に既存ビュー、
        // 右に LPD8 のビュー（まずはサンプラ）のプラグインを並列で表示したい」）。
        //
        // 本番は**両手で弾く** — 鍵盤（左列の focus pane）と LPD8（右列）。
        // 持ち替えで左は入れ替わるが、**右は居座る**（ドラム席は選択の影響を
        // 受けない = docs/live-setup §3 の「持ち替えの影響を受けない」がそのまま
        // 画面の形になる）
        HStack(spacing: 0) {
            mainColumn
            if drumPaneExpanded {
                Divider()
                drumColumn
            }
        }
    }

    /// Main 右列 — **LPD8（ドラム席）の楽器**。まずはサンプラー。
    ///
    /// ⚠️ 左列の focus pane と**同じ custody 機構で同時に借りる**。
    /// `selectedSlot` は `slots[selected]` でドラム席を含まないので、
    /// 両者が同じ席を取り合うことがない（`AppState.drumPaneView`）
    @ViewBuilder
    private var drumColumn: some View {
        VStack(spacing: CreoUITokens.spacingS) {
            HStack(spacing: CreoUITokens.spacingS) {
                Image(systemName: "circle.grid.2x2.fill")
                    .foregroundColor(theme.brandSecondary)
                Text(appState.rack.drumSlot.displayName ?? "LPD8（空き）")
                    .font(LadylandFont.bodyBold)
                    .foregroundColor(theme.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                // **持ち替えの影響を受けない**ことを画面でも言う
                Text("常駐")
                    .font(LadylandFont.chip)
                    .foregroundColor(theme.textTertiary)
                Button {
                    drumPaneExpanded = false
                } label: {
                    Image(systemName: "sidebar.right")
                }
                .buttonStyle(.borderless)
                .help("右列を畳む（横幅が足りない画面用）")
            }
            .padding(.horizontal, CreoUITokens.spacingS)
            .padding(.top, CreoUITokens.spacingS)

            FocusPaneView(
                slot: appState.rack.drumSlot,
                hosted: appState.drumPaneView,
                editorOnScreen: appState.editors.isOpenOnScreen(appState.rack.drumSlot.index),
                thumbnail: appState.thumbnails.image(for: appState.rack.drumSlot),
                onOpenWindow: { appState.openEditor(for: appState.rack.drumSlot) }
            )
            .frame(maxHeight: .infinity)
        }
        // ⚠️ **サンプラーの画面はここにも埋まっている**（`FocusPaneView(hosted:)`）。
        //
        // **窓は 900pt の横長**（`requestViewController`）だが、この列はそこまで
        // 広げられない — 広げるぶん Main の左列が痩せる。だから
        // **View 側が幅で折り返す**（`LadySamplerView.padGrid`）:
        // 窓では 4 列、ここでは 2 列。⚠️ **並びの順序は同じ**なので、
        // どちらでも左上が pad 1 で、上の行が若い番号になる
        .frame(width: 470)
        .padding(.bottom, 22)  // footer 常駐分の逃げ（左列と揃える）
        .background(theme.surfaceBgBase)
    }

    /// Main 左列 — 既存の三段構え
    @ViewBuilder
    private var mainColumn: some View {
        // 三段構え（mako 裁定 2026-08-02）:
        //   上  ノブストリップ — 手が触れているものが最上段
        //   中  プラグイン表示（縦を最大に取る主役）
        //   下  トラックを**横一列**。focus は常に定位置に居座る
        // 操作ガイド + ユーティリティはウィンドウ下端の footer に常駐
        ZStack(alignment: .bottom) {
            VStack(spacing: CreoUITokens.spacingM) {
                // ── 上: ノブストリップ ──────────────────────────────
                KnobStripView(
                    slot: appState.rack.selectedSlot,
                    page: appState.activeKnobPage,
                    controller: appState.faceKnobs,
                    latchEngaged: appState.latchEngaged,
                    latchSustaining: appState.latchSustaining,
                    pedal: appState.pedalMode,
                    clockBPM: appState.clockBPM,
                    tempoSyncEnabled: appState.tempoSyncEnabled,
                    // 席の明示色（パラメータ色 > 席色）を弧に映し、右クリックで
                    // 付けられる（mako 要望 2026-08-16「アイコンに色をつける動線」）
                    cellColor: { appState.rotoSeatCellColors()[$0] },
                    setCellColor: { appState.setCellColor($0, to: $1) }
                )

                // ── 中: プラグイン表示（残り全部の高さを取る） ────────
                FocusPaneView(
                    slot: appState.rack.selectedSlot,
                    hosted: appState.focusPaneView,
                    editorOnScreen: appState.editors.isOpenOnScreen(appState.rack.selected),
                    thumbnail: appState.thumbnails.image(for: appState.rack.selectedSlot),
                    onOpenWindow: { appState.openEditor(for: appState.rack.selectedSlot) }
                )
                .frame(maxHeight: .infinity)

                // ── 下: トラック横一列 + ドラム（LPD8）────────────────
                trackLane

                if let error = appState.startupError {
                    CreoToast(title: "エラー", description: error, variant: .error) {
                        appState.startupError = nil
                    }
                }
            }
            .padding(.bottom, 22)  // footer 常駐分の逃げ
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // footer — ウィンドウ下端に常駐。キーバインドの説明テキストは
            // 2026-08-13 にオフ（mako「一覧上の説明テキスト、オミット」。
            // 操作の知識: クリック=ロード/選択 1-8=選択 ⌘矢印=カーソル
            // ⌘⏎=draft 昇格 ←→=順送り ↑↓=音量 番号ドラッグ=並び替え Esc=全消音）
            HStack {
                rotoShadowFooter
                Spacer()

                // PC キーボード演奏モード中の常駐表示（Tab で切替。
                // ⚠️ モードが見えないと「キーが効かない」に見える）
                if appState.playModeOn {
                    Label(
                        "演奏モード C\(appState.keyPlay.octave)（Tab 解除 / Z・X オクターブ）",
                        systemImage: "pianokeys")
                        .font(LadylandFont.caption)
                        .foregroundColor(theme.brandPrimary)
                }

                // 出力の誤ルート警告 — Zenith 2 / L6max 以外に出ている時だけ現れる
                // （mako 裁定 2026-08-01。正常時は何も出ない = 静かなのが健康。
                // 「内蔵スピーカーに向いたまま気づかない」事故の再発防止）。
                // ⚠️ **リグ（Keystage / ROTO）が居ないときは黙る**（監査 2026-08-09
                // C-2）— 機材ゼロのデモでは内蔵スピーカーが正常で、常時オレンジは
                // 「正常が警告状態」という嘘になる。ライブ = リグが居る、で判定
                if let output = appState.currentOutputInfo,
                   appState.keystage.connected || appState.roto.connected,
                   !OutputDevice.isExpectedLiveOutput(name: output.name) {
                    Button(action: { appState.openSettings() }) {
                        Label("出力: \(output.name)", systemImage: "speaker.badge.exclamationmark")
                            .font(LadylandFont.caption)
                            .foregroundColor(theme.semanticWarningText)
                    }
                    .buttonStyle(.borderless)
                    .help("Zenith 2 / L6max 以外に出力中 — クリックで設定を開く")
                }

                // **右列（LPD8）の開閉**。畳んだら戻す口がここにしか無いので、
                // footer の常駐ボタンに置く（設定を開かずに戻せること）
                Button {
                    drumPaneExpanded.toggle()
                } label: {
                    Image(systemName: drumPaneExpanded
                        ? "rectangle.righthalf.filled" : "rectangle.righthalf.inset.filled")
                        .foregroundColor(
                            drumPaneExpanded ? theme.brandSecondary : theme.textSecondary)
                }
                .buttonStyle(.borderless)
                .keyboardShortcut("l", modifiers: [.command, .shift])
                .help("LPD8 の楽器を右に並べる（⇧⌘L）")

                // Editor Mode の toggle（D-7: 手動のみ — floating button + ⌘E）
                Button {
                    appState.editorModeOn.toggle()
                } label: {
                    Image(systemName: "slider.horizontal.2.square")
                        .foregroundColor(
                            appState.editorModeOn ? theme.brandPrimary : theme.textSecondary)
                }
                .buttonStyle(.borderless)
                .keyboardShortcut("e", modifiers: .command)
                .help("Editor Mode（⌘E）— 定数を live で触る")

                Button(action: { appState.openDebug() }) {
                    Image(systemName: "ladybug")
                        .foregroundColor(theme.textSecondary)
                }
                .buttonStyle(.borderless)
                .keyboardShortcut("d", modifiers: .command)
                .help("Debug ログ（Cmd+D）")

                Button(action: { appState.openSettings() }) {
                    Image(systemName: "gearshape")
                        .foregroundColor(theme.textSecondary)
                }
                .buttonStyle(.borderless)
                .keyboardShortcut(",", modifiers: .command)
                .help("設定（Cmd+,）")
            }
        }
        .padding(CreoUITokens.spacingL)
        // トラック列は中央のまま R Area の幅変化に追随する
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// ROTO 差分焼きの影の状態 — footer 常駐のリアルタイム表示（mako 要望
    /// 2026-08-13「shadow の状態ってそこにリアルタイム表示できる？」）。
    /// 同期は無彩色で静かに、影なし/ポート待ちだけ警告色（正常時は目立たない）
    @ViewBuilder
    private var rotoShadowFooter: some View {
        Group {
            switch appState.rotoShadowStatus {
            case .unprimed:
                Text("影: なし")
                    .foregroundColor(theme.semanticWarningText)
                    .help("差分焼きは沈黙中 — ROTO Surface の全焼きが再出発点")
            case .synced(let note):
                Text("影: 同期（\(note)）")
                    .foregroundColor(theme.textTertiary)
            case .waiting:
                Text("影: 差分待ち…")
                    .foregroundColor(theme.textSecondary)
            case .burning(let note):
                Text("影: 焼き中（\(note)）")
                    .foregroundColor(theme.brandPrimary)
            case .portBusy:
                Text("影: ポート待ち")
                    .foregroundColor(theme.semanticWarningText)
                    .help("シリアルポートが取れない — ROTO-SETUP が開いていないか確認")
            }
        }
        .font(LadylandFont.caption)
        .monospacedDigit()
    }

    // MARK: - トラックレーン（横一列。mako 裁定 2026-08-02）

    /// **focus の Track が常にここにある**という制約。レーン自身が横に滑り、
    /// focus タイルはこの位置から動かない — 目線を固定できるのがライブで効く。
    /// 端では滑りを止める（左右に空白を作らない）
    private static let focusPin: CGFloat = 0.5  // レーン可視幅に対する比率（中央）

    private var trackLane: some View {
        HStack(alignment: .top, spacing: CreoUITokens.spacingM) {
            GeometryReader { geometry in
                let step = SlotView.width + CreoUITokens.spacingS
                let visible = geometry.size.width
                let total = step * CGFloat(InstrumentRack.trackCount) - CreoUITokens.spacingS
                // focus タイルの左端が pin に来るような並びの offset
                let wanted =
                    visible * Self.focusPin - SlotView.width / 2
                    - CGFloat(appState.rack.selected) * step
                // 端で止める（総幅が可視幅に収まるなら滑らせない）
                let offset = total <= visible ? 0 : min(0, max(visible - total, wanted))

                HStack(spacing: CreoUITokens.spacingS) {
                    ForEach(appState.rack.slots) { slot in
                        // セル（動かない枠）とタイル（浮遊する中身）を分離 —
                        // ガイドとヒットテストの基準はセル、offset はタイルだけ
                        ZStack {
                            tileCellGuide(for: slot.index)
                            SlotView(
                                slot: slot,
                                isSelected: slot.index == appState.rack.selected,
                                catalog: appState.rack.catalog,
                                thumbnail: appState.thumbnails.image(for: slot),
                                onSelect: { appState.select(slot.index) },
                                onLoad: { appState.load($0, into: slot) },
                                onActivateDraft: { appState.activateDraft($0, on: slot) },
                                onOpenEditor: { appState.openEditor(for: slot) },
                                onOpenAssign: {
                                    appState.select(slot.index)
                                    assignSidebarExpanded = true
                                },
                                onToggleMute: { appState.toggleMute(slot) },
                                onDragChanged: { dragChanged(slot.index, $0) },
                                onDragEnded: { dragEnded($0) },
                                compact: true
                            )
                            .scaleEffect(drag?.sourceIndex == slot.index ? 1.04 : 1)
                            .shadow(
                                color: .black.opacity(drag?.sourceIndex == slot.index ? 0.3 : 0),
                                radius: 8, y: 4)
                            .animation(
                                .spring(duration: 0.15),
                                value: drag?.sourceIndex == slot.index)
                            .offset(tileOffset(for: slot.index))
                        }
                        // シンセ入力の固定先バッジ（spec/09 Jack。鍵1 = Keystage、
                        // 鍵2 = NCXse / MiniLab。両方同じ席なら並ぶ）
                        .overlay(alignment: .topTrailing) {
                            HStack(spacing: 2) {
                                if appState.synthInput1Slot == slot.index {
                                    CreoBadge("鍵1", variant: .brand, size: .s, shape: .square)
                                        .help("鍵盤 1（Keystage）はこの席を弾く（右クリックで解除）")
                                }
                                if appState.secondKeyboardSlot == slot.index {
                                    CreoBadge("鍵2", variant: .brand, size: .s, shape: .square)
                                        .help("鍵盤 2（NCXse / MiniLab）はこの席を弾く（右クリックで解除）")
                                }
                            }
                            .padding(4)
                        }
                        .contextMenu {
                            // シンセ入力の固定（spec/09 Jack — 「Keystage は A Track、
                            // MiniLab は B Track」。nil = 選択に追従）
                            if appState.synthInput1Slot == slot.index {
                                Button("鍵盤 1（Keystage）の固定を解除（選択に追従）") {
                                    appState.synthInput1Slot = nil
                                }
                            } else {
                                Button("鍵盤 1（Keystage）をこの席に固定") {
                                    appState.synthInput1Slot = slot.index
                                }
                            }
                            if appState.secondKeyboardSlot == slot.index {
                                Button("鍵盤 2（MiniLab / NCXse）の固定を解除（選択に追従）") {
                                    appState.secondKeyboardSlot = nil
                                }
                            } else {
                                Button("鍵盤 2（MiniLab / NCXse）をこの席に固定") {
                                    appState.secondKeyboardSlot = slot.index
                                }
                            }
                            // 席を空にする（今の姿は draft として棚に残る —
                            // タイルメニューから着せ直せる）
                            if slot.audioUnit != nil {
                                Divider()
                                Button("音源を外す（空にする）", role: .destructive) {
                                    appState.unload(slot)
                                }
                            }
                        }
                        .background(TileFrameReader(index: slot.index))
                        .zIndex(tileZIndex(for: slot.index))
                    }
                }
                .offset(x: offset)
                .animation(.spring(duration: 0.25), value: appState.rack.selected)
                .frame(width: visible, alignment: .leading)
                .clipped()
            }
            .frame(height: SlotView.compactHeight)

            // ドラム（LPD8）は滑らない — 持ち替えから独立という性格を
            // 位置でも表す（design/06 §3）
            DrumSlotView(
                slot: appState.rack.drumSlot,
                catalog: appState.rack.catalog,
                thumbnail: appState.thumbnails.image(for: appState.rack.drumSlot),
                onLoad: { appState.load($0, into: appState.rack.drumSlot) },
                onActivateDraft: { appState.activateDraft($0, on: appState.rack.drumSlot) },
                onOpenEditor: { appState.openEditor(for: appState.rack.drumSlot) }
            )
        }
        .coordinateSpace(name: "lane")
        .onPreferenceChange(TileFramesKey.self) { tileFrames = $0 }
    }

    // MARK: - タイル並び替え（design/06 §8 追補）

    /// ホバー中の着地先セル（ドラッグ中のみ）
    private var hoveredTarget: Int? {
        guard let drag else { return nil }
        return TileDragMath.target(frames: tileFrames, point: drag.location)
    }

    /// Layout Grid Frame — ドラッグ中だけ浮かぶセルの枠ガイド。
    /// ホバー先 = brand primary の実線 + subtle 塗り（着地予告）、
    /// 掴んだ元 = 減光した破線、他のセル = 破線
    @ViewBuilder
    private func tileCellGuide(for index: Int) -> some View {
        if let drag {
            let isTarget = index == hoveredTarget && index != drag.sourceIndex
            RoundedRectangle(cornerRadius: CreoUITokens.radiusM)
                .fill(isTarget ? theme.brandPrimarySubtle : Color.clear)
                .overlay(
                    RoundedRectangle(cornerRadius: CreoUITokens.radiusM)
                        .strokeBorder(
                            isTarget
                                ? theme.brandPrimary
                                : theme.surfaceBorderSubtle.opacity(
                                    index == drag.sourceIndex ? 0.5 : 1),
                            style: StrokeStyle(
                                lineWidth: isTarget ? 2 : 1, dash: isTarget ? [] : [4])
                        )
                )
        }
    }

    /// タイルの浮遊 offset: ドラッグ中はポインタ追従、着地アニメ中は
    /// 双方が相手セルへ滑る
    private func tileOffset(for index: Int) -> CGSize {
        if let drag, drag.sourceIndex == index {
            return drag.translation
        }
        if let settle,
           let sourceFrame = tileFrames[settle.source],
           let targetFrame = tileFrames[settle.target] {
            if settle.source == index {
                return TileDragMath.settleOffset(source: sourceFrame, target: targetFrame)
            }
            if settle.target == index {
                return TileDragMath.settleOffset(source: targetFrame, target: sourceFrame)
            }
        }
        return .zero
    }

    /// ドラッグ中 / 着地中のタイルは隣のタイルの上に浮かせる
    private func tileZIndex(for index: Int) -> Double {
        (drag?.sourceIndex == index || settle?.source == index) ? 10 : 0
    }

    /// ドラッグ / 着地中のタイルがいる行（バンク）を他の行より上に
    private func rowZIndex(for bank: Int) -> Double {
        let range = (bank * InstrumentRack.visibleCount)..<((bank + 1) * InstrumentRack.visibleCount)
        if let source = drag?.sourceIndex ?? settle?.source, range.contains(source) {
            return 10
        }
        return 0
    }

    private func dragChanged(_ index: Int, _ value: DragGesture.Value) {
        guard settle == nil else { return }  // 着地アニメ中は新規ドラッグを受けない
        drag = TileDragState(
            sourceIndex: index, translation: value.translation, location: value.location)
    }

    private func dragEnded(_ value: DragGesture.Value) {
        guard let drag else { return }
        let source = drag.sourceIndex
        let target = TileDragMath.target(frames: tileFrames, point: value.location)
        if let target, target != source {
            // 着地: 双方のタイルを相手のセルへ滑らせ、完了と同時に中身を交換して
            // offset を 0 へ即時リセット — 画面上は同じ絵なので繋ぎ目が見えない
            withAnimation(.spring(duration: 0.25), completionCriteria: .logicallyComplete) {
                settle = (source: source, target: target)
                self.drag = nil
            } completion: {
                appState.swapTiles(source, target)
                settle = nil
            }
        } else {
            // 枠外 or 元のセルでリリース: 元位置へ戻すだけ（スワップなし）
            withAnimation(.spring(duration: 0.25)) {
                self.drag = nil
            }
        }
    }

    /// ウィンドウ全体のキーモニタを登録する。
    ///
    /// フォーカス（firstResponder）に依存しない — ライブ運用では
    /// メニュー操作やクリックの後でも数字/方向キーが常に効く必要がある。
    /// 旧実装（背面 NSView の firstResponder 方式）は Menu 操作で
    /// フォーカスを失いキーが死ぬ問題があった。
    private func installKeyMonitor() {
        // ⚠️ **多重登録ガード**（監査 2026-08-09 D-2）— 戻り値を保持せず捨てて
        // いたので、View が作り直されると監視が重なる余地があった。演奏モード
        // のような状態持ちの処理を足すと二重発音になるので、ここで塞ぐ
        guard keyMonitors.isEmpty else { return }
        if let down = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { event in
            handleKey(event) ? nil : event
        }) { keyMonitors.append(down) }
        // keyUp は演奏モードの Note Off 専用（他の役割は keyDown で完結）
        if let up = NSEvent.addLocalMonitorForEvents(matching: .keyUp, handler: { event in
            appState.playKeyUp(event.keyCode) ? nil : event
        }) { keyMonitors.append(up) }
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        // ⌥ のページ送りキーだけは**どのウィンドウが key でも通す**
        // （mako 2026-08-08「機材繋いでないと効かない」— 実際は機材ではなく、
        // Debug/設定ウィンドウが key の間このガードが全キーを返していた）。
        // テキスト編集中はすぐ下の NSTextView ガードが守るので奪い過ぎない
        let isPageStepKey =
            event.modifierFlags.contains(.option)
            && [123, 124, 43, 47].contains(Int(event.keyCode))
        // 設定/Debug ウィンドウが key の間は飲まない — TextField 等の通常入力を
        // 壊さないため（ミキサーが key の時のライブ挙動は従来どおり）
        if appState.settings.isKeyWindow || appState.debugWindow.isKeyWindow
            || appState.panes.isAnyKeyWindow,
            !isPageStepKey { return false }
        // **テキスト入力中は一切奪わない**（2026-08-04）。
        // 別ウィンドウは上で除いていたが、メインウィンドウ内の
        // 別名の編集・ログのフィルタは素通しで、数字キーがスロット選択に、
        // ⌥←→ が ROTO のページ送りに食われていた
        // ⚠️ **編集できるものだけ**除外する（2026-08-04 の修正が広すぎた）。
        // `.textSelection(.enabled)` を付けた Text も NSTextView になるので、
        // ログの行を一度クリックしただけで ⌥←→ が死んでいた
        if let text = NSApp.keyWindow?.firstResponder as? NSTextView, text.isEditable {
            return false
        }
        // Esc = パニック（全消音）。**ライブの最後の砦** — 音が残ったら
        // 何をおいてもまず止められる手段が要る。修飾キー無しで即座に効かせる
        if event.keyCode == 53 {
            appState.panic()
            return true
        }
        // Tab = PC キーボード演奏モード切替（mako 依頼 2026-08-09 — 機材ゼロで
        // 起動して音を出す。cortex の Tab と同じ）。⚠️ 修飾付きは OS のもの。
        // フォーカス移動は失うが、ContentView に FocusState は 1 つも無い
        if event.keyCode == 48,
            event.modifierFlags.intersection([.command, .option, .control]).isEmpty
        {
            appState.togglePlayMode()
            return true
        }
        // 演奏モード中の音符キー（A 行 = 白鍵 / W 行 = 黒鍵 / Z・X = オクターブ）。
        // ⚠️ **リピートは捨てる** — 押しっぱなしが数十発の Note On になる
        // （cortex が `key_event.repeat` で潰していた罠）。音符キーのリピートは
        // 「飲んで何もしない」— 他の役割へも回さない。
        // ⚠️ 数字 1-8（トラック選択）・矢印・Esc はこの下で今までどおり生きる
        if appState.playModeOn,
            event.modifierFlags.intersection([.command, .option, .control]).isEmpty
        {
            if event.isARepeat {
                if KeyPlay.semitoneOffsets[event.keyCode] != nil
                    || event.keyCode == KeyPlay.octaveDownKey
                    || event.keyCode == KeyPlay.octaveUpKey
                {
                    return true
                }
            } else if appState.playKeyDown(event.keyCode) {
                return true
            }
        }
        // Cmd+矢印 = 選択カーソルの 2D 移動（←→ = ±1、↑↓ = 行ジャンプ ±8。
        // 全体ラップ。mako 裁定 2026-08-01「1 画面内で完結」）
        if event.modifierFlags.contains(.command) {
            switch event.keyCode {
            case 123: appState.selectOffset(-1); return true
            case 124: appState.selectOffset(+1); return true
            case 126: appState.selectOffset(-InstrumentRack.visibleCount); return true
            case 125: appState.selectOffset(+InstrumentRack.visibleCount); return true
            case 36:  // Cmd+Return = アクティブ draft を空きトラックへ昇格
                appState.promoteDraft()
                return true
            default: break
            }
        }
        // ⌥← / ⌥→ と ⌥, / ⌥. = ROTO の SMART ページを繰る（mako 2026-08-04、
        // < > キーは mako 2026-08-08「opt+</> で Page 切り替えを動かそう」—
        // 画面の ‹ › ボタンと同じ刻印で覚えられる）。
        // **ROTO のボタンからは繰れない** — ← → / SEL / MODE は MIDI を
        // 一切送っていないことがログで確定した（ch16 は 1 通も来ない）。
        // 繰れるのはここと画面のボタンだけ
        if event.modifierFlags.contains(.option) {
            switch event.keyCode {
            case 123, 43: appState.roto.stepSmartPage(-1); return true  // ← / ,(<)
            case 124, 47: appState.roto.stepSmartPage(+1); return true  // → / .(>)
            default: break
            }
        }
        // 数字キー 1-8 = アクティブバンク（選択のいる行）の列を選択 — LED と同じ対応
        if let chars = event.charactersIgnoringModifiers,
           let digit = Int(chars), (1...InstrumentRack.visibleCount).contains(digit) {
            appState.select(appState.rack.bankStart + digit - 1)
            return true
        }
        switch event.keyCode {
        case 123: // ← 戻し
            appState.selectPrevious()
            return true
        case 124: // → 順送り
            appState.selectNext()
            return true
        case 126: // ↑ 選択中スロットの音量アップ
            appState.adjustSelectedGain(+gainStep)
            return true
        case 125: // ↓ 選択中スロットの音量ダウン
            appState.adjustSelectedGain(-gainStep)
            return true
        default:
            return false
        }
    }
}

/// セル枠の Lane 座標を PreferenceKey へ流す。offset の影響を受けない
/// ZStack セル側に付ける — ガイドとヒットテストの基準は動かないセル
private struct TileFrameReader: View {
    let index: Int

    var body: some View {
        GeometryReader { geo in
            Color.clear.preference(
                key: TileFramesKey.self,
                value: [index: geo.frame(in: .named("lane"))]
            )
        }
    }
}

private struct TileFramesKey: PreferenceKey {
    static let defaultValue: [Int: CGRect] = [:]
    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// 楽器スロットのタイル
///
/// 状態と色の対応（creo-ui セマンティック）:
/// - 選択中 + ロード済み = brand primary（いま鳴る楽器）
/// - 選択中 + 空 = **semantic warning**（弾いても音が出ない — ライブ事故の視覚警告)
/// - 非選択 = surface
struct SlotView: View {
    @Environment(\.creoTheme) private var theme
    @ObservedObject var slot: InstrumentSlot
    let isSelected: Bool
    let catalog: [InstrumentComponent]
    let thumbnail: NSImage?
    let onSelect: () -> Void
    let onLoad: (InstrumentComponent) -> Void
    let onActivateDraft: (Draft) -> Void
    let onOpenEditor: () -> Void
    let onOpenAssign: () -> Void
    let onToggleMute: () -> Void
    let onDragChanged: (DragGesture.Value) -> Void
    let onDragEnded: (DragGesture.Value) -> Void

    /// focus pane レイアウト用の圧縮表示 — 全 24 トラック表示を守ったまま
    /// 画面中央にプラグイン view の場所を空ける（mako 裁定 2026-08-01）。
    /// 圧縮時はエディタ/割当ボタンを畳む（エディタは focus pane、割当は
    /// R Area から届く — タイル上の複製を削る）
    var compact = false

    /// billboard（規則的に並ぶタイルの面 — mako 命名 2026-08-01）の 1 枚。
    /// 幅はフルスクリーン 13" に 8 列 + ドラム列 + R Area が収まる上限から逆算
    /// （48 padding + 11 アクセント + 8W + 56 + 18 + W + 357 ≤ 1470 → W ≤ 108）
    static let width: CGFloat = 104
    static let compactHeight: CGFloat = 104
    /// 顔（サムネ）— 右にメーターを並べた残り幅（104 - 12 padding - 4 - 16）
    static let thumbSize = CGSize(width: 72, height: 42)

    private var isEmptySelected: Bool { isSelected && slot.audioUnit == nil }

    private var fillColor: Color {
        if isEmptySelected { return theme.semanticWarningSubtle }
        if isSelected { return theme.brandPrimarySubtle }
        return theme.surfaceSurface
    }

    private var borderColor: Color {
        if isEmptySelected { return theme.semanticWarning }
        if isSelected { return theme.brandPrimary }
        return theme.surfaceBorderSubtle
    }

    var body: some View {
        VStack(spacing: 4) {
            // ヘッダ = ドラッグハンドル + 番号 + 音量値。
            // 番号バッジだけが掴める（クリック選択・サムネタップ・メニューとの
            // 誤発を構造で防ぐ。design/06 §8 追補）。単クリックは
            // minimumDistance 未満なのでタイルの選択タップに抜ける
            HStack(spacing: 3) {
                HStack(spacing: 3) {
                    Image(systemName: "line.3.horizontal")
                        .font(LadylandFont.caption)
                        .foregroundColor(theme.textTertiary)
                    Text("\(slot.index + 1)")
                        .font(LadylandFont.badgeNumber)
                        .foregroundColor(
                            isSelected ? theme.textPrimary : theme.textSecondary)
                }
                .contentShape(Rectangle())
                .onHover { hovering in
                    if hovering { NSCursor.openHand.push() } else { NSCursor.pop() }
                }
                .gesture(
                    DragGesture(minimumDistance: 2, coordinateSpace: .named("lane"))
                        .onChanged(onDragChanged)
                        .onEnded(onDragEnded)
                )

                Spacer(minLength: 0)

                // 音量値はヘッダ右へ（旧: バー直下）— カードの縦を詰める。
                // クリックでミュート（主は ROTO MIXER 冊のボタン — こちらで
                // 切って実機トグルとズレても、ボタン 1 押しで再び一致する）
                if slot.audioUnit != nil {
                    Button(action: onToggleMute) {
                        if slot.mute {
                            Image(systemName: "speaker.slash.fill")
                                .font(LadylandFont.caption)
                                .foregroundColor(theme.semanticError)
                        } else {
                            Text(String(format: "%.0f", slot.gain * 100))
                                .font(LadylandFont.captionNumber)
                                .foregroundColor(theme.textTertiary)
                        }
                    }
                    .buttonStyle(.plain)
                    .help(slot.mute ? "ミュート解除" : "ミュート")
                }
            }

            CatalogMenu(
                current: slot.displayName, drafts: slot.drafts, catalog: catalog,
                onLoad: onLoad, onActivateDraft: onActivateDraft)

            // 顔（サムネ）とメーターを横に並べる（mako 裁定 2026-08-01
            // 「メータをアイコンの右に持ってこよう」— 縦長のカードを詰める）
            HStack(spacing: 4) {
                PluginThumb(
                    image: thumbnail, level: slot.level, isLoaded: slot.audioUnit != nil,
                    seed: Double(slot.index) * 1.7, onOpen: onOpenEditor,
                    size: Self.thumbSize)

                if isEmptySelected {
                    // 音が出ない状態の明示（P1 実機で踏んだ事故の再発防止）
                    Label("無音", systemImage: "exclamationmark.triangle.fill")
                        .font(LadylandFont.caption)
                        .foregroundColor(theme.semanticWarningText)
                        .labelStyle(.titleAndIcon)
                        .frame(maxWidth: .infinity)
                } else {
                    GainBar(
                        gain: slot.gain, isSelected: isSelected,
                        height: Self.thumbSize.height)
                    LevelBar(level: slot.level, height: Self.thumbSize.height)
                }
            }

            if !compact, slot.audioUnit != nil {
                HStack(spacing: CreoUITokens.spacingS) {
                    // 音色を作る場所 = プラグイン自身の画面（design/06 §2）
                    Button(action: onOpenEditor) {
                        Image(systemName: "slider.horizontal.3")
                            .font(LadylandFont.caption)
                            .foregroundColor(theme.textSecondary)
                    }
                    .buttonStyle(.borderless)
                    .help("プラグイン画面を開く")

                    // ⚠️ **サンプラーだけは空のままだと絶対に鳴らない**
                    // （mako 2026-08-06「音を割り当てる動線がないね」）。
                    // 他のプラグインは画面を開かなくても音が出るので
                    // `slider.horizontal.3` で足りるが、これは**割り当てに
                    // 辿り着けないと無音のまま**なので、専用の口を出す
                    if slot.displayName == LadySampler.displayName {
                        Button(action: onOpenEditor) {
                            Image(systemName: "waveform.badge.plus")
                                .font(LadylandFont.caption)
                                .foregroundColor(theme.brandPrimary)
                        }
                        .buttonStyle(.borderless)
                        .help("8 パッドに音を割り当てる")
                    }

                    // 顔つまみ割当 — 選択して R Area の割当サイドバーを開く
                    // （旧ポップオーバーは 2026-08-01 の常設化で廃止）
                    Button(action: onOpenAssign) {
                        Image(systemName: "dial.medium")
                            .font(LadylandFont.caption)
                            .foregroundColor(
                                slot.knobMappings.isEmpty
                                    ? theme.textSecondary : theme.brandPrimary)
                    }
                    .buttonStyle(.borderless)
                    .help("面を開く（R Area）")
                }
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .frame(width: SlotView.width, height: compact ? SlotView.compactHeight : 132)
        .background(RoundedRectangle(cornerRadius: CreoUITokens.radiusM).fill(fillColor))
        .overlay(
            RoundedRectangle(cornerRadius: CreoUITokens.radiusM)
                .stroke(borderColor, lineWidth: isSelected ? 2 : 1)
        )
        // トラックカラーのストライプ（Track 面で設定。未設定なら出さない —
        // 枠や地は選択状態が使っているので、左端の細い帯だけを色に貸す）
        .overlay(alignment: .leading) {
            if let color = slot.rotoColor {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(RotoPaletteMap.color(color))
                    .frame(width: 3)
                    .padding(.vertical, 8)
                    .padding(.leading, 1.5)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
    }
}

/// プラグイン画面のサムネ（design/06 §8 追補 — プラグイン UI はそれ自体が「顔」）。
/// エディタを開いた時に自動で撮られ、再起動後も残る。クリックでエディタを開く。
/// サムネが無い（未撮影 / Metal 系で撮れない）ロード済みスロットは
/// 磁性流体プレースホルダ — 液中の流体が音で緩やかに反応する生きた顔
struct PluginThumb: View {
    @Environment(\.creoTheme) private var theme
    let image: NSImage?
    let level: Float
    let isLoaded: Bool
    let seed: Double
    let onOpen: () -> Void
    var size = CGSize(width: 88, height: 50)

    var body: some View {
        if let image {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: size.width, height: size.height)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(theme.surfaceBorderSubtle, lineWidth: 1)
                )
                .onTapGesture(perform: onOpen)
                .help("プラグイン画面を開く")
        } else if isLoaded {
            FerrofluidThumb(level: level, seed: seed)
                .frame(width: size.width, height: size.height)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(theme.surfaceBorderSubtle, lineWidth: 1)
                )
                .onTapGesture(perform: onOpen)
                .help("プラグイン画面を開く（開くとサムネ撮影を試みる）")
        } else {
            // 空スロット — 顔の場所を確保して行の高さを揃える
            RoundedRectangle(cornerRadius: 4)
                .fill(theme.surfaceBgBase.opacity(0.4))
                .frame(width: size.width, height: size.height)
        }
    }
}

/// AU カタログのプルダウン（メーカー別サブメニュー + この席の棚 = Drafts）
struct CatalogMenu: View {
    @Environment(\.creoTheme) private var theme
    let current: String?
    var drafts: [Draft] = []
    let catalog: [InstrumentComponent]
    let onLoad: (InstrumentComponent) -> Void
    var onActivateDraft: (Draft) -> Void = { _ in }

    private var byManufacturer: [(String, [InstrumentComponent])] {
        Dictionary(grouping: catalog, by: \.manufacturer)
            .sorted { $0.key < $1.key }
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    var body: some View {
        Menu {
            // 棚（新しい順）— 選ぶと着替える。今の姿は暗黙で棚に入るので無損失
            if !drafts.isEmpty {
                Section("Drafts") {
                    ForEach(drafts.reversed()) { draft in
                        Button("\(draft.name)  \(Self.timeFormatter.string(from: draft.savedAt))") {
                            onActivateDraft(draft)
                        }
                    }
                }
                Divider()
            }
            ForEach(byManufacturer, id: \.0) { manufacturer, components in
                Menu(manufacturer) {
                    ForEach(components) { component in
                        Button(component.name) { onLoad(component) }
                    }
                }
            }
        } label: {
            Text(current ?? "(empty)")
                .font(LadylandFont.body)
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundColor(current == nil ? theme.textTertiary : theme.textPrimary)
        }
        .menuStyle(.borderlessButton)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// スロット音量の縦フェーダー表示（設定値）
struct GainBar: View {
    @Environment(\.creoTheme) private var theme
    let gain: Float
    let isSelected: Bool
    var height: CGFloat = 44

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(theme.levelTrack)
                RoundedRectangle(cornerRadius: 2)
                    .fill(isSelected ? theme.live : theme.standby)
                    .frame(height: geo.size.height * CGFloat(gain))
            }
        }
        .frame(width: 8, height: height)
    }
}

/// リアルタイム出力レベルメーター
///
/// 色は AV semantic（緑=safe / 黄=hot / 赤=clip）。選択中でないスロットの
/// 余韻（切替後のリリース）も見える — ミキサーの実像がそのまま画面にある
struct LevelBar: View {
    @Environment(\.creoTheme) private var theme
    let level: Float
    var height: CGFloat = 44

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(theme.levelTrack)
                RoundedRectangle(cornerRadius: 2)
                    .fill(theme.levelColor(for: level))
                    .frame(height: geo.size.height * CGFloat(min(level, 1.0)))
            }
        }
        .frame(width: 4, height: height)
        .animation(.linear(duration: 0.05), value: level)
    }
}

/// ドラムスロットのタイル — LPD8 の打面。Keystage の持ち替えから独立（design/06 §3）
struct DrumSlotView: View {
    @Environment(\.creoTheme) private var theme
    @ObservedObject var slot: InstrumentSlot
    let catalog: [InstrumentComponent]
    let thumbnail: NSImage?
    let onLoad: (InstrumentComponent) -> Void
    var onActivateDraft: (Draft) -> Void = { _ in }
    let onOpenEditor: () -> Void

    var body: some View {
        // 楽器タイルと同じ骨格（ヘッダ / 名前 / 顔 + メーター）で高さを揃える
        VStack(spacing: 4) {
            HStack(spacing: 3) {
                Image(systemName: "circle.grid.2x2")
                    .font(LadylandFont.body)
                    .foregroundColor(theme.brandSecondary)
                Spacer(minLength: 0)
                Text("LPD8")
                    .font(LadylandFont.caption)
                    .foregroundColor(theme.textTertiary)
            }

            CatalogMenu(
                current: slot.displayName, drafts: slot.drafts, catalog: catalog,
                onLoad: onLoad, onActivateDraft: onActivateDraft)

            HStack(spacing: 4) {
                PluginThumb(
                    image: thumbnail, level: slot.level, isLoaded: slot.audioUnit != nil,
                    seed: Double(slot.index) * 1.7, onOpen: onOpenEditor,
                    size: SlotView.thumbSize)
                LevelBar(level: slot.level, height: SlotView.thumbSize.height)

                // ⚠️ **ここが本命の動線** — サンプラーはドラムスロットに載せて
                // LPD8 のパッドで叩くもの（mako 要望 2026-08-05）。
                // 割り当てるまで無音なので、タイルから直接開ける
                if slot.displayName == LadySampler.displayName {
                    Button(action: onOpenEditor) {
                        Image(systemName: "waveform.badge.plus")
                            .font(LadylandFont.caption)
                            .foregroundColor(theme.brandPrimary)
                    }
                    .buttonStyle(.borderless)
                    .help("8 パッドに音を割り当てる")
                }
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .frame(width: SlotView.width, height: SlotView.compactHeight)
        .background(
            RoundedRectangle(cornerRadius: CreoUITokens.radiusM)
                .fill(theme.brandSecondarySubtle)
        )
        .overlay(
            RoundedRectangle(cornerRadius: CreoUITokens.radiusM)
                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4]))
                .foregroundColor(theme.brandSecondary.opacity(0.5))
        )
    }
}
