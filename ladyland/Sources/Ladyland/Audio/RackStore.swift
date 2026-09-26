//! ラック構成の永続化（design/06 §2・§4）。
//!
//! 「アプリ再開した時に、自分の楽器がそのまま並んでいる」の実体。
//! 各スロットの AU 識別子 + fullState blob + gain を JSON で
//! Application Support に保存し、起動時に復元する。
//!
//! 音色の分担（design/06 §2）: 作る場所はプラグイン自身の画面、
//! 残す仕組みがこのホスト側保存。プリセットとして保存し忘れた
//! いじりかけの状態も fullState ごと戻る（DAW のプロジェクト保存と同じ層）。

import AVFoundation

/// Track の棚にある 1 着 — プラグイン + 音色 + 手元の割当（design/06 §8 Drafts。
/// mako 発案 2026-08-01「工房と舞台の分離」）。
/// 差し替えのたびに暗黙生成されるので、音色が構造的に消えない
struct Draft: Codable, Equatable, Identifiable {
    var id: UUID

    // AudioComponentDescription の識別 3 要素
    var componentType: UInt32
    var componentSubType: UInt32
    var componentManufacturer: UInt32

    /// プラグイン表示名
    var name: String

    var gain: Float

    /// auAudioUnit.fullState の blob
    var state: Data?

    var knobs: [FaceKnobMapping]?

    /// 棚に入った時刻（メニュー表示で個体識別の手掛かりになる）
    var savedAt: Date

    var description: AudioComponentDescription {
        var desc = AudioComponentDescription()
        desc.componentType = componentType
        desc.componentSubType = componentSubType
        desc.componentManufacturer = componentManufacturer
        return desc
    }
}

/// スロット 1 つ分のスナップショット
struct SlotSnapshot: Codable {
    /// スロット位置（0-7 = 楽器、8 = ドラムスロット）
    var index: Int

    // AudioComponentDescription の識別 3 要素
    var componentType: UInt32
    var componentSubType: UInt32
    var componentManufacturer: UInt32

    /// 表示名（復元失敗時のエラー表示にも使う）
    var name: String

    /// スロット音量
    var gain: Float

    /// ミュート（nil = off。ROTO MIXER 冊の TOGGLE ボタンと連動 — 実機が主、
    /// こちらは追従。optional なので導入前の rack.json もそのまま読める）
    var mute: Bool?

    /// トラックカラー（ROTO 83 色パレットの index。nil = 未設定）。
    /// 席の属性 — 楽器を差し替えても残る
    var rotoColor: UInt8?

    /// トラック名（nil = プラグイン名にフォールバック）。席の属性
    var customName: String?

    /// auAudioUnit.fullState を PropertyList 化した blob
    var state: Data?

    /// Keystage ノブ → AU パラメータの顔つまみ割当（P4）。
    /// optional なので割当導入前の rack.json もそのまま読める（後方互換）
    var knobs: [FaceKnobMapping]?

    /// この席の棚（非アクティブ draft。nil = 導入前の旧ファイル = 棚なし）
    var drafts: [Draft]?

    /// **この席の既定**（mako 要望 2026-08-06「set default / load default が欲しい」）。
    /// 中身は draft と同じ（音色 + 割当）だが、**選んでも消えない**のが違い。
    /// ⚠️ Optional なので、この列を知らない旧 Snapshot もそのまま読める
    var defaultSnapshot: Draft?

    var description: AudioComponentDescription {
        var desc = AudioComponentDescription()
        desc.componentType = componentType
        desc.componentSubType = componentSubType
        desc.componentManufacturer = componentManufacturer
        return desc
    }
}

/// ラック全体のスナップショット
struct RackSnapshot: Codable {
    /// ロード済みスロットのみ（空スロットは含まない）
    var slots: [SlotSnapshot]
    var selected: Int

    /// 選択した出力デバイスの UID（design/06 §8）。
    /// optional なので導入前の rack.json もそのまま読める（後方互換の慣習）
    var outputDeviceUID: String?

