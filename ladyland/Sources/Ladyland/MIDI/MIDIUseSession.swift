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
    @Published private(set) var rotoSetupError: String?
    @Published private(set) var rotoSelecting = false
    var onReleased: ((DeviceView) async -> Void)?
    var onAcquired: ((DeviceView) -> Void)?
    var onSnapshot: ((MidistageClient.Snapshot) -> Void)?
    private var owned: [String: DeviceView] = [:]
    private var releases: [String: Task<Void, Never>] = [:]
    private var client: MidistageClient.Client?
    private var task: Task<Void, Never>?
    private var rotoErrorLease: String?
    private let endpointURL: URL
    private let nativeMIDI: Bool

    init(endpointURL: URL = MidistageClient.Client.defaultEndpointURL, nativeMIDI: Bool = true) {
        self.endpointURL = endpointURL
        self.nativeMIDI = nativeMIDI
    }
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
    func selectRotoSetup(_ setup: Int) async throws {
        guard let client, connected,
              let device = devices.first(where: { $0.deviceID == "roto" && owns($0) }),
              !rotoSelecting, device.configuring != true, Self.rotoSetups.contains(setup),
              device.setupOwners?["ladyland"]?.contains(setup) == true,
              let token = device.lease?.token else { throw MIDIUseError.rotoUnavailable }
        rotoSelecting = true
        rotoSetupError = nil
        rotoErrorLease = nil
        defer { rotoSelecting = false }
        // 受付→完了がポーリング間に収まっても、送信停止と同期リセットを省かない。
        // この要求自身は RotoService の workGate を保持しない（release の待ちと循環させない）。
        access.revoke(profileID: "roto")
        await release(device.deviceID)
        do {
            try Task.checkCancellation()
            guard self.client === client,
                  let latest = devices.first(where: { $0.deviceID == device.deviceID }),
                  owns(latest), latest.lease?.token == token
            else { throw MIDIUseError.rotoUnavailable }
            let accepted = try await client.selectSetup(deviceID: device.deviceID, leaseToken: token, setup: setup)
            guard accepted.devices.first(where: { $0.deviceID == device.deviceID })?.configuring == true
            else { throw MIDIUseError.rotoConfigurationFailed("サービスが切替受付を確認できませんでした。") }
            // 応答は受付。適用は受信 loop に一本化し、その後の同じ lease の完了を待つ。
            let deadline = ContinuousClock.now + .seconds(30)
            while true {
                try Task.checkCancellation()
                guard self.client === client, connected, let current = snapshot,
                      current.serverEpoch == accepted.serverEpoch, current.sessionID == accepted.sessionID,
                      let roto = current.devices.first(where: { $0.deviceID == device.deviceID }),
                      current.owns(roto), roto.lease?.token == token else { throw MIDIUseError.rotoUnavailable }
                if current.sequence > accepted.sequence, roto.configuring == false {
                    if let error = roto.configError { throw MIDIUseError.rotoConfigurationFailed(error) }
                    guard roto.currentSetup == setup else {
                        throw MIDIUseError.rotoConfigurationFailed("切替先の setup を確認できませんでした。")
                    }
                    break
                }
                guard ContinuousClock.now < deadline else {
                    throw MIDIUseError.rotoConfigurationFailed("setup の切替が時間内に完了しませんでした。")
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            rotoSetupError = nil
        } catch {
            if self.client === client,
               let latest = devices.first(where: { $0.deviceID == device.deviceID }),
               owns(latest), latest.lease?.token == token {
                rotoSetupError = error.localizedDescription
                rotoErrorLease = token
            }
            throw error
        }
    }
    func send(profileID: String, bytes: [UInt8], completion: @escaping @MainActor () -> Void) -> Bool {
        guard let client, let device = owned.values.first(where: { $0.profileID == profileID }),
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
        // lease の所有と、設定が済んで演奏できることは別。設定中は
        // NativeAccess も閉じ、遅延した MIDI callback / sender を通さない。
        var usable = incoming
        let staleSelectionError = rotoErrorLease != nil
            && incoming.devices.first(where: { $0.deviceID == "roto" })?.lease?.token != rotoErrorLease
        usable.devices = incoming.devices.filter { device in
            guard device.profileID == "roto" else { return true }
            return !rotoSelecting && (rotoSetupError == nil || staleSelectionError)
                && device.configuring == false && device.configError == nil
                && device.currentSetup.map { Self.rotoSetups.contains($0)
                    && device.setupOwners?["ladyland"]?.contains($0) == true } == true
        }
        guard access.update(usable) else { return }
        if staleSelectionError { rotoSetupError = nil; rotoErrorLease = nil }
        snapshot = incoming
        let next = Dictionary(uniqueKeysWithValues: usable.devices.filter(usable.owns).map { ($0.deviceID, $0) })
        for (id, previous) in owned {
            if next[id]?.lease != previous.lease || next[id]?.nativePorts != previous.nativePorts
                || (previous.profileID == "roto" && next[id]?.currentSetup != previous.currentSetup) {
                await release(id)
            }
        }
        // SelectSetup が開始した release も含め、同じ drain を待つ。
        // owned から除去済みでも、完了前に quiesced / 再取得へ進まない。
        await drainReleases()
        for device in usable.devices where usable.owns(device) && owned[device.deviceID] == nil {
            // 別機材の release を await している間に SelectSetup が始まった場合も守る。
            if device.profileID == "roto" && rotoSelecting { continue }
            owned[device.deviceID] = device
            onAcquired?(device)
        }
        onSnapshot?(incoming)
    }
    static let rotoSetups = [0, 1, 2, 3]
    private func release(_ id: String) async {
        if let pending = releases[id] { await pending.value; return }
        guard let previous = owned.removeValue(forKey: id) else { return }
        let callback = onReleased
        let pending = Task { @MainActor in
            await callback?(previous)
            self.releases[id] = nil
        }
        releases[id] = pending
        await pending.value
    }
    private func drainReleases() async {
        for pending in Array(releases.values) { await pending.value }
    }
    private func clear() async {
        access.clear()
        for id in Array(owned.keys) { await release(id) }
        await drainReleases()
        snapshot = nil
        connected = false
    }
    private func run() async {
        while !Task.isCancelled {
            do {
                let (connection, first) = try await MidistageClient.Client.connect(
                    endpointURL: endpointURL, clientID: "ladyland", displayName: "Ladyland",
                    nativeMIDI: nativeMIDI,
                    initialEnabledProfiles: ["nanokontrol", "lpd8", "roto", "keystage", "numa", "minilab", "fgdp", "generic"])
                client = connection
                connected = true
                connectionError = nil
                rotoSetupError = nil
                rotoErrorLease = nil
                var current = first
                var acknowledged: Set<String> = []
                var registrationAttempted = false
                while !Task.isCancelled {
                    // 未接続の機材がまだ台帳に無い場合は、現れた時に一度だけ登録する。
                    // conflict / 旧サービスの未対応で、他の機材まで切断・再接続しない。
                    if !registrationAttempted, current.devices.contains(where: { $0.deviceID == "roto" }) {
                        registrationAttempted = true
                        do {
                            current = try await connection.setDeviceSetups(deviceID: "roto", setups: Self.rotoSetups)
                        } catch {
                            try Task.checkCancellation()
                            rotoSetupError = error.localizedDescription
                        }
                    }
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
    case rotoUnavailable
    case rotoConfigurationFailed(String)
    var errorDescription: String? {
        switch self {
        case .unavailable: return "MIDI サービスに接続していません。"
        case .rotoUnavailable: return "ROTO の使用権または setup の準備ができていません。"
        case .rotoConfigurationFailed(let message): return message
        }
    }
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
