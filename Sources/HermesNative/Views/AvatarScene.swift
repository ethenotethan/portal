import SceneKit
import SwiftUI

/// Animation states driven by gateway streaming events.
enum AvatarState: String, CaseIterable {
    case idle
    case thinking
    case speaking
    case toolUse
    case error
}

/// SceneKit scene containing a programmatic 3D character that animates per state.
/// Zero model files — everything is built from SCNNodes (spheres, capsules, etc.)
final class AvatarScene: SCNScene {
    // MARK: - Node References
    private var headNode: SCNNode!
    private var leftEyeNode: SCNNode!
    private var rightEyeNode: SCNNode!
    private var mouthNode: SCNNode!
    private var bodyNode: SCNNode!
    private var leftArmNode: SCNNode!
    private var rightArmNode: SCNNode!
    private var floatOrbNode: SCNNode!
    private var gearParticles: SCNNode!
    private var glowRingNode: SCNNode!

    // Accent color (derived from persona)
    var accentColor: NSColor = NSColor(hex: "#5856D6") ?? .systemPurple {
        didSet { applyAccentColor() }
    }

    private var currentState: AvatarState = .idle
    private var stateAnimations: [String: SCNAnimation] = [:]

    // MARK: - Init

    override init() {
        super.init()
        buildCharacter()
        setupLighting()
        setupCamera()
        applyAccentColor()
        transition(to: .idle)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    // MARK: - State Transitions

    func transition(to state: AvatarState) {
        guard state != currentState else { return }
        let oldState = currentState
        currentState = state
        clearStateAnimations(for: oldState)
        applyStateAnimations(for: state)
    }

    // MARK: - Character Construction

    private func buildCharacter() {
        let root = rootNode

        // ── Floating orb (base) ──
        let orbGeo = SCNSphere(radius: 0.35)
        let orbMat = SCNMaterial()
        orbMat.diffuse.contents = NSColor.systemPurple.withAlphaComponent(0.3)
        orbMat.emission.contents = NSColor.systemPurple.withAlphaComponent(0.15)
        orbMat.transparent.contents = NSColor(white: 1, alpha: 0.5)
        orbMat.transparencyMode = .dualLayer
        orbGeo.materials = [orbMat]
        floatOrbNode = SCNNode(geometry: orbGeo)
        floatOrbNode.position = SCNVector3(0, -0.45, 0)
        root.addChildNode(floatOrbNode)

        // ── Glow ring around orb ──
        let ringGeo = SCNTorus(ringRadius: 0.38, pipeRadius: 0.02)
        let ringMat = SCNMaterial()
        ringMat.diffuse.contents = NSColor.systemPurple.withAlphaComponent(0.6)
        ringMat.emission.contents = NSColor.systemPurple.withAlphaComponent(0.4)
        ringGeo.materials = [ringMat]
        glowRingNode = SCNNode(geometry: ringGeo)
        glowRingNode.position = SCNVector3(0, -0.45, 0)
        glowRingNode.eulerAngles = SCNVector3(Float.pi / 2, 0, 0)
        root.addChildNode(glowRingNode)

        // ── Body ──
        let bodyGeo = SCNCapsule(capRadius: 0.22, height: 0.5)
        let bodyMat = SCNMaterial()
        bodyMat.diffuse.contents = NSColor(white: 0.95, alpha: 1)
        bodyMat.emission.contents = NSColor(white: 0.08, alpha: 1)
        bodyGeo.materials = [bodyMat]
        bodyNode = SCNNode(geometry: bodyGeo)
        bodyNode.position = SCNVector3(0, 0, 0)
        root.addChildNode(bodyNode)

        // ── Head ──
        let headGeo = SCNSphere(radius: 0.28)
        let headMat = SCNMaterial()
        headMat.diffuse.contents = NSColor(white: 0.97, alpha: 1)
        headMat.emission.contents = NSColor(white: 0.06, alpha: 1)
        headGeo.materials = [headMat]
        headNode = SCNNode(geometry: headGeo)
        headNode.position = SCNVector3(0, 0.52, 0)
        root.addChildNode(headNode)

        // ── Eyes ──
        let eyeGeo = SCNSphere(radius: 0.055)
        let eyeMat = SCNMaterial()
        eyeMat.diffuse.contents = NSColor.black
        eyeMat.emission.contents = NSColor(white: 0.5, alpha: 1)
        eyeGeo.materials = [eyeMat]

        let pupilGeo = SCNSphere(radius: 0.035)
        let pupilMat = SCNMaterial()
        pupilMat.diffuse.contents = NSColor.white
        pupilMat.emission.contents = NSColor(white: 0.8, alpha: 1)
        pupilGeo.materials = [pupilMat]

        leftEyeNode = SCNNode(geometry: eyeGeo)
        leftEyeNode.position = SCNVector3(-0.1, 0.55, 0.24)
        root.addChildNode(leftEyeNode)

        let leftPupil = SCNNode(geometry: pupilGeo)
        leftPupil.position = SCNVector3(0, 0, 0.03)
        leftEyeNode.addChildNode(leftPupil)

        rightEyeNode = SCNNode(geometry: eyeGeo)
        rightEyeNode.position = SCNVector3(0.1, 0.55, 0.24)
        root.addChildNode(rightEyeNode)

        let rightPupil = SCNNode(geometry: pupilGeo)
        rightPupil.position = SCNVector3(0, 0, 0.03)
        rightEyeNode.addChildNode(rightPupil)

        // ── Mouth ──
        let mouthGeo = SCNCylinder(radius: 0.04, height: 0.01)
        let mouthMat = SCNMaterial()
        mouthMat.diffuse.contents = NSColor(white: 0.15, alpha: 1)
        mouthGeo.materials = [mouthMat]
        mouthNode = SCNNode(geometry: mouthGeo)
        mouthNode.position = SCNVector3(0, 0.42, 0.26)
        mouthNode.eulerAngles = SCNVector3(0, 0, Float.pi / 2)
        root.addChildNode(mouthNode)

        // ── Arms ──
        let armGeo = SCNCapsule(capRadius: 0.04, height: 0.28)

        leftArmNode = SCNNode(geometry: armGeo)
        leftArmNode.position = SCNVector3(-0.32, 0.05, 0)
        leftArmNode.eulerAngles = SCNVector3(0, 0, 0.3)
        root.addChildNode(leftArmNode)

        rightArmNode = SCNNode(geometry: armGeo)
        rightArmNode.position = SCNVector3(0.32, 0.05, 0)
        rightArmNode.eulerAngles = SCNVector3(0, 0, -0.3)
        root.addChildNode(rightArmNode)

        // ── Gear particles (hidden by default) ──
        gearParticles = SCNNode()
        gearParticles.isHidden = true
        root.addChildNode(gearParticles)
        buildGearParticles()

        // ── Idle float animation (always running) ──
        let floatUp = SCNAction.moveBy(x: 0, y: 0.06, z: 0, duration: 1.5)
        floatUp.timingMode = .easeInEaseOut
        let floatDown = SCNAction.moveBy(x: 0, y: -0.06, z: 0, duration: 1.5)
        floatDown.timingMode = .easeInEaseOut
        root.runAction(SCNAction.repeatForever(SCNAction.sequence([floatUp, floatDown])), forKey: "idle_float")

        // Glow ring rotation (always running)
        let spin = SCNAction.rotateBy(x: 0, y: 0, z: CGFloat(Float.pi * 2), duration: 4.0)
        glowRingNode.runAction(SCNAction.repeatForever(spin), forKey: "ring_spin")
    }

    private func buildGearParticles() {
        let gearGeo = SCNSphere(radius: 0.025)
        let gearMat = SCNMaterial()
        gearMat.diffuse.contents = NSColor.systemYellow
        gearMat.emission.contents = NSColor.systemYellow.withAlphaComponent(0.6)
        gearGeo.materials = [gearMat]

        for i in 0..<8 {
            let angle = Float(i) * Float.pi * 2 / 8
            let r: Float = 0.5
            let node = SCNNode(geometry: gearGeo)
            node.position = SCNVector3(r * cos(angle), 0.5 + 0.15 * sin(angle * 2), r * sin(angle) * 0.4)
            node.name = "gear_\(i)"

            // Orbit animation
            let orbit = SCNAction.rotateBy(x: 0, y: CGFloat(Float.pi * 2), z: 0, duration: 2.0 + Double(i) * 0.2)
            node.runAction(SCNAction.repeatForever(orbit))

            gearParticles.addChildNode(node)
        }
    }

    // MARK: - Lighting

    private func setupLighting() {
        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.color = NSColor(white: 0.4, alpha: 1)
        ambient.light?.castsShadow = false
        rootNode.addChildNode(ambient)

        let key = SCNNode()
        key.light = SCNLight()
        key.light?.type = .omni
        key.light?.color = NSColor.white
        key.light?.intensity = 1200
        key.position = SCNVector3(2, 3, 2)
        rootNode.addChildNode(key)

        let fill = SCNNode()
        fill.light = SCNLight()
        fill.light?.type = .omni
        fill.light?.color = NSColor(white: 0.6, alpha: 1)
        fill.light?.intensity = 600
        fill.position = SCNVector3(-2, 1, 2)
        rootNode.addChildNode(fill)

        let rim = SCNNode()
        rim.light = SCNLight()
        rim.light?.type = .omni
        rim.light?.color = NSColor.systemPurple.withAlphaComponent(0.5)
        rim.light?.intensity = 400
        rim.position = SCNVector3(0, 0, -3)
        rootNode.addChildNode(rim)
    }

    // MARK: - Camera

    private func setupCamera() {
        let camera = SCNCamera()
        camera.fieldOfView = 40
        camera.zNear = 0.1
        camera.zFar = 100
        let cameraNode = SCNNode()
        cameraNode.camera = camera
        cameraNode.position = SCNVector3(0, 0.2, 2.5)
        rootNode.addChildNode(cameraNode)
    }

    // MARK: - Accent Color

    private func applyAccentColor() {
        let c = accentColor

        // Orb
        if let mat = floatOrbNode.geometry?.firstMaterial {
            mat.diffuse.contents = c.withAlphaComponent(0.3)
            mat.emission.contents = c.withAlphaComponent(0.15)
        }

        // Ring
        if let mat = glowRingNode.geometry?.firstMaterial {
            mat.diffuse.contents = c.withAlphaComponent(0.6)
            mat.emission.contents = c.withAlphaComponent(0.4)
        }

        // Rim light
        rootNode.childNodes.filter { $0.light?.type == .omni }.last?.light?.color = c.withAlphaComponent(0.5)
    }

    // MARK: - State Animations

    private func clearStateAnimations(for state: AvatarState) {
        switch state {
        case .idle:
            break // idle float is always-on
        case .thinking:
            headNode.removeAction(forKey: "think_tilt")
            headNode.removeAction(forKey: "think_nod")
            gearParticles.isHidden = true
            gearParticles.removeAllActions()
            leftArmNode.removeAction(forKey: "think_chin")
            // Reset head
            headNode.runAction(SCNAction.rotateTo(x: 0, y: 0, z: 0, duration: 0.3, usesShortestUnitArc: true))
            leftArmNode.runAction(SCNAction.rotateTo(x: 0, y: 0, z: 0.3, duration: 0.3, usesShortestUnitArc: true))
            // Restore eyes
            leftEyeNode.scale = SCNVector3(1, 1, 1)
            rightEyeNode.scale = SCNVector3(1, 1, 1)
        case .speaking:
            mouthNode.removeAction(forKey: "speak_mouth")
            headNode.removeAction(forKey: "speak_bob")
            rightArmNode.removeAction(forKey: "speak_gesture")
            // Reset mouth
            mouthNode.scale = SCNVector3(1, 1, 1)
            headNode.runAction(SCNAction.rotateTo(x: 0, y: 0, z: 0, duration: 0.3, usesShortestUnitArc: true))
            rightArmNode.runAction(SCNAction.rotateTo(x: 0, y: 0, z: -0.3, duration: 0.3, usesShortestUnitArc: true))
        case .toolUse:
            leftArmNode.removeAction(forKey: "tool_type")
            rightArmNode.removeAction(forKey: "tool_type")
            headNode.removeAction(forKey: "tool_look")
            // Reset
            leftArmNode.runAction(SCNAction.rotateTo(x: 0, y: 0, z: 0.3, duration: 0.3, usesShortestUnitArc: true))
            rightArmNode.runAction(SCNAction.rotateTo(x: 0, y: 0, z: -0.3, duration: 0.3, usesShortestUnitArc: true))
            headNode.runAction(SCNAction.rotateTo(x: 0, y: 0, z: 0, duration: 0.3, usesShortestUnitArc: true))
        case .error:
            headNode.removeAction(forKey: "error_shake")
            leftArmNode.removeAction(forKey: "error_raise")
            rightArmNode.removeAction(forKey: "error_raise")
            bodyNode.removeAction(forKey: "error_recoil")
            // Reset
            headNode.runAction(SCNAction.rotateTo(x: 0, y: 0, z: 0, duration: 0.3, usesShortestUnitArc: true))
            leftArmNode.runAction(SCNAction.rotateTo(x: 0, y: 0, z: 0.3, duration: 0.3, usesShortestUnitArc: true))
            rightArmNode.runAction(SCNAction.rotateTo(x: 0, y: 0, z: -0.3, duration: 0.3, usesShortestUnitArc: true))
        }
    }

    private func applyStateAnimations(for state: AvatarState) {
        switch state {
        case .idle:
            // Already floating — just ensure mouth is neutral
            mouthNode.scale = SCNVector3(1, 1, 1)
            // Slow blink
            let blinkDown = SCNAction.scale(to: 0.1, duration: 0.15)
            let blinkUp = SCNAction.scale(to: 1.0, duration: 0.15)
            let wait = SCNAction.wait(duration: 3.0)
            let blinkSeq = SCNAction.sequence([wait, blinkDown, blinkUp])
            leftEyeNode.runAction(SCNAction.repeatForever(blinkSeq), forKey: "blink")
            rightEyeNode.runAction(SCNAction.repeatForever(blinkSeq), forKey: "blink")

        case .thinking:
            // Squint eyes
            leftEyeNode.scale = SCNVector3(1, 0.5, 1)
            rightEyeNode.scale = SCNVector3(1, 0.5, 1)
            leftEyeNode.removeAction(forKey: "blink")
            rightEyeNode.removeAction(forKey: "blink")

            // Head tilt
            let tiltRight = SCNAction.rotateTo(x: 0, y: 0, z: 0.2, duration: 0.8, usesShortestUnitArc: true)
            let tiltLeft = SCNAction.rotateTo(x: 0, y: 0, z: -0.15, duration: 0.8, usesShortestUnitArc: true)
            headNode.runAction(SCNAction.repeatForever(SCNAction.sequence([tiltRight, tiltLeft])), forKey: "think_tilt")

            // Slow nod
            let nodDown = SCNAction.rotateBy(x: 0.1, y: 0, z: 0, duration: 2.0)
            let nodUp = SCNAction.rotateBy(x: -0.1, y: 0, z: 0, duration: 2.0)
            headNode.runAction(SCNAction.repeatForever(SCNAction.sequence([nodDown, nodUp])), forKey: "think_nod")

            // Left arm to chin
            let chinUp = SCNAction.rotateTo(x: 0, y: 0, z: 1.2, duration: 0.5, usesShortestUnitArc: true)
            leftArmNode.runAction(chinUp, forKey: "think_chin")

            // Show gear particles
            gearParticles.isHidden = false

        case .speaking:
            leftEyeNode.removeAction(forKey: "blink")
            rightEyeNode.removeAction(forKey: "blink")

            // Mouth animation (open/close rapidly)
            let mouthOpen = SCNAction.scale(to: 1.8, duration: 0.08)
            let mouthClose = SCNAction.scale(to: 0.6, duration: 0.08)
            let mouthPause = SCNAction.wait(duration: 0.05)
            let speakCycle = SCNAction.sequence([mouthOpen, mouthClose, mouthPause])
            mouthNode.runAction(SCNAction.repeatForever(speakCycle), forKey: "speak_mouth")

            // Head bob
            let bobDown = SCNAction.moveBy(x: 0, y: -0.03, z: 0, duration: 0.3)
            let bobUp = SCNAction.moveBy(x: 0, y: 0.03, z: 0, duration: 0.3)
            headNode.runAction(SCNAction.repeatForever(SCNAction.sequence([bobDown, bobUp])), forKey: "speak_bob")

            // Right arm gesture
            let waveRight = SCNAction.rotateTo(x: -0.5, y: 0, z: -0.8, duration: 0.4, usesShortestUnitArc: true)
            let waveBack = SCNAction.rotateTo(x: 0, y: 0, z: -0.3, duration: 0.4, usesShortestUnitArc: true)
            rightArmNode.runAction(SCNAction.repeatForever(SCNAction.sequence([waveRight, waveBack])), forKey: "speak_gesture")

        case .toolUse:
            leftEyeNode.removeAction(forKey: "blink")
            rightEyeNode.removeAction(forKey: "blink")

            // Both arms typing motion
            let typeDown1 = SCNAction.rotateBy(x: -0.3, y: 0, z: 0, duration: 0.1)
            let typeUp1 = SCNAction.rotateBy(x: 0.3, y: 0, z: 0, duration: 0.1)
            leftArmNode.runAction(SCNAction.repeatForever(SCNAction.sequence([typeDown1, typeUp1])), forKey: "tool_type")

            let typeDown2 = SCNAction.rotateBy(x: -0.3, y: 0, z: 0, duration: 0.12)
            let typeUp2 = SCNAction.rotateBy(x: 0.3, y: 0, z: 0, duration: 0.12)
            rightArmNode.runAction(SCNAction.repeatForever(SCNAction.sequence([typeDown2, typeUp2])), forKey: "tool_type")

            // Head looking down (at screen)
            headNode.runAction(SCNAction.rotateTo(x: 0.25, y: 0, z: 0, duration: 0.3, usesShortestUnitArc: true), forKey: "tool_look")

            // Mouth small (focused)
            mouthNode.scale = SCNVector3(0.5, 0.5, 1)

        case .error:
            leftEyeNode.removeAction(forKey: "blink")
            rightEyeNode.removeAction(forKey: "blink")

            // Eyes wide
            leftEyeNode.scale = SCNVector3(1.3, 1.3, 1)
            rightEyeNode.scale = SCNVector3(1.3, 1.3, 1)

            // Head shake
            let shakeR = SCNAction.rotateBy(x: 0, y: 0, z: 0.3, duration: 0.1)
            let shakeL = SCNAction.rotateBy(x: 0, y: 0, z: -0.3, duration: 0.1)
            headNode.runAction(SCNAction.repeatForever(SCNAction.sequence([shakeR, shakeL])), forKey: "error_shake")

            // Arms up (surprised)
            let raise = SCNAction.rotateTo(x: -1.0, y: 0, z: 0, duration: 0.3, usesShortestUnitArc: true)
            leftArmNode.runAction(raise, forKey: "error_raise")
            rightArmNode.runAction(raise, forKey: "error_raise")

            // Recoil body
            let recoil = SCNAction.moveBy(x: 0, y: -0.05, z: -0.05, duration: 0.2)
            bodyNode.runAction(recoil, forKey: "error_recoil")

            // Mouth wide
            mouthNode.scale = SCNVector3(2.0, 2.0, 1)
        }
    }
}

// MARK: - NSColor hex init

extension NSColor {
    convenience init?(hex: String) {
        var hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        hexSanitized = hexSanitized.replacingOccurrences(of: "#", with: "")
        guard hexSanitized.count == 6 else { return nil }
        var rgb: UInt64 = 0
        Scanner(string: hexSanitized).scanHexInt64(&rgb)
        self.init(
            red: CGFloat((rgb & 0xFF0000) >> 16) / 255.0,
            green: CGFloat((rgb & 0x00FF00) >> 8) / 255.0,
            blue: CGFloat(rgb & 0x0000FF) / 255.0,
            alpha: 1.0
        )
    }
}
