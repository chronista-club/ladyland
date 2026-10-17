//! AU インストゥルメントのカタログ（design/06 §4）。
//!
//! AVAudioUnitComponentManager で AU Instrument を列挙する。
//! Splice Sounds は deny list で遮断（design/06 §5-1: AU Instrument を自称する
//! サンプルブラウザで、ホストすると main thread の RunLoop コールバック内で
//! null mutex を lock して SIGSEGV する。cortex 時代の実機クラッシュより）。

import AVFoundation

/// ホスティング不適合プラグインの deny list（名前の部分一致）
let hostingDenyList = ["Splice"]

/// deny list 判定 — 純関数（テスト対象）
func isDenyListed(_ name: String) -> Bool {
    hostingDenyList.contains { name.contains($0) }
}

/// カタログ上の 1 エントリ
struct InstrumentComponent: Identifiable, Hashable {
    let name: String
    let manufacturer: String
    let description: AudioComponentDescription

    var id: String { "\(manufacturer)/\(name)" }

    init(name: String, manufacturer: String, description: AudioComponentDescription) {
        self.name = name
        self.manufacturer = manufacturer
        self.description = description
    }

    init(component: AVAudioUnitComponent) {
        self.init(
            name: component.name, manufacturer: component.manufacturerName,
            description: component.audioComponentDescription)
    }

    /// 同じ楽器か（種類・サブタイプ・メーカーの 4 文字コードで見る）
    func isSame(as other: InstrumentComponent) -> Bool {
        description.componentType == other.description.componentType
            && description.componentSubType == other.description.componentSubType
            && description.componentManufacturer == other.description.componentManufacturer
    }

    static func == (a: InstrumentComponent, b: InstrumentComponent) -> Bool {
        a.id == b.id && a.isSame(as: b)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(description.componentSubType)
        hasher.combine(description.componentManufacturer)
    }
}

enum PluginCatalog {
    /// システムの AU インストゥルメントを列挙する（deny list 適用済み）
    ///
    /// `builtIns` = プロセス内登録の自作楽器。**`registerSubclass` は一覧へ非同期に届く**
    /// （更新はメインキューで処理されるので、メインスレッドで同期的に待っても現れない。
    /// 2026-10-17 実測: 登録した直後に引くと 30 回中 29 回は無い）。記述も名前も分かって
    /// いるので、一覧の到着を待たずに足す。読み込みは記述で行うので一覧に無くても載る
    static func instruments(builtIns: [InstrumentComponent] = []) -> [InstrumentComponent] {
        var description = AudioComponentDescription()
        description.componentType = kAudioUnitType_MusicDevice

        let listed = AVAudioUnitComponentManager.shared()
            .components(matching: description)
            .filter { !isDenyListed($0.name) }
            .map(InstrumentComponent.init(component:))
        return merge(listed, builtIns: builtIns)
    }

    /// 一覧に無い自作楽器だけ足して、メーカー → 名前の順に並べる
    static func merge(_ listed: [InstrumentComponent], builtIns: [InstrumentComponent]) -> [InstrumentComponent] {
        let missing = builtIns.filter { builtIn in !listed.contains { $0.isSame(as: builtIn) } }
        return (listed + missing).sorted { ($0.manufacturer, $0.name) < ($1.manufacturer, $1.name) }
    }
}
