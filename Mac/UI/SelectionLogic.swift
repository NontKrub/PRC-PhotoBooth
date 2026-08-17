import Foundation

enum SelectionLogic {
    static func toggled<T: Hashable>(_ selection: Set<T>, id: T) -> Set<T> {
        var next = selection
        if !next.insert(id).inserted { next.remove(id) }
        return next
    }

    static func range<T: Hashable>(from anchor: T, to target: T, in orderedIDs: [T]) -> Set<T> {
        guard let start = orderedIDs.firstIndex(of: anchor),
              let end = orderedIDs.firstIndex(of: target) else { return [target] }
        return Set(orderedIDs[min(start, end)...max(start, end)])
    }

    static func uniqueIDs(
        count: Int,
        existing: Set<String>,
        makeID: () -> String
    ) -> [String] {
        var used = existing
        var result: [String] = []
        for _ in 0..<count {
            var candidate = makeID()
            while !used.insert(candidate).inserted { candidate = makeID() }
            result.append(candidate)
        }
        return result
    }

    static func nextZOrders(existing: [Int], count: Int) -> [Int] {
        let first = (existing.max() ?? -1) + 1
        return (0..<count).map { first + $0 }
    }
}

struct EventDeletionPlan: Equatable {
    let ids: Set<String>
    let removesActiveEvent: Bool
}

enum EventSelectionLogic {
    static func deletionPlan(selectedIDs: Set<String>, activeID: String?) -> EventDeletionPlan {
        EventDeletionPlan(
            ids: selectedIDs,
            removesActiveEvent: activeID.map(selectedIDs.contains) ?? false
        )
    }
}
