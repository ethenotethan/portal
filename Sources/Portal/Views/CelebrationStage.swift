import SwiftUI
import Combine

/// The shared stage every celebration style performs on.
///
/// Owns the timeline — it walks `CelebrationBeat.sequence` and publishes the
/// current beat — so a style only has to draw a pose for a beat. That is the
/// plug point the confetti overlay never had: adding an effect means a
/// `CelebrationStyle` case and a branch here, not touching the presentation
/// site or the manager.
///
/// Driven by a single `Timer` publisher rather than `TimelineView(.animation)`
/// because the poses are spring transitions between discrete states, not a
/// per-frame integration; a 60fps redraw of the whole character to animate seven
/// steps is the sort of thing that put the app at 100% CPU in the markdown path.
internal struct CelebrationStage: View {
    internal let event: CelebrationManager.CelebrationEvent
    internal let preferences: CelebrationPreferences
    internal let onComplete: () -> Void

    @State private var beat: CelebrationBeat = .offstage
    @State private var startDate: Date?

    /// Tick fast enough that a beat boundary lands within a frame or two of its
    /// scheduled time — the shortest beat is 0.15s.
    private static let tickInterval: TimeInterval = 1.0 / 30.0

    internal var body: some View {
        ZStack {
            // Particles are additive: they run behind whichever style is on
            // stage, and the toggle removes them without removing the effect.
            if preferences.shouldDrawParticles {
                CelebrationOverlay(
                    particles: ConfettiParticle.burst(count: preferences.resolvedParticleCount),
                    onComplete: {}
                )
            }

            performer
        }
        .allowsHitTesting(false)
        .onAppear(perform: start)
        .onReceive(ticker) { _ in advance() }
    }

    private var ticker: Publishers.Autoconnect<Timer.TimerPublisher> {
        Timer.publish(every: Self.tickInterval, on: .main, in: .common).autoconnect()
    }

    @ViewBuilder
    private var performer: some View {
        switch preferences.style {
        case .confetti:
            // Particles alone, already drawn above. Nothing to stage.
            EmptyView()
        case .monkey:
            VStack {
                Spacer()
                MonkeyCelebrationView(beat: beat, message: event.message)
                    .padding(.bottom, 48)
            }
        case .card:
            VStack {
                Spacer()
                MilestoneCardView(beat: beat, badge: event.badge, message: event.message)
                    .padding(.bottom, 64)
            }
        }
    }

    private func start() {
        startDate = Date()
        beat = CelebrationBeat.beat(at: 0)
    }

    private func advance() {
        guard let startDate else { return }
        let elapsed = Date().timeIntervalSince(startDate)
        let next = CelebrationBeat.beat(at: elapsed)
        if next != beat {
            // The pose change is what gets animated; the beat itself is a step
            // function. Spring on the way in, ease on the way out.
            withAnimation(next.isShaking ? .linear(duration: 0.08) : .spring(response: 0.32, dampingFraction: 0.62)) {
                beat = next
            }
        }
        if elapsed >= CelebrationBeat.totalDuration {
            self.startDate = nil
            onComplete()
        }
    }
}
