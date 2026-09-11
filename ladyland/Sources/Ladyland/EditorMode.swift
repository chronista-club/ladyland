//! creo-ui **Editor Mode** の Swift 最小 runtime（ladyland 内実験、2026-08-14
//! mako 裁定「そうしよう」）。
//!
//! 正典は creo-ui の docs/design/editor-mode.md（Universal Editor Protocol、
//! D-1〜D-13）。D-11 で「protocol owner は creo-ui、runtime 実装は consumer 側
//! （CreoUI for Swift）」と規定され **Swift runtime は未着手** — ここはその
//! 先行実験で、育ったら CreoUI パッケージへ昇格する（Phase 3+）。
//!
//! 対応範囲:
//! - D-4 field 宣言（id / label / group / bind）— bind は closure で
//!   AppState の @Published へ繋ぐ
//! - D-9 reactive 反映 — bind 先が @Published なので変更は即 Content に出る
//!   （ROTO の役割色なら差分焼きまで自動で走る）
//! - D-2/D-6 は EditorOverlay 側（TOP + RIGHT のみ、Content 非侵襲）
//! - 未対応: persistence 宣言 / MCP アクセス（D-10）/ export to patch — 次段

import Foundation

/// 編集できる 1 項目（D-4 の最小形）
struct EditorField: Identifiable {
    /// bind の型と操作（D-5 の「カスタム（app-specific）」ルート —
    /// あらかじめ枠は CreoUI 昇格時に）
    enum Kind {
        /// ROTO 83 色パレットの色（nil を渡すと既定へ戻す）
        case rotoColor(get: () -> UInt8, set: (UInt8?) -> Void)
        case toggle(get: () -> Bool, set: (Bool) -> Void)
    }

    let id: String
    let label: String
    /// 表示グループ（RIGHT パネルの見出し。登録順を保つ）
    let group: String
    let kind: Kind
}
