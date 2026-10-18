// mem_1Cg9RCew1FXTqxVCJjgcrs
import Combine
import Foundation
import Testing
import MidistageClient
@testable import Ladyland

@Test(.enabled(if: ProcessInfo.processInfo.environment["MIDISTAGE_TEST_SERVER"] != nil))
@MainActor func rotoSessionAutomaticApplyStartsWhileChangesContinue() async throws {
    let fixture = try await RotoServiceFixture.start()
    defer { fixture.stop() }
    let session = MIDIUseSession(endpointURL: fixture.endpoint, nativeMIDI: false)
    let sync = RotoSetupSync(session: session, debounce: .milliseconds(100))
    var acquired = false
    var attempts = 0
    let observation = session.$rotoApplying.sink { if $0 { attempts += 1 } }
    var updates: Task<Void, Never>?
    defer { updates?.cancel(); observation.cancel() }
    session.onAcquired = { if $0.deviceID == "roto" { acquired = true } }
    session.onSnapshot = { _ in sync.refresh() }
    session.start()
    do {
        try await waitForRotoCondition { acquired }
        updates = Task { @MainActor in
            var version = 0
            while !Task.isCancelled {
                sync.submit([.init(setup: 2, content: .init(name: "CHANGE\(version)"))])
                version += 1
                do { try await Task.sleep(for: .milliseconds(10)) } catch { return }
            }
        }
        // 静止期間を作らずに開始を待つ。末尾だけの debounce はここで期限切れになる。
        try await waitForRotoCondition { attempts > 0 }
        updates?.cancel()
        await updates?.value
        sync.submit([.init(setup: 2, content: .init(name: "FINAL"))])
        try await waitForRotoCondition { attempts >= 2 && sync.status == .applied(1) }
        await session.stop()
    } catch { updates?.cancel(); await session.stop(); throw error }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["MIDISTAGE_TEST_SERVER"] != nil))
@MainActor func rotoSessionAutomaticApplyCoalescesChangesAndSkipsIdenticalRequests() async throws {
    let fixture = try await RotoServiceFixture.start()
    defer { fixture.stop() }
    let session = MIDIUseSession(endpointURL: fixture.endpoint, nativeMIDI: false)
    let sync = RotoSetupSync(session: session, debounce: .milliseconds(30))
    var attempts = 0
    var snapshots = 0
    let observation = session.$rotoApplying.sink { if $0 { attempts += 1 } }
    defer { observation.cancel() }
    session.onSnapshot = { _ in snapshots += 1; sync.refresh() }
    func payloads(_ name: String) -> [RotoSetupPayload] {
        (0...3).map { .init(setup: $0, content: .init(name: $0 == 2 ? name : "BOOK\($0)")) }
    }
    sync.submit(payloads("FIRST"))
    session.start()
    do {
        try await waitForRotoCondition { sync.status == .applied(4) }
        #expect(attempts == 1)
        sync.submit(payloads("DISCARDED"))
        sync.submit(payloads("LATEST"))
        try await waitForRotoCondition { sync.status == .applied(1) }
        #expect(attempts == 2)
        let count = snapshots
        sync.submit(payloads("LATEST"))
        try await waitForRotoCondition { snapshots >= count + 3 }
        #expect(attempts == 2)
        sync.submit(payloads("LATEST"), force: true)
        try await waitForRotoCondition { sync.status == .applied(4) }
        #expect(attempts == 3)
        await session.stop()
    } catch { await session.stop(); throw error }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["MIDISTAGE_TEST_SERVER"] != nil))
@MainActor func rotoSessionAutomaticApplyDoesNotRetryFailuresOnEverySnapshot() async throws {
    let fixture = try await RotoServiceFixture.start()
    defer { fixture.stop() }
    let session = MIDIUseSession(endpointURL: fixture.endpoint, nativeMIDI: false)
    let sync = RotoSetupSync(session: session, debounce: .milliseconds(10))
    var snapshots = 0
    session.onSnapshot = { _ in snapshots += 1; sync.refresh() }
    sync.submit([.init(setup: 2, content: .init(name: "invalid non-ASCII 音"))])
    session.start()
    do {
        try await waitForRotoCondition { if case .failed = sync.status { return true }; return false }
        let error = session.rotoSetupError
        #expect(error != nil)
        let status = sync.status
        let count = snapshots
        try await waitForRotoCondition { snapshots >= count + 3 }
        #expect(sync.status == status)
        #expect(session.rotoSetupError == error)
        sync.submit([.init(setup: 2, content: .init(name: "RECOVERED"))], force: true)
        try await waitForRotoCondition { sync.status == .applied(1) }
        #expect(session.rotoSetupError == nil)
        await session.stop()
    } catch { await session.stop(); throw error }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["MIDISTAGE_TEST_SERVER"] != nil), arguments: [false, true])
