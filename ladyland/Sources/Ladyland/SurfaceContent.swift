//! 切り離せる面の中身（Keystage / LPD8 / ROTO / Jack）。
//!
//! サイドバー（ContentView）と別ウィンドウ（PaneWindows）の**両方がここを差す** —
//! 中身の正はここ 1 か所。Track 面は選択に張り付くので ContentView に残る。

import CreoUI
import SwiftUI

struct SurfaceContent: View {
    let pane: PaneID
    @Environment(\.creoTheme) private var theme
    @EnvironmentObject private var appState: AppState

    var body: some View {
        switch pane.surface {
        case .keystage:
            // 面の責務原則（mako 裁定 2026-08-13/14「Keystage surface を
            // 新しく」）: Page の設計は Track 面（InstMatrix + Page 既定）。
            // Keystage 面は**機材の受け方 = 演奏** — ARP / CHORD /
            // テンポ同期 / ボタン焼き。割当パネル（KnobAssignPanel）は
            // ここから退いた（LPD8 タブには残る — あちらは面が 8 ノブで
            // マトリクスが要らない）
            KeystageSettingsView()
        case .lpd8:
            KnobAssignPanel(
                slot: appState.rack.drumSlot,
                surface: .lpd8(knobCCs: appState.lpd8KnobCCs.map(Int.init)),
                onChanged: { appState.knobMappingsChanged() },
                onSetDefault: {
                    appState.rememberDefault(on: appState.rack.drumSlot)
                },
                onLoadDefault: {
                    appState.loadDefault(on: appState.rack.drumSlot)
                },
                hasDefault: appState.rack.drumSlot.defaultSnapshot != nil
            )
            .id(-1)
        case .roto:
            // ⚠️ **ここは割り当ての面ではない**。ROTO の SMART 面が
            // 映すのは**選択中の席の割当**（Keystage タブと同じもの）
            // なので、「ROTO の割り当て」というものは存在しない。
            // 3 つ並ぶと誤解されるので、1 行で言い切っておく
            VStack(alignment: .leading, spacing: CreoUITokens.spacingS) {
                Text(
                    "ROTO **本体**の面（色・パレット・埋め方）。\n"
                    + "SMART 面が映すのは**選択中の席の割り当て**"
                    + "（Keystage タブで編集）。"
                )
                .font(LadylandFont.deskCaption)
                .foregroundColor(theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                RotoSettingsView()
            }
        case .jack:
            // Jack 結線図（spec/09 — 機材 → Jack → Track の見取り図。
            // 演奏前チェック: いま誰がどこ？が一目）
            JackBoardView()
        case .track:
            EmptyView()
        }
    }
}

/// 切り離し中のサイドバー側 — 文字は 1 行、操作は「戻す」だけ
struct DetachedPaneStub: View {
    let pane: PaneID
    @Environment(\.creoTheme) private var theme
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: CreoUITokens.spacingS) {
            Text("別ウィンドウで表示中")
                .font(LadylandFont.deskCaption)
                .foregroundColor(theme.textTertiary)
            HStack(spacing: CreoUITokens.spacingS) {
                Button("前面へ") { appState.panes.open(pane, appState: appState) }
                Button("ここに戻す") { appState.panes.close(pane) }
            }
            .font(LadylandFont.deskCaption)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
