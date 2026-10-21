import CoreMIDI
import Foundation
import Testing
@testable import Ladyland

private final class MIDIOutputRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: [[UInt8]] = []
    func add(_ bytes: [UInt8], _ destination: MIDIEndpointRef) { lock.withLock { self.bytes.append(bytes) } }
    var count: Int { lock.withLock { bytes.count } }
}

@Test func delayedRotoOutputCannotCrossADeviceHandoff() async throws {
    let gate = MIDIWorkGate()
    let recorder = MIDIOutputRecorder()
    let queue = RotoSendQueue(gate: gate, sysEx: { recorder.add($0, $1) }, raw: { recorder.add($0, $1) })
    gate.activate()
    queue.sendRaw([[0xb0, 7, 10]], to: 0, gap: 0, after: 0.04)
    gate.revoke()
    await gate.waitUntilIdle()
    gate.activate()
    try await Task.sleep(for: .milliseconds(100))
    #expect(recorder.count == 0)
    queue.send([[0xf0, 0x7d, 1, 0xf7]], to: 0, gap: 0)
    for _ in 0..<50 where recorder.count == 0 { try await Task.sleep(for: .milliseconds(2)) }
    #expect(recorder.count == 1)
}

@Test @MainActor
func keystageHandoffWaitsForStartedWork() async throws {
    let service = KeystageService()
    service.workGate.activate()
    let stamp = try #require(service.workGate.stamp)
    let work = try #require(service.workGate.begin(stamp))
    var finished = false
    let stopping = Task { await service.releaseDevice(); finished = true }
    for _ in 0..<50 where service.workGate.stamp != nil { try await Task.sleep(for: .milliseconds(2)) }
    #expect(service.workGate.stamp == nil)
    #expect(!finished)
    work.finish()
    await stopping.value
    #expect(finished)
    #expect(!service.connected)
}
