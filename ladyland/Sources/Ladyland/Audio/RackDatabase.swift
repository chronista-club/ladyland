//! 永続化の SSOT（mako 裁定 2026-08-02「GRDB 導入しよう。ここが SSOT」）。
//!
//! 単一 JSON（rack.json、21MB まで育った）から SQLite へ。狙いは**部分書き込み**:
//! 音量ノブ 1 回の変更で 21MB を再エンコードしていたのを、行 1 つの upsert にする。
//!
//! 競合を「解決」せず**存在させない**構造（mako 裁定 2026-08-01「データアクセスを
//! チョッパヤかつ、並行性の競合は気にしたくない」）:
//!   - 演奏中の正はメモリの InstrumentRack。**DB を読むのは起動時の 1 回だけ**
//!     → read/write 競合が原理的に起きない（レンダースレッドを DB で止めない）
//!   - 書き手は DatabaseQueue 1 本。GRDB は生の接続を渡さないので、
//!     直列化はライブラリの構造として保証される（自前のロックが 1 つも要らない）
//!   - 音色 blob は**内容アドレス + 追記のみ**。上書きが存在しないので競合も無い。
//!     同じ音色を持つ draft が何着あっても実体は 1 個（自動で重複排除）
//!
//! 二層保存は維持する（design/06 §8「パツパツ」の解剖）: fullState を AU に
//! 問い合わせるコストは保存層と無関係で安くならない。よって
//!   軽い保存 = 目録の行だけ（AU に触らない・blob も触らない）
//!   重い保存 = blob も含めて書く（音の節目だけ）

import AVFoundation
import CryptoKit
import GRDB

