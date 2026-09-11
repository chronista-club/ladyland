//! 永続化 SSOT（SQLite / GRDB）のテスト（mako 裁定 2026-08-02）。
//!
//! 守りたい不変条件:
//!   - ラウンドトリップ（保存 → 読み戻しで同じラックが返る）
//!   - blob は内容アドレス = 同じ音色は 1 行しか存在しない（draft が何着あっても）
//!   - **軽い保存は音色への参照を壊さない**（blob を書いていないので stateHash を
//!     nil で上書きしてはいけない — ここを踏むと再起動で音色が消える）
//!   - rack.json からの移行は 1 度きりで、元ファイルに触らない
//!   - 消えた席・棚は行ごと落ちる

import Foundation
import Testing

@testable import Ladyland

@Suite("永続化 SSOT（SQLite）")
struct RackDatabaseTests {
    private func slot(
        index: Int, name: String, gain: Float = 0.8, state: Data? = nil,
        drafts: [Draft]? = nil
    ) -> SlotSnapshot {
        SlotSnapshot(
            index: index, componentType: 1635085685, componentSubType: 100,
            componentManufacturer: 1263553842, name: name, gain: gain, state: state,
            knobs: [FaceKnobMapping(knob: 16, address: 0xA1, name: "Cutoff")], drafts: drafts)
    }

    private func draft(name: String, state: Data?) -> Draft {
        Draft(
            id: UUID(), componentType: 1635085685, componentSubType: 100,
            componentManufacturer: 1263553842, name: name, gain: 0.5, state: state,
            knobs: nil, savedAt: Date(timeIntervalSince1970: 1_800_000_000))
    }

