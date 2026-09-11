//! **波形（全体） + 再生カーソル**（mako 要望 2026-08-07「全体と再生位置を
//! 表示できるようにして、クリックで、再生カーソルを移動させる UI が欲しい」）。
//!
//! ## ⚠️ 層を 2 つに分ける
//!
//! | 層 | 更新 | なぜ |
//! |---|---|---|
//! | **波形** | **静止**。包絡が変わったときだけ | 8 席 × 2048 バケットを 60fps で描き直すと、それだけで CPU が埋まる |
//! | **カーソル** | 動く（60fps） | **線 1 本**なので安い |
//!
//! `drawingGroup()` で波形をラスタライズして固定する — 中身が変わらない限り
//! **再描画されず、テクスチャを 1 枚貼るだけ**になる。
//!
//! ## ⚠️ 全長を 1 枚に収める（拡大しない）
//!
//! mako 指定「全体の静的描画で固定で」。拡大・スクロール・追従ズームは作らない。
//! だから包絡のバケット数は**固定で足りる**（`PeakEnvelope.bucketCount`）。
//!
//! ## ⚠️ 頭出しで再生状態を変えない
//!
//! 止まっているなら止まったまま、鳴っているならそのまま続ける。
//! 「頭出ししたら鳴り出した」は演奏中に事故になる（`LadySampler.seek`）。

import CreoUI
import SwiftUI

struct WaveformView: View {
    @Environment(\.creoTheme) private var theme

    /// **静止する側**（包絡が変わらない限り同じ絵）
    let envelope: LadySampler.PeakEnvelope?
    /// **動く側** 0...1
    let progress: Double
    /// 鳴っているか（カーソルの色だけ変える）
    let isPlaying: Bool
    /// 押した / 引いた位置 0...1
    let onSeek: (Double) -> Void

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                // ── 静止する層 ─────────────────────────────
                // ⚠️ `drawingGroup()` が要点 — ラスタライズして固定するので、
                // カーソルが動いてもここは描き直されない
                waveform
                    .drawingGroup()
                    // ⚠️ **描画層に当たり判定を持たせない** — `drawingGroup()` は
                    // 部分木をオフスクリーンへ焼くので、**中の当たり判定が壊れる**。
                    // 明示的に外して、判定は下の `contentShape` 1 枚に集める
                    .allowsHitTesting(false)

                // ── 動く層（線 1 本だけ） ───────────────────
                Rectangle()
                    .fill(isPlaying ? theme.semanticSuccessText : theme.textSecondary)
                    .frame(width: 1)
                    .offset(x: geo.size.width * min(1, max(0, progress)))
            }
            // ⚠️ **`GeometryReader` の枠いっぱいを当たり判定にする**。
            // ZStack は中身なりの大きさなので、空いた所を押しても効かなかった
            .frame(width: geo.size.width, height: geo.size.height, alignment: .leading)
            .contentShape(Rectangle())
            // ⚠️ **ドラッグでも追従**（mako 要望）— 一発で目的の位置に押せることは
            // 少ない。`minimumDistance: 0` で「押しただけ」も拾う。
            //
            // ⚠️ **`highPriorityGesture`** — Card や窓の側にジェスチャが増えても
            // **こちらが先に取る**。実機で「カーソルは動くが頭出しできない」
            // （= 押しても届いていない）が出たので、取りこぼす余地を消す
            .highPriorityGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard geo.size.width > 0 else { return }
                        onSeek(value.location.x / geo.size.width)
                    }
            )
        }
    }

    /// ピーク包絡を 1 本の帯として描く。
    ///
    /// ⚠️ **バケットが幅より多い**（2048 対 数百 pt）ので、`Canvas` に
    /// そのまま渡すと 1px に何本も重なる。**幅ぶんに間引いて**から描く —
    /// 見た目は変わらず、線の本数が 1/4 以下になる
    @ViewBuilder
    private var waveform: some View {
        if let envelope, !envelope.isEmpty {
            Canvas { context, size in
                let mid = size.height / 2
                let columns = max(1, Int(size.width))
                let step = max(1, envelope.lows.count / columns)
                var path = Path()
                for column in 0..<columns {
                    let bucket = min(envelope.lows.count - 1, column * step)
                    // 間引いたぶんの山を落とさない（区間の最大・最小を取る）
                    var low = envelope.lows[bucket]
                    var high = envelope.highs[bucket]
                    for offset in 1..<step where bucket + offset < envelope.lows.count {
                        low = min(low, envelope.lows[bucket + offset])
                        high = max(high, envelope.highs[bucket + offset])
                    }
                    let x = CGFloat(column) + 0.5
                    // ⚠️ **無音でも 1px は描く** — 完全に消えると
                    // 「素材が無い」と見分けが付かない
                    let top = mid - max(0.5, CGFloat(high) * mid)
                    let bottom = mid - min(-0.5, CGFloat(low) * mid)
                    path.move(to: CGPoint(x: x, y: top))
                    path.addLine(to: CGPoint(x: x, y: bottom))
                }
                context.stroke(path, with: .color(theme.brandPrimary), lineWidth: 1)
            }
        } else {
            // まだ包絡が無い（空席 / 変換中）— 中央に細い線だけ
            Rectangle()
                .fill(theme.surfaceBorderSubtle)
                .frame(height: 1)
                .frame(maxHeight: .infinity, alignment: .center)
        }
    }
}
