//! 差分焼きの影の規律 — 「変わった席だけ焼く」「信頼が崩れたら全部捨てる」

import Foundation
import Testing

@testable import Ladyland

@Suite("差分焼きの影")
struct RotoDiffShadowTests {
    private typealias Key = RotoMidiSetupExport.SeatKey

    private func requests(names: [String]) -> [(key: Key, request: [UInt8])] {
        RotoMidiSetupExport.allRequests(slotNames: names)
    }

    private let base = (0..<32).map { "T\($0 + 1)" }

    @Test("影が無い間は沈黙 — 全焼き前に中途半端な差分を撃たない")
    func silentBeforePrime() {
        var shadow = RotoDiffShadow()
        #expect(shadow.isPrimed == false)
        #expect(shadow.pending(requests(names: base)).isEmpty)
    }

    @Test("全焼き直後は差分ゼロ — 同じ姿を焼き直さない")
    func noDiffAfterPrime() {
        var shadow = RotoDiffShadow()
        shadow.prime(requests(names: base))
        #expect(shadow.pending(requests(names: base)).isEmpty)
    }

    @Test("1 席の名前変更はその席のぶんだけ — 全 96 席を焼き直さない")
    func oneSeatChange() {
        var shadow = RotoDiffShadow()
        shadow.prime(requests(names: base))
        var renamed = base
        renamed[2] = "Lead"
        // T3 の変更が及ぶのは MIXER のノブ 1 席だけ（選択ボタンは番号固定の
        // 最小表現になったので名前に追従しない — 2026-08-13）
        let pending = shadow.pending(requests(names: renamed))
        #expect(pending.count == 1)
        // 返した分は影が進む — 同じ姿の再要求は沈黙
        #expect(shadow.pending(requests(names: renamed)).isEmpty)
    }

    @Test("ライブラベルの変更は INST 冊の席だけに及ぶ")
    func liveLabelChange() {
        var shadow = RotoDiffShadow()
        shadow.prime(requests(names: base))
        let pending = shadow.pending(
            RotoMidiSetupExport.allRequests(slotNames: base, seatLabels: [0: "Cutoff"]))
        #expect(pending.count == 1)  // CC0 の席（SETUP 02 のノブ 1）だけ
    }

    @Test("影は Codable で往復する — 再起動しても差分焼きが即効く")
    func shadowRoundTrips() throws {
        var shadow = RotoDiffShadow()
        shadow.prime(requests(names: base))
        let data = try JSONEncoder().encode(shadow)
        var restored = try JSONDecoder().decode(RotoDiffShadow.self, from: data)
        #expect(restored.isPrimed)
        #expect(restored.pending(requests(names: base)).isEmpty, "同じ姿なら差分ゼロ")
        var renamed = base
        renamed[2] = "Lead"
        #expect(restored.pending(requests(names: renamed)).count == 1)
    }

    @Test("invalidate で影ごと捨てる — 書き込み失敗後は全焼きまで沈黙")
    func invalidateSilences() {
        var shadow = RotoDiffShadow()
        shadow.prime(requests(names: base))
        shadow.invalidate()
        #expect(shadow.isPrimed == false)
        var renamed = base
        renamed[0] = "Lead"
        #expect(shadow.pending(requests(names: renamed)).isEmpty)
    }
}
