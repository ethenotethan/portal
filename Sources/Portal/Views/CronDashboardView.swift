import SwiftUI

/// The Cron Activity surface as a scrolling stack of sections. Used on iOS (and
/// as the pushed detail from the cron list). On macOS the same sections are
/// hosted as a free-form draggable canvas — see `CronDashboardCanvas`.
struct CronDashboardView: View {
    @EnvironmentObject var gatewayClientWrapper: GatewayClientWrapper
    @ObservedObject var store: CronRunHistoryStore = .shared
    @State private var cronListVM = CronListViewModel()
    @State private var timeHorizon: CronTimeHorizon = .day

    private var filteredRecords: [CronRunRecord] {
        CronRunMetrics.filter(store.allRecordsSorted(), horizon: timeHorizon)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerBar

            Divider().background(Theme.border)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    CronSummaryView(records: filteredRecords)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
                    CronVolumeView(records: filteredRecords, horizon: timeHorizon)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
                    CronJobsView(vm: cronListVM)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
                    if !filteredRecords.isEmpty {
                        CronTimelineView(records: filteredRecords, horizon: timeHorizon)
                            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
                        CronBreakdownView(records: filteredRecords)
                            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .refreshable { await refreshData() }
        }
        .background(Theme.background)
        .task { await refreshData() }
    }

    private func refreshData() async {
        cronListVM.setGatewayClient(gatewayClientWrapper.client)
        await cronListVM.refreshJobs()
        store.seedFromJobs(cronListVM.jobs)
        store.detectNewRuns(from: cronListVM.jobs)
    }

    private var headerBar: some View {
        HStack(spacing: 12) {
            Text("Cron Activity")
                .font(.headline)
                .foregroundStyle(Theme.primary)

            Spacer()

            // Themed capsule control, matching the rest of the app's chrome —
            // not the stock segmented picker, which ignores the palette.
            ThemedSegmentedControl(
                selection: $timeHorizon,
                options: CronTimeHorizon.allCases,
                label: { $0.rawValue }
            )
            .frame(width: 280)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Theme.surface)
    }
}
