//! ROTO の 14bit CC 値組み立て。

import Testing

@testable import Ladyland

@Suite("ROTO の 14bit 値")
struct RotoValue14Tests {
    @Test("MSB の後に LSB が届くと値が完成する")
    func assemblesValue() {
        var value = RotoValue14()
        #expect(value.receive(control: 0, kind: .lsb, value: 127) == nil)
        #expect(value.receive(control: 0, kind: .msb, value: 127) == nil)
        #expect(value.receive(control: 0, kind: .lsb, value: 127) == RotoValue14.maximum)
    }

    @Test("コントロールごとの MSB を混線させない")
    func keepsControlsIndependent() {
        var value = RotoValue14()
        _ = value.receive(control: 2, kind: .msb, value: 1)
        _ = value.receive(control: 3, kind: .msb, value: 2)
        #expect(value.receive(control: 2, kind: .lsb, value: 3) == 131)
        #expect(value.receive(control: 3, kind: .lsb, value: 4) == 260)
    }

    @Test("同じ MSB で LSB だけを更新できる")
    func reusesMostRecentMsb() {
        var value = RotoValue14()
        _ = value.receive(control: 0, kind: .msb, value: 64)
        #expect(value.receive(control: 0, kind: .lsb, value: 0) == 8_192)
        #expect(value.receive(control: 0, kind: .lsb, value: 1) == 8_193)
        #expect(value.receive(control: 0, kind: .touch, value: 127) == nil)
    }

    @Test("14bit の両端を 0...1 へ正規化する")
    func normalizesValue() {
        #expect(RotoValue14.normalized(0) == 0)
        #expect(RotoValue14.normalized(RotoValue14.maximum) == 1)
        #expect(RotoValue14.normalized(-1) == 0)
        #expect(RotoValue14.normalized(RotoValue14.maximum + 1) == 1)
    }
}