/// ラック状態を SQLite に保持する。DB に触れる唯一の場所
final class RackDatabase: @unchecked Sendable {
    /// 保存先: ~/Library/Application Support/ladyland/ladyland.sqlite
    static var url: URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0]
        return base.appendingPathComponent("ladyland/ladyland.sqlite")
    }

    private let dbQueue: DatabaseQueue

    init(path: URL = RackDatabase.url) throws {
        let dir = path.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        dbQueue = try DatabaseQueue(path: path.path)
        try Self.migrator.migrate(dbQueue)
    }

    /// テスト用のインメモリ DB
    static func inMemory() throws -> RackDatabase {
        try RackDatabase(queue: DatabaseQueue())
    }

    private init(queue: DatabaseQueue) throws {
        dbQueue = queue
        try Self.migrator.migrate(dbQueue)
    }

    // MARK: - スキーマ

    /// 明示的・順序付きの移行（適用済みかは DB 自身が覚える）。
    /// **既存の移行は二度と書き換えない** — 追加は必ず新しい登録として足す
    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1-rack") { db in
            // 目録（単一行）。ラック全体にかかる値
            try db.create(table: "rackState") { t in
                t.primaryKey("id", .integer).check { $0 == 1 }
                t.column("trackCount", .integer).notNull()
                t.column("selected", .integer).notNull()
                t.column("outputDeviceUID", .text)
                t.column("keyRoot", .integer)
                t.column("keyScale", .text)
                t.column("ledFeedback", .boolean)
            }

            // 音色の実体。内容アドレス = 同じ中身は 1 行しか存在しない。
            // 一度書いたら書き換えない（追記のみ）
            try db.create(table: "blob") { t in
                t.primaryKey("hash", .text)
                t.column("data", .blob).notNull()
                t.column("byteCount", .integer).notNull()
            }

            // 席（ロード済みのみ。ドラム席は index = trackCount 規約）
            try db.create(table: "slot") { t in
                t.primaryKey("slotIndex", .integer)
                t.column("componentType", .integer).notNull()
                t.column("componentSubType", .integer).notNull()
                t.column("componentManufacturer", .integer).notNull()
                t.column("name", .text).notNull()
                t.column("gain", .double).notNull()
                t.column("stateHash", .text).references("blob")
                // 割当は数十件の小さい配列。行にせず JSON で持つ（席を 1 行で
                // 読み書きできる = 部分書き込みの単位を揃える）
                t.column("knobs", .text)
            }

            // 席の棚（design/06 §8 Track Drafts）。slot と同形で blob を共有できる
            try db.create(table: "draft") { t in
                t.primaryKey("id", .text)
                t.column("slotIndex", .integer).notNull().indexed()
                t.column("componentType", .integer).notNull()
                t.column("componentSubType", .integer).notNull()
                t.column("componentManufacturer", .integer).notNull()
                t.column("name", .text).notNull()
                t.column("gain", .double).notNull()
                t.column("stateHash", .text).references("blob")
                t.column("knobs", .text)
                t.column("savedAt", .datetime).notNull()
            }
        }

        // ダンパーペダルの役割（mako 裁定 2026-08-03）。
        // **既存の移行は書き換えない** — 追加は必ず新しい登録として足す
        migrator.registerMigration("v2-pedal-mode") { db in
            try db.alter(table: "rackState") { t in
                t.add(column: "pedalMode", .text)
            }
        }

        // Keystage の ARP / CHORD 設定（mako 裁定 2026-08-04「ラック全体で 1 セット」）。
        // **列を 12 個生やさず JSON 1 列**にする — 実機のパラメータが増えても
        // マイグレーションを足さずに済む（設定は ladyland が SSOT なので、
        // 読み書きするのはこちらだけ）
        migrator.registerMigration("v3-keystage") { db in
            try db.alter(table: "rackState") { t in
                t.add(column: "keystage", .text)
            }
        }

        // ROTO の配色（mako 要望 2026-08-04「色を設定したいね」）。
        // Keystage と同じく JSON 1 列 — 用途が増えても移行を足さずに済む
        migrator.registerMigration("v4-roto-colors") { db in
            try db.alter(table: "rackState") { t in
                t.add(column: "rotoColors", .text)
            }
        }

        // **この席の既定**（mako 要望 2026-08-06「set default / load default が欲しい」）。
        // 中身は draft と同じ（音色 + 割当）だが、**選んでも消えない**。
        // draft は別テーブルだが、既定は席に 1 つなので slot の列に JSON で載せる
        migrator.registerMigration("v5-slot-default") { db in
            try db.alter(table: "slot") { t in
                t.add(column: "defaultSnapshot", .text)
            }
        }

        // **画面のテーマ**（mako 要望 2026-08-06「画面の UI テーマを作成しよう」）。
        // `"mint/dark"` の 1 列。Optional なので旧 rack.json もそのまま読める
        migrator.registerMigration("v6-theme") { db in
            try db.alter(table: "rackState") { t in
                t.add(column: "theme", .text)
            }
        }

        // スロットのミュート（NULL = off。draft には足さない — ミュートは
        // 演奏状態であって音色ではない）
        migrator.registerMigration("v7-slot-mute") { db in
            try db.alter(table: "slot") { t in
                t.add(column: "mute", .boolean)
            }
        }

        // トラックカラー（ROTO 83 色 index）とトラック名。**席の属性**なので
        // slot にだけ足す — draft（音色）には属さない
        migrator.registerMigration("v8-track-identity") { db in
            try db.alter(table: "slot") { t in
                t.add(column: "rotoColor", .integer)
                t.add(column: "customName", .text)
            }
        }

        // ダンパーペダルの極性反転（mako 報告 2026-08-14「キープが逆」）
        migrator.registerMigration("v9-pedal-inverted") { db in
            try db.alter(table: "rackState") { t in
                t.add(column: "pedalInverted", .boolean)
            }
        }

        // シンセ入力の担当スロット（spec/09 Jack — シンセ入力 1 = Keystage の
        // 固定。⚠️ secondKeyboardSlot は snapshot にだけ居て DB 列が無かった
        // （= 鍵盤 2 の固定が再起動で消えていた）— ここで一緒に塞ぐ
        migrator.registerMigration("v10-jack-synth-slots") { db in
            try db.alter(table: "rackState") { t in
                t.add(column: "synthInput1Slot", .integer)
                t.add(column: "secondKeyboardSlot", .integer)
            }
        }

        // テンポ同期（RackSnapshotには先に存在していたが、SQLite側の列が無く
        // falseを保存しても再起動時に既定trueへ戻っていた）。
        migrator.registerMigration("v11-tempo-sync") { db in
            try db.alter(table: "rackState") { t in
                t.add(column: "tempoSync", .boolean)
            }
        }

        // LPD8 ノブ 8 の刺し先（spec/09 Jack — drums / face。mako 裁定 2026-09-26）
        migrator.registerMigration("v12-lpd8-knob-jack") { db in
            try db.alter(table: "rackState") { t in
                t.add(column: "lpd8KnobJack", .text)
            }
        }

        return migrator
    }

    // MARK: - 保存

    /// スナップショットを書く（**呼び手のスレッドを塞ぐ**）。
    ///
    /// 終了時の書き切りとテストのための同期版。演奏中は `saveAsync` を使う —
    /// 実測 2026-08-03 で重い保存が最大 544ms かかっており、メインで待つと
    /// 30 秒ごとに UI がその分固まる。
    ///
    /// - Parameter includeBlobs: 重い保存（AU から fullState を取り直した直後）
    ///   でだけ true。false のときは既存の stateHash を temper せず、目録の行だけ
    ///   更新する — 軽い保存で 21MB をハッシュし直さないための切り分け
    func save(_ snapshot: RackSnapshot, includeBlobs: Bool) throws {
        try dbQueue.write { db in
            try self.write(snapshot, includeBlobs: includeBlobs, to: db)
        }
    }

    /// スナップショットを**書き込みキューへ預けて即座に戻る**（演奏中はこちら）。
    ///
    /// 順序は GRDB の DatabaseQueue が保証する — 預けた順に直列で実行される。
    /// 後から預けたスナップショットが必ず後に書かれるので、途中の状態が
    /// 最終状態を上書きすることはない。
    ///
    /// `completion` は**書き込みキューのスレッド**で呼ばれる（main ではない）。
    func saveAsync(
        _ snapshot: RackSnapshot, includeBlobs: Bool,
        completion: @escaping @Sendable (Result<Void, Error>) -> Void
    ) {
        dbQueue.asyncWrite({ db in
            try self.write(snapshot, includeBlobs: includeBlobs, to: db)
        }, completion: { _, result in
            completion(result)
        })
    }

    /// 実際の書き込み（同期版・非同期版で共有する一本道）
    private func write(
        _ snapshot: RackSnapshot, includeBlobs: Bool, to db: Database
    ) throws {
        try RackStateRow(snapshot: snapshot).save(db)

        var liveSlotIndices: Set<Int> = []
        var liveDraftIDs: Set<String> = []

        for slot in snapshot.slots {
            liveSlotIndices.insert(slot.index)
            let hash = try self.storeBlob(slot.state, in: db, when: includeBlobs)
            try SlotRow(snapshot: slot, stateHash: hash)
                .upsertPreservingState(db, hasNewState: includeBlobs)

            for draft in slot.drafts ?? [] {
                liveDraftIDs.insert(draft.id.uuidString)
                let draftHash = try self.storeBlob(draft.state, in: db, when: includeBlobs)
                try DraftRow(draft: draft, slotIndex: slot.index, stateHash: draftHash)
                    .upsertPreservingState(db, hasNewState: includeBlobs)
            }
        }

        // 消えた席・棚を落とす（空席にした / draft を昇格した後）
        try Slot_deleteMissing(db, keeping: liveSlotIndices)
        try Draft_deleteMissing(db, keeping: liveDraftIDs)

        // blob を書いたら同じトランザクションで孤児を回収する。
        // **実測 2026-08-02**: AU は中身が変わっていなくても fullState の
        // バイト列を変えて返すことがある（内部カウンタ等）。内容アドレス
        // なので毎回 新 blob が積まれ、重い保存 2 回で 9MB のゴミが出た。
        // 30 秒タイマー × 40 分のセットなら数百 MB — 起動時 GC だけでは
        // 本番中に肥り続ける。行の DELETE はファイル操作ではなく同じ
        // 直列キュー内の安い書き込みなので、ここで回収してよい
        if includeBlobs {
            try Self.deleteOrphanBlobs(db)
        }
    }

    /// blob を内容アドレスで入れてハッシュを返す（追記のみ・重複排除）。
    /// `when` が false のときは触らない = 既存のハッシュを維持させる
    private func storeBlob(_ data: Data?, in db: Database, when include: Bool) throws -> String? {
        guard include, let data, !data.isEmpty else { return nil }
        let hash = Self.hash(data)
        // **存在確認は DB に聞く**（主キー参照なのでマイクロ秒。blob 本体は
        // 一切運ばない）。以前はプロセス内の Set をキャッシュしていたが、
        // これが実害を出した（2026-08-03 実機ログ「FOREIGN KEY constraint
        // failed」が 30 秒ごとに永続）:
        //
        //   トランザクションが何かの理由でロールバックすると、SQLite 側の
        //   blob 挿入は消えるのに**メモリ上の Set は消えない**。以後 storeBlob は
        //   「もうある」と誤判定して INSERT を省き、slot.stateHash が存在しない
        //   blob を指して FK 違反 → またロールバック、の自己増殖ループになる。
        //   さらに Set の変更は GRDB の書き込みキュー上で起きるため、
        //   MainActor 側と競合しうるデータ競合でもあった。
        //
        // 内容アドレスなので衝突＝同一内容。既にあれば何もしない
        let exists =
            try Bool.fetchOne(
                db, sql: "SELECT EXISTS(SELECT 1 FROM blob WHERE hash = ?)", arguments: [hash])
            ?? false
        if !exists {
            try db.execute(
                sql: "INSERT OR IGNORE INTO blob (hash, data, byteCount) VALUES (?, ?, ?)",
                arguments: [hash, data, data.count])
        }
        return hash
    }

    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - 読み込み（起動時の 1 回だけ）

    /// 保存された状態を復元する。1 行も無ければ nil（初回起動）
    func load() throws -> RackSnapshot? {
        try dbQueue.read { db in
            guard let state = try RackStateRow.fetchOne(db) else { return nil }
            let draftRows = try DraftRow.order(Column("savedAt")).fetchAll(db)
            let draftsBySlot = Dictionary(grouping: draftRows, by: \.slotIndex)

            var slots: [SlotSnapshot] = []
            for row in try SlotRow.order(Column("slotIndex")).fetchAll(db) {
                let drafts = try (draftsBySlot[row.slotIndex] ?? []).map {
                    try $0.draft(state: self.blob($0.stateHash, in: db))
                }
                slots.append(
                    row.snapshot(
                        state: try self.blob(row.stateHash, in: db),
                        drafts: drafts.isEmpty ? nil : drafts))
            }
            return state.snapshot(slots: slots)
        }
    }

    private func blob(_ hash: String?, in db: Database) throws -> Data? {
        guard let hash else { return nil }
        return try Data.fetchOne(db, sql: "SELECT data FROM blob WHERE hash = ?", arguments: [hash])
    }

    // MARK: - 掃除

    /// どこからも参照されていない blob を落とす（重い保存のたびに自動で走る。
    /// これは明示呼び出し用 = 起動時の掃除）
    @discardableResult
    func collectGarbage() throws -> Int {
        let removed = try dbQueue.write { db -> Int in
            try Self.deleteOrphanBlobs(db)
            return db.changesCount
        }
        // SQLite は DELETE でファイルを縮めない（空きページを再利用するだけ）。
        // 起動時だけ VACUUM して実際に縮める — 演奏中はやらない（全体書き直し）
        if removed > 0 {
            try dbQueue.writeWithoutTransaction { db in
                try db.execute(sql: "VACUUM")
            }
        }
        return removed
    }

    private static func deleteOrphanBlobs(_ db: Database) throws {
        try db.execute(
            sql: """
                DELETE FROM blob WHERE hash NOT IN (
                    SELECT stateHash FROM slot WHERE stateHash IS NOT NULL
                    UNION SELECT stateHash FROM draft WHERE stateHash IS NOT NULL
                )
                """)
    }

    // MARK: - rack.json からの移行

    /// DB が空で rack.json があれば取り込む。**rack.json は消さない** —
    /// 後戻りできる状態を残す（8/8 を挟む変更なので。design/06 §8）
    @discardableResult
    func importLegacyIfNeeded(from source: URL = RackStore.url) throws -> Bool {
        let isEmpty = try dbQueue.read { db in
            try RackStateRow.fetchCount(db) == 0
        }
        guard isEmpty, let legacy = RackStore.load(from: source) else { return false }
        try save(legacy, includeBlobs: true)
        NSLog("rack.json → SQLite に移行しました（%d スロット）", legacy.slots.count)
        return true
    }

    /// 保存サイズ（Debug 表示・診断用）
    func fileSize() -> Int {
        (try? dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT SUM(byteCount) FROM blob") ?? 0
        }) ?? 0
    }
}

