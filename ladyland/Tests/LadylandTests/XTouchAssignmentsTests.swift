// mem_1CfpRU9jTnXL4MeK2kfE42 — Jack / VirtualDesk の X-Touch Mixer Surface
import Testing
@testable import Ladyland

@Suite("X-Touch assignment reference")
struct XTouchAssignmentsTests {
    @Test("割当一覧が実際に受ける全ボタンを漏れなく示す")
    func mappedButtons() {
        let decoded = Set((UInt8(0)...UInt8(0x67)).filter { XTouchMCU.decode(0x90, $0, 127) != nil })
        let documented = Set(XTouchAssignments.all.filter(\.assigned).flatMap { $0.notes.map(Array.init) ?? [] })
        #expect(documented == decoded)
        #expect(Set(XTouchAssignments.all.map(\.id)).count == XTouchAssignments.all.count)
    }

    @Test("未割当RECは録音できるように見せず、操作してもイベントを出さない")
    func unassignedRecord() throws {
        let rec = try #require(XTouchAssignments.all.first { $0.id == "rec" })
        #expect(!rec.assigned)
        for note in try #require(rec.notes) {
            #expect(XTouchMCU.decode(0x90, note, 127) == nil)
        }
        #expect(XTouchAssignments.all.contains { $0.id == "transport" && !$0.assigned })
    }
}
