//! 色チップ — **押すとパレットがフロートで出る**（mako 要望 2026-08-13
//! 「色アイコンを押した時、floatpanel？…として、これが出てきて、クリック
//! したら変更。ダブルクリックで、変更＆閉じる」）。
//!
//! シングルクリック = 変更して**開いたまま** — 実機の LCD と見比べながら
//! 色を試せる（差分焼きが 1 秒後に反映するライブ探索の作法）。
//! ダブルクリック = 変更して閉じる（決まったときの終止形）。
//!
//! コンテキストメニューではなく popover なのは、macOS の NSMenu に
//! スウォッチグリッドのカスタムビューを置けないため。

import CreoUI
import SwiftUI

struct RotoColorChip: View {
    @Environment(\.creoTheme) private var theme

    /// いまの色（nil = 未設定 — 破線の空チップ）
    let current: UInt8?
    /// 色の変更（nil = 未設定に戻す）
    let onPick: (UInt8?) -> Void
    var size: CGFloat = 22

    @State private var isOpen = false

    var body: some View {
        // チップは**丸**（mako 裁定 2026-08-13「カラーアイコンだけ、Surface
        // タイトルの Tn の隣に、丸にして」）。パレットの swatch（角丸 0 の
        // タイル）とは役割が違う — こちらはトラックの顔
        Group {
            if let current {
                Circle().fill(RotoPaletteMap.color(current))
            } else {
                Circle()
                    .strokeBorder(
                        theme.textTertiary.opacity(0.6),
                        style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
            }
        }
        .frame(width: size, height: size)
        .overlay(Circle().stroke(theme.surfaceBorderSubtle, lineWidth: 0.5))
        .contentShape(Circle())
        .onTapGesture { isOpen = true }
        .help(current.map(RotoPaletteMap.describe) ?? "未設定（クリックでパレット）")
        .popover(isPresented: $isOpen, arrowEdge: .bottom) {
            // パレットだけの顔（mako 要望 2026-08-13「説明よりも x ボタンで
            // close」「右上に clear と close…あとはカラーパレットだけ」）。
            // タブはセンター、右上に clear / close を重ねる
            ZStack(alignment: .topTrailing) {
                RotoPaletteMap(
                    current: current,
                    onPick: { onPick($0) },
                    onPickDouble: {
                        onPick($0)
                        isOpen = false
                    })
                HStack(spacing: CreoUITokens.spacingS) {
                    if current != nil {
                        Button {
                            onPick(nil)
                            isOpen = false
                        } label: {
                            Image(systemName: "square.slash")
                                .foregroundColor(theme.textSecondary)
                        }
                        .help("未設定に戻す")
                    }
                    Button {
                        isOpen = false
                    } label: {
                        Image(systemName: "xmark")
                            .foregroundColor(theme.textSecondary)
                    }
                    .help("閉じる")
                }
                .buttonStyle(.borderless)
            }
            .padding(CreoUITokens.spacingM)
        }
    }
}