// MARK: - 行の型（DB 表現 ⇄ RackSnapshot）

private struct RackStateRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "rackState"

    var id: Int = 1
    var trackCount: Int
    var selected: Int
    var outputDeviceUID: String?
    var keyRoot: Int?
    var keyScale: String?
    var ledFeedback: Bool?
    var pedalMode: String?
    var pedalInverted: Bool?
    var synthInput1Slot: Int?
    var secondKeyboardSlot: Int?
    /// Keystage の ARP / CHORD 設定（JSON。KeystageSettings をそのまま符号化）
    var keystage: String?
    /// ROTO の配色（JSON）
    var rotoColors: String?
    /// 画面のテーマ（`"mint/dark"`）
    var theme: String?
    var tempoSync: Bool?
    /// LPD8 ノブ 8 の刺し先（`Lpd8KnobJack` の raw 値）
    var lpd8KnobJack: String?

    /// 総数の既定 8 は「trackCount 導入前のファイル」の歴史的事実であって
    /// 設定値ではない（InstrumentRack.restore と同じ読み替え）
    static let legacyTrackCount = 8

    init(snapshot: RackSnapshot) {
        trackCount = snapshot.trackCount ?? Self.legacyTrackCount
        selected = snapshot.selected
        outputDeviceUID = snapshot.outputDeviceUID
        keyRoot = snapshot.keyRoot
        keyScale = snapshot.keyScale
        ledFeedback = snapshot.ledFeedback
        pedalMode = snapshot.pedalMode
        pedalInverted = snapshot.pedalInverted
        synthInput1Slot = snapshot.synthInput1Slot
        secondKeyboardSlot = snapshot.secondKeyboardSlot
        keystage = snapshot.keystage
        rotoColors = snapshot.rotoColors
        theme = snapshot.theme
        tempoSync = snapshot.tempoSync
        lpd8KnobJack = snapshot.lpd8KnobJack
    }

    func snapshot(slots: [SlotSnapshot]) -> RackSnapshot {
        var snapshot = RackSnapshot(slots: slots, selected: selected)
        snapshot.trackCount = trackCount
        snapshot.outputDeviceUID = outputDeviceUID
        snapshot.keyRoot = keyRoot
        snapshot.keyScale = keyScale
        snapshot.ledFeedback = ledFeedback
        snapshot.pedalMode = pedalMode
        snapshot.pedalInverted = pedalInverted
        snapshot.synthInput1Slot = synthInput1Slot
        snapshot.secondKeyboardSlot = secondKeyboardSlot
        snapshot.keystage = keystage
        snapshot.rotoColors = rotoColors
        snapshot.theme = theme
        snapshot.tempoSync = tempoSync
        snapshot.lpd8KnobJack = lpd8KnobJack
        return snapshot
    }
}

