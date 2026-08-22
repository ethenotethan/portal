import SwiftUI

/// The Cron Activity surface as a scrolling stack of sections. Used on iOS (and
/// as the pushed detail from the cron list). On macOS the same sections are
/// hosted as a free-form draggable canvas — see `CronDashboardCanvas`.
struct CronDashboardView: View {
    @EnvironmentObject var gatewayClientWrapper: GatewayClientWrapper
    @ObservedObject var store: CronRunHistoryStore = .shared
    @State private var cronListVM = CronListViewModel()
    @StateObject private var cronGraphVM = CronGraphViewModel()
    @State private var timeHorizon: CronTimeHorizon = .day
    @State private var isGraphExpanded = false

    private var filteredRecords: [CronRunRecord] {
        CronRunMetrics.filter(store.allRecordsSorted(), horizon: timeHorizon)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerBar

            Divider().background(Theme.border)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // On the macOS canvas the Jobs panel (and its folder tree) is
                    // visible beside the charts. In this single-column compact
                    // surface, placing two metric panels first pushed categories
                    // below the initial viewport and made them appear absent.
                    // Keep the actionable job hierarchy first; activity metrics
                    // follow once the user scrolls.
                    CronJobsView(vm: cronListVM)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
                    dataflowSection
                    CronSummaryView(records: filteredRecords)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
                    CronVolumeView(records: filteredRecords, horizon: timeHorizon)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .refreshable { await refreshData() }
        }
        .background(Theme.background)
        #if !os(macOS)
        .fullScreenCover(isPresented: $isGraphExpanded) {
            CronDataflowExpandedView(
                graphVM: cronGraphVM,
                listVM: cronListVM,
                onDismiss: { isGraphExpanded = false }
            )
            .environmentObject(gatewayClientWrapper)
        }
        #endif
        .task { await refreshData() }
    }

    private func refreshData() async {
        cronListVM.setGatewayClient(gatewayClientWrapper.client)
        await cronListVM.refreshJobs()
        store.seedFromJobs(cronListVM.jobs)
        store.detectNewRuns(from: cronListVM.jobs)
    }

    /// A labeled preview makes the graph discoverable on a compact screen. The
    /// previous icon-only control lived inside the canvas alongside zoom/reset,
    /// so it read as another graph tool rather than navigation. Keep expansion
    /// in the section chrome with a clear labeled, 44-point tap target on iOS.
    private var dataflowSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Data flow")
                    .font(.headline)
                    .foregroundStyle(Theme.primary)
                Text("Explore how jobs read, write, and deliver data")
                    .font(.caption)
                    .foregroundStyle(Theme.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)

            Button {
                isGraphExpanded = true
            } label: {
                Label("Expand data flow", systemImage: "arrow.up.left.and.arrow.down.right")
                    .font(.subheadline.weight(.medium))
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.accent)
            .background(Theme.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 9))
            .padding(.horizontal, 8)
            .accessibilityIdentifier("cron.dataflow.expand")

            CronInterflowGraphView(viewModel: cronGraphVM)
                .environmentObject(gatewayClientWrapper)
                .frame(height: 320)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .padding([.horizontal, .bottom], 8)
        }
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
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
