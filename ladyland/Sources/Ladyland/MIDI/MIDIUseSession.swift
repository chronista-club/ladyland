import Foundation
import Combine
import MidistageClient

/// アプリの使用意思と機材接続の窓口。実機ポートへのフォールバックはしない。
@MainActor
final class MIDIUseSession: ObservableObject {
    let access = NativeAccess()
    @Published private(set) var snapshot: MidistageClient.Snapshot?
    @Published private(set) var connected = false
    @Published private(set) var connectionError: String?
    var onReleased: ((DeviceView) async -> Void)?
    var onAcquired: ((DeviceView) -> Void)?
    var onSnapshot: ((MidistageClient.Snapshot) -> Void)?
    private var owned: [String: DeviceView] = [:]
    private var client: MidistageClient.Client?
    private var task: Task<Void, Never>?
    private let endpointURL: URL

    init(endpointURL: URL = MidistageClient.Client.defaultEndpointURL) { self.endpointURL = endpointURL }
    var devices: [DeviceView] { snapshot?.devices ?? [] }
    func owns(_ device: DeviceView) -> Bool { snapshot?.owns(device) ?? false }

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in await self?.run() }
    }
    func stop() async {
        task?.cancel()
        await task?.value
        task = nil
    }
    func setEnabled(_ device: DeviceView, enabled: Bool, takeover: Bool = false) async throws {
        guard let client, connected else { throw MIDIUseError.unavailable }
        _ = try await client.setEnabled(deviceID: device.deviceID, enabled: enabled,
                                       expectedRevision: device.assignment.revision, takeover: takeover)
    }
    func send(profileID: String, bytes: [UInt8], completion: @escaping @MainActor () -> Void) -> Bool {
        guard let client, let device = devices.first(where: { $0.profileID == profileID && owns($0) }),
              let token = device.lease?.token, let port = device.nativeOutputs.first else { return false }
        Task { [weak self] in
            do {
                _ = try await client.sendMIDI(deviceID: device.deviceID, leaseToken: token, portName: port, bytes: bytes)
                guard let self, self.owned[device.deviceID]?.lease?.token == token else { return }
                completion()
            } catch {
                // LedBus の watchdog が再試行する。失敗を実機送信完了にしない。
                NSLog("MIDI output: %@", error.localizedDescription)
            }
        }
        return true
    }

    /// 接続取得時のleaseを固定し、遅延した旧接続の送信を新しい機材へ流さない。
    func sendXTouch(_ bytes: [UInt8], lease: String) async throws {
        try Task.checkCancellation()
        guard let client, connected,
              let device = devices.first(where: { $0.profileID == "xtouch" && owns($0) }),
              device.lease?.token == lease,
              let port = device.nativeOutputs.first(where: { $0.hasSuffix("X-Touch INT") })
        else { throw MIDIUseError.unavailable }
        _ = try await client.sendMIDI(deviceID: device.deviceID, leaseToken: lease, portName: port, bytes: bytes)
    }

    /// 一つの受信 loop だけから適用する。遅延した応答では所有権を戻さない。
    func apply(_ incoming: MidistageClient.Snapshot) async {
        guard access.update(incoming) else { return }
        snapshot = incoming
        let next = Dictionary(uniqueKeysWithValues: incoming.devices.filter(incoming.owns).map { ($0.deviceID, $0) })
        for (id, previous) in owned {
            if next[id]?.lease != previous.lease || next[id]?.nativePorts != previous.nativePorts {
                owned.removeValue(forKey: id)
                await onReleased?(previous)
            }
        }
        for device in incoming.devices where incoming.owns(device) && owned[device.deviceID] == nil {
            owned[device.deviceID] = device
            onAcquired?(device)
        }
        onSnapshot?(incoming)
    }
    private func clear() async {
        access.clear()
        let previous = owned.values
        owned.removeAll()
        for device in previous { await onReleased?(device) }
        snapshot = nil
        connected = false
    }
    private func run() async {
        while !Task.isCancelled {
            do {
                let (connection, first) = try await MidistageClient.Client.connect(
                    endpointURL: endpointURL, clientID: "ladyland", displayName: "Ladyland",
                    initialEnabledProfiles: ["nanokontrol", "lpd8", "roto", "keystage", "numa", "minilab", "fgdp", "generic"])
                client = connection
                connected = true
                connectionError = nil
                var current = first
                var acknowledged: Set<String> = []
                while !Task.isCancelled {
                    await apply(current)
                    for device in current.devices where device.phase == "releasing" {
                        if let lease = device.lease, lease.sessionID == current.sessionID,
                           !acknowledged.contains(lease.token) {
                            // apply が入力停止・発音整理・送信/serial 作業の完了を待った後。
                            _ = try await connection.quiesced(deviceID: device.deviceID, leaseToken: lease.token)
                            acknowledged.insert(lease.token)
                        }
                    }
                    try await Task.sleep(for: .milliseconds(200))
                    current = try await connection.snapshot()
                }
            } catch {
                if !Task.isCancelled { connectionError = error.localizedDescription }
            }
            let previous = client
            client = nil
            await clear()
            await previous?.close()
            if !Task.isCancelled { try? await Task.sleep(for: .seconds(1)) }
        }
    }
}

enum MIDIUseError: LocalizedError {
    case unavailable
    var errorDescription: String? { "MIDI サービスに接続していません。" }
}

@MainActor
final class MidistageLedSender: LedSender {
    private weak var session: MIDIUseSession?
    private var generation: UInt64 = 0
    init(session: MIDIUseSession) { self.session = session }
    func send(_ frame: [UInt8], onComplete: @escaping @MainActor () -> Void) -> Bool {
        let sentGeneration = generation
        return session?.send(profileID: "lpd8", bytes: frame) { [weak self] in
            guard self?.generation == sentGeneration else { return }
            onComplete()
        } ?? false
    }
    func invalidate() { generation &+= 1 }
}
