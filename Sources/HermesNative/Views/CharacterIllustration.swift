import SwiftUI

/// Black-and-white line-art character illustration.
/// Stylized manga-inspired girl: chin-length dark hair, blunt bangs, headband,
/// Peter Pan collar dress, hands on hips. Above head: scribble cloud + question marks.
/// Pure line art — no color fills beyond black/white/gray.
struct CharacterIllustration: View {
    let mood: Mood
    let frameHeight: CGFloat

    enum Mood {
        case thinking      // confused — scribble cloud + ??
        case speaking      // calm — speaking lines
        case idle          // neutral
    }

    init(mood: Mood = .thinking, frameHeight: CGFloat = Theme.illustrationHeight) {
        self.mood = mood
        self.frameHeight = frameHeight
    }

    private let lineColor = Color.white.opacity(0.85)
    private let fillColor = Color.white.opacity(0.06)
    private let dimColor = Color.white.opacity(0.4)

    var body: some View {
        Canvas { context, size in
            let s = min(size.width / 200, size.height / 300) // scale factor
            let cx = size.width / 2
            let cy = size.height * 0.55 // center offset (leave room for thought cloud)

            // ── Body / Dress ──
            let dressPath = Path { p in
                // Peter Pan collar
                p.move(to: CGPoint(x: cx - 25*s, y: cy - 40*s))
                p.addQuadCurve(to: CGPoint(x: cx, y: cy - 35*s),
                               control: CGPoint(x: cx - 12*s, y: cy - 30*s))
                p.addQuadCurve(to: CGPoint(x: cx + 25*s, y: cy - 40*s),
                               control: CGPoint(x: cx + 12*s, y: cy - 30*s))
                // Left shoulder
                p.addLine(to: CGPoint(x: cx - 35*s, y: cy - 50*s))
                // Left sleeve
                p.addLine(to: CGPoint(x: cx - 50*s, y: cy - 30*s))
                // Left arm (hands on hips)
                p.addQuadCurve(to: CGPoint(x: cx - 45*s, y: cy + 10*s),
                               control: CGPoint(x: cx - 55*s, y: cy - 10*s))
                // Left hand on hip
                p.addQuadCurve(to: CGPoint(x: cx - 30*s, y: cy + 20*s),
                               control: CGPoint(x: cx - 35*s, y: cy + 15*s))
                // Dress body left
                p.addLine(to: CGPoint(x: cx - 20*s, y: cy + 60*s))
                // Skirt left
                p.addQuadCurve(to: CGPoint(x: cx - 40*s, y: cy + 100*s),
                               control: CGPoint(x: cx - 25*s, y: cy + 80*s))
                // Skirt bottom
                p.addLine(to: CGPoint(x: cx + 40*s, y: cy + 100*s))
                // Skirt right
                p.addQuadCurve(to: CGPoint(x: cx + 20*s, y: cy + 60*s),
                               control: CGPoint(x: cx + 25*s, y: cy + 80*s))
                // Right hand on hip
                p.addQuadCurve(to: CGPoint(x: cx + 45*s, y: cy + 10*s),
                               control: CGPoint(x: cx + 35*s, y: cy + 15*s))
                // Right arm
                p.addQuadCurve(to: CGPoint(x: cx + 50*s, y: cy - 30*s),
                               control: CGPoint(x: cx + 55*s, y: cy - 10*s))
                // Right sleeve
                p.addLine(to: CGPoint(x: cx + 35*s, y: cy - 50*s))
                p.closeSubpath()
            }
            context.fill(dressPath, with: .color(fillColor))
            context.stroke(dressPath, with: .color(lineColor), lineWidth: 1.5)

            // ── Collar detail (Peter Pan) ──
            let collarPath = Path { p in
                p.move(to: CGPoint(x: cx - 25*s, y: cy - 40*s))
                p.addQuadCurve(to: CGPoint(x: cx, y: cy - 33*s),
                               control: CGPoint(x: cx - 12*s, y: cy - 28*s))
                p.addQuadCurve(to: CGPoint(x: cx + 25*s, y: cy - 40*s),
                               control: CGPoint(x: cx + 12*s, y: cy - 28*s))
            }
            context.stroke(collarPath, with: .color(lineColor), lineWidth: 1.2)

            // ── Head ──
            let headPath = Path { p in
                p.addEllipse(in: CGRect(
                    x: cx - 28*s, y: cy - 100*s,
                    width: 56*s, height: 60*s
                ))
            }
            context.fill(headPath, with: .color(fillColor))
            context.stroke(headPath, with: .color(lineColor), lineWidth: 1.5)

            // ── Face ──
            // Eyes (simple dots)
            let leftEye = CGRect(x: cx - 12*s, y: cy - 80*s, width: 4*s, height: 4*s)
            let rightEye = CGRect(x: cx + 8*s, y: cy - 80*s, width: 4*s, height: 4*s)
            context.fill(Path(ellipseIn: leftEye), with: .color(lineColor))
            context.fill(Path(ellipseIn: rightEye), with: .color(lineColor))

            // Mouth (small line)
            let mouthPath = Path { p in
                p.move(to: CGPoint(x: cx - 5*s, y: cy - 65*s))
                p.addQuadCurve(to: CGPoint(x: cx + 5*s, y: cy - 65*s),
                               control: CGPoint(x: cx, y: cy - 60*s))
            }
            context.stroke(mouthPath, with: .color(lineColor), lineWidth: 1.2)

            // ── Hair (chin-length, blunt bangs) ──
            let hairPath = Path { p in
                // Bangs across forehead
                p.move(to: CGPoint(x: cx - 30*s, y: cy - 85*s))
                p.addLine(to: CGPoint(x: cx - 28*s, y: cy - 105*s))
                // Top of head
                p.addQuadCurve(to: CGPoint(x: cx, y: cy - 115*s),
                               control: CGPoint(x: cx - 15*s, y: cy - 118*s))
                p.addQuadCurve(to: CGPoint(x: cx + 28*s, y: cy - 105*s),
                               control: CGPoint(x: cx + 15*s, y: cy - 118*s))
                p.addLine(to: CGPoint(x: cx + 30*s, y: cy - 85*s))
                // Blunt bang line
                p.addLine(to: CGPoint(x: cx + 22*s, y: cy - 92*s))
                p.addLine(to: CGPoint(x: cx + 14*s, y: cy - 85*s))
                p.addLine(to: CGPoint(x: cx + 6*s, y: cy - 92*s))
                p.addLine(to: CGPoint(x: cx - 2*s, y: cy - 85*s))
                p.addLine(to: CGPoint(x: cx - 10*s, y: cy - 92*s))
                p.addLine(to: CGPoint(x: cx - 18*s, y: cy - 85*s))
                p.addLine(to: CGPoint(x: cx - 26*s, y: cy - 92*s))
                p.closeSubpath()
            }
            context.fill(hairPath, with: .color(lineColor.opacity(0.8)))

            // Side hair (chin-length sides)
            let leftHairPath = Path { p in
                p.move(to: CGPoint(x: cx - 30*s, y: cy - 85*s))
                p.addQuadCurve(to: CGPoint(x: cx - 35*s, y: cy - 55*s),
                               control: CGPoint(x: cx - 38*s, y: cy - 70*s))
                p.addLine(to: CGPoint(x: cx - 28*s, y: cy - 45*s))
                p.addLine(to: CGPoint(x: cx - 26*s, y: cy - 85*s))
            }
            context.fill(leftHairPath, with: .color(lineColor.opacity(0.7)))

            let rightHairPath = Path { p in
                p.move(to: CGPoint(x: cx + 30*s, y: cy - 85*s))
                p.addQuadCurve(to: CGPoint(x: cx + 35*s, y: cy - 55*s),
                               control: CGPoint(x: cx + 38*s, y: cy - 70*s))
                p.addLine(to: CGPoint(x: cx + 28*s, y: cy - 45*s))
                p.addLine(to: CGPoint(x: cx + 26*s, y: cy - 85*s))
            }
            context.fill(rightHairPath, with: .color(lineColor.opacity(0.7)))

            // ── Headband ──
            let headbandPath = Path { p in
                p.move(to: CGPoint(x: cx - 30*s, y: cy - 92*s))
                p.addQuadCurve(to: CGPoint(x: cx, y: cy - 98*s),
                               control: CGPoint(x: cx - 15*s, y: cy - 100*s))
                p.addQuadCurve(to: CGPoint(x: cx + 30*s, y: cy - 92*s),
                               control: CGPoint(x: cx + 15*s, y: cy - 100*s))
            }
            context.stroke(headbandPath, with: .color(Color(hex: "7c7cff")!.opacity(0.7)), lineWidth: 3*s)
            // Headband bow (right side)
            let bowPath = Path { p in
                p.move(to: CGPoint(x: cx + 28*s, y: cy - 94*s))
                p.addQuadCurve(to: CGPoint(x: cx + 38*s, y: cy - 100*s),
                               control: CGPoint(x: cx + 35*s, y: cy - 102*s))
                p.addQuadCurve(to: CGPoint(x: cx + 32*s, y: cy - 92*s),
                               control: CGPoint(x: cx + 36*s, y: cy - 93*s))
                p.addQuadCurve(to: CGPoint(x: cx + 40*s, y: cy - 86*s),
                               control: CGPoint(x: cx + 38*s, y: cy - 88*s))
                p.addQuadCurve(to: CGPoint(x: cx + 30*s, y: cy - 92*s),
                               control: CGPoint(x: cx + 35*s, y: cy - 88*s))
            }
            context.fill(bowPath, with: .color(Color(hex: "7c7cff")!.opacity(0.5)))

            // ── Legs ──
            let leftLeg = Path { p in
                p.move(to: CGPoint(x: cx - 15*s, y: cy + 100*s))
                p.addLine(to: CGPoint(x: cx - 15*s, y: cy + 130*s))
            }
            context.stroke(leftLeg, with: .color(lineColor), lineWidth: 1.5)

            let rightLeg = Path { p in
                p.move(to: CGPoint(x: cx + 15*s, y: cy + 100*s))
                p.addLine(to: CGPoint(x: cx + 15*s, y: cy + 130*s))
            }
            context.stroke(rightLeg, with: .color(lineColor), lineWidth: 1.5)

            // ── Shoes ──
            let leftShoe = Path { p in
                p.addEllipse(in: CGRect(x: cx - 22*s, y: cy + 128*s, width: 16*s, height: 6*s))
            }
            context.fill(leftShoe, with: .color(lineColor.opacity(0.5)))

            let rightShoe = Path { p in
                p.addEllipse(in: CGRect(x: cx + 6*s, y: cy + 128*s, width: 16*s, height: 6*s))
            }
            context.fill(rightShoe, with: .color(lineColor.opacity(0.5)))

            // ── Mood indicators ──
            if mood == .thinking {
                drawThinkingCloud(context: context, cx: cx, cy: cy, s: s)
            } else if mood == .speaking {
                drawSpeakingLines(context: context, cx: cx, cy: cy, s: s)
            }
        }
        .frame(height: frameHeight)
    }

