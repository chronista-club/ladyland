//! 機材の 3D 資産の置き場（midistage docs/design/04。mako 2026-10-10
//! 「midistage に集めるか。3D モデルも。」→「C で」）。
//!
//! 機材の形・実寸・操作子の対応は機材の事実なので、正本は midistage に移った。
//! midistage の `build.py` が `~/Library/Application Support/midistage/gear/` に
//! `<id>.usdz` / `<id>.json` / `manifest.json` を書く。Ladyland はそこを優先し、
//! 無ければ従来の `ladyland/gear`（studio_export.py の出力）にフォールバックする。
//! 机・棚・環境光（desk.usdz / desk_layout.json / environment.exr）はアプリの産物なので
//! 従来の置き場のまま。

import Foundation

enum GearAssets {
    /// midistage の配布物の置き場
    nonisolated static let midistageDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/midistage/gear")

    /// 旧 ID（Ladyland 時代の資産名）→ inventory の profile ID
    static let legacyIDs: [String: String] = ["ncxse": "numa", "fgdp50": "fgdp"]

    /// 機材の JSON / USDZ を読む場所。manifest.json のある midistage の置き場を優先
    static func gearDirectory(studio: URL, midistage: URL = midistageDirectory) -> URL {
        FileManager.default.fileExists(atPath: midistage.appendingPathComponent("manifest.json").path)
            ? midistage : studio
    }

    static func canonical(_ id: String) -> String { legacyIDs[id] ?? id }

    /// 机の配置（desk_layout.json）に旧 ID が残っていても引ける
    static func lookup(_ catalog: [String: GearBlueprint], id: String) -> GearBlueprint? {
        catalog[id] ?? catalog[canonical(id)]
    }
}
