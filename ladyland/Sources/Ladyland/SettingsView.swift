//! 設定ウィンドウの中身（design/06 §8）。
//!
//! ⚠️ **ROTO は L sidebar のタブへ移した**（mako 要望 2026-08-06
//! 「Keystage / LPD8 / ROTO のタブにしよう」）。ここには置かない —
//! 同じものが 2 か所にあると、どちらを直したか分からなくなる
//! （`Colors.assigned` を「効かない設定を並べておく方が害が大きい」で
//! 設定 UI から外した前例と同じ判断）。
//!
//! タブ構成:
//!   オーディオ出力 — 出力デバイスの一覧と切替（PR: audio-output-switch で実装）
//!   LPD8          — LED フィードバック設定とプログラムエディタ（後続 PR で実装）

import CreoUI
import SwiftUI

struct SettingsView: View {
    @Environment(\.creoTheme) private var theme
    @EnvironmentObject private var appState: AppState

    var body: some View {
        TabView {
            AudioOutputSettingsView()
                .tabItem { Label("オーディオ出力", systemImage: "speaker.wave.2") }
            Lpd8SettingsView()
                .tabItem { Label("LPD8", systemImage: "circle.grid.2x2") }
            // Keystage は R sidebar の面へ移した（2026-08-14 — ROTO と同じ道。
            // 冒頭の「同じものが 2 か所にあると分からなくなる」裁定に従いここから撤去）
            KeyScaleSettingsView()
                .tabItem { Label("キー・スケール", systemImage: "music.note") }
            AppearanceSettingsView()
                .tabItem { Label("外観", systemImage: "paintpalette") }
            WindowSettingsView()
                .tabItem { Label("ウィンドウ", systemImage: "macwindow") }
            SnapshotSettingsView()
                .tabItem { Label("スナップショット", systemImage: "square.and.arrow.up.on.square") }
        }
        .padding(CreoUITokens.spacingL)
        .frame(minWidth: 720, minHeight: 560)
        .background(theme.surfaceBgBase)
    }
}

