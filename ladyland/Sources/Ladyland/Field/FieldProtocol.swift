//! Field プロトコルの Swift channel meta（field/schemas/field.kdl の写し。
//! KDL→Swift codegen は club-unison の将来項目なので当面手書き —
//! swift-client-api.md §5 の作法どおり）。
//!
//! ⚠️ **wire の形は schemas/field.kdl が正**。ここがズレると fieldd と
//! 話が通じない。vision/（visionOS）も同じ型を使う — v0 はコピーで開始し、
//! 育ったら FieldKit として共有パッケージへ抜く。

import Foundation
import UnisonClient

/// field のエンティティ（v0 = ladyland のスロットの写し）
struct FieldEntity: Codable, Sendable, Equatable {
    /// トラック番号（1-64）
    var id: Int
    var name: String
    /// トラックカラー "#RRGGBB"（nil = 未設定。ROTO の palette index は
    /// ladyland 内部の語 — wire は見た目に必要な形で運ぶ）
    var color: String?
    var selected: Bool
    /// 出音 peak 0.0-1.0
    var level: Float
}

/// presence チャネル（Join / UpdateEntities / FieldTick）
struct FieldPresenceChannel: StreamChannelMeta {
    static let name = "presence"
    typealias Event = FieldTick
}

/// field → 購読者: 場の鼓動
struct FieldTick: Decodable, Sendable {
    var entities: [FieldEntity]
}

/// 降り立つ / 楽器を供給する（role で同格クライアントを見分ける）
struct FieldJoin: UnisonRequest {
    static let method = "Join"
    var role: String
    struct Response: Decodable, Sendable {
        var entities: [FieldEntity]
        /// fieldd の版（pkg+ビルド時刻。同梱版との**完全一致**で同一性判定 —
        /// 旧 fieldd は nil = 不一致扱いで入れ替え対象）
        var serverVersion: String?

        enum CodingKeys: String, CodingKey {
            case entities
            case serverVersion = "server_version"
        }
    }
}

/// 入れ替えのための退場（自動アプデ — 版違いの fieldd に退いてもらう）
struct FieldShutdown: UnisonRequest {
    static let method = "Shutdown"
    struct Response: Decodable, Sendable {}
}

/// ladyland → field: スロットの姿
struct FieldUpdateEntities: UnisonRequest {
    static let method = "UpdateEntities"
    var entities: [FieldEntity]
    struct Response: Decodable, Sendable {}
}
