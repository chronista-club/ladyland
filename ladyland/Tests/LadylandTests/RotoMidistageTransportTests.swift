// mem_1Cg9RCew1FXTqxVCJjgcrs
import Foundation
import Testing
import MidistageClient
@testable import Ladyland

/// midistage の protocol_fixture のみ。常駐 endpoint・実機ポートには触れない。
@Test(.enabled(if: ProcessInfo.processInfo.environment["MIDISTAGE_TEST_SERVER"] != nil))
@MainActor func rotoSessionRegistersOnlyItsFourSetups() async throws {
    let fixture = try await RotoServiceFixture.start()
    defer { fixture.stop() }
    let session = MIDIUseSession(endpointURL: fixture.endpoint, nativeMIDI: false)
    var releasedRoto = 0
    session.onReleased = { if $0.deviceID == "roto" { releasedRoto += 1 } }
    session.onAcquired = { device in
        if device.deviceID == "roto" {
            #expect(!session.rotoSelecting)
            #expect(device.configuring == false)
        }
    }
    session.start()
    do {
        try await waitForRotoCondition {
            session.devices.first(where: { $0.deviceID == "roto" })?.setupOwners?["ladyland"] == [0, 1, 2, 3]
        }
        #expect(session.connectionError == nil)
        #expect(session.connected)
        try await waitForRotoCondition {
            session.devices.first(where: { $0.deviceID == "roto" })?.currentSetup == 0
        }
        try await session.selectRotoSetup(3)
        // 受付だけで戻らず、送信を止めてから完了を確認する。
        #expect(releasedRoto == 1)
        #expect(session.devices.first(where: { $0.deviceID == "roto" })?.currentSetup == 3)
        try await waitForRotoCondition {
            session.devices.first(where: { $0.deviceID == "roto" })?.currentSetup == 3
        }
        await #expect(throws: MIDIUseError.self) { try await session.selectRotoSetup(6) }
        let (vp, _) = try await Client.connect(endpointURL: fixture.endpoint, clientID: "vp",
                                              displayName: "VP fixture", nativeMIDI: false)
        do {
            _ = try await vp.setDeviceSetups(deviceID: "roto", setups: [6])
            let device = try #require(session.devices.first(where: { $0.deviceID == "roto" }))
            _ = try await vp.setEnabled(deviceID: "roto", enabled: true,
                                        expectedRevision: device.assignment.revision, takeover: true)
            do {
                try await session.selectRotoSetup(2)
                Issue.record("A stale lease selected a setup after takeover")
            } catch { /* local guard or server rejects the old lease */ }
            try await waitForRotoCondition {
                guard let device = session.devices.first(where: { $0.deviceID == "roto" }) else { return false }
                return device.assignment.clientID == "vp" && device.currentSetup == 6 && !session.owns(device)
            }
            await #expect(throws: MIDIUseError.self) { try await session.selectRotoSetup(2) }
            #expect(session.rotoSetupError == nil)
            let foreign = try #require(session.devices.first(where: { $0.deviceID == "roto" }))
            try await session.setEnabled(foreign, enabled: true, takeover: true)
            let releasing = try await vp.snapshot()
            let token = try #require(releasing.devices.first(where: { $0.deviceID == "roto" })?.lease?.token)
            _ = try await vp.quiesced(deviceID: "roto", leaseToken: token)
            try await waitForRotoCondition {
                guard let device = session.devices.first(where: { $0.deviceID == "roto" }) else { return false }
                return session.owns(device) && device.currentSetup == 3 && device.configuring == false
            }
            await vp.close()
        } catch { await vp.close(); throw error }
        await session.stop()
    } catch {
        #expect(session.connected, "connectionError: \(session.connectionError ?? "none")")
        await session.stop()
        throw error
    }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["MIDISTAGE_TEST_SERVER"] != nil))