private struct SlotRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "slot"

    var slotIndex: Int
    var componentType: UInt32
    var componentSubType: UInt32
    var componentManufacturer: UInt32
    var name: String
    var gain: Double
    var mute: Bool?
    var rotoColor: Int?
    var customName: String?
    var stateHash: String?
    var knobs: String?
    /// この席の既定（音色 + 割当を JSON 1 列で。**draft と違って消えない**）
    var defaultSnapshot: String?

    init(snapshot: SlotSnapshot, stateHash: String?) {
        slotIndex = snapshot.index
        componentType = snapshot.componentType
        componentSubType = snapshot.componentSubType
        componentManufacturer = snapshot.componentManufacturer
        name = snapshot.name
        gain = Double(snapshot.gain)
        mute = snapshot.mute
        rotoColor = snapshot.rotoColor.map(Int.init)
        customName = snapshot.customName
        self.stateHash = stateHash
        knobs = JSONColumn.encode(snapshot.knobs)
        defaultSnapshot = JSONColumn.encode(snapshot.defaultSnapshot)
    }

    func snapshot(state: Data?, drafts: [Draft]?) -> SlotSnapshot {
        SlotSnapshot(
            index: slotIndex,
            componentType: componentType,
            componentSubType: componentSubType,
            componentManufacturer: componentManufacturer,
            name: name,
            gain: Float(gain),
            mute: mute,
            rotoColor: rotoColor.map(UInt8.init),
            customName: customName,
            state: state,
            knobs: JSONColumn.decode(knobs, as: [FaceKnobMapping].self),
            drafts: drafts,
            defaultSnapshot: JSONColumn.decode(defaultSnapshot, as: Draft.self))
    }

    /// 軽い保存では stateHash 列に触らない（blob を書いていないので、
    /// nil で上書きすると音色への参照を失う）
    func upsertPreservingState(_ db: Database, hasNewState: Bool) throws {
        if hasNewState {
            try save(db)
            return
        }
        try db.execute(
            sql: """
                INSERT INTO slot
                    (slotIndex, componentType, componentSubType, componentManufacturer,
                     name, gain, mute, rotoColor, customName, stateHash, knobs)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, ?)
                ON CONFLICT(slotIndex) DO UPDATE SET
                    componentType = excluded.componentType,
                    componentSubType = excluded.componentSubType,
                    componentManufacturer = excluded.componentManufacturer,
                    name = excluded.name,
                    gain = excluded.gain,
                    mute = excluded.mute,
                    rotoColor = excluded.rotoColor,
                    customName = excluded.customName,
                    knobs = excluded.knobs
                """,
            arguments: [
                slotIndex, componentType, componentSubType, componentManufacturer,
                name, gain, mute, rotoColor, customName, knobs,
            ])
    }
}

