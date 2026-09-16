import SwiftUI

/// The inline "voice turn" that replaces the tool-trace streaming panel while a
/// hands-free conversation is live. It sits in the message stream where the
/// streaming bubble would be, so prior turns stay visible above it.
///
/// The look is chosen in Settings (`ConversationVisual`): a warm organic orb
/// modeled on Claude's voice mode, or a glowing gradient sphere modeled on
/// OpenAI's. Both animate through the same three phases — listening, thinking,
/// speaking — reading state straight off `ChatViewModel`.
internal struct VoiceConversationCard: View {
    @ObservedObject internal var chatViewModel: ChatViewModel

    internal var body: some View {
        let phase = chatViewModel.conversationPhase
        let caption = chatViewModel.conversationCaption

        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 14) {
                orb(for: phase)
                    .frame(width: 56, height: 56)

                VStack(alignment: .leading, spacing: 3) {
                    Text(phaseLabel(phase))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.secondary)
                    Text("In conversation")
                        .font(.caption2)
                        .foregroundStyle(Theme.tertiary)
                }

                Spacer(minLength: 8)

                Button {
                    Task { await chatViewModel.endConversation() }
                } label: {
                    Text("End")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Theme.surfaceHover, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("End conversation")
            }

            if !caption.isEmpty {
                Text(phase == .listening ? "\u{201C}\(caption)\u{201D}" : caption)
                    .font(.callout)
                    .foregroundStyle(phase == .listening ? Theme.secondary : Theme.primary)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Theme.accent.opacity(0.25), lineWidth: 1)
        )
        .animation(.easeInOut(duration: 0.2), value: phase)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Voice conversation, \(phaseLabel(phase))")
    }

    @ViewBuilder
    private func orb(for phase: ChatViewModel.ConversationPhase) -> some View {
        switch chatViewModel.conversationVisual {
        case .claude: ClaudeOrb(phase: phase)
        case .openai: OpenAIOrb(phase: phase)
        }
    }

    private func phaseLabel(_ phase: ChatViewModel.ConversationPhase) -> String {
        switch phase {
        case .listening: "Listening\u{2026}"
        case .thinking: "Thinking\u{2026}"
        case .speaking: "Speaking"
        }
    }
}

// MARK: - Claude-style organic orb

/// A warm, morphing blob whose outline wobbles with layered sine waves and
/// whose glow breathes. Livelier while speaking, calmer while listening.
private struct ClaudeOrb: View {
    internal let phase: ChatViewModel.ConversationPhase

    /// Outline wobble amount by phase — how far the blob departs from a circle.
    private var wobble: Double {
        switch phase {
        case .listening: 0.05
        case .thinking: 0.07
        case .speaking: 0.13
        }
    }

    /// Animation speed by phase.
    private var speed: Double {
        switch phase {
        case .listening: 1.4
        case .thinking: 1.0
        case .speaking: 3.0
        }
    }

    private static let warm = Gradient(colors: [
        Color(red: 1.00, green: 0.88, blue: 0.74),
        Color(red: 0.97, green: 0.60, blue: 0.38),
        Color(red: 0.86, green: 0.34, blue: 0.26)
    ])

    internal var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let glowScale = CGFloat(0.9 + 0.08 * (0.5 + 0.5 * sin(t * speed)))
            ZStack {
                // Breathing glow behind the blob.
                Circle()
                    .fill(Color(red: 0.97, green: 0.60, blue: 0.38).opacity(0.35))
                    .blur(radius: 10)
                    .scaleEffect(glowScale)

                Canvas { ctx, size in
                    let center = CGPoint(x: size.width / 2, y: size.height / 2)
                    let base = min(size.width, size.height) / 2 * 0.72
                    let path = Self.blobPath(center: center, base: base, wobble: wobble, speed: speed, t: t)
                    ctx.fill(
                        path,
                        with: .radialGradient(
                            Self.warm,
                            center: center,
                            startRadius: 0,
                            endRadius: base * 1.25
                        )
                    )
                }
            }
        }
    }

    /// The morphing outline for one animation frame, factored out of `body` so
    /// the SwiftUI type-checker doesn't choke on the whole expression at once.
    private static func blobPath(
        center: CGPoint,
        base: CGFloat,
        wobble: Double,
        speed: Double,
        t: Double
    ) -> Path {
        var path = Path()
        let steps = 60
        for i in 0...steps {
            let a = Double(i) / Double(steps) * 2 * .pi
            let w = wobble * (sin(a * 3 + t * speed) + 0.5 * sin(a * 5 - t * speed * 0.7))
            let r = base * CGFloat(1 + w)
            let point = CGPoint(x: center.x + cos(a) * r, y: center.y + sin(a) * r)
            if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }
}

// MARK: - OpenAI-style gradient sphere

/// A glowing blue/violet sphere ringed by expanding sonar pulses. Rings ripple
/// outward while listening; the core shimmers (rotates its highlight) while
/// speaking.
private struct OpenAIOrb: View {
    internal let phase: ChatViewModel.ConversationPhase

    private var ringSpeed: Double {
        switch phase {
        case .listening: 0.8
        case .thinking: 0.5
        case .speaking: 1.3
        }
    }

    private static let sphere = Gradient(colors: [
        Color(red: 0.45, green: 0.75, blue: 1.00),
        Color(red: 0.25, green: 0.45, blue: 0.98),
        Color(red: 0.52, green: 0.24, blue: 0.92)
    ])

    internal var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            ZStack {
                // Sonar rings — three staggered pulses expanding and fading.
                ForEach(0..<3, id: \.self) { index in
                    let progress = (t * ringSpeed + Double(index) / 3).truncatingRemainder(dividingBy: 1)
                    Circle()
                        .strokeBorder(Color(red: 0.35, green: 0.55, blue: 1.0), lineWidth: 1.5)
                        .scaleEffect(0.55 + progress * 0.6)
                        .opacity((1 - progress) * 0.5)
                }

                // Core sphere with a rotating specular highlight while speaking.
                Circle()
                    .fill(
                        RadialGradient(
                            gradient: Self.sphere,
                            center: .init(x: 0.38, y: 0.34),
                            startRadius: 1,
                            endRadius: 34
                        )
                    )
                    .scaleEffect(0.62 + (phase == .speaking ? 0.05 * (0.5 + 0.5 * sin(t * 6)) : 0))
                    .overlay(
                        Circle()
                            .fill(Color.white.opacity(0.35))
                            .frame(width: 10, height: 10)
                            .offset(
                                x: cos(t * (phase == .speaking ? 3 : 0.6)) * 8,
                                y: sin(t * (phase == .speaking ? 3 : 0.6)) * 8
                            )
                            .blur(radius: 3)
                            .scaleEffect(0.62)
                    )
                    .shadow(color: Color(red: 0.3, green: 0.4, blue: 1.0).opacity(0.6), radius: 12)
            }
        }
    }
}
