import SceneKit
import SwiftUI

#if os(macOS)
internal typealias SceneColor = NSColor
/// `SCNVector3`'s components and `eulerAngles` are `CGFloat` on macOS and
/// `Float` on iOS. Posing code writes scalars constantly, so it goes through
/// this alias rather than sprinkling casts at every assignment.
internal typealias SceneScalar = CGFloat
#else
internal typealias SceneColor = UIColor
internal typealias SceneScalar = Float
#endif

/// The monkey as actual 3D geometry: spheres, capsules and boxes with materials
/// and lights, posed by `CelebrationBeat`.
///
/// Built in code rather than loaded from a `.scn`/`.usdz` asset so a celebration
/// cannot fail to appear because a bundled file did not resolve. Geometry in
/// code always resolves.
///
/// The rig is a node hierarchy so a pose is a handful of rotations rather than
/// recomputed vertices. Named pivots (`rig`, `armPivot`, `head`) are the only
/// things `apply(beat:)` touches; the limb meshes hang off them and follow.
@MainActor
internal final class MonkeyScene {

    internal let scene = SCNScene()
    internal let cameraNode = SCNNode()

    /// Everything that moves as one body: what rises, exits, and shakes.
    private let rig = SCNNode()
    /// Shoulder pivot for the pistol arm — rotating this swings the whole arm
    /// and the gun in its hand, which is why the gun needed no counter-rotation
    /// the way the flat version did.
    private let armPivot = SCNNode()
    private let head = SCNNode()
    private let muzzleFlash = SCNNode()
    private let leftEye = SCNNode()
    private let rightEye = SCNNode()
    private let mouth = SCNNode()

    /// How far below the frame the rig sits when offstage, in scene units.
    private static let offstageDrop: SceneScalar = -7.0
    /// Aiming pose for the pistol arm, as (x, z) euler angles.
    ///
    /// Mostly a swing OUTWARD (z) with only a little forward lean (x). Aiming
    /// straight down the camera axis was the obvious reading of "points at the
    /// viewer" and it renders as nothing: the arm foreshortens into the torso
    /// and all that survives is the muzzle disc. Out to the side, the raised
    /// limb and the gun both have a silhouette.
    /// Past 90°, because the limb hangs DOWN at rest: 60° only swings it to
    /// diagonally-down-and-out, and 90° is horizontal. Raising it above the
    /// shoulder — which is what "holds the gun up" means — needs the overswing.
    private static let aimOutward: SceneScalar = 2.15   // ≈ 123°, up and out
    private static let aimForward: SceneScalar = -0.5   // ≈ −29° toward camera

    /// Resting arm angle — a slight outward hang so the limb clears the torso
    /// instead of disappearing behind its widest point.
    private static let armRest: SceneScalar = 0.2

    private static let fur = SceneColor(red: 0.42, green: 0.30, blue: 0.22, alpha: 1)
    private static let skin = SceneColor(red: 0.85, green: 0.70, blue: 0.56, alpha: 1)
    private static let metal = SceneColor(red: 0.26, green: 0.27, blue: 0.30, alpha: 1)
    private static let dark = SceneColor(red: 0.05, green: 0.04, blue: 0.04, alpha: 1)

    internal init() {
        scene.background.contents = SceneColor.clear
        buildLights()
        buildCamera()
        buildBody()
        scene.rootNode.addChildNode(rig)
        // Start below the frame so the first beat is genuinely a rise, not a
        // pop-in at final position.
        rig.position.y = Self.offstageDrop
    }

    // MARK: - Posing

