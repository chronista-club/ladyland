//! Field への接続 — **クライアント②「降り立つ目」**（design/07 §1）。
//!
//! fieldd へ role=visitor で Join し、FieldTick（30Hz / 心拍 1s）を浴びて
//! entities を更新する。切れたら 5 秒ごとに静かに再接続 — ladyland の
//! FieldLink と同じ「機材扱い」。
//!
//! wire 型は field/schemas/field.kdl の写し（ladyland の FieldProtocol.swift
//! と同型 — v0 はコピー、育ったら FieldKit へ共有化）。

import Foundation
import Observation
import UnisonClient

// MARK: - wire 型（schemas/field.kdl の写し）

struct FieldEntity: Codable, Sendable, Equatable, Identifiable {
    var id: Int
    var name: String
    /// "#RRGGBB"（nil = 未設定）
    var color: String?
    var selected: Bool
    var level: Float
}

struct FieldPresenceChannel: StreamChannelMeta {
    static let name = "presence"
    typealias Event = FieldTick
}

struct FieldTick: Decodable, Sendable {
    var entities: [FieldEntity]
}

struct FieldJoin: UnisonRequest {
    static let method = "Join"
    var role: String
    struct Response: Decodable, Sendable {
        var entities: [FieldEntity]
    }
}

// MARK: - クライアント

@Observable
@MainActor
final class FieldClient {
    private(set) var connected = false
    private(set) var entities: [FieldEntity] = []
    /// 目の前に出す一体（v0 = 選択中の lady。spec/08「目の前楽器が一つ」）
    var focused: FieldEntity? { entities.first(where: \.selected) ?? entities.first }

    /// fieldd の場所（fieldd DEFAULT_ADDR と対）
    static let port: UInt16 = 7879

    private var runner: Task<Void, Never>?

    func start(host: String) {
        stop()
        runner = Task { [weak self] in
            while let self, !Task.isCancelled {
                await self.session(host: host)
                self.connected = false
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    func stop() {
        runner?.cancel()
        runner = nil
        connected = false
    }

    /// 接続 1 回ぶん — Join のスナップショットで場が即見え、以降は鼓動に乗る
    private func session(host: String) async {
        do {
            let connection = try await UnisonClient.connect(
                to: .host(host, port: Self.port), trust: .skipVerify)
            let channel = try await connection.openChannel(FieldPresenceChannel())
            let snapshot = try await channel.request(FieldJoin(role: "visitor"))
            entities = snapshot.entities
            connected = true
            defer { Task { await connection.disconnect() } }
            for await tick in channel.events {
                if Task.isCancelled { break }
                entities = tick.entities
            }
        } catch {
            // 未達・切断 — runner のループが 5 秒後に取り直す
        }
    }
}