    /// LPD8 LED フィードバックのキルスイッチ（design/06 §8。nil = 有効）
    var ledFeedback: Bool?

    /// 画面のテーマ（`"mint/dark"`）。nil = 既定（mint / dark）。
    /// **family と appearance を 1 列に畳む** — 設定 1 つに列 2 本を足すより、
    /// 増えたときに移行が楽（`ThemeStore.persistedValue`）
    var theme: String?

    /// キー/スケール（design/06 §8。nil = C メジャー既定）
    var keyRoot: Int?
    var keyScale: String?

    /// ダンパーペダルの役割（mako 裁定 2026-08-03。nil = keep = 従来の挙動）
    var pedalMode: String?

    /// ダンパーペダルの極性反転（mako 報告 2026-08-14「キープが逆」。
    /// nil = false = MIDI 標準の向き）
    var pedalInverted: Bool?

    /// 鍵盤 2（NCXse）の担当スロット（nil = 選択に追従。2nd キーボード計画 ②、
    /// 2026-08-10 追加 — mako「別々の二つの音源同時に弾きたい」）
    var secondKeyboardSlot: Int?

    /// シンセ入力 1（Keystage）の担当スロット（spec/09 Jack。nil = 選択追従）
    var synthInput1Slot: Int?

    /// LPD8 ノブ 8 の刺し先（`Lpd8KnobJack` の raw 値。nil = drums = 従来。
    /// mako 裁定 2026-09-26「Keystage のつまみの役は LPD8 で」）
    var lpd8KnobJack: String?

    /// Keystage の ARP / CHORD 設定（JSON。mako 裁定 2026-08-04「ラック全体で
    /// 1 セット」）。nil = 未保存 = 起動時に実機から読んだ値をそのまま使う
    var keystage: String?

    /// ROTO の配色（JSON。83 色パレットの index を用途ごとに持つ）
    var rotoColors: String?
    /// テンポ同期（Keystage の Clock を AU へ渡すか）。nil = 既定 = 入
    var tempoSync: Bool?

    /// 保存時のトラック総数 N（design/06 §8 表示窓。nil = 総数 8 の旧ファイル。
    /// ドラムの index は「= トラック総数」規約なので、この値が復元の鍵）
    var trackCount: Int?

    /// 表示窓の左端 a（nil = 選択追従で決める）
    var windowStart: Int?
}

enum RackStore {
    /// 保存先: ~/Library/Application Support/ladyland/rack.json
    static var url: URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0]
        return base.appendingPathComponent("ladyland/rack.json")
    }

    /// スナップショットの正準エンコード。キー順を固定（sortedKeys）する —
    /// 素の JSONEncoder はキー順が実行ごとに揺れ、常時保存の
    /// 「前回書いたバイト列と同じなら書かない」dedup が壊れるため
    static func encode(_ snapshot: RackSnapshot) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(snapshot)
    }

    static func save(_ snapshot: RackSnapshot, to destination: URL = url) throws {
        try write(try encode(snapshot), to: destination)
    }

    /// エンコード済みバイト列を書く（常時保存の dedup 用に encode と write を
    /// 分離 — AppState が「前回書いた内容と同じなら書かない」を判定できる）
    static func write(_ data: Data, to destination: URL = url) throws {
        let dir = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try data.write(to: destination, options: .atomic)
    }

    static func load(from source: URL = url) -> RackSnapshot? {
        guard let data = try? Data(contentsOf: source) else { return nil }
        return try? JSONDecoder().decode(RackSnapshot.self, from: data)
    }

    /// fullState ([String: Any]) ⇄ Data の変換
    static func encodeState(_ state: [String: Any]?) -> Data? {
        guard let state else { return nil }
        return try? PropertyListSerialization.data(
            fromPropertyList: state, format: .binary, options: 0
        )
    }

    static func decodeState(_ data: Data?) -> [String: Any]? {
        guard let data else { return nil }
        let plist = try? PropertyListSerialization.propertyList(from: data, format: nil)
        return plist as? [String: Any]
    }
}
