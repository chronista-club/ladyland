//! 機材の 3D 資産は midistage が正本（midistage docs/design/04、mako「midistage に集めるか。3D モデルも。」）。
//! Ladyland は midistage の置き場を優先し、無ければ従来の `ladyland/gear` にフォールバックする。
//! 機材 ID は inventory の ID（numa / fgdp）に揃い、机の配置に残る旧 ID（ncxse / fgdp50）は読み替える。

import Foundation
import Testing

@testable import Ladyland

@Suite("機材資産の置き場")
struct GearAssetsTests {
    private func temp() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    @Test("manifest.json のある midistage の置き場を優先する")
    func prefersMidistageWhenManifestExists() throws {
        let studio = try temp(), midistage = try temp()
        try Data("{}".utf8).write(to: midistage.appendingPathComponent("manifest.json"))
        #expect(GearAssets.gearDirectory(studio: studio, midistage: midistage) == midistage)
    }

    @Test("midistage の置き場が無い / manifest が無いときは従来の置き場")
    func fallsBackToStudio() throws {
        let studio = try temp(), empty = try temp()
        #expect(GearAssets.gearDirectory(studio: studio, midistage: empty) == studio)
        #expect(GearAssets.gearDirectory(studio: studio, midistage: studio.appendingPathComponent("nope")) == studio)
    }

    @Test("旧 ID は inventory の ID に読み替える（ncxse → numa、fgdp50 → fgdp）")
    func canonicalIDs() {
        #expect(GearAssets.canonical("ncxse") == "numa")
        #expect(GearAssets.canonical("fgdp50") == "fgdp")
        #expect(GearAssets.canonical("lpd8") == "lpd8")
    }

    @Test("カタログは旧 ID でも新 ID でも引ける")
    func lookupByEitherID() {
        let numa = GearBlueprint(id: "numa", title: "Numa", size: [1, 1, 1], parts: [], sections: [])
        let catalog = ["numa": numa]
        #expect(GearAssets.lookup(catalog, id: "ncxse")?.id == "numa")
        #expect(GearAssets.lookup(catalog, id: "numa")?.id == "numa")
        #expect(GearAssets.lookup(catalog, id: "roto") == nil)
    }

    @Test("midistage の JSON（model / blend_root / control 付き）もそのまま読める")
    func decodesMidistageJSON() throws {
        let json = """
        {"id":"numa","title":"Numa Compact X SE","model":"Numa Compact X SE","blend_root":"ncxse",
         "size":[1270,224,100],"body_height":45,
         "parts":[{"name":"drawbar_1","kind":"fader","center":[0,0],"size":[8,20,10],"travel":30,"control":"fader.0"}],
         "sections":[{"id":"numa.drawbars","kind":"faders","parts":["drawbar_1"],"ccs":[]}]}
        """
        let b = try GearBlueprint.decode(Data(json.utf8))
        #expect(b.id == "numa")
        #expect(b.parts.first?.kind == .fader)
    }
}
