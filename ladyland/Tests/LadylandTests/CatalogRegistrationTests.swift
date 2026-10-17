//! 自作楽器（Lady MPE / Lady Sampler）が**いつでも**カタログに載る。
//!
//! CI で数回に 1 回、`rack.catalog` に自作楽器が無くてテストが落ちていた
//! （UnloadTests / FocusPaneTests、2026-10 に 3 回）。`registerSubclass` は
//! `AVAudioUnitComponentManager` の一覧へ**非同期に**届き、その更新はメインキューで
//! 処理される — メインスレッドで同期的に待っても現れない（2026-10-17 実測）。
//! プロセスで最初のラックだけが当たるので、テストの並びで落ちる場所が変わっていた。
//! 自作楽器は記述も名前も分かっているので、一覧の到着を待たずにカタログへ足す。

import AVFoundation
import Testing

@testable import Ladyland

@Suite("カタログの合わせ方")
struct CatalogMergeTests {
    private func entry(_ name: String, _ subtype: OSType) -> InstrumentComponent {
        InstrumentComponent(name: name, manufacturer: "", description: AudioComponentDescription(
            componentType: kAudioUnitType_MusicDevice, componentSubType: subtype,
            componentManufacturer: LadySynth.componentManufacturer, componentFlags: 0, componentFlagsMask: 0))
    }

    @Test("一覧にまだ無い自作楽器は足す")
    func addsMissing() {
        let listed = [InstrumentComponent(name: "Serum", manufacturer: "Xfer", description: AudioComponentDescription())]
        let merged = PluginCatalog.merge(listed, builtIns: [entry("Lady MPE", 1), entry("Lady Sampler", 2)])
        #expect(Set(merged.map(\.name)) == ["Serum", "Lady MPE", "Lady Sampler"])
    }

    @Test("一覧に既にあれば足さない（記述で見る）")
    func skipsListed() {
        let merged = PluginCatalog.merge([entry("Lady MPE", 1)], builtIns: [entry("Lady MPE", 1)])
        #expect(merged.count == 1)
    }

    @Test("並びは メーカー → 名前")
    func sorted() {
        let merged = PluginCatalog.merge(
            [InstrumentComponent(name: "B", manufacturer: "Z", description: AudioComponentDescription())],
            builtIns: [entry("Lady MPE", 1)])
        #expect(merged.map(\.name) == ["Lady MPE", "B"])
    }
}

@Suite("自作楽器の登録", .serialized)
@MainActor
struct CatalogRegistrationTests {
    @Test("プロセスで最初のラックでも、カタログに自作楽器が載る")
    func builtInsInFirstRackCatalog() {
        let names = Set(InstrumentRack().catalog.map(\.name))
        #expect(names.contains(LadySynth.displayName))
        #expect(names.contains(LadySampler.displayName))
    }

    @Test("一覧に届く前でも、自作楽器は載せられる")
    func builtInLoadsBeforeListed() async throws {
        let rack = InstrumentRack()
        try rack.start()
        defer { rack.engine.stop() }
        rack.engine.mainMixerNode.outputVolume = 0
        let synth = try #require(rack.catalog.first { $0.name == LadySynth.displayName })
        try await rack.load(synth, into: rack.slots[0])
        #expect(rack.slots[0].audioUnit != nil)
    }

    @Test("一覧に既に載っていれば二重にしない")
    func noDuplicates() async throws {
        _ = InstrumentRack()
        for _ in 0..<150 where !PluginCatalog.instruments().contains(where: { $0.name == LadySynth.displayName }) {
            try await Task.sleep(for: .milliseconds(20))
        }
        let catalog = InstrumentRack().catalog
        #expect(catalog.filter { $0.name == LadySynth.displayName }.count == 1)
        #expect(catalog.filter { $0.name == LadySampler.displayName }.count == 1)
    }
}
