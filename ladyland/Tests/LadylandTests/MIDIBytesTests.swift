//! 切替作法（All Notes Off）のテスト。
//!
//! cortex から持ち越した作法（design/06 §5-3）を固定する:
//! 全 16ch に CC64=0（サスティンオフ）→ CC123（All Notes Off）。
//! サスティンが踏まれたまま切り替わると鳴り続けるため、順序も仕様。

import Testing

@testable import Ladyland

@Suite("MIDIBytes")
struct MIDIBytesTests {
    @Test("全 16ch × (サスティンオフ + All Notes Off) = 32 メッセージ")
    func coversAllChannels() {
        let messages = MIDIBytes.allNotesOff()
        #expect(messages.count == 32)

        let sustainOffs = messages.filter { $0[1] == 64 && $0[2] == 0 }
        let allNotesOffs = messages.filter { $0[1] == 123 && $0[2] == 0 }
        #expect(sustainOffs.count == 16)
        #expect(allNotesOffs.count == 16)
    }

    @Test("すべて CC (0xB0) で、チャンネルが 0-15 を網羅する")
    func statusBytes() {
        let messages = MIDIBytes.allNotesOff()
        #expect(messages.allSatisfy { $0[0] & 0xF0 == 0xB0 })

        let channels = Set(messages.map { $0[0] & 0x0F })
        #expect(channels == Set(0..<16))
    }

    @Test("各チャンネルでサスティンオフが All Notes Off より先に送られる")
    func sustainOffComesFirst() {
        let messages = MIDIBytes.allNotesOff()
        for channel: UInt8 in 0..<16 {
            let indexOfSustain = messages.firstIndex { $0[0] == 0xB0 | channel && $0[1] == 64 }
            let indexOfNotesOff = messages.firstIndex { $0[0] == 0xB0 | channel && $0[1] == 123 }
            #expect(indexOfSustain != nil && indexOfNotesOff != nil)
            if let s = indexOfSustain, let n = indexOfNotesOff {
                #expect(s < n, "ch\(channel): サスティンオフが先であること")
            }
        }
    }
}