/// オーディオ出力タブ — デバイス一覧から選んで即切替（design/06 §8）
struct AudioOutputSettingsView: View {
    @Environment(\.creoTheme) private var theme
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: CreoUITokens.spacingM) {
            Text("出力デバイス")
                .font(LadylandFont.deskHeading)
                .foregroundColor(theme.textPrimary)

            Picker("出力デバイス", selection: Binding(
                get: { appState.rack.outputDeviceUID ?? "" },
                set: { appState.switchOutput(uid: $0) }
            )) {
                Text("既定（L6max 優先 → OS 既定）").tag("")
                ForEach(appState.outputDevices) { device in
                    Text(device.name).tag(device.uid)
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()

            Text("切替時に音が一瞬途切れます。選択は保存され、次回起動時に再適用（デバイス不在時は既定へフォールバック）。")
                .font(LadylandFont.deskCaption)
                .foregroundColor(theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// 外観タブ — 色の系統と明暗（mako 要望 2026-08-06「画面の UI テーマを作成しよう」）。
///
/// creo-ui の 8 テーマ（4 系統 × light/dark）から選ぶ。選択は `rack.json` に
/// 残り、次回起動で戻る。
///
/// ⚠️ **フォントサイズはここに出さない**。`LadylandFont` の 4 つの役割
/// （stage / desk / chip / log）は**視距離と役割で決まっていて好みではない** —
/// ステージから読めるかどうかは調整で壊せてはいけない。
struct AppearanceSettingsView: View {
    @Environment(\.creoTheme) private var theme
    @ObservedObject private var store = ThemeStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: CreoUITokens.spacingM) {
            Text("色の系統")
                .font(LadylandFont.deskHeading)
                .foregroundColor(theme.textPrimary)

            // **色そのものを見て選ぶ** — 名前で選ぶより速い
            VStack(alignment: .leading, spacing: CreoUITokens.spacingS) {
                ForEach(CreoThemeFamily.allCases, id: \.self) { family in
                    HStack(spacing: CreoUITokens.spacingS) {
                        Image(
                            systemName: store.family == family
                                ? "largecircle.fill.circle" : "circle"
                        )
                        .foregroundColor(
                            store.family == family ? theme.brandPrimary : theme.textTertiary)
                        Text(family.label)
                            .font(LadylandFont.deskBody)
                            .foregroundColor(theme.textPrimary)
                        Spacer(minLength: CreoUITokens.spacingS)
                        ForEach(Array(family.swatch.enumerated()), id: \.offset) { _, color in
                            RoundedRectangle(cornerRadius: 3)
                                .fill(color)
                                .frame(width: 22, height: 14)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { store.family = family }
                }
            }

            Divider()

            Text("明暗")
                .font(LadylandFont.deskHeading)
                .foregroundColor(theme.textPrimary)

            Picker("明暗", selection: Binding(
                get: { store.appearance }, set: { store.appearance = $0 }
            )) {
                ForEach(ThemeAppearance.allCases) { appearance in
                    Text(appearance.label).tag(appearance)
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()

            Text(
                """
                いま切り替わり、次回起動にも引き継がれます（`rack.json` に同居）。
                **既定はダーク** — 客席が暗いので、明るい画面はステージで目が眩みます。
                レベルメーターの色（緑 → 黄 → 赤）も系統に合わせて変わりますが、\
                **何 dB で赤くなるかは変わりません** — それは音の事実で、見た目の好みではないためです。
                """
            )
            .font(LadylandFont.deskCaption)
            .foregroundColor(theme.textTertiary)
            .fixedSize(horizontal: false, vertical: true)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// ウィンドウタブ — 起動時の表示モード（mako 裁定 2026-08-01）。
/// 切替は即座に効き、そのまま次回起動の既定になる
struct WindowSettingsView: View {
    @Environment(\.creoTheme) private var theme
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: CreoUITokens.spacingM) {
            Text("表示モード")
                .font(LadylandFont.deskHeading)
                .foregroundColor(theme.textPrimary)

            Picker("表示モード", selection: Binding(
                get: { appState.windowPlacement.mode },
                set: { appState.windowPlacement.setMode($0) }
            )) {
                Text("フルスクリーン").tag(WindowMode.fullscreen)
                Text("ウィンドウ").tag(WindowMode.windowed)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()

            Text(
                """
                いま切り替わり、次回起動にも引き継がれます（緑ボタン / ⌃⌘F での切替も同じように記憶）。
                ウィンドウモードは画面と位置も覚えます — 覚えた画面が無ければ内蔵ディスプレイ、\
                それも無ければ先頭の画面へフォールバックし、枠が画面外に落ちていたら押し戻します。
                """
            )
            .font(LadylandFont.deskCaption)
            .foregroundColor(theme.textTertiary)
            .fixedSize(horizontal: false, vertical: true)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// LPD8 タブ — LED フィードバック設定 + プログラムエディタ
struct Lpd8SettingsView: View {
    @Environment(\.creoTheme) private var theme
    @EnvironmentObject private var appState: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: CreoUITokens.spacingM) {
                Text("LED フィードバック")
                    .font(LadylandFont.deskHeading)
                    .foregroundColor(theme.textPrimary)

                Toggle("パッド LED フィードバック", isOn: Binding(
                    get: { appState.ledBus.enabled },
                    set: { appState.setLedFeedback($0) }
                ))

                Text("選択スロットの flash と音量連動の輝度をパッドに表示します。オフで即全消灯（ステージの非常口）。LED の上書きは LPD8 を挿し直すと本体設定の色に戻ります。")
                    .font(LadylandFont.deskCaption)
                    .foregroundColor(theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                Divider()

                // ダンパーペダルの役割（mako 裁定 2026-08-03）。
                // ペダルは 1 本しかないのに用途が 2 つある — 曲ごとに選ぶ
                Text("ダンパーペダル")
                    .font(LadylandFont.deskHeading)
                    .foregroundColor(theme.textPrimary)

                Picker("ペダルの役割", selection: Binding(
                    get: { appState.pedalMode },
                    set: { appState.pedalMode = $0 }
                )) {
                    ForEach(PedalMode.allCases, id: \.self) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.radioGroup)

                // 逆極性のペダル対応（mako 報告 2026-08-14「キープが逆」—
                // 踏むと閉じる/開くの 2 種がある。入口で反転するので
                // キープもネイティブ sustain も割当も全部揃う）
                Toggle("極性を反転（踏むと離すが逆のペダル）", isOn: Binding(
                    get: { appState.pedalInverted },
                    set: { appState.pedalInverted = $0 }
                ))
                .toggleStyle(.switch)

                Text(
                    "キープ = 踏んでいる間ノートを保持（両手が空く）。CC64 は楽器へも素通しするのでプラグイン側のサスティンも効きます。\n"
                        + "割当 = CC64 を割当一覧の一級市民にして、ペダルで好きなパラメータを動かします（キープはしません）。未割当ならこれまでどおり楽器へ素通し。"
                )
                .font(LadylandFont.deskCaption)
                .foregroundColor(theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

                Divider()

                Lpd8EditorView(editor: appState.lpd8Editor)
            }
            .padding(.bottom, CreoUITokens.spacingL)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// キー・スケールタブ — LED 基本色の源（ルート = 暖色 / 内 = 淡 / 外 = 消灯）
struct KeyScaleSettingsView: View {
    @Environment(\.creoTheme) private var theme
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: CreoUITokens.spacingM) {
            Text("キー・スケール")
                .font(LadylandFont.deskHeading)
                .foregroundColor(theme.textPrimary)

            HStack(spacing: CreoUITokens.spacingM) {
                Picker("ルート", selection: Binding(
                    get: { appState.keyScale.root },
                    set: { appState.keyScale.root = $0 }
                )) {
                    ForEach(0..<12, id: \.self) { pc in
                        Text(KeyScale.noteNames[pc]).tag(pc)
                    }
                }
                .frame(maxWidth: 120)

                Picker("スケール", selection: Binding(
                    get: { appState.keyScale.scale },
                    set: { appState.keyScale.scale = $0 }
                )) {
                    ForEach(ScaleKind.allCases, id: \.self) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                .frame(maxWidth: 240)
            }

            Text("パッド LED の基本色に反映: ルート音 = オレンジ / スケール内 = 青 / 外 = 消灯。LPD8 をセカンドキーボードとして弾くときの道しるべ。")
                .font(LadylandFont.deskCaption)
                .foregroundColor(theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
