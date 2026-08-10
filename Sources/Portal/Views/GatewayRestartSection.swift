import SwiftUI

/// The "Restart gateway" control for a harness's settings pane.
///
/// Exists because the gateway's `gateway.restart` RPC had no caller: the
/// process could re-exec itself on request, but nothing in the app ever asked,
/// so picking up pulled backend code meant going to the host and bouncing it by
/// hand. The gateway side was built with this control in mind — it is
/// deliberately RPC-only and not an agent tool, so the restart is the user's to
/// trigger.
///
/// Confirmed rather than one-tap: a restart interrupts every in-flight turn on
/// that gateway, which is not recoverable by pressing the button again.
internal struct GatewayRestartSection: View {
    /// The live transport for this harness. `nil` when nothing is dialing it —
    /// there is no process to talk to, so there is nothing to restart.
    internal let client: GatewayClient?

    @EnvironmentObject private var capabilitiesStore: GatewayCapabilitiesStore
    @StateObject private var controller = GatewayRestartController()
    @State private var showConfirm = false

    internal var body: some View {
        if capabilitiesStore.capabilities.supportsGatewayRestart {
            VStack(alignment: .leading, spacing: 8) {
                Text("Restart")
                    .font(.headline)

                Text("Restarts the gateway process so it loads updated backend code. "
                     + "Sessions, skills and memories on the host are untouched; any turn "
                     + "running right now is interrupted.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    Button {
                        showConfirm = true
                    } label: {
                        Label(
                            controller.phase.isBusy ? "Restarting…" : "Restart Gateway",
                            systemImage: "arrow.clockwise.circle"
                        )
                    }
                    .portalButton(size: .small)
                    .disabled(client == nil || controller.phase.isBusy)

                    if controller.phase.isBusy {
                        ProgressView()
                            .controlSize(.small)
                    }
                }

                if let status = statusText {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(statusColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .confirmationDialog(
                "Restart the gateway?",
                isPresented: $showConfirm,
                titleVisibility: .visible
            ) {
                Button("Restart", role: .destructive) {
                    guard let client else { return }
                    controller.restart(client: client, capabilities: capabilitiesStore)
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Any turn in progress on this harness is interrupted. "
                     + "The app reconnects on its own once the gateway is back.")
            }
            // A result from a previous visit is stale news; start each visit
            // with no claim about the gateway's state.
            .onAppear { if !controller.phase.isBusy { controller.reset() } }
        }
    }

    /// The offline case gets its own line: the button is disabled and saying
    /// nothing would read as the control being broken.
    private var statusText: String? {
        if client == nil { return "Connect this harness to restart its gateway." }
        return controller.phase.statusText
    }

    private var statusColor: Color {
        guard client != nil else { return Theme.secondary }
        switch controller.phase {
        case .succeeded: return Theme.success
        case .failed, .unsupported: return Theme.warning
        case .idle, .requesting, .waitingForGateway: return Theme.secondary
        }
    }
}
