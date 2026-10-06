//! nanoKONTROL2: S で開く → その列のノブで候補 → S で確定。
import Foundation

enum StudioKeyboard: String, CaseIterable, Identifiable {
    case numa, keystage, miniLab
    var id: String { rawValue }
    var title: String {
        switch self { case .numa: "Numa"; case .keystage: "Keystage"; case .miniLab: "MiniLab" }
    }
}

struct StudioTrackSelection: Equatable {
    struct Pending: Equatable {
        var slot: Int
        var keyboard: StudioKeyboard
    }
    private(set) var pending: Pending?

    mutating func press(slot: Int, current: StudioKeyboard?) -> Pending? {
        if let pending, pending.slot == slot {
            self.pending = nil
            return pending
        }
        pending = Pending(slot: slot, keyboard: current ?? .numa)
        return nil
    }
    mutating func turn(slot: Int, value: UInt8) {
        guard pending?.slot == slot else { return }
        pending?.keyboard = StudioKeyboard.allCases[min(2, Int(value) * 3 / 128)]
    }
    mutating func cancel() { pending = nil }

    static func bankTarget(selected: Int, trackCount: Int, direction: Int) -> Int {
        let current = selected / 8
        let last = max(0, (trackCount - 1) / 8)
        let next = min(last, max(0, current + direction))
        return next == current ? selected : next * 8
    }
}
