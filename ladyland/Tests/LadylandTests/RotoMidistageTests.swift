// mem_1Cg9RCew1FXTqxVCJjgcrs
import Foundation
import Testing
import MidistageClient
@testable import Ladyland

@Suite @MainActor
struct RotoMidistageTests {
    @Test func configuringStopsIOAndReacquiresAfterCompletion() async throws {
        let session = MIDIUseSession()
        var events: [String] = []
        session.onAcquired = { events.append("acquire:\($0.deviceID)") }
        session.onReleased = { device in
            #expect(!session.access.allowsOutput("roto output"))
            events.append("release:\(device.deviceID)")
        }
        await session.apply(try rotoSnapshot(sequence: 1, configuring: true))
        #expect(events == ["acquire:lpd"])
        #expect(!session.access.allowsInput("roto input"))
        #expect(!session.access.allowsOutput("roto output"))
        #expect(session.access.allowsOutput("lpd output"))
        await session.apply(try rotoSnapshot(sequence: 2))
        #expect(events == ["acquire:lpd", "acquire:roto"])
        #expect(session.access.allowsOutput("roto output"))
        await session.apply(try rotoSnapshot(sequence: 3, configuring: true))
        #expect(events.last == "release:roto")
        await session.apply(try rotoSnapshot(sequence: 4))
        #expect(events == ["acquire:lpd", "acquire:roto", "release:roto", "acquire:roto"])
        await session.apply(try rotoSnapshot(sequence: 3, configuring: true))
        #expect(session.access.allowsOutput("roto output"))
    }

    @Test func failedConfigurationDoesNotStartMotors() async throws {
        let session = MIDIUseSession()
        var acquired: [String] = []
        session.onAcquired = { acquired.append($0.deviceID) }
        await session.apply(try rotoSnapshot(sequence: 1, error: "admin port busy"))
        #expect(acquired == ["lpd"])
        #expect(!session.access.allowsOutput("roto output"))
        #expect(session.devices.first?.configError == "admin port busy")
        await session.apply(try rotoSnapshot(sequence: 2))
        #expect(acquired == ["lpd", "roto"])
    }

    @Test func waitsUntilLadylandsRegisteredSetupIsCurrent() async throws {
        let session = MIDIUseSession()
        for (index, setup) in [nil, 6].enumerated() {
            var pending = try rotoSnapshot(sequence: index + 1)
            pending.devices[0].currentSetup = setup
            await session.apply(pending)
            #expect(!session.access.allowsOutput("roto output"))
        }
        await session.apply(try rotoSnapshot(sequence: 3))
        #expect(session.access.allowsOutput("roto output"))
    }

    @Test func generatedSetupsNeverTouchAnotherAppsSeats() {
        let requests = RotoMidiSetupExport.allRequests(slotNames: [])
        #expect(Set(requests.map(\.key.setup)) == Set(0...3))
    }

    @Test func applicationNeverOpensTheAdminPort() throws {
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Ladyland")
        let files = try #require(FileManager.default.enumerator(at: source, includingPropertiesForKeys: nil))
        for case let file as URL in files where file.pathExtension == "swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            let hasDirectAccess = text.contains("RotoAdminPort.withPort")
            #expect(!hasDirectAccess, "Direct serial access in \(file.lastPathComponent)")
        }
    }

    @Test func setupChangeBetweenPollsResetsMotorSynchronization() async throws {
        let session = MIDIUseSession()
        var acquired = 0
        session.onAcquired = { if $0.deviceID == "roto" { acquired += 1 } }
        await session.apply(try rotoSnapshot(sequence: 1))
        var changed = try rotoSnapshot(sequence: 2)
        changed.devices[0].currentSetup = 3
        await session.apply(changed)
        #expect(acquired == 2)
        await session.apply(try rotoSnapshot(sequence: 3, configuring: true))
        await session.apply(try rotoSnapshot(sequence: 4, phase: "releasing"))
        #expect(!session.access.allowsOutput("roto output"))
        #expect(acquired == 2)
    }
}

func rotoSnapshot(sequence: Int, configuring: Bool = false, error: String? = nil,
                  phase: String = "active", token: String = "roto-lease") throws -> MidistageClient.Snapshot {
    func device(_ id: String, profile: String) -> [String: Any] { [
        "device_id": id, "profile_id": profile, "name": profile, "present": true,
        "assignment": ["client_id": "ladyland", "revision": 1, "expected": true],
        "phase": id == "roto" ? phase : "active",
        "lease": ["session_id": "session", "token": id == "roto" ? token : "lpd-lease"],
        "controls": [], "native_ports": ["inputs": [id + " input"], "outputs": [id + " output"]]
    ] }
    var roto = device("roto", profile: "roto")
    roto["configuring"] = configuring
    roto["current_setup"] = 2
    roto["setup_owners"] = ["ladyland": [0, 1, 2, 3], "vp": [6]]
    roto["config_error"] = error
    return try JSONDecoder().decode(MidistageClient.Snapshot.self, from: JSONSerialization.data(withJSONObject: [
        "sequence": sequence, "protocol_version": 1, "server_epoch": "test", "session_id": "session",
        "devices": [roto, device("lpd", profile: "lpd8")]
    ]))
}