@MainActor func rotoRegistrationConflictKeepsOtherDevicesConnected() async throws {
    let fixture = try await RotoServiceFixture.start()
    defer { fixture.stop() }
    let (vp, _) = try await Client.connect(endpointURL: fixture.endpoint, clientID: "vp",
                                          displayName: "VP fixture", nativeMIDI: false)
    let session = MIDIUseSession(endpointURL: fixture.endpoint, nativeMIDI: false)
    var acquired: [String] = []
    session.onAcquired = { acquired.append($0.deviceID) }
    do {
        _ = try await vp.setDeviceSetups(deviceID: "roto", setups: [0])
        session.start()
        try await waitForRotoCondition { session.rotoSetupError != nil }
        #expect(session.rotoSetupError?.contains("conflict") == true)
        #expect(session.connectionError == nil)
        #expect(session.connected)
        #expect(session.devices.contains { $0.deviceID == "nano" && session.owns($0) })
        #expect(!acquired.contains("roto"))
        #expect(acquired.contains("nano"))
        await session.stop()
        await vp.close()
    } catch { await session.stop(); await vp.close(); throw error }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["MIDISTAGE_TEST_SERVER"] != nil))
@MainActor func rotoSessionTakeoverWaitsForSelectionDrain() async throws {
    let fixture = try await RotoServiceFixture.start()
    defer { fixture.stop() }
    let session = MIDIUseSession(endpointURL: fixture.endpoint, nativeMIDI: false)
    let (vp, _) = try await Client.connect(endpointURL: fixture.endpoint, clientID: "vp",
                                          displayName: "VP fixture", nativeMIDI: false)
    let drain = RotoReleaseLatch()
    var acquired = false
    session.onAcquired = { if $0.deviceID == "roto" { acquired = true } }
    session.onReleased = { if $0.deviceID == "roto" { await drain.wait() } }
    session.start()
    do {
        try await waitForRotoCondition { acquired }
        _ = try await vp.setDeviceSetups(deviceID: "roto", setups: [6])
        let selection = Task { try await session.selectRotoSetup(2) }
        try await waitForRotoCondition { drain.started }
        let previous = try #require(session.devices.first(where: { $0.deviceID == "roto" }))
        _ = try await vp.setEnabled(deviceID: "roto", enabled: true,
                                    expectedRevision: previous.assignment.revision, takeover: true)
        // 受信 loop が譲渡要求を観測したところまで進める。drain はまだ停止中。
        try await waitForRotoCondition {
            guard let roto = session.devices.first(where: { $0.deviceID == "roto" }) else { return false }
            return roto.phase == "releasing" || roto.assignment.clientID == "vp"
        }
        for _ in 0..<10 {
            let current = try await vp.snapshot()
            let roto = try #require(current.devices.first(where: { $0.deviceID == "roto" }))
            #expect(roto.phase == "releasing")
            #expect(roto.lease?.token == previous.lease?.token)
        }
        drain.finish()
        do {
            try await selection.value
            Issue.record("Selection succeeded after its lease was surrendered")
        } catch { /* the old selection must be rejected */ }
        try await waitForRotoCondition {
            guard let roto = session.devices.first(where: { $0.deviceID == "roto" }) else { return false }
            return roto.phase == "active" && roto.currentSetup == 6 && !session.owns(roto)
        }
        await session.stop()
        await vp.close()
    } catch {
        drain.finish()
        await session.stop()
        await vp.close()
        throw error
    }
}

@MainActor
private final class RotoReleaseLatch {
    private(set) var started = false
    private var finished = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        started = true
        guard !finished else { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func finish() {
        finished = true
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
struct RotoServiceFixture {
    let process: Process
    let directory: URL
    var endpoint: URL { directory.appendingPathComponent("endpoint.json") }

    static func start() async throws -> Self {
        let binary = try #require(ProcessInfo.processInfo.environment["MIDISTAGE_TEST_SERVER"])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ladyland-roto-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = [directory.path]
        let fixture = Self(process: process, directory: directory)
        do {
            try process.run()
            try await waitForRotoCondition { FileManager.default.fileExists(atPath: fixture.endpoint.path) }
            return fixture
        } catch { fixture.stop(); throw error }
    }
    func stop() {
        if process.isRunning { process.terminate(); process.waitUntilExit() }
        try? FileManager.default.removeItem(at: directory)
    }
}

@MainActor
func waitForRotoCondition(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(10)
    while !condition() {
        guard ContinuousClock.now < deadline else {
            throw RotoFixtureError.conditionNotReached
        }
        try await Task.sleep(for: .milliseconds(20))
    }
}

enum RotoFixtureError: Error { case conditionNotReached }