@MainActor func rotoSessionAutomaticApplyPreservesChangesDuringAnInFlightWrite(rejecting: Bool) async throws {
    let fixture = try await RotoServiceFixture.start()
    defer { fixture.stop() }
    let session = MIDIUseSession(endpointURL: fixture.endpoint, nativeMIDI: false)
    let sync = RotoSetupSync(session: session, debounce: .milliseconds(10))
    let drain = RotoReleaseLatch()
    var acquired = false
    session.onAcquired = { if $0.deviceID == "roto" { acquired = true } }
    var attempts = 0
    let observation = session.$rotoApplying.sink { if $0 { attempts += 1 } }
    defer { observation.cancel() }
    session.onReleased = { if $0.deviceID == "roto" { await drain.wait() } }
    session.onSnapshot = { _ in sync.refresh() }
    func payloads(_ name: String) -> [RotoSetupPayload] {
        (0...3).map { .init(setup: $0, content: .init(name: $0 == 2 ? name : "BOOK\($0)")) }
    }
    session.start()
    do {
        try await waitForRotoCondition { acquired }
        sync.submit(payloads("FIRST"))
        try await waitForRotoCondition { drain.started }
        if rejecting { sync.reject(MIDIUseError.rotoConfigurationFailed("invalid new color")) }
        else { sync.submit(payloads("LATEST")) }
        drain.finish()
        if rejecting {
            try await waitForRotoCondition { !session.rotoApplying }
            #expect(sync.status == .failed("invalid new color"))
            #expect(attempts == 1)
        } else {
            try await waitForRotoCondition { sync.status == .applied(1) }
            #expect(attempts == 2)
        }
        await session.stop()
    } catch { drain.finish(); await session.stop(); throw error }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["MIDISTAGE_TEST_SERVER"] != nil))
@MainActor func rotoSessionAutomaticApplyResendsAfterLeaseChanges() async throws {
    let fixture = try await RotoServiceFixture.start()
    defer { fixture.stop() }
    let session = MIDIUseSession(endpointURL: fixture.endpoint, nativeMIDI: false)
    let sync = RotoSetupSync(session: session, debounce: .milliseconds(10))
    let (vp, _) = try await Client.connect(endpointURL: fixture.endpoint, clientID: "vp",
                                           displayName: "VP fixture", nativeMIDI: false)
    var attempts = 0
    let observation = session.$rotoApplying.sink { if $0 { attempts += 1 } }
    defer { observation.cancel() }
    session.onSnapshot = { _ in sync.refresh() }
    sync.submit([.init(setup: 2, content: .init(name: "SAME"))])
    session.start()
    do {
        try await waitForRotoCondition { sync.status == .applied(1) }
        #expect(attempts == 1)
        let original = try #require(session.devices.first(where: { $0.deviceID == "roto" }))
        _ = try await vp.setDeviceSetups(deviceID: "roto", setups: [8])
        _ = try await vp.setEnabled(deviceID: "roto", enabled: true,
                                    expectedRevision: original.assignment.revision, takeover: true)
        try await waitForRotoCondition {
            session.devices.first(where: { $0.deviceID == "roto" })?.currentSetup == 8
        }
        #expect(sync.status == .idle)
        let foreign = try #require(session.devices.first(where: { $0.deviceID == "roto" }))
        try await session.setEnabled(foreign, enabled: true, takeover: true)
        let releasing = try await vp.snapshot()
        let token = try #require(releasing.devices.first(where: { $0.deviceID == "roto" })?.lease?.token)
        _ = try await vp.quiesced(deviceID: "roto", leaseToken: token)
        try await waitForRotoCondition { sync.status == .applied(1) }
        #expect(attempts == 2)
        #expect(session.devices.first(where: { $0.deviceID == "roto" })?.lease?.token != original.lease?.token)
        await session.stop()
        await vp.close()
    } catch { await session.stop(); await vp.close(); throw error }
}
