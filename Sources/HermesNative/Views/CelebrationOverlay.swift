import SwiftUI

/// Floating confetti particles that burst upward and fall with gravity.
/// Pure SwiftUI — no external assets needed.
struct CelebrationOverlay: View {
    let particles: [ConfettiParticle]
    let onComplete: () -> Void

    @State private var animating = false

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 60, paused: !animating)) { _ in
            Canvas { ctx, size in
                for p in particles {
                    let age = Date().timeIntervalSince(p.birth)
                    let progress = min(age / p.lifetime, 1.0)
                    guard progress < 1.0 else { continue }

                    var x = p.startX * size.width + p.velocityX * age * 60
                    var y = p.startY * size.height - p.velocityY * age * 60 + 0.5 * 300 * age * age

                    // Fade near end
                    let alpha = progress > 0.7 ? 1.0 - (progress - 0.7) / 0.3 : 1.0

                    // Rotation
                    let rotation = p.rotationSpeed * age

                    // Draw
                    ctx.translateBy(x: x, y: y)
                    ctx.rotate(by: .degrees(rotation))
                    ctx.opacity = alpha

                    let rect = CGRect(x: -p.size / 2, y: -p.size / 2, width: p.size, height: p.size)
                    ctx.fill(Path(roundedRect: rect, cornerRadius: p.size * 0.2), with: .color(p.color))

                    ctx.rotate(by: .degrees(-rotation))
                    ctx.translateBy(x: -x, y: -y)
                }
            }
        }
        .allowsHitTesting(false)
        .onAppear {
            animating = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                onComplete()
            }
        }
    }
}

struct ConfettiParticle {
    let color: Color
    let startX: CGFloat // 0..1 relative to width
    let startY: CGFloat // 0..1 relative to height
    let velocityX: CGFloat // horizontal drift per second
    let velocityY: CGFloat // initial upward burst per second
    let rotationSpeed: Double // degrees per second
    let size: CGFloat
    let lifetime: TimeInterval
    let birth = Date()
}

extension ConfettiParticle {
    static func burst(count: Int, colors: [Color] = [.red, .blue, .green, .yellow, .orange, .purple, .pink, .cyan]) -> [ConfettiParticle] {
        (0..<count).map { _ in
            ConfettiParticle(
                color: colors.randomElement() ?? .blue,
                startX: CGFloat.random(in: 0.3...0.7),
                startY: CGFloat.random(in: 0.85...0.95),
                velocityX: CGFloat.random(in: -0.8...0.8),
                velocityY: CGFloat.random(in: 3.0...6.0),
                rotationSpeed: Double.random(in: -180...180),
                size: CGFloat.random(in: 6...12),
                lifetime: TimeInterval.random(in: 1.5...2.5)
            )
        }
    }
}
