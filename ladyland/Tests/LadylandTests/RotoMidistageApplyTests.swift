// mem_1Cg9RCew1FXTqxVCJjgcrs
import Foundation
import Testing
import MidistageClient
import RotoKit
@testable import Ladyland

@Suite @MainActor
struct RotoMidistageApplyTests {
    @Test func booksMapToServiceContractAndOmittedSeatsStayAbsent() throws {
        let books = RotoMidiSetupExport.books(slotNames: ["Piano"], seatLabels: [0: "Cutoff", 63: "Release"],
                                              assignedSeatsOnly: true, selectedTrack: 1)
        let payloads = try books.map(RotoMidiSetupExport.servicePayload)
        #expect(payloads.map(\.setup) == [0, 1, 2, 3])
        let mixer = try #require(payloads.first?.content)
        #expect(mixer.name == "MIXER-")
        #expect(mixer.knobs.count == 32 && mixer.switches.count == 32)
        #expect(mixer.knobs[0] == KnobConfig(control: 0, mode: .cc7, channel: 2, param: 0,
                    max: 127, name: ">Piano", color: 36, haptics: .smooth(indents: [])))
        #expect(payloads[1].content.knobs.last?.param == 63)
        #expect(payloads[1].content.switches.last?.param == 127)
        #expect(mixer.switches[0] == SwitchConfig(control: 0, mode: .cc7, channel: 2, param: 64,
                    max: 127, name: "T1", color: Int(Roto.Color.darkGreen), ledOn: 13, ledOff: 70, action: .push))
        #expect(payloads[2].content.knobs.map(\.control) == [0])
        #expect(payloads[3].content.knobs.map(\.control) == [31])
        #expect(payloads[3].content.knobs.first?.param == 63)
        #expect(payloads[3].content.knobs.first?.channel == 1)
        #expect(payloads[2].content.switches.isEmpty && payloads[3].content.switches.isEmpty)
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(mixer)) as? [String: Any]
        let knob = try #require((encoded?["knobs"] as? [[String: Any]])?.first)
        #expect(knob["nrpn_address"] as? Int == 0)
        #expect((knob["haptics"] as? [String: Any])?["kind"] as? String == "smooth")
    }

    @Test func namesUsePrintableASCII12AndToggleIsPreserved() throws {
        let book = RotoMidiSetupExport.Book(setupIndex: 2, name: "ABCDEFGHIJKLM",
            knobs: [.init(controlIndex: 0, channel: 16, cc: 127, name: "音\nCutoff123456789", colorScheme: 82)],
            buttons: [.init(controlIndex: 31, channel: 1, cc: 0, name: "Toggle", colorScheme: 0,
                            ledOn: 82, ledOff: 0, toggle: true)])
        let payload = try RotoMidiSetupExport.servicePayload(book)
        #expect(payload.content.name == "ABCDEFGHIJKL")
        #expect(payload.content.knobs[0].name == "??Cutoff1234")
        #expect(payload.content.switches[0].action == .toggle)
    }

    @Test func invalidControlsAndForeignSetupsAreRejected() {
        func book(setup: Int = 0, control: Int = 0, channel: Int = 1, cc: Int = 0, color: UInt8 = 0) -> RotoMidiSetupExport.Book {
            .init(setupIndex: setup, name: "Test", knobs: [.init(controlIndex: control, channel: channel,
                  cc: cc, name: "Test", colorScheme: color)], buttons: [])
        }
        for invalid in [book(setup: 8), book(control: 32), book(control: -1), book(channel: 0),
                        book(channel: 17), book(cc: 128), book(cc: -1), book(color: 83)] {
            #expect(throws: (any Error).self) { try RotoMidiSetupExport.servicePayload(invalid) }
        }
        let duplicate = book()
        #expect(throws: (any Error).self) {
            try RotoMidiSetupExport.servicePayload(.init(setupIndex: 0, name: "Test",
                     knobs: duplicate.knobs + duplicate.knobs, buttons: []))
        }
        #expect(throws: (any Error).self) {
            try RotoMidiSetupExport.servicePayload(.init(setupIndex: 0, name: "Test", knobs: [],
                buttons: [.init(controlIndex: 0, channel: 1, cc: 0, name: "Test", colorScheme: 0,
                                ledOn: 83, ledOff: 0, toggle: false)]))
        }
    }
    @Test func completionRequiresNewSnapshotAndSameLeaseAndPropagatesConfigError() throws {
        let accepted = try rotoSnapshot(sequence: 2, configuring: true)
        #expect(try !MIDIUseSession.configurationFinished(accepted, accepted: accepted, token: "roto-lease"))
        var current = try rotoSnapshot(sequence: 3)
        // Apply は現在の冊を切り替えない。書いた冊の番号とは比較しない。
        current.devices[0].currentSetup = 0
        #expect(try MIDIUseSession.configurationFinished(current, accepted: accepted, token: "roto-lease"))
        current.devices[0].configError = "readback mismatch"
        #expect(throws: MIDIUseError.self) {
            try MIDIUseSession.configurationFinished(current, accepted: accepted, token: "roto-lease")
        }
        current.devices[0].configError = nil
        current.devices[0].configuring = true
        #expect(try !MIDIUseSession.configurationFinished(current, accepted: accepted, token: "roto-lease"))
        current.devices[0].configuring = false
        current.sequence = 1
        #expect(try !MIDIUseSession.configurationFinished(current, accepted: accepted, token: "roto-lease"))
        current.sequence = 3
        current.sessionID = "other-session"
        #expect(throws: MIDIUseError.self) {
            try MIDIUseSession.configurationFinished(current, accepted: accepted, token: "roto-lease")
        }
        current.sessionID = accepted.sessionID
        #expect(throws: MIDIUseError.self) {
            try MIDIUseSession.configurationFinished(current, accepted: accepted, token: "old-lease")
        }
        current.serverEpoch = "restarted"
        #expect(throws: MIDIUseError.self) {
            try MIDIUseSession.configurationFinished(current, accepted: accepted, token: "roto-lease")
        }
    }

}

@Test(.enabled(if: ProcessInfo.processInfo.environment["MIDISTAGE_TEST_SERVER"] != nil))
@MainActor func rotoSessionApplyWaitsForCompletionWithoutSelectingTheWrittenSetup() async throws {
    let fixture = try await RotoServiceFixture.start()
    defer { fixture.stop() }
    let session = MIDIUseSession(endpointURL: fixture.endpoint, nativeMIDI: false)
    var releases = 0
    session.onReleased = { if $0.deviceID == "roto" { releases += 1 } }
    session.start()
    do {
        try await waitForRotoCondition {
            session.devices.first(where: { $0.deviceID == "roto" })?.currentSetup == 0
        }
        let before = try #require(session.snapshot?.sequence)
        let payloads = try RotoMidiSetupExport.books(slotNames: ["Piano"], seatLabels: [0: "Cutoff"],
                assignedSeatsOnly: true).map(RotoMidiSetupExport.servicePayload)
        try await session.applyRotoSetups(payloads)
        let roto = try #require(session.devices.first(where: { $0.deviceID == "roto" }))
        #expect(session.snapshot!.sequence > before)
        #expect(roto.currentSetup == 0)
        #expect(roto.configuring == false)
        #expect(roto.configError == nil && session.rotoSetupError == nil)
        #expect(releases == 1)
        await #expect(throws: (any Error).self) {
            try await session.applyRotoSetups([.init(setup: 8, content: .init(name: "VP"))])
        }
        await session.stop()
    } catch { await session.stop(); throw error }
}
