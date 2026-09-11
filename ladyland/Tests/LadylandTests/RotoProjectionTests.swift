import RotoKit
import Testing

@testable import Ladyland

@Suite("ROTO 表示の差分投影")
struct RotoProjectionTests {
    @Test("SMART は変わったセルだけ送り、空席設定と割当状態を区別する")
    func smartDiff() {
        var shadow = RotoShadow()
        let cells = [
            RotoProjection.SmartCell(
                deviceCell: 0, isMapped: true, label: "Cutoff", color: 21),
            RotoProjection.SmartCell(
                deviceCell: 1, isMapped: false, label: "-", color: 2),
            // 名前を解決できなくても、割当済みなら活性状態を伝える。
            RotoProjection.SmartCell(
                deviceCell: 2, isMapped: true, label: "-", color: 3),
        ]

        let first = RotoProjection.smartMessages(
            cells: cells, fillsEmpty: false, shadow: &shadow)
        #expect(first == [
            Roto.setPluginControlDetails(0, name: "Cutoff", color: 21),
            Roto.setPluginControlDetails(2, name: "-", color: 3),
        ])
        #expect(shadow.label[0] == "21|Cutoff")
        #expect(shadow.label[1] == nil, "送らなかった空席は影にも残さない")
        #expect(shadow.label[2] == "3|-")

        #expect(
            RotoProjection.smartMessages(
                cells: cells, fillsEmpty: false, shadow: &shadow
            ).isEmpty,
            "同じ表示は送り直さない")

        let filled = RotoProjection.smartMessages(
            cells: cells, fillsEmpty: true, shadow: &shadow)
        #expect(filled == [Roto.setPluginControlDetails(1, name: "-", color: 2)])
    }

    @Test("MAIN LCD は初回だけ据え、以後は文字と色の差分だけ送る")
    func mainLcdSequence() {
        var shadow = RotoShadow()
        let color = Roto.Color.red

        let first = RotoProjection.mainLcdMessages(
            track: 20, text: "Berlin    #1", color: color,
            enabled: true, shadow: &shadow)
        #expect(first == [
            Roto.selectFocusTrack(
                15, name: "Berlin    #1", red: 255, green: 0, blue: 0),
            Roto.setMenuText("Berlin    #1"),
            Roto.setMenuColor(red: 255, green: 0, blue: 0),
        ])
        #expect(shadow.menu == "\(color)|Berlin    #1")
        #expect(
            RotoProjection.mainLcdMessages(
                track: 20, text: "Berlin    #1", color: color,
                enabled: true, shadow: &shadow
            ).isEmpty)

        let changed = RotoProjection.mainLcdMessages(
            track: 20, text: "Berlin    #2", color: color,
            enabled: true, shadow: &shadow)
        #expect(changed == [
            Roto.setMenuText("Berlin    #2"),
            Roto.setMenuColor(red: 255, green: 0, blue: 0),
        ])
    }

    @Test("無効な MAIN LCD 投影は影も進めない")
    func disabledMainLcd() {
        var shadow = RotoShadow()
        let messages = RotoProjection.mainLcdMessages(
            track: 0, text: "#1", color: Roto.Color.black,
            enabled: false, shadow: &shadow)

        #expect(messages.isEmpty)
        #expect(shadow.menu == nil)
    }

    @Test("Bitwig の一覧は枠付きバッチと選択通知を一組で差分送信する")
    func trackBatchDiff() {
        var shadow = RotoShadow()
        let names = ["Berlin", "Paris"]

        let first = RotoProjection.trackMessages(
            names: names, selected: 1, shadow: &shadow)
        #expect(first == Roto.trackBatch(names) + [Roto.selectedTrack(1, name: "Paris")])
        #expect(
            RotoProjection.trackMessages(
                names: names, selected: 1, shadow: &shadow
            ).isEmpty)

        let outside = RotoProjection.trackMessages(
            names: names, selected: 20, shadow: &shadow)
        #expect(outside == Roto.trackBatch(names), "MIX 面の外には選択通知を送らない")
    }
}