    @Test("blob の有無は毎回 DB に問う — 手元の思い込みで INSERT を省かない")
    func blobExistenceIsAskedOfTheDatabase() throws {
        // 実機 2026-08-03 の再現: 「FOREIGN KEY constraint failed」が 30 秒ごとに
        // 永続し、音色（fullState）の保存が全部落ちていた。
        //
        // 原因はプロセス内の「もう入れた blob」キャッシュ。DB 側で blob が
        // 消えてもキャッシュは消えないため、storeBlob が INSERT を省いて
        // slot.stateHash が存在しない blob を指す → FK 違反 → ロールバック。
        // しかもロールバックでキャッシュは戻らないので**自己増殖ループ**になる。
        //
        // 乖離をそのまま作る: 同じファイルを開いた別インスタンスに blob を
        // 消させ、元のインスタンスで同じ音色を保存し直す。キャッシュを信じる
        // 実装はここで落ちる
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("ladyland-blob-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: path) }

        let db = try RackDatabase(path: path)
        let tone = Data("KORG-fullstate".utf8)
        let loaded = RackSnapshot(
            slots: [slot(index: 0, name: "Madrid", state: tone)], selected: 0)

        try db.save(loaded, includeBlobs: true)

        // 別インスタンスが席を空にして掃除 — blob は DB から消える
        let other = try RackDatabase(path: path)
        try other.save(RackSnapshot(slots: [], selected: 0), includeBlobs: true)
        _ = try other.collectGarbage()

        // 最初のインスタンスで同じ音色を保存し直す（実機では 30 秒タイマー）
        try db.save(loaded, includeBlobs: true)

        let restored = try #require(try RackDatabase(path: path).load())
        #expect(restored.slots.first?.state == tone)
    }

    /// **画面のテーマも rack.json に同居する**（2026-08-06）。
    /// 「セット一式の持ち運び = このファイル 1 個」（docs/live-setup §5）を守る
    @Test("テーマが往復する — 会場で選んだ見た目が次回も戻る")
    func themeRoundTrip() throws {
        let db = try RackDatabase.inMemory()
        var snapshot = RackSnapshot(slots: [], selected: 0)
        snapshot.theme = "sora/light"
        try db.save(snapshot, includeBlobs: false)

        let loaded = try #require(try db.load())
        #expect(loaded.theme == "sora/light")
    }

    /// ⚠️ Optional なので**テーマ導入前の rack.json もそのまま読める**
    @Test("テーマ未設定でも読める — 旧 rack.json を弾かない")
    func themeMissingIsFine() throws {
        let db = try RackDatabase.inMemory()
        try db.save(RackSnapshot(slots: [], selected: 0), includeBlobs: false)

        let loaded = try #require(try db.load())
        #expect(loaded.theme == nil)
    }

    @Test("ラウンドトリップ — 席・音量・割当・棚・音色が戻る")
    func roundTrip() throws {
        let db = try RackDatabase.inMemory()
        let tone = Data("KORG-fullstate".utf8)
        var snapshot = RackSnapshot(
            slots: [slot(index: 3, name: "Madrid", gain: 0.42, state: tone,
                         drafts: [draft(name: "Madrid alt", state: Data("alt".utf8))])],
            selected: 3)
        snapshot.slots[0].mute = true
        snapshot.slots[0].rotoColor = 22  // azure
        snapshot.slots[0].customName = "Lead"
        snapshot.trackCount = 24
        snapshot.keyRoot = 5
        snapshot.keyScale = "minor"
        snapshot.ledFeedback = false
        snapshot.outputDeviceUID = "zenith-uid"

        try db.save(snapshot, includeBlobs: true)
        let loaded = try #require(try db.load())

        #expect(loaded.selected == 3)
        #expect(loaded.trackCount == 24)
        #expect(loaded.keyRoot == 5)
        #expect(loaded.keyScale == "minor")
        #expect(loaded.ledFeedback == false)
        #expect(loaded.outputDeviceUID == "zenith-uid")
        #expect(loaded.slots.count == 1)
        let restored = try #require(loaded.slots.first)
        #expect(restored.index == 3)
        #expect(restored.name == "Madrid")
        #expect(restored.gain == 0.42)
        #expect(restored.mute == true)
        #expect(restored.rotoColor == 22)
        #expect(restored.customName == "Lead")
        #expect(restored.state == tone, "音色 blob が戻ること")
        #expect(restored.knobs?.first?.name == "Cutoff")
        #expect(restored.drafts?.count == 1)
        #expect(restored.drafts?.first?.state == Data("alt".utf8))
    }

    @Test("blob は内容アドレス — 同じ音色は何着あっても 1 行")
    func blobsAreDeduplicated() throws {
        let db = try RackDatabase.inMemory()
        let same = Data(repeating: 0xAB, count: 4096)
        // 席と棚 3 着すべてが同じ音色
        let snapshot = RackSnapshot(
            slots: [
                slot(index: 0, name: "A", state: same,
                     drafts: [draft(name: "d1", state: same), draft(name: "d2", state: same)]),
                slot(index: 1, name: "B", state: same),
            ],
            selected: 0)
        try db.save(snapshot, includeBlobs: true)

        // 実体は 1 個分のバイト数しか持たない
        #expect(db.fileSize() == 4096, "同一内容の blob が重複排除されること")

        let loaded = try #require(try db.load())
        #expect(loaded.slots.allSatisfy { $0.state == same })
    }

    @Test("軽い保存は音色への参照を壊さない（踏むと再起動で音色が消える）")
    func lightSavePreservesBlobReference() throws {
        let db = try RackDatabase.inMemory()
        let tone = Data("tone".utf8)
        let heavy = RackSnapshot(
            slots: [slot(index: 0, name: "A", gain: 0.8, state: tone,
                         drafts: [draft(name: "d", state: tone)])],
            selected: 0)
        try db.save(heavy, includeBlobs: true)

        // 軽い保存 = AU に触っていないので state は nil で上がってくる
        let light = RackSnapshot(
            slots: [slot(index: 0, name: "A", gain: 0.25, state: nil,
                         drafts: [draft(name: "d", state: nil)])],
            selected: 0)
        try db.save(light, includeBlobs: false)

        let loaded = try #require(try db.load())
        let restored = try #require(loaded.slots.first)
        #expect(restored.gain == 0.25, "目録（音量）は更新されること")
        #expect(restored.state == tone, "音色への参照は維持されること")
    }

    @Test("消えた席と棚は行ごと落ちる（空席化・draft 昇格の後始末）")
    func removedRowsAreDeleted() throws {
        let db = try RackDatabase.inMemory()
        let kept = draft(name: "keep", state: Data("k".utf8))
        try db.save(
            RackSnapshot(
                slots: [
                    slot(index: 0, name: "A", state: Data("a".utf8),
                         drafts: [kept, draft(name: "gone", state: Data("g".utf8))]),
                    slot(index: 1, name: "B", state: Data("b".utf8)),
                ], selected: 0),
            includeBlobs: true)

        // 席 1 を空席にし、draft を 1 着だけ残す
        try db.save(
            RackSnapshot(
                slots: [slot(index: 0, name: "A", state: Data("a".utf8), drafts: [kept])],
                selected: 0),
            includeBlobs: true)

        let loaded = try #require(try db.load())
        #expect(loaded.slots.map(\.index) == [0])
        #expect(loaded.slots.first?.drafts?.count == 1)
        #expect(loaded.slots.first?.drafts?.first?.name == "keep")

        // 参照されなくなった blob（席 B と消えた draft の音色）は保存の中で
        // 既に回収済み — 生きているのは席 A の 1 個だけ
        // 生きているのは席 A の "a" と残した draft の "k" の 2 個だけ
        #expect(db.fileSize() == 2, "孤児 blob（席 B と消えた draft の音色）が残っていないこと")
        #expect(try db.collectGarbage() == 0, "起動時 GC に残り物が無いこと")
        #expect(try db.load()?.slots.first?.state == Data("a".utf8), "生きている音色は残る")
    }

    @Test("重い保存のたびに孤児 blob を回収する（AU が同じ音色でも別バイトを返す）")
    func heavySaveCollectsOrphans() throws {
        let db = try RackDatabase.inMemory()
        // 実機で観測: AU は中身が変わらなくても fullState のバイト列を
        // 変えて返すことがある（2026-08-02、重い保存 2 回で 9MB のゴミ）。
        // 保存のたびに違う blob が積まれても、生きているのは常に最新だけ
        for generation in 0..<10 {
            let churn = Data("state-\(generation)".utf8)
            try db.save(
                RackSnapshot(
                    slots: [slot(index: 0, name: "A", state: churn)], selected: 0),
                includeBlobs: true)
        }
        #expect(
            try db.collectGarbage() == 0,
            "保存のたびに回収済み = 起動時 GC に残り物が無いこと")
        #expect(try db.load()?.slots.first?.state == Data("state-9".utf8), "最新が生きる")
    }

