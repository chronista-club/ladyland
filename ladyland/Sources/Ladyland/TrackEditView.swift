//! Track 面 — **選択中の席そのもの**を編集する（mako 要望 2026-08-12
//! 「Surface に Track surface 追加して、選択中のトラックと連動して、
//! トラックのエディットしたい」）。
//!
//! 機材 3 面（Keystage / LPD8 / ROTO）が「機材から見た席」なのに対し、
//! ここは席の**アイデンティティと出音**: 名前・カラー・ミュート・gain。
//!
//! カラーは ROTO の 83 色パレットから選ぶ（`RotoPaletteMap` — ROTO 設定と
//! 同じ面）。選んだ色はタイルのストライプに出て、ROTO の焼き色にも使う（次段）。
//! 名前は **トラック名 > プラグイン名** の順で表示に使われる（`trackName`）。

import CreoUI
import SwiftUI

struct TrackEditPanel: View {
    @Environment(\.creoTheme) private var theme
    @ObservedObject var slot: InstrumentSlot
    let onColorChanged: (UInt8?) -> Void
    let onNameChanged: (String?) -> Void
    let onMuteToggled: () -> Void
    let onGainChanged: (Float) -> Void
    /// INST マトリクス（席色 = trackCells。AppState.cellColor / setCellColor）
    let cellColor: (Int) -> UInt8
    /// 席の明示色（チップ用 — nil = 未設定の破線）
    let explicitCellColor: (Int) -> UInt8?
    let setCellColor: (Int, UInt8?) -> Void
    let onMappingsChanged: () -> Void
    /// プラグインの Page 既定（mako 要望 2026-08-14 — 配置をプラグイン自体の
    /// default として保存 / ロード。ロードは default があるときだけ活性）
    let hasPageDefault: Bool
    let onSavePageDefault: () -> Void
    let onLoadPageDefault: () -> Void
    /// default 一式の持ち運び（環境のコピー — 書き出し / 読み込み）
    let onExportDefaults: () -> Void
    let onImportDefaults: () -> Void

    /// 入力中の下書き（確定は submit / フォーカス外れ — 1 文字ごとに
    /// 保存 + MIXER 席名が揺れるのを避ける）
    @State private var nameDraft: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: CreoUITokens.spacingM) {
            // ── 名前 + トラックカラー（丸チップ — 押すとパレットが出る）──
            HStack(spacing: CreoUITokens.spacingS) {
                Text("T\(slot.index + 1)")
                    .font(LadylandFont.badgeNumber)
                    .foregroundColor(theme.textSecondary)
                RotoColorChip(
                    current: slot.rotoColor, onPick: { onColorChanged($0) }, size: 16)
                TextField(
                    slot.displayName ?? "トラック名", text: $nameDraft,
                    onCommit: { onNameChanged(nameDraft) }
                )
                .textFieldStyle(.roundedBorder)
                .help("トラック名（空 = プラグイン名。MIXER 冊の席名にも出る）")
            }

            // ── 出音（gain + ミュート）──────────────────────
            HStack(spacing: CreoUITokens.spacingS) {
                Button(action: onMuteToggled) {
                    Image(systemName: slot.mute ? "speaker.slash.fill" : "speaker.wave.2")
                        .foregroundColor(slot.mute ? theme.semanticError : theme.textSecondary)
                }
                .buttonStyle(.borderless)
                .help(slot.mute ? "ミュート解除" : "ミュート（ROTO MIXER 冊のボタンと連動）")

                Slider(
                    value: Binding(
                        get: { slot.gain },
                        set: { onGainChanged($0) }),
                    in: 0...1)

                Text(String(format: "%.0f", slot.gain * 100))
                    .font(LadylandFont.captionNumber)
                    .foregroundColor(theme.textTertiary)
                    .frame(width: 26, alignment: .trailing)
                    .monospacedDigit()
            }

            // ── INST 冊の配置図（mako 要望 2026-08-12「マトリクスがあって、
            // drag & drop で割り当て変更、空いてるマスをクリックして選択」）──
            GroupBox {
                InstMatrix(
                    slot: slot, cellColor: cellColor,
                    explicitCellColor: explicitCellColor,
                    setCellColor: setCellColor,
                    onChanged: onMappingsChanged
                )
                .padding(CreoUITokens.spacingS)
            } label: {
                HStack {
                    Text("INST")
                    Spacer()
                    // Page 既定の保存 / ロード（プラグイン単位。空スロットでは出ない）
                    Menu {
                        if slot.displayName != nil {
                            Button("いまの Page を default に保存", action: onSavePageDefault)
                            Button("default をロード（上書き）", action: onLoadPageDefault)
                                .disabled(!hasPageDefault)
                            Divider()
                        }
                        // 環境のコピー（mako 要望 2026-08-14）— default 一式を
                        // ファイルで持ち運ぶ。読み込みは丸ごと置き換え
                        Button("default 一式を書き出す…", action: onExportDefaults)
                        Button("default 一式を読み込む…", action: onImportDefaults)
                    } label: {
                        Image(systemName: "square.on.square.dashed")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Page 配置をプラグインの default として保存 / ロード / 持ち運び")
                }
            }

            Spacer(minLength: 0)
        }
        .onAppear { nameDraft = slot.customName ?? "" }
    }
}
