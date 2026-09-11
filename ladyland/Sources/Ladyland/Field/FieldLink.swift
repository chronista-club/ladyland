//! Field への接続 — **クライアント①「楽器の供給者」**（design/07 §1）。
//!
//! fieldd（Rust、[::1]:7879）へ UnisonClient で繋ぎ、role=instruments で
//! Join して 64 スロットの姿（名前・色・選択・peak）を 10Hz で流す。
//!
//! **機材と同じ扱い**: fieldd が居なければ黙って 5 秒ごとに再接続を試みる
//! （初回失敗だけログ）。ladyland の音は field と無関係に鳴り続ける —
//! field は増設された景色であって、依存ではない。
//! `LADYLAND_FIELD=0` で丸ごと切れる（会場の退避路流儀）。

import Foundation
import UnisonClient

@MainActor
final class FieldLink: ObservableObject {
    @Published private(set) var connected = false

    /// 現在の姿を供給するクロージャ（AppState が rack から写して渡す）
    private var supply: (() -> [FieldEntity])?
    private var runner: Task<Void, Never>?
    /// 「fieldd が居ない」ログは接続試行の連打で洪水になるので初回だけ
    private var loggedUnreachable = false

    static var enabled: Bool {
        ProcessInfo.processInfo.environment["LADYLAND_FIELD"] != "0"
    }

    /// fieldd の spawn / 自動入れ替え（mako 要望 2026-08-15「launchd は開発中
    /// めんどくさい」— 居なければ同梱バイナリを起こし、版違いは退かせて
    /// 入れ替える。=0 で手動運用・別 PC 構成へ）
    static var spawnEnabled: Bool {
        ProcessInfo.processInfo.environment["LADYLAND_FIELD_SPAWN"] != "0"
    }

    /// fieldd の場所（fieldd 側 DEFAULT_ADDR と対。台帳の block 取得は宿題）
    static let port: UInt16 = 7879

    /// アプリ同梱の fieldd（build-app.sh が Resources へ入れる。
    /// swift run の開発起動には無い — その場合 spawn はしない = 手動 cargo run）
    private static let bundledFieldd: URL? = Bundle.main.url(
        forResource: "fieldd", withExtension: nil)

