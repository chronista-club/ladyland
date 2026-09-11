//! 83 色パレットの選択面 — **見る面**でありタップで選ぶ面。ROTO 設定と
//! Track 面が**同じ面を共有する**（第 2 の定義を作らない）。
//!
//! ## 配置は 3 つ（mako 裁定 2026-08-13「明度順、色相順、プリセットの
//! 改善カスタム版の３つを残そう」— 探索タブの決着）
//!
//! - **明度順**: L 降順の一本道（「暗い背景選びたい時に」）
//! - **色相順**: H 昇順の虹 + 無彩色は最下部
//! - **プリセット**: 原典の 14 色行構造のまま、**行を白っぽい → 濃い → 暗いの
//!   順に並べ替え**（行末の無彩色が右端の縦に揃う）。既定タブ
//!
//! 探索の経緯: 帯（toneMap の 2 次元面、B 案 2026-08-07）→ 左詰め
//! （2026-08-12）→ タブで見比べ（2026-08-13）→ この 3 つに決着。
//! 帯そのもの（`Roto.Color.toneMap`）は knob のページ色の既定として現役。
//!
//! ⚠️ **列は固定にする**（`.adaptive` を使わない）— 折り返し位置が幅で
//! 変わると並びの意味が崩れる。
//! ⚠️ **角丸は 0**（mako 裁定 2026-08-12）— タイリングの面として隙間なく敷く。

import RotoKit
import SwiftUI

struct RotoPaletteMap: View {
    @Environment(\.creoTheme) private var theme

    /// いま選ばれている色（枠で示す。nil = どれも選ばれていない）
    let current: UInt8?
    let onPick: (UInt8) -> Void
    /// ダブルクリック（変更 **して閉じる** — ポップオーバー時に親が閉じ処理を
    /// 入れる。nil = ダブルクリックに特別な意味なし）。
    /// ⚠️ ダブルの 1 打目でシングルの onPick も走るが、同じ色の変更なので冪等
    var onPickDouble: ((UInt8) -> Void)?

    /// 既定はプリセット（mako 所見 2026-08-13「並び的にみて、一番いい感じ」）
    @State private var layout: Layout = .preset

    /// 並びは使う順（mako 裁定 2026-08-13「プリセット、色相順、明度順に」）
    enum Layout: String, CaseIterable {
        case preset = "プリセット"
        case hueOrder = "色相順"
        case lightness = "明度順"
    }

    /// タイリングなので隙間は 0。14 列 × 20 = 280pt — R Area の既定 356pt に収まる
    static let swatchSize: CGFloat = 20

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // テキストだけなら segmented で問題ない（2026-08-07 に落ちたのは
            // Label/アイコンを渡した場合 — 面タブの経緯）。
            // 左寄せ（mako 裁定 2026-08-13 — 右上はポップオーバーの
            // clear / close ボタンの席。センターは 1 度試して却下）
            Picker("", selection: $layout) {
                ForEach(Layout.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 180)
            .padding(.bottom, 4)

            switch layout {
            case .preset:
                // 原典の行構造 × mako 並び。**無彩色は行から抜いて最下部の
                // 1 セットだけに**（mako 2026-08-13「行末のほう抜いてみて」—
                // 両方に出すとどちらが本物か分からなくなる、toneMap と同じ掟へ）
                let neutrals = Set(Roto.Color.neutralRow())
                ForEach(
                    Array(Roto.Color.presetRowsCustom().enumerated()), id: \.offset
                ) { _, presetRow in
                    row(presetRow.filter { !neutrals.contains($0) })
                }
                row(Roto.Color.neutralRow())
                    .padding(.top, 3)
            case .hueOrder:
                // 虹の一本道 + 無彩色は最下部に 1 セット
                rows(of: Roto.Color.hueOrdered())
                row(Roto.Color.neutralRow())
                    .padding(.top, 3)
            case .lightness:
                // 白 → 黒の一本道（無彩色も明度の座席に混ざる）
                rows(of: Roto.Color.lightnessOrdered())
            }
        }
    }

    /// フラットな並びを 14 列で折り返す
    @ViewBuilder
    private func rows(of ordered: [UInt8]) -> some View {
        ForEach(Array(stride(from: 0, to: ordered.count, by: 14)), id: \.self) { start in
            row(Array(ordered[start..<min(start + 14, ordered.count)]))
        }
    }

    @ViewBuilder
    private func row(_ row: [UInt8]) -> some View {
        if !row.isEmpty {
            HStack(spacing: 0) {
                ForEach(Array(row.enumerated()), id: \.offset) { _, index in
                    swatch(index)
                }
                Spacer(minLength: 0)
            }
        }
    }

    /// 色見本（選択中の色は枠で示す）。クリック = 変更、ダブルクリック =
    /// 変更して閉じる（onPickDouble があるとき — ポップオーバー運用）
    private func swatch(_ index: UInt8) -> some View {
        Rectangle()
            .fill(Self.color(index))
            .frame(width: Self.swatchSize, height: Self.swatchSize)
            .overlay(
                Rectangle()
                    .stroke(
                        current == index ? theme.semanticSuccessText : theme.textSecondary,
                        lineWidth: current == index ? 2 : 0.5)
            )
            .gesture(TapGesture(count: 2).onEnded { onPickDouble?(index) })
            .simultaneousGesture(TapGesture().onEnded { onPick(index) })
            .help(Self.describe(index))
    }

    /// パレット index → SwiftUI の色（色見本・タイルのストライプ・影の表示で共有）
    static func color(_ index: UInt8) -> Color {
        let rgb = Roto.Color.palette[Int(index) % Roto.Color.palette.count]
        return Color(
            red: Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >> 8) & 0xFF) / 255,
            blue: Double(rgb & 0xFF) / 255)
    }

    /// index / RGB / OKLCH の明度を 1 行に（ツールチップ用）
    static func describe(_ index: UInt8) -> String {
        let rgb = Roto.Color.palette[Int(index) % Roto.Color.palette.count]
        let l = Roto.Color.oklch(index).lightness
        return String(format: "#%d  0x%06X  L=%.2f", index, rgb, l)
    }
}

