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
    let component: AVAudioUnitComponent

    var id: String { "\(component.manufacturerName)/\(component.name)" }
    var name: String { component.name }
    var manufacturer: String { component.manufacturerName }
    var description: AudioComponentDescription { component.audioComponentDescription }
}

enum PluginCatalog {
    /// システムの AU インストゥルメントを列挙する（deny list 適用済み）
    static func instruments() -> [InstrumentComponent] {
        var description = AudioComponentDescription()
        description.componentType = kAudioUnitType_MusicDevice

        return AVAudioUnitComponentManager.shared()
            .components(matching: description)
            .filter { !isDenyListed($0.name) }
            .map(InstrumentComponent.init)
            .sorted { ($0.manufacturer, $0.name) < ($1.manufacturer, $1.name) }
    }
}
