import Testing
import SwiftUI
import AppKit
import Foundation
import MidistageClient
@testable import Ladyland

@Test func deviceHandoffDrainsHeldAndSustainedNotes() {
    var latch = NoteLatch()
    latch.noteOn(60, channel: 2)
    _ = latch.pedal(127)
    let heldOff = latch.shouldSendNoteOff(60)
    #expect(!heldOff)
    latch.noteOn(64, channel: 3)
    let released = latch.drainAll()
    #expect(released.map(\.note) == [60, 64])
    #expect(released.map(\.channel) == [2, 3])
    #expect(latch.heldNotes.isEmpty)
    #expect(latch.sustainedCount == 0)
    #expect(!latch.isEngaged)
    let again = latch.drainAll()
    #expect(again.isEmpty)
}

@Test func deviceHandoffPreservesOtherKeyboardAndComputerNotes() {
    var notes = DeviceNoteLatches()
    notes.noteOn(60, channel: 0, deviceID: "keystage")
    notes.noteOn(64, channel: 0, deviceID: "numa")
    notes.noteOn(67, channel: 0)
    _ = notes.pedal(127, deviceID: "keystage")
    let heldOff = notes.shouldSendNoteOff(60, deviceID: "keystage")
    #expect(!heldOff)
    let keystage = notes.drain(deviceID: "keystage")
    #expect(keystage.map(\.note) == [60])
    #expect(notes.heldNotes == [64, 67])
    #expect(!notes.isEngaged(deviceID: "keystage"))
    let numa = notes.drain(deviceID: "numa")
    #expect(numa.map(\.note) == [64])
    #expect(notes.heldNotes == [67])
}

@Test func deviceHandoffDoesNotReleaseSameNoteStillHeldByAnotherInput() {
    var notes = DeviceNoteLatches()
    notes.noteOn(60, channel: 2, deviceID: "keystage")
    notes.noteOn(60, channel: 2)
    let keystage = notes.drain(deviceID: "keystage")
    #expect(keystage.isEmpty)
    #expect(notes.heldNotes == [60])
    let local = notes.drain(deviceID: "local")
    #expect(local.map(\.note) == [60])
}

@Test func routerHandoffReleasesOnlyRequestedDevice() {
    let router = MIDIRouter()
    router.routeKeyboard(0x90, 60, 100, deviceID: "keystage")
    router.routeKeyboard(0xb0, 64, 127, deviceID: "keystage")
    router.routeKeyboard(0x80, 60, 0, deviceID: "keystage")
    router.routeKeyboard(0x90, 67, 100)
    #expect(router.releaseDevice("keystage") == 1)
    #expect(router.releaseDevice("keystage") == 0)
    #expect(router.releaseDevice("local") == 1)
}

@Test func handoffInvalidatesDelayedWorkAndWaitsForStartedWork() async throws {
    let gate = MIDIWorkGate()
    #expect(gate.stamp == nil)
    gate.activate()
    let old = try #require(gate.stamp)
    let work = try #require(gate.begin(old))
    gate.revoke()
    #expect(!work.isCurrent)
    #expect(gate.begin(old) == nil)
    #expect(!gate.isIdle)
    #expect(!gate.activate())
    work.finish()
    await gate.waitUntilIdle()
    #expect(gate.isIdle)
    gate.activate()
    #expect(gate.begin(old) == nil)
    let newStamp = try #require(gate.stamp)
    let current = try #require(gate.begin(newStamp))
    #expect(current.isCurrent)
    current.finish()
}

@Test func midiPlanUsesOnlyOwnedPortsAndIgnoresUnownedKeystage() {
    let generic = "Midistage/ladyland/lease/4 | Studio Keyboard"
    let physical = "Keystage KBD/CTRL"
    let peer = "Midistage/vp/other/1 | Keystage KBD/CTRL"
    let plan = MIDIInput.plan(sourceNames: [physical, peer, generic], allowedSourceNames: [generic])
    #expect(plan == [MIDIConnectedSource(name: generic, route: .genericKeyboard)])
    #expect(MIDIInput.plan(sourceNames: [physical, peer], allowedSourceNames: []).isEmpty)
}

@Test @MainActor
func midiSessionRevokesOnlyChangedDeviceAndRejectsDelayedSnapshots() async throws {
    let session = MIDIUseSession()
    var started: [String] = []
    var stopped: [String] = []
    session.onAcquired = { started.append($0.deviceID) }
    session.onReleased = { stopped.append($0.deviceID) }
    let first = try handoffSnapshot(sequence: 1, nanoPhase: "active")
    await session.apply(first)
    #expect(started == ["nano", "lpd"])
    #expect(session.access.allowsInput("nano input"))
    await session.apply(try handoffSnapshot(sequence: 2, nanoPhase: "releasing"))
    #expect(stopped == ["nano"])
    #expect(!session.access.allowsInput("nano input"))
    #expect(session.access.allowsOutput("lpd output"))
    await session.apply(first)
    #expect(started.count == 2)
    #expect(!session.access.allowsInput("nano input"))
}

private func handoffSnapshot(sequence: Int, nanoPhase: String) throws -> MidistageClient.Snapshot {
    let device: (String, String, String) -> [String: Any] = { id, profile, phase in [
        "device_id": id, "profile_id": profile, "name": profile, "present": true,
        "assignment": ["client_id": "ladyland", "revision": 1, "expected": true],
        "phase": phase, "lease": ["session_id": "session", "token": id + "-lease"],
        "controls": [], "native_ports": ["inputs": [id + " input"], "outputs": [id + " output"]]
    ] }
    let data = try JSONSerialization.data(withJSONObject: [
        "sequence": sequence, "protocol_version": 1, "server_epoch": "test", "session_id": "session",
        "devices": [device("nano", "nanokontrol", nanoPhase), device("lpd", "lpd8", "active")]
    ])
    return try JSONDecoder().decode(MidistageClient.Snapshot.self, from: data)
}

// opt-in visual proof: renders only the settings view; never starts audio, MIDI, or a service.
@Test @MainActor
func midiSettingsVisualFixture() async throws {
    guard let path = ProcessInfo.processInfo.environment["LADYLAND_MIDI_SETTINGS_RENDER"] else { return }
    let session = MIDIUseSession()
    await session.apply(try handoffSnapshot(sequence: 1, nanoPhase: "releasing"))
    let view = NSHostingView(rootView: MIDIUseSettingsView(session: session).padding(24).background(Color(nsColor: .windowBackgroundColor)))
    view.frame = NSRect(x: 0, y: 0, width: 740, height: 460)
    view.layoutSubtreeIfNeeded()
    let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
    view.cacheDisplay(in: view.bounds, to: bitmap)
    let png = try #require(bitmap.representation(using: .png, properties: [:]))
    try png.write(to: URL(fileURLWithPath: path))
}