    @Test("rack.json からの移行 — 1 度きり・元ファイルには触らない")
    func legacyImport() throws {
        let legacyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ladyland-legacy-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: legacyURL) }

        var legacy = RackSnapshot(
            slots: [slot(index: 2, name: "Salzburg", gain: 0.9, state: Data("piano".utf8))],
            selected: 2)
        legacy.trackCount = 24
        try RackStore.save(legacy, to: legacyURL)

        let db = try RackDatabase.inMemory()
        #expect(try db.importLegacyIfNeeded(from: legacyURL) == true)
        #expect(try db.load()?.slots.first?.name == "Salzburg")
        #expect(try db.load()?.slots.first?.state == Data("piano".utf8))

        // 2 度目は取り込まない（DB が正になった後に古い JSON で上書きしない）
        #expect(try db.importLegacyIfNeeded(from: legacyURL) == false)
        // 元ファイルは残る（後戻りできる状態を保つ）
        #expect(FileManager.default.fileExists(atPath: legacyURL.path))
    }

    @Test("空の DB は nil を返す（初回起動）")
    func emptyDatabase() throws {
        let db = try RackDatabase.inMemory()
        #expect(try db.load() == nil)
    }

    @Test("再オープンしても残る（ファイル実体での永続性）")
    func survivesReopen() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ladyland-db-\(UUID().uuidString)/ladyland.sqlite")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let first = try RackDatabase(path: url)
        try first.save(
            RackSnapshot(
                slots: [slot(index: 7, name: "Glasgow", state: Data("keys".utf8))],
                selected: 7),
            includeBlobs: true)

        let second = try RackDatabase(path: url)
        let loaded = try #require(try second.load())
        #expect(loaded.selected == 7)
        #expect(loaded.slots.first?.state == Data("keys".utf8))
    }
}