    private func drawThinkingCloud(context: GraphicsContext, cx: CGFloat, cy: CGFloat, s: CGFloat) {
        // Scribble cloud above head
        let cloudPath = Path { p in
            p.move(to: CGPoint(x: cx - 15*s, y: cy - 135*s))
            p.addCurve(to: CGPoint(x: cx - 5*s, y: cy - 145*s),
                       control1: CGPoint(x: cx - 18*s, y: cy - 150*s),
                       control2: CGPoint(x: cx - 12*s, y: cy - 150*s))
            p.addCurve(to: CGPoint(x: cx + 5*s, y: cy - 140*s),
                       control1: CGPoint(x: cx + 2*s, y: cy - 148*s),
                       control2: CGPoint(x: cx + 8*s, y: cy - 145*s))
            p.addCurve(to: CGPoint(x: cx + 15*s, y: cy - 148*s),
                       control1: CGPoint(x: cx + 10*s, y: cy - 145*s),
                       control2: CGPoint(x: cx + 18*s, y: cy - 150*s))
            p.addCurve(to: CGPoint(x: cx + 8*s, y: cy - 135*s),
                       control1: CGPoint(x: cx + 12*s, y: cy - 138*s),
                       control2: CGPoint(x: cx + 10*s, y: cy - 132*s))
            // Tangled scribble inside
            p.move(to: CGPoint(x: cx - 8*s, y: cy - 140*s))
            p.addCurve(to: CGPoint(x: cx + 3*s, y: cy - 138*s),
                       control1: CGPoint(x: cx - 5*s, y: cy - 145*s),
                       control2: CGPoint(x: cx + 1*s, y: cy - 143*s))
            p.addCurve(to: CGPoint(x: cx + 10*s, y: cy - 142*s),
                       control1: CGPoint(x: cx + 5*s, y: cy - 136*s),
                       control2: CGPoint(x: cx + 8*s, y: cy - 144*s))
        }
        context.stroke(cloudPath, with: .color(dimColor), lineWidth: 1.5)

        // Question marks
        let qFont = Font.system(size: 18 * s, weight: .bold, design: .rounded)
        context.draw(
            Text("?")
                .font(qFont)
                .foregroundStyle(.white.opacity(0.6)),
            at: CGPoint(x: cx - 20*s, y: cy - 155*s)
        )
        context.draw(
            Text("?")
                .font(Font.system(size: 14 * s, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.4)),
            at: CGPoint(x: cx + 22*s, y: cy - 152*s)
        )

        // Small connecting bubbles
        let bubble1 = Path(ellipseIn: CGRect(x: cx - 3*s, y: cy - 122*s, width: 4*s, height: 4*s))
        context.fill(bubble1, with: .color(dimColor))
        let bubble2 = Path(ellipseIn: CGRect(x: cx - 6*s, y: cy - 128*s, width: 6*s, height: 6*s))
        context.fill(bubble2, with: .color(dimColor.opacity(0.6)))
    }

    private func drawSpeakingLines(context: GraphicsContext, cx: CGFloat, cy: CGFloat, s: CGFloat) {
        // Small speech indicator
        let lines = Path { p in
            p.move(to: CGPoint(x: cx + 30*s, y: cy - 75*s))
            p.addLine(to: CGPoint(x: cx + 42*s, y: cy - 75*s))
            p.move(to: CGPoint(x: cx + 30*s, y: cy - 70*s))
            p.addLine(to: CGPoint(x: cx + 38*s, y: cy - 70*s))
            p.move(to: CGPoint(x: cx + 30*s, y: cy - 65*s))
            p.addLine(to: CGPoint(x: cx + 35*s, y: cy - 65*s))
        }
        context.stroke(lines, with: .color(dimColor), lineWidth: 1.5)
    }
}
