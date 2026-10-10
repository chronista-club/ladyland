import Foundation
import Combine
import RotoKit

@MainActor
final class XTouchController: ObservableObject {
    @Published private(set) var bank = XTouchBank()
    @Published private(set) var connected = false
    @Published private(set) var greeting = false
    @Published private(set) var error: String?
    let rack: InstrumentRack
    let onSelect: (Int) -> Void
    let onChange: () -> Void
    init(rack: InstrumentRack, onSelect: @escaping (Int) -> Void, onChange: @escaping () -> Void) {
        self.rack = rack; self.onSelect = onSelect; self.onChange = onChange
    }
    private var task: Task<Void, Never>?
    private var sent: [String: [UInt8]] = [:]

    func move(_ delta: Int) { bank.move(delta, trackCount: rack.slots.count) }
    func select(_ index: Int) { onSelect(index) }
    func setMaster(_ value: Float) { rack.masterGain = min(1, max(0, value)); onChange() }
    func handle(_ event: XTouchMCU.Event) {
        if case let .touch(index, down) = event {
            bank.touch(index, down: down, trackCount: rack.slots.count)
            // release 後には現在値をもう一度送り、抑止期間中の値と揃える。
            if !down { sent.removeValue(forKey: "fader.\(index)") }
            return
        }
        guard !greeting else { return }
        if case let .move(delta) = event { move(delta); return }
        if case let .fader(8, gain) = event {
            if bank.touched.contains(8) { setMaster(gain) }
            return
        }
        let channel: Int
        switch event {
        case let .fader(i, _), let .pan(i, _), let .mute(i), let .solo(i), let .select(i), let .centerPan(i): channel = i
        default: return
        }
        let index = bank.start + channel
        guard (0..<8).contains(channel), rack.slots.indices.contains(index) else { return }
        let slot = rack.slots[index]
        switch event {
        case let .fader(_, gain):
            guard bank.touched.contains(channel) else { return } // motor echo はgainへ戻さない
            slot.gain = min(1, max(0, gain))
        case let .pan(_, delta): slot.pan = min(1, max(-1, slot.pan + Float(delta) * 0.02))
        case .centerPan: slot.pan = 0
        case .mute: slot.mute.toggle()
        case .solo: slot.solo.toggle()
        case .select: onSelect(index)
        default: return
        }
        onChange()
    }

    var strips: [XTouchStrip] {
        bank.indices(trackCount: rack.slots.count).map { index in
            let slot = rack.slots[index]
            let rgb = slot.rotoColor.map { Roto.Color.palette[Int($0) % Roto.Color.palette.count] }
            return XTouchStrip(index: index, name: slot.trackName ?? "T\(index + 1)", gain: slot.gain,
                pan: slot.pan, mute: slot.mute, solo: slot.solo, selected: rack.selected == index,
                color: XTouchMCU.stripColor(rgb: rgb))
        }
    }

    /// 一接続につき一本の送信ループ。release は await stop してから Quiesced へ。
    func start(ready: @escaping @MainActor () async -> Void,
               greetingDuration: TimeInterval = 0.8,
               send: @escaping @MainActor ([UInt8]) async throws -> Void) {
        guard task == nil else { return }
        connected = true; greeting = true; error = nil; sent = [:]
        task = Task { [weak self] in
            await ready()
            guard let self, !Task.isCancelled else { return }
            let deadline = Date().addingTimeInterval(greetingDuration)
            while !Task.isCancelled {
                greeting = Date() < deadline
                let start = bank.start
                let frames = XTouchProjection.frames(strips: strips, master: rack.masterGain,
                    touched: bank.touched, greeting: greeting)
                do {
                    for frame in frames {
                        try Task.checkCancellation()
                        guard start == bank.start else { break }
                        if frame.key.hasPrefix("fader."), let i = Int(frame.key.dropFirst(6)), bank.touched.contains(i) { continue }
                        guard sent[frame.key] != frame.bytes else { continue }
                        try await send(frame.bytes)
                        try Task.checkCancellation()
                        sent[frame.key] = frame.bytes
                    }
                    error = nil
                    try await Task.sleep(for: .milliseconds(50))
                } catch {
                    if Task.isCancelled { break }
                    self.error = "X-Touch送信: \(error.localizedDescription)"
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
        }
    }
    func stop() async {
        connected = false; greeting = false
        task?.cancel()
        await task?.value
        task = nil; sent = [:]; bank.releaseTouches()
    }
}
