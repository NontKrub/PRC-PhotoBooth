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

    @Test("restored anchor stays selected and valid")
    func restoresAnchor() {
        #expect(SelectionLogic.restoredAnchor("b", selection: ["a", "b"], validElements: ["a", "b"]) == "b")
        #expect(SelectionLogic.restoredAnchor("missing", selection: ["a"], validElements: ["a"]) == "a")
        #expect(SelectionLogic.restoredAnchor("b", selection: ["a"], validElements: ["a", "b"]) == "a")
        #expect(SelectionLogic.restoredAnchor("b", selection: [], validElements: ["a", "b"]) == nil)
    }

    @Test("activating one event leaves only that event active")
    func activeEventSelectionIsExclusive() {
        #expect(EventSelectionLogic.activeIDs(eventIDs: ["a", "b"], selectedID: "b") == ["b"])
        #expect(EventSelectionLogic.activeIDs(eventIDs: ["a", "b"], selectedID: nil).isEmpty)
        #expect(EventSelectionLogic.activeIDs(eventIDs: ["a", "b"], selectedID: "missing").isEmpty)
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

    @Test("context-menu delete keeps the full selection for a selected event")
    func contextMenuDeleteUsesSelection() {
        #expect(EventSelectionLogic.contextMenuDeletionIDs(
            clickedID: "a",
            selectedIDs: ["a", "b", "c"]
        ) == ["a", "b", "c"])
    }

    @Test("context-menu delete targets only an unselected event")
    func contextMenuDeleteUsesClickedEvent() {
        #expect(EventSelectionLogic.contextMenuDeletionIDs(
            clickedID: "c",
            selectedIDs: ["a", "b"]
        ) == ["c"])
    }

    @Test("duplicate IDs are unique and z-order continues after existing elements")
    func duplicateIDsAndZOrder() {
        var candidates = ["existing", "existing", "copy-1", "copy-2"]
        let ids = SelectionLogic.uniqueIDs(count: 2, existing: ["existing"]) { candidates.removeFirst() }
        #expect(ids == ["copy-1", "copy-2"])
        #expect(SelectionLogic.nextZOrders(existing: [0, 4, 2], count: 2) == [5, 6])
    }
}
