import Combine
import Foundation

/// 希望値の変更を束ねる。保存済みの「実機の影」は持たず、同じ lease 内の要求だけを重複抑止する。
@MainActor
final class RotoSetupSync: ObservableObject {
    enum Status: Equatable { case idle, waiting, applying(Int), applied(Int), failed(String) }
    @Published private(set) var status: Status = .idle
    var message: String? {
        switch status {
        case .idle: return nil
        case .waiting: return "変更を待ち合わせ中…"
        case .applying(let count): return "\(count) 冊を書き込み中…"
        case .applied(let count): return count == 0 ? "変更なし" : "\(count) 冊を反映しました"
        case .failed(let message): return "書き込み失敗: \(message)"
        }
    }
    private struct Identity: Equatable {
        let epoch: String
        let session: String
        let lease: String
    }
    private let session: MIDIUseSession
    private let debounce: Duration
    private var identity: Identity?
    private var desired: [RotoSetupPayload]?
    private var attempted: [RotoSetupPayload]?
    private var confirmed: [RotoSetupPayload] = []
    private var force = false
    private var pending: Task<Void, Never>?
    private var inFlight: Task<Void, Never>?

    init(session: MIDIUseSession, debounce: Duration = .seconds(1)) {
        self.session = session
        self.debounce = debounce
    }

    func submit(_ payloads: [RotoSetupPayload], force: Bool = false) {
        desired = payloads
        if force {
            guard session.hasRotoLease else { reject(MIDIUseError.rotoUnavailable); return }
            self.force = true
        }
        // 最初の変更で決めた送信時刻を保つ。継続変更や連打でも先送りしない。
        // begin はその時点の最新 desired / force を使う。
        refresh()
    }

    /// 変換できない希望値を、古い希望値で置き換えて送らない。
    func reject(_ error: Error) {
        desired = nil
        attempted = nil
        force = false
        pending?.cancel()
        pending = nil
        status = .failed(error.localizedDescription)
    }

    /// snapshot ごとの呼び出しで、切断・譲渡・設定完了による可否を更新する。
    func refresh() {
        let current = currentIdentity()
        if current != identity {
            identity = current
            attempted = nil
            confirmed = []
            pending?.cancel()
            pending = nil
            status = .idle
            if current == nil { force = false }
        }
        guard current != nil, inFlight == nil, pending == nil, let desired,
              force || desired != attempted, ready else { return }
        status = .waiting
        pending = Task { [weak self, debounce] in
            do { try await Task.sleep(for: debounce) } catch { return }
            guard let self, !Task.isCancelled else { return }
            self.pending = nil
            self.begin()
        }
    }

    private var ready: Bool {
        guard session.hasRotoLease, !session.rotoConfiguring,
              let roto = session.devices.first(where: { $0.deviceID == "roto" }),
              roto.configuring == false else { return false }
        // サービスが示した設定エラーは人が全冊ボタンで再試行する。poll で撃ち続けない。
        return force || roto.configError == nil
    }
    private func currentIdentity() -> Identity? {
        guard session.hasRotoLease, let snapshot = session.snapshot,
              let token = session.devices.first(where: { $0.deviceID == "roto" })?.lease?.token else { return nil }
        return Identity(epoch: snapshot.serverEpoch, session: snapshot.sessionID, lease: token)
    }
    private func begin() {
        guard inFlight == nil, ready, let identity, identity == currentIdentity(), let desired else { return }
        let sending = force ? desired : desired.filter { !confirmed.contains($0) }
        attempted = desired
        force = false
        guard !sending.isEmpty else { status = .applied(0); return }
        status = .applying(sending.count)
        // 変更が来ても進行中の Apply はキャンセルしない。終わってから最新を送る。
        inFlight = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.session.applyRotoSetups(sending)
                if self.currentIdentity() == identity {
                    self.confirmed = desired
                    // 送信中に新しい入力が変換エラーになった場合、そのエラー表示を消さない。
                    if self.desired != nil { self.status = .applied(sending.count) }
                }
            } catch {
                if self.currentIdentity() == identity {
                    self.confirmed = []
                    if self.desired != nil { self.status = .failed(error.localizedDescription) }
                }
            }
            self.inFlight = nil
            self.refresh()
        }
    }
}
