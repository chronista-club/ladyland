//! タイル並び替えのドラッグ幾何（design/06 §8 追補）。
//!
//! 番号バッジを掴むと Lane（タイル列）上に Layout Grid Frame（枠ガイド）が
//! 浮かび、ホバー先セルが着地予告される。リリースで**スワップ**確定 —
//! 落とした先の 1 枚とだけ交換し、他は不動（数字キー 1-8 の対応を保つ）。
//! ここは幾何の純関数層（テスト対象）。UI は ContentView、モデル交換は
//! InstrumentRack.swapSlots。

import CoreGraphics

/// ドラッグ進行中の状態（ContentView の @State に載る値型）
struct TileDragState: Equatable {
    /// 掴んだタイルのスロット index
    var sourceIndex: Int
    /// ドラッグ開始点からの移動量（タイルの浮遊 offset）
    var translation: CGSize
    /// 現在のポインタ位置（Lane 座標系 — セルのヒットテストに使う）
    var location: CGPoint
}

enum TileDragMath {
    /// ポインタ位置が落ちるセルの index（Lane 座標系。どのセルにも
    /// 掛からなければ nil = 枠外リリースで「元に戻る」）
    static func target(frames: [Int: CGRect], point: CGPoint) -> Int? {
        frames.first { $0.value.contains(point) }?.key
    }

    /// 着地アニメの offset: source セルに居るタイルを target セルの位置へ
    /// 滑らせるための座標差分
    static func settleOffset(source: CGRect, target: CGRect) -> CGSize {
        CGSize(width: target.minX - source.minX, height: target.minY - source.minY)
    }
}