private struct DraftRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "draft"

    var id: String
    var slotIndex: Int
    var componentType: UInt32
    var componentSubType: UInt32
    var componentManufacturer: UInt32
    var name: String
    var gain: Double
    var stateHash: String?
    var knobs: String?
    var savedAt: Date

    init(draft: Draft, slotIndex: Int, stateHash: String?) {
        id = draft.id.uuidString
        self.slotIndex = slotIndex
        componentType = draft.componentType
        componentSubType = draft.componentSubType
        componentManufacturer = draft.componentManufacturer
        name = draft.name
        gain = Double(draft.gain)
        self.stateHash = stateHash
        knobs = JSONColumn.encode(draft.knobs)
        savedAt = draft.savedAt
    }

    func draft(state: Data?) -> Draft {
        Draft(
            id: UUID(uuidString: id) ?? UUID(),
            componentType: componentType,
            componentSubType: componentSubType,
            componentManufacturer: componentManufacturer,
            name: name,
            gain: Float(gain),
            state: state,
            knobs: JSONColumn.decode(knobs, as: [FaceKnobMapping].self),
            savedAt: savedAt)
    }

    func upsertPreservingState(_ db: Database, hasNewState: Bool) throws {
        if hasNewState {
            try save(db)
            return
        }
        try db.execute(
            sql: """
                INSERT INTO draft
                    (id, slotIndex, componentType, componentSubType, componentManufacturer,
                     name, gain, stateHash, knobs, savedAt)
                VALUES (?, ?, ?, ?, ?, ?, ?, NULL, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    slotIndex = excluded.slotIndex,
                    name = excluded.name,
                    gain = excluded.gain,
                    knobs = excluded.knobs,
                    savedAt = excluded.savedAt
                """,
            arguments: [
                id, slotIndex, componentType, componentSubType, componentManufacturer,
                name, gain, knobs, savedAt,
            ])
    }
}

/// 消えた行を落とす（空席にした / draft を昇格した後の掃除）
private func Slot_deleteMissing(_ db: Database, keeping indices: Set<Int>) throws {
    if indices.isEmpty {
        try db.execute(sql: "DELETE FROM slot")
    } else {
        let list = indices.map(String.init).joined(separator: ",")
        try db.execute(sql: "DELETE FROM slot WHERE slotIndex NOT IN (\(list))")
    }
}

private func Draft_deleteMissing(_ db: Database, keeping ids: Set<String>) throws {
    if ids.isEmpty {
        try db.execute(sql: "DELETE FROM draft")
    } else {
        let placeholders = ids.map { _ in "?" }.joined(separator: ",")
        try db.execute(
            sql: "DELETE FROM draft WHERE id NOT IN (\(placeholders))",
            arguments: StatementArguments(Array(ids)))
    }
}

/// 小さい配列を 1 列に畳む（席を 1 行で読み書きできる = 部分書き込みの単位を揃える）
enum JSONColumn {
    static func encode<T: Encodable>(_ value: T?) -> String? {
        guard let value else { return nil }
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func decode<T: Decodable>(_ text: String?, as type: T.Type) -> T? {
        guard let text, let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