    /// 同梱 fieldd の版（`fieldd --version` を 1 回だけ叩いて控える）
    private static let bundledVersion: String? = {
        guard let binary = bundledFieldd else { return nil }
        let process = Process()
        process.executableURL = binary
        process.arguments = ["--version"]
        let pipe = Pipe()
        process.standardOutput = pipe
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        let output = String(
            decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return parseVersionOutput(output)
    }()

    /// `fieldd 0.1.0+1786765142` → `0.1.0+1786765142`。
    /// ⚠️ --version は慣例の「名前 版」形式、Join の server_version は素の版 —
    /// **プレフィクス差で完全一致が永遠に失敗し、同版なのに 30 秒ごとに
    /// Shutdown → spawn を繰り返した**（実例 2026-08-15。fieldd が消えたり
    /// 再起動したりの正体 + VP 接続不能の巻き添え）。版は最後のトークン
    nonisolated static func parseVersionOutput(_ output: String) -> String? {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.split(separator: " ").last.map(String.init)
    }

    /// 直近の spawn 時刻（接続失敗のたびに起こすと多重 spawn の泡が立つ —
    /// ポート衝突で自然死するとはいえログが汚れるのでデバウンス）
    private var lastSpawn: Date?

    func start(supply: @escaping () -> [FieldEntity]) {
        guard Self.enabled else {
            NSLog("field: 切ってある（LADYLAND_FIELD=0）")
            return
        }
        // start は再接続ではなく「供給元の差し替え」でも呼ばれる。
        // 以前の runner を残すと二本が同じ fieldd を更新し、停止不能な
        // Task と古いクロージャが残る。
        runner?.cancel()
        runner = nil
        self.supply = supply
        runner = Task { [weak self] in
            while let self, !Task.isCancelled {
                await self.session()
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

    /// 接続 1 回ぶん（Join → 10Hz 供給。切れたら戻って再接続へ）。
    /// ⚠️ **request は全部タイムアウトで包む** — 応答が消えると await が
    /// 永遠に固まり、エラーも再試行も起きない（実例 2026-08-15: Join の
    /// 応答待ちで沈黙し、供給ゼロのまま気づけなかった）
    private func session() async {
        do {
            // ローカル開発 — fieldd は dev cert なので検証はスキップ
            let connection = try await Self.timeout(seconds: 5) {
                try await UnisonClient.connect(
                    to: .localDaemon(port: Self.port), trust: .skipVerify)
            }
            defer { Task { await connection.disconnect() } }
            let channel = try await Self.timeout(seconds: 3) {
                try await connection.openChannel(FieldPresenceChannel())
            }
            let snapshot = try await Self.timeout(seconds: 3) {
                try await channel.request(FieldJoin(role: "instruments"))
            }
            // 版の握手 — 同梱と不一致なら退かせて入れ替える（自動アプデ。
            // 判定は完全一致のみ: 旧 fieldd は server_version 無し = nil で
            // 自然に入れ替え対象になる）
            if let bundled = Self.bundledVersion, snapshot.serverVersion != bundled,
               Self.spawnEnabled {
                NSLog(
                    "field: fieldd が別版（%@ ≠ 同梱 %@）— 入れ替える",
                    snapshot.serverVersion ?? "旧版", bundled)
                _ = try? await Self.timeout(seconds: 2) {
                    try await channel.request(FieldShutdown())
                }
                lastSpawn = nil  // すぐ spawn できるように
                throw CancellationError()  // session を畳む → 失敗経路 → spawn
            } else if let bundled = Self.bundledVersion,
                      snapshot.serverVersion != bundled {
                // 手動運用（SPAWN=0）の fieldd は所有者が別にいるため、
                // Shutdown を送らず、そのまま接続を維持する。
                NSLog(
                    "field: fieldd は別版（%@ ≠ 同梱 %@）だが自動入れ替え無効 — 継続",
                    snapshot.serverVersion ?? "旧版", bundled)
            }
            connected = true
            loggedUnreachable = false
            NSLog("field: 接続 — 楽器の供給を開始（10Hz、fieldd %@）",
                snapshot.serverVersion ?? "?")
            while !Task.isCancelled {
                let entities = supply?() ?? []
                _ = try await Self.timeout(seconds: 2) {
                    try await channel.request(FieldUpdateEntities(entities: entities))
                }
                try await Task.sleep(for: .milliseconds(100))
            }
        } catch {
            if connected {
                NSLog("field: 切断 — 再接続へ（%@）", String(describing: error))
            } else if !loggedUnreachable {
                NSLog("field: fieldd に届かない — 5 秒ごとに静かに再試行（%@）",
                    String(describing: error))
                loggedUnreachable = true
            }
            spawnFielddIfNeeded()
        }
    }

    /// fieldd を同梱バイナリから起こす（detached — Ladyland を落としても
    /// fieldd は残る = 「ladyland が落ちても field は生きる」design/07 §1）。
    /// 接続失敗時にだけ呼ばれ、30 秒デバウンス。ポートが既に取られていれば
    /// 新プロセスは bind 失敗で自然死するので多重常駐にはならない
    private func spawnFielddIfNeeded() {
        guard Self.spawnEnabled, let binary = Self.bundledFieldd else { return }
        if let last = lastSpawn, Date().timeIntervalSince(last) < 30 { return }
        lastSpawn = Date()
        let process = Process()
        process.executableURL = binary
        // ログの置き場は手動運用（cargo run | tee /tmp/fieldd.log）と揃える
        if let log = try? FileHandle(
            forWritingTo: Self.preparedLogURL()) {
            log.seekToEndOfFile()
            process.standardOutput = log
            process.standardError = log
        }
        do {
            try process.run()
            NSLog("field: fieldd を起動（同梱 %@）", Self.bundledVersion ?? "?")
        } catch {
            NSLog("field: fieldd の起動に失敗 — %@", String(describing: error))
        }
    }

    private static func preparedLogURL() -> URL {
        let url = URL(fileURLWithPath: "/tmp/fieldd.log")
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        return url
    }

    /// 期限つき await（超えたら CancellationError — session が仕切り直す）
    private static func timeout<T: Sendable>(
        seconds: Double, _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw CancellationError()
            }
            guard let first = try await group.next() else { throw CancellationError() }
            group.cancelAll()
            return first
        }
    }
}
