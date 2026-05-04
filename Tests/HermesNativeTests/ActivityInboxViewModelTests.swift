import Testing
import Foundation
@testable import HermesNative

@Suite("Activity Inbox ViewModel")
@MainActor
struct ActivityInboxViewModelTests {
    @Test("created and updated events are sorted newest first")
    func upsertsAndSortsEvents() {
        let vm = ActivityInboxViewModel()

        vm.applyForTesting(.activityCreated(ActivityItem(
            id: "old",
            createdAt: Date(timeIntervalSince1970: 10),
            kind: "activity",
            severity: .info,
            source: "test",
            title: "Old",
            summary: "",
            isRead: false,
            isDismissed: false,
            actions: [],
            artifacts: [],
            externalRefs: []
        )))
        vm.applyForTesting(.activityCreated(ActivityItem(
            id: "new",
            createdAt: Date(timeIntervalSince1970: 20),
            kind: "activity",
            severity: .info,
            source: "test",
            title: "New",
            summary: "",
            isRead: false,
            isDismissed: false,
            actions: [],
            artifacts: [],
            externalRefs: []
        )))

        #expect(vm.items.map(\.id) == ["new", "old"])
    }

    @Test("dismissed activity update removes the item and clears selection")
    func dismissedUpdateRemovesItem() {
        let vm = ActivityInboxViewModel()
        let item = ActivityItem(
            id: "dismiss-me",
            createdAt: Date(timeIntervalSince1970: 10),
            kind: "activity",
            severity: .warning,
            source: "test",
            title: "Dismiss me",
            summary: "",
            isRead: false,
            isDismissed: false,
            actions: [],
            artifacts: [],
            externalRefs: []
        )
        vm.applyForTesting(.activityCreated(item))
        vm.selectedItem = item

        var dismissed = item
        dismissed.isDismissed = true
        vm.applyForTesting(.activityUpdated(dismissed))

        #expect(vm.items.isEmpty)
        #expect(vm.selectedItem == nil)
    }
}