    /// Move the rig to `beat`'s pose, animating over the beat's own duration so
    /// the motion and the timeline can't drift apart.
    ///
    /// - Parameter animated: false snaps straight to the pose. Used for the
    ///   initial pose (there is nothing to interpolate from) and by offline
    ///   renders, where no display link runs to advance a `CAAnimation` and an
    ///   animated write would render at its *start* value.
    internal func apply(_ beat: CelebrationBeat, animated: Bool = true) {
        SCNTransaction.begin()
        SCNTransaction.animationDuration = animated ? max(beat.duration, 0.08) : 0
        // Ease both ends; the shake is driven by discrete flips, which read
        // better linear.
        SCNTransaction.animationTimingFunction = CAMediaTimingFunction(
            name: beat.isShaking ? .linear : .easeInEaseOut
        )

        rig.position.y = beat == .offstage || beat == .exit ? Self.offstageDrop : 0
        armPivot.eulerAngles.x = beat.isAiming ? Self.aimForward : 0
        // POSITIVE z sweeps the +x arm away from the body: rotating the
        // downward (0,−1) limb by +θ carries its tip to +x. Negative swings it
        // across the torso instead, which renders as the gun appearing on the
        // wrong side of the body.
        armPivot.eulerAngles.z = beat.isAiming ? Self.aimOutward : Self.armRest

        // Sighting down the barrel: narrow the eyes by squashing them, and tip
        // the head forward a touch.
        let squint: SceneScalar = beat.isAiming ? 0.35 : 1.0
        leftEye.scale = SCNVector3(1, squint, 1)
        rightEye.scale = SCNVector3(1, squint, 1)
        head.eulerAngles.x = beat.isAiming ? -0.12 : 0

        // Mouth opens on the line.
        mouth.scale = beat.isSpeaking ? SCNVector3(1.5, 2.4, 1) : SCNVector3(1, 1, 1)

        muzzleFlash.isHidden = !beat.isAiming

        SCNTransaction.commit()

        if beat.isShaking {
            startShake(duration: beat.duration)
        } else {
            rig.removeAction(forKey: Self.shakeKey)
            rig.eulerAngles.z = 0
        }
    }

    private static let shakeKey = "shake"

    /// A quick left-right wobble for the shake beat. An `SCNAction` rather than
    /// a transaction: it has to repeat inside the beat, which a single
    /// interpolated transaction cannot do.
    private func startShake(duration: TimeInterval) {
        let swing: CGFloat = 0.14
        let step = 0.07
        let cycle = SCNAction.sequence([
            SCNAction.rotateTo(x: 0, y: 0, z: swing, duration: step),
            SCNAction.rotateTo(x: 0, y: 0, z: -swing, duration: step),
        ])
        let count = max(Int(duration / (step * 2)), 1)
        let shake = SCNAction.sequence([
            SCNAction.repeat(cycle, count: count),
            SCNAction.rotateTo(x: 0, y: 0, z: 0, duration: step),
        ])
        rig.runAction(shake, forKey: Self.shakeKey)
    }

    // MARK: - Scene furniture

    private func buildCamera() {
        let camera = SCNCamera()
        camera.fieldOfView = 40
        camera.zNear = 0.1
        camera.zFar = 100
        cameraNode.camera = camera
        // Pulled back and offset to +x so the RAISED-ARM pose is what fits the
        // frame, not the resting one. Framed on the body, the gun hand clips the
        // right edge at exactly the beat it has to be visible.
        cameraNode.position = SCNVector3(1.1, 0.5, 15)
        cameraNode.eulerAngles.x = -0.03
        scene.rootNode.addChildNode(cameraNode)
    }

    private func buildLights() {
        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.intensity = 320
        ambient.light?.color = SceneColor(red: 0.75, green: 0.78, blue: 0.95, alpha: 1)
        scene.rootNode.addChildNode(ambient)

        // Key light, front-left and high — gives the spheres their roundness.
        let key = SCNNode()
        key.light = SCNLight()
        key.light?.type = .omni
        key.light?.intensity = 950
        key.position = SCNVector3(-5, 7, 9)
        scene.rootNode.addChildNode(key)

        // Warm rim from the right so the silhouette separates from a dark
        // chat background instead of dissolving into it.
        let rim = SCNNode()
        rim.light = SCNLight()
        rim.light?.type = .omni
        rim.light?.intensity = 520
        rim.light?.color = SceneColor(red: 1.0, green: 0.86, blue: 0.66, alpha: 1)
        rim.position = SCNVector3(6, 3, -4)
        scene.rootNode.addChildNode(rim)
    }