/// 保存でメインを塞がない（2026-08-03 実測: 重い保存が最大 544ms、30 秒ごとに
/// UI がその分固まっていた）。順序保証と「終了時は書き切る」を守りながら
/// 非同期化したので、その 2 点を固定する
@Suite("保存の非同期化")
struct AsyncSaveTests {
    private func slot(index: Int, name: String, state: Data?) -> SlotSnapshot {
        SlotSnapshot(
            index: index, componentType: 1635085685, componentSubType: 100,
            componentManufacturer: 1263553842, name: name, gain: 0.8, state: state,
            knobs: [], drafts: nil)
    }

    @Test("非同期保存は完了後に読み戻せる")
    func asyncSavePersists() async throws {
        let db = try RackDatabase.inMemory()
        let tone = Data("tone".utf8)

        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            db.saveAsync(
                RackSnapshot(slots: [slot(index: 0, name: "Madrid", state: tone)], selected: 0),
                includeBlobs: true
            ) { c.resume(with: $0) }
        }

        let restored = try #require(try db.load())
        #expect(restored.slots.first?.name == "Madrid")
        #expect(restored.slots.first?.state == tone)
    }

    @Test("預けた順に書かれる — 後から預けた状態が最終状態になる")
    func asyncSavesKeepOrder() async throws {
        // 順序が崩れると「途中の状態が最終状態を上書きする」= 演奏中の
        // 変更が巻き戻る。GRDB の DatabaseQueue が直列化することに依存している
        let db = try RackDatabase.inMemory()

        await withTaskGroup(of: Void.self) { group in
            for step in 1...20 {
                db.saveAsync(
                    RackSnapshot(
                        slots: [slot(index: 0, name: "step\(step)", state: nil)],
                        selected: step % 8),
                    includeBlobs: false
                ) { _ in }
            }
            group.addTask {}
        }

        // 最後の 1 本が書き切るのを待つ（同期保存は同じキューの末尾に並ぶ）
        try db.save(
            RackSnapshot(slots: [slot(index: 0, name: "final", state: nil)], selected: 3),
            includeBlobs: false)

        let restored = try #require(try db.load())
        #expect(restored.slots.first?.name == "final")
        #expect(restored.selected == 3)
    }

    @Test("同期保存は戻った時点で書き終わっている（終了時の書き切り）")
    func syncSaveIsDoneOnReturn() throws {
        // プロセスが死ぬ前に書き切る経路。ここが非同期になると
        // willTerminate で状態を失う
        let db = try RackDatabase.inMemory()
        db.saveAsync(
            RackSnapshot(slots: [slot(index: 0, name: "async", state: nil)], selected: 0),
            includeBlobs: false
        ) { _ in }

        try db.save(
            RackSnapshot(slots: [slot(index: 0, name: "sync", state: nil)], selected: 1),
            includeBlobs: false)

        // 待たずに即読む — 同期保存が戻っていれば必ず見える
        let restored = try #require(try db.load())
        #expect(restored.slots.first?.name == "sync")
    }

    @Test("tempoSync=false が SQLite 往復で保持される")
    func tempoSyncRoundTrip() throws {
        let db = try RackDatabase.inMemory()
        var snapshot = RackSnapshot(slots: [], selected: 0)
        snapshot.tempoSync = false

        try db.save(snapshot, includeBlobs: false)

        let loaded = try #require(try db.load())
        #expect(loaded.tempoSync == false)
    }
}
