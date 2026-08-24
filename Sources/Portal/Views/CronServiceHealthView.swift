import SwiftUI

internal struct CronServiceHealthBadge: View {
    internal let health: CronServiceHealth

    private var color: Color {
        health.isHealthy ? .green : (health.isUnhealthy ? .red : .orange)
    }

    internal var body: some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(health.status.capitalized)
                .font(.system(size: 9, weight: .semibold))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(color.opacity(0.12), in: Capsule())
    }
}

internal struct CronServiceHealthDetails: View {
    internal let health: CronServiceHealth

    internal var body: some View {
        Divider().overlay(Theme.border.opacity(0.4)).padding(.vertical, 2)
        Text("HEALTH")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(Theme.secondary.opacity(0.65))
        detailRow(icon: "stethoscope", value: "\(health.probe) probe · \(health.message)")
        if !health.target.isEmpty {
            detailRow(icon: "scope", value: health.target)
        }
        if health.latencyMilliseconds > 0 {
            detailRow(icon: "timer", value: String(format: "%.1f ms", health.latencyMilliseconds))
        }
        if !health.checkedAt.isEmpty {
            detailRow(icon: "clock.arrow.circlepath", value: health.checkedAt)
        }
    }

    private func detailRow(icon: String, value: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 9))
                .foregroundStyle(Theme.secondary.opacity(0.7))
                .frame(width: 12)
            Text(value)
                .font(.system(size: 10))
                .foregroundStyle(Theme.secondary)
                .lineLimit(1)
        }
    }
}
