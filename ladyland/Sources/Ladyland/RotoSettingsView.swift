//! ROTO Surface（mako 裁定 2026-08-13、面の責務原則）: ROTO の受け方 =
//! **焼き**なので、この面は「接続状態 / 冊の焼き込み / 役割ごとの色」だけ。
//!
//! ROTO は**任意 RGB を受け付けない** — 83 色の固定パレットから index を選ぶ。
//! 色選びは行のチップ（`RotoColorChip` の popover パレット、Track 面と同じ）。
//! トーンマップの常設表示・説明テキスト・割当の補完は 2026-08-13 にオミット
//! （「テキストの説明は、全部オフ」「詳しい設定もオミット」「トーンマップも」）。

import AppKit
import CreoUI
import RotoKit
import SwiftUI

struct RotoSettingsView: View {
    @Environment(\.creoTheme) private var theme
    @EnvironmentObject private var appState: AppState

    /// **淡色セットの決着**（mako 裁定 2026-08-07、実機で 3 案を見比べた上で）。
    ///
    /// > B でまとめつつ、縦に彩度・明るさで分けて、全色振り分けたいね
    ///
    /// A（色相ごとに一番白っぽい 1 色）/ B（パレットの淡色行そのもの）/
    /// C（B に足りない色相を補ったもの）を並べて見せたところ、**B が選ばれた**。
    ///
    /// ⚠️ **C が落ちた理由が設計に効く** — C は「180° シアン・240° 青が空く」
    /// のを他の行から補って 12 色相を揃えていた。mako はそれを採らなかった。
    /// つまり**空きは埋めるべき欠損ではなく、見せるべき事実**だということ。
    /// トーンマップで空きを詰めていないのはこの裁定に従っている。
    ///
    /// 3 案のタブは役目を終えたので落とし、**B の作法（帯をそのまま使う）を
    /// 縦に開いて 83 色すべてを配置する**形にした（`Roto.Color.toneMap`）

    /// MIDI モード setup 書き出しの結果（ボタンの隣に出す）
    @State private var exportResult: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: CreoUITokens.spacingL) {
                header

                // 面の責務原則（mako 合意 2026-08-13）: Page の設計は Track 面、
                // 機材面は「その機材が正典をどう受けるか」だけ。ROTO の受け方 =
                // **焼き**なので、この面は焼きの管理と実機の色だけを持つ。
                // DAW モード時代の遺物（影 / 面の状態 / ページの色 / 死んだ
                // 役割色 4 つ）は 2026-08-13 に整理 — 「効かない設定を並べて
                // おく方が害が大きい」（assigned を外したときと同じ理屈）

                // トーンマップの常設表示は 2026-08-13 にオミット — 色選びは
                // 行のチップ（RotoColorChip の popover パレット、Track 面と同じ）
                GroupBox("役割ごとの色") {
                    VStack(alignment: .leading, spacing: CreoUITokens.spacingS) {
                        ForEach(Roto.Colors.slots.indices, id: \.self) { index in
                            slotRow(index)
                        }
                    }
                    .padding(CreoUITokens.spacingS)
                }

                GroupBox("冊の焼き込み") {
                    VStack(alignment: .leading, spacing: CreoUITokens.spacingS) {
                        HStack {
                            Button("ROTO へ直接焼く（全 \(RotoMidiSetupExport.bookCount) 冊）") {
                                appState.burnRotoSetups()
                            }
                            Button("JSON 書き出し（Import 用）") {
                                exportMidiSetups()
                            }
                            if let result = appState.rotoBurnResult ?? exportResult {
                                Text(result)
                                    .font(.caption)
                                    .foregroundColor(Color.colorTextSecondary)
                            }
                            Spacer()
                        }
                        // 配置説明の Text はオフ（mako 要望 2026-08-13「テキストの
                        // 説明は、全部オフ」）。冊配置の知識は RotoMidiSetupExport の
                        // 冒頭コメントが正典 — SETUP 01/02 = -MIXER / +MIXER（ch2）、
                        // 03/04 = -INST / +INST（ch1、冊名が選択に追従）
                    }
                    .padding(CreoUITokens.spacingS)
                }

                // 「詳しい設定」（割当の補完）は 2026-08-13 にオミット — 割当は
                // Track 面の領分（面の責務原則）。fillMissingAssignments /
                // applySpecLayout は AppState に生きている
            }
            .padding(CreoUITokens.spacingM)
        }
    }

    // 影 / 面の状態 / ページの色は 2026-08-13 の整理で撤去した（DAW モードの
    // 投影計器 — MIDI モード本線では映すものが無い）。実機の状態は焼きの
    // 読み戻し（roto-admin read）と差分焼きの影（roto-shadow.json）が担う

    // 焼き込み（burnRotoSetups）と席名（rotoMixerSlotNames）は AppState へ
    // 移した — UI ボタンと外部トリガー（notifyutil）の共通入口にするため

    /// 書き出し先を選ばせて Export All 互換フォルダを書き、Finder で見せる。
    /// ROTO-SETUP の Import All ダイアログへそのまま渡せる状態で終わる
    private func exportMidiSetups() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "ここに書き出す"
        guard panel.runModal() == .OK, let parent = panel.url else { return }
        do {
            let folder = try RotoMidiSetupExport.write(
                into: parent, slotNames: appState.rotoMixerSlotNames(),
                slotColors: appState.rotoMixerSlotColors())
            exportResult = "\(folder.lastPathComponent) に \(RotoMidiSetupExport.bookCount) 冊書いた"
            NSWorkspace.shared.activateFileViewerSelecting([folder])
        } catch {
            exportResult = "書き出し失敗: \(error.localizedDescription)"
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: CreoUITokens.spacingS) {
            HStack(spacing: CreoUITokens.spacingS) {
                Circle()
                    .fill(appState.roto.connected
                        ? theme.semanticSuccessText : theme.textSecondary)
                    .frame(width: 8, height: 8)
                Text(appState.roto.connected ? "ROTO 接続中" : "ROTO 未接続")
                    .foregroundColor(theme.textSecondary)
            }
        }
    }

    /// 用途 1 行（チップ + 名前）。チップを押すとパレット popover（Track 面と
    /// 同じ RotoColorChip）。クリア = 既定色（darkGreen）へ戻す。
    ///
    /// ⚠️ **MAIN LCD の文字は白で固定**（デバイスが握っていて変えられない）。
    /// **明るい色を選ぶと白地に白文字**になって読めなくなるので、地には
    /// 暗い色を選ぶ必要がある。
    ///
    /// ⚠️ これは**実測で分かった制約**であって好みではない。画面の説明文は
    /// 落としたが（mako 要望 2026-08-07）、**知識としては消してはいけない**
    private func slotRow(_ index: Int) -> some View {
        let slot = Roto.Colors.slots[index]
        return HStack(spacing: CreoUITokens.spacingS) {
            RotoColorChip(
                current: appState.rotoColors[keyPath: slot.keyPath],
                onPick: { picked in
                    appState.rotoColors[keyPath: slot.keyPath] = picked ?? Roto.Color.darkGreen
                },
                size: 16)
            Text(slot.name)
            Spacer()
        }
        .padding(.vertical, 2)
        .padding(.horizontal, CreoUITokens.spacingS)
    }
}
