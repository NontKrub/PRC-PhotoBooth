import Testing

@testable import PRC_PhotoBooth_Mac

@Suite("Selection logic")
struct SelectionLogicTests {
    @Test("Command selection toggles one ID")
    func togglesSelection() {
        #expect(SelectionLogic.toggled(["a"], id: "b") == ["a", "b"])
        #expect(SelectionLogic.toggled(["a", "b"], id: "b") == ["a"])
    }

    @Test("Range selection returns the inclusive ordered range")
    func selectsRange() {
        #expect(SelectionLogic.range(from: "b", to: "d", in: ["a", "b", "c", "d", "e"]) == ["b", "c", "d"])
        #expect(SelectionLogic.range(from: "d", to: "b", in: ["a", "b", "c", "d", "e"]) == ["b", "c", "d"])
    }

    @Test("Missing range anchor falls back to the target")
    func missingAnchorFallsBack() {
        #expect(SelectionLogic.range(from: "missing", to: "c", in: ["a", "b", "c"]) == ["c"])
    }

    @Test("batch deletion identifies an included active event")
    func deletionPlanIncludesActiveEvent() {
        let plan = EventSelectionLogic.deletionPlan(selectedIDs: ["a", "b"], activeID: "b")
        #expect(plan.ids == ["a", "b"])
        #expect(plan.removesActiveEvent)
    }

    @Test("batch deletion leaves the active event alone when it is not selected")
    func deletionPlanKeepsActiveEvent() {
        let plan = EventSelectionLogic.deletionPlan(selectedIDs: ["a"], activeID: "b")
        #expect(!plan.removesActiveEvent)
    }

    @Test("duplicate IDs are unique and z-order continues after existing elements")
    func duplicateIDsAndZOrder() {
        var candidates = ["existing", "existing", "copy-1", "copy-2"]
        let ids = SelectionLogic.uniqueIDs(count: 2, existing: ["existing"]) { candidates.removeFirst() }
        #expect(ids == ["copy-1", "copy-2"])
        #expect(SelectionLogic.nextZOrders(existing: [0, 4, 2], count: 2) == [5, 6])
    }
}