    private static func material(_ color: SceneColor, roughness: CGFloat = 0.85) -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .physicallyBased
        material.diffuse.contents = color
        material.roughness.contents = roughness
        material.metalness.contents = 0.0
        return material
    }

    private static func node(_ geometry: SCNGeometry, _ material: SCNMaterial) -> SCNNode {
        geometry.materials = [material]
        return SCNNode(geometry: geometry)
    }

    // MARK: - Body

    private func buildBody() {
        let furMaterial = Self.material(Self.fur)
        let skinMaterial = Self.material(Self.skin, roughness: 0.7)

        // Torso: a sphere scaled into an egg, which reads rounder under this
        // lighting than a capsule of the same silhouette.
        let torso = Self.node(SCNSphere(radius: 1.55), furMaterial)
        torso.scale = SCNVector3(1.0, 1.12, 0.92)
        torso.position = SCNVector3(0, -0.9, 0)
        rig.addChildNode(torso)

        // Belly patch.
        let belly = Self.node(SCNSphere(radius: 1.02), skinMaterial)
        belly.scale = SCNVector3(1.0, 1.05, 0.55)
        belly.position = SCNVector3(0, -1.0, 0.95)
        rig.addChildNode(belly)

        buildHead(furMaterial: furMaterial, skinMaterial: skinMaterial)
        buildLegs(furMaterial)
        buildArms(furMaterial, skinMaterial: skinMaterial)
    }

    private func buildHead(furMaterial: SCNMaterial, skinMaterial: SCNMaterial) {
        let skull = Self.node(SCNSphere(radius: 1.28), furMaterial)
        head.addChildNode(skull)

        for side in [SceneScalar(-1), 1] {
            let ear = Self.node(SCNSphere(radius: 0.44), furMaterial)
            ear.scale = SCNVector3(1, 1, 0.6)
            ear.position = SCNVector3(1.22 * side, 0.05, 0)
            head.addChildNode(ear)

            let inner = Self.node(SCNSphere(radius: 0.26), skinMaterial)
            inner.scale = SCNVector3(1, 1, 0.5)
            inner.position = SCNVector3(1.34 * side, 0.05, 0.12)
            head.addChildNode(inner)
        }

        // Face patch — a flattened sphere pushed forward, giving the muzzle its
        // own silhouette against the skull.
        let face = Self.node(SCNSphere(radius: 0.9), skinMaterial)
        face.scale = SCNVector3(1.0, 0.86, 0.62)
        face.position = SCNVector3(0, -0.22, 0.78)
        head.addChildNode(face)

        let browMaterial = Self.material(Self.fur, roughness: 0.9)
        let brow = Self.node(SCNSphere(radius: 0.72), browMaterial)
        brow.scale = SCNVector3(1.15, 0.42, 0.55)
        brow.position = SCNVector3(0, 0.44, 0.72)
        head.addChildNode(brow)

        let eyeMaterial = Self.material(Self.dark, roughness: 0.25)
        for (eye, side) in [(leftEye, SceneScalar(-1)), (rightEye, SceneScalar(1))] {
            let ball = Self.node(SCNSphere(radius: 0.17), eyeMaterial)
            eye.addChildNode(ball)
            eye.position = SCNVector3(0.36 * side, 0.16, 1.33)
            head.addChildNode(eye)
        }

        let mouthBall = Self.node(SCNSphere(radius: 0.13), Self.material(Self.dark, roughness: 0.4))
        mouthBall.scale = SCNVector3(1.6, 0.7, 0.6)
        mouth.addChildNode(mouthBall)
        mouth.position = SCNVector3(0, -0.52, 1.32)
        head.addChildNode(mouth)

        head.position = SCNVector3(0, 1.35, 0.12)
        rig.addChildNode(head)
    }

    private func buildLegs(_ furMaterial: SCNMaterial) {
        for side in [SceneScalar(-1), 1] {
            let leg = Self.node(SCNCapsule(capRadius: 0.34, height: 1.15), furMaterial)
            leg.position = SCNVector3(0.62 * side, -2.25, 0.25)
            leg.eulerAngles.z = 0.18 * side
            rig.addChildNode(leg)

            let foot = Self.node(SCNSphere(radius: 0.32), furMaterial)
            foot.scale = SCNVector3(1, 0.6, 1.35)
            foot.position = SCNVector3(0.7 * side, -2.75, 0.5)
            rig.addChildNode(foot)
        }
    }

    private func buildArms(_ furMaterial: SCNMaterial, skinMaterial: SCNMaterial) {
        // Idle left arm — a fixed hang, since only the right one performs.
        let leftPivot = SCNNode()
        leftPivot.position = SCNVector3(-1.45, -0.35, 0.1)
        let leftArm = Self.node(SCNCapsule(capRadius: 0.3, height: 1.7), furMaterial)
        leftArm.position = SCNVector3(0, -0.85, 0)
        leftPivot.addChildNode(leftArm)
        let leftHand = Self.node(SCNSphere(radius: 0.33), skinMaterial)
        leftHand.position = SCNVector3(0, -1.7, 0)
        leftPivot.addChildNode(leftHand)
        leftPivot.eulerAngles.z = -0.16
        rig.addChildNode(leftPivot)

        // Pistol arm. The capsule hangs along -y from the pivot, so rotating the
        // pivot about x sweeps it forward toward the camera.
        armPivot.position = SCNVector3(1.45, -0.35, 0.1)
        let arm = Self.node(SCNCapsule(capRadius: 0.3, height: 1.7), furMaterial)
        arm.position = SCNVector3(0, -0.85, 0)
        armPivot.addChildNode(arm)

        let hand = Self.node(SCNSphere(radius: 0.33), skinMaterial)
        hand.position = SCNVector3(0, -1.7, 0)
        armPivot.addChildNode(hand)

        armPivot.addChildNode(buildPistol(at: SCNVector3(0, -1.9, 0)))
        // No static z here: `apply(_:)` owns this pivot's rotation, and a value
        // set at build time would be silently overwritten on the first beat.
        rig.addChildNode(armPivot)
    }

    /// A stylized pistol: slide, grip, trigger guard, and a hidden muzzle glow
    /// that only shows while aiming. Small and blocky on purpose — it's the prop
    /// in a gag, not an illustration of a weapon.
    private func buildPistol(at position: SCNVector3) -> SCNNode {
        let gun = SCNNode()
        let metalMaterial = Self.material(Self.metal, roughness: 0.35)

        // Slide, extending along -y — i.e. straight out along the arm, so it
        // points wherever the arm points.
        let slide = Self.node(SCNBox(width: 0.26, height: 0.8, length: 0.32, chamferRadius: 0.05),
                              metalMaterial)
        slide.position = SCNVector3(0, -0.3, 0)
        gun.addChildNode(slide)

        // Grip, tilted back behind the hand.
        let grip = Self.node(SCNBox(width: 0.26, height: 0.62, length: 0.3, chamferRadius: 0.06),
                             metalMaterial)
        grip.position = SCNVector3(0, 0.1, -0.32)
        grip.eulerAngles.x = 0.42
        gun.addChildNode(grip)

        let guard_ = Self.node(SCNTorus(ringRadius: 0.18, pipeRadius: 0.045), metalMaterial)
        guard_.eulerAngles.z = .pi / 2
        guard_.position = SCNVector3(0, -0.12, -0.12)
        gun.addChildNode(guard_)

        let flashMaterial = SCNMaterial()
        flashMaterial.lightingModel = .constant
        flashMaterial.diffuse.contents = SceneColor(red: 1.0, green: 0.78, blue: 0.32, alpha: 1)
        flashMaterial.emission.contents = SceneColor(red: 1.0, green: 0.72, blue: 0.25, alpha: 1)
        let flashBall = Self.node(SCNSphere(radius: 0.19), flashMaterial)
        muzzleFlash.addChildNode(flashBall)
        muzzleFlash.position = SCNVector3(0, -0.76, 0)
        muzzleFlash.isHidden = true
        gun.addChildNode(muzzleFlash)

        gun.position = position
        return gun
    }
}
