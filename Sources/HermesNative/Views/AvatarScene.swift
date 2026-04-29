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

/// Stylized 3D avatar — a floating "helmet head" mascot with persona accessories.
/// Think Daft Punk meets BB-8: a smooth rounded visor head on a floating orb,
/// with accessories that swap per persona (cowboy hat, fedora, cat ears, etc).
final class AvatarScene: SCNScene {
    // MARK: - Node References
    private var headNode: SCNNode!
    private var visorNode: SCNNode!
    private var leftEyeNode: SCNNode!
    private var rightEyeNode: SCNNode!
    private var mouthNode: SCNNode!
    private var orbNode: SCNNode!
    private var ringNode: SCNNode!
    private var innerRingNode: SCNNode!
    private var accessoryNodes: [SCNNode] = []

    // Accent color
    var accentColor: NSColor = NSColor(red: 0.34, green: 0.34, blue: 0.84, alpha: 1) {
        didSet { applyAccentColor() }
    }

    // Active accessories
    var accessories: [PersonaAccessory] = [] {
        didSet { rebuildAccessories() }
    }

    private var currentState: AvatarState = .idle

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
        let old = currentState
        currentState = state
        clearAnimations(for: old)
        applyAnimations(for: state)
    }

    // MARK: - Character Construction

    private func buildCharacter() {
        let root = rootNode

        // ── Main orb (body) ──
        let orbGeo = SCNSphere(radius: 0.4)
        let orbMat = SCNMaterial()
        orbMat.diffuse.contents = NSColor(white: 0.95, alpha: 1)
        orbMat.specular.contents = NSColor.white
        orbMat.shininess = 80
        orbMat.emission.contents = NSColor(white: 0.04, alpha: 1)
        orbGeo.materials = [orbMat]
        orbNode = SCNNode(geometry: orbGeo)
        orbNode.position = SCNVector3(0, 0, 0)
        root.addChildNode(orbNode)

        // ── Head dome (sits on top of orb) ──
        let headGeo = SCNSphere(radius: 0.3)
        let headMat = SCNMaterial()
        headMat.diffuse.contents = NSColor(white: 0.97, alpha: 1)
        headMat.specular.contents = NSColor.white
        headMat.shininess = 100
        headMat.emission.contents = NSColor(white: 0.03, alpha: 1)
        headGeo.materials = [headMat]
        headNode = SCNNode(geometry: headGeo)
        headNode.position = SCNVector3(0, 0.5, 0)
        root.addChildNode(headNode)

        // ── Visor (dark band across face) ──
        let visorGeo = SCNBox(width: 0.5, height: 0.12, length: 0.15, chamferRadius: 0.04)
        let visorMat = SCNMaterial()
        visorMat.diffuse.contents = NSColor(white: 0.08, alpha: 1)
        visorMat.specular.contents = NSColor(white: 0.3, alpha: 1)
        visorMat.shininess = 40
        visorMat.emission.contents = NSColor(white: 0.02, alpha: 1)
        visorGeo.materials = [visorMat]
        visorNode = SCNNode(geometry: visorGeo)
        visorNode.position = SCNVector3(0, 0.52, 0.22)
        root.addChildNode(visorNode)

        // ── Eyes (glowing on the visor) ──
        let eyeGeo = SCNSphere(radius: 0.04)
        let eyeMat = SCNMaterial()
        eyeMat.diffuse.contents = NSColor.cyan
        eyeMat.emission.contents = NSColor.cyan.withAlphaComponent(0.8)
        eyeMat.specular.contents = NSColor.white
        eyeGeo.materials = [eyeMat]

        leftEyeNode = SCNNode(geometry: eyeGeo)
        leftEyeNode.position = SCNVector3(-0.09, 0.52, 0.27)
        root.addChildNode(leftEyeNode)

        rightEyeNode = SCNNode(geometry: eyeGeo.copy() as! SCNGeometry)
        rightEyeNode.position = SCNVector3(0.09, 0.52, 0.27)
        root.addChildNode(rightEyeNode)

        // Eye glow halos
        let haloGeo = SCNSphere(radius: 0.06)
        let haloMat = SCNMaterial()
        haloMat.diffuse.contents = NSColor.cyan.withAlphaComponent(0.15)
        haloMat.emission.contents = NSColor.cyan.withAlphaComponent(0.1)
        haloMat.transparent.contents = NSColor(white: 1, alpha: 0.3)
        haloMat.transparencyMode = .dualLayer
        haloGeo.materials = [haloMat]

        let leftHalo = SCNNode(geometry: haloGeo)
        leftHalo.position = SCNVector3(0, 0, -0.01)
        leftEyeNode.addChildNode(leftHalo)

        let rightHalo = SCNNode(geometry: haloGeo.copy() as! SCNGeometry)
        rightHalo.addChildNode(rightHalo)

        // ── Mouth (LED strip under visor) ──
        let mouthGeo = SCNCylinder(radius: 0.03, height: 0.008)
        mouthGeo.materials = [eyeMat.copy() as! SCNMaterial]
        mouthNode = SCNNode(geometry: mouthGeo)
        mouthNode.position = SCNVector3(0, 0.44, 0.27)
        mouthNode.eulerAngles = SCNVector3(0, Float.pi / 2, 0)
        root.addChildNode(mouthNode)

        // ── Glow ring (orbital) ──
        let ringGeo = SCNTorus(ringRadius: 0.44, pipeRadius: 0.015)
        let ringMat = SCNMaterial()
        ringMat.diffuse.contents = NSColor.systemPurple.withAlphaComponent(0.7)
        ringMat.emission.contents = NSColor.systemPurple.withAlphaComponent(0.5)
        ringGeo.materials = [ringMat]
        ringNode = SCNNode(geometry: ringGeo)
        ringNode.eulerAngles = SCNVector3(Float.pi / 2, 0, 0)
        root.addChildNode(ringNode)

        // ── Inner ring (counter-rotating) ──
        let innerRingGeo = SCNTorus(ringRadius: 0.38, pipeRadius: 0.008)
        let innerRingMat = SCNMaterial()
        innerRingMat.diffuse.contents = NSColor.systemPurple.withAlphaComponent(0.4)
        innerRingMat.emission.contents = NSColor.systemPurple.withAlphaComponent(0.25)
        innerRingGeo.materials = [innerRingMat]
        innerRingNode = SCNNode(geometry: innerRingGeo)
        innerRingNode.eulerAngles = SCNVector3(Float.pi / 2, 0.3, 0)
        root.addChildNode(innerRingNode)

        // ── Idle float ──
        let floatUp = SCNAction.moveBy(x: 0, y: 0.05, z: 0, duration: 2.0)
        floatUp.timingMode = .easeInEaseOut
        let floatDown = SCNAction.moveBy(x: 0, y: -0.05, z: 0, duration: 2.0)
        floatDown.timingMode = .easeInEaseOut
        root.runAction(SCNAction.repeatForever(SCNAction.sequence([floatUp, floatDown])), forKey: "idle_float")

        // Ring rotations
        let spin1 = SCNAction.rotateBy(x: 0, y: CGFloat(Float.pi * 2), z: 0, duration: 5.0)
        ringNode.runAction(SCNAction.repeatForever(spin1), forKey: "ring_spin")

        let spin2 = SCNAction.rotateBy(x: 0, y: CGFloat(-Float.pi * 2), z: 0, duration: 3.5)
        innerRingNode.runAction(SCNAction.repeatForever(spin2), forKey: "inner_ring_spin")
    }

    // MARK: - Accessories

    private func rebuildAccessories() {
        // Remove old accessories
        for node in accessoryNodes {
            node.removeFromParentNode()
        }
        accessoryNodes.removeAll()

        for acc in accessories {
            let node = buildAccessory(acc)
            accessoryNodes.append(node)
            rootNode.addChildNode(node)
        }
    }

    private func buildAccessory(_ acc: PersonaAccessory) -> SCNNode {
        let container = SCNNode()

        switch acc {
        case .cowboyHat:
            // Wide brim (flat cylinder) + dome on top
            let brimGeo = SCNCylinder(radius: 0.38, height: 0.03)
            let hatMat = SCNMaterial()
            hatMat.diffuse.contents = NSColor(red: 0.55, green: 0.35, blue: 0.15, alpha: 1)
            hatMat.specular.contents = NSColor(white: 0.2, alpha: 1)
            brimGeo.materials = [hatMat]

            let brim = SCNNode(geometry: brimGeo)
            brim.position = SCNVector3(0, 0.78, 0)
            container.addChildNode(brim)

            let crownGeo = SCNCylinder(radius: 0.16, height: 0.18)
            crownGeo.materials = [hatMat.copy() as! SCNMaterial]
            let crown = SCNNode(geometry: crownGeo)
            crown.position = SCNVector3(0, 0.89, 0)
            container.addChildNode(crown)

            // Hat band
            let bandGeo = SCNCylinder(radius: 0.165, height: 0.03)
            let bandMat = SCNMaterial()
            bandMat.diffuse.contents = NSColor.systemOrange.withAlphaComponent(0.8)
            bandMat.emission.contents = NSColor.systemOrange.withAlphaComponent(0.2)
            bandGeo.materials = [bandMat]
            let band = SCNNode(geometry: bandGeo)
            band.position = SCNVector3(0, 0.82, 0)
            container.addChildNode(band)

        case .fedora:
            let brimGeo = SCNCylinder(radius: 0.35, height: 0.025)
            let hatMat = SCNMaterial()
            hatMat.diffuse.contents = NSColor(white: 0.15, alpha: 1)
            hatMat.specular.contents = NSColor(white: 0.3, alpha: 1)
            brimGeo.materials = [hatMat]

            let brim = SCNNode(geometry: brimGeo)
            brim.position = SCNVector3(0, 0.77, 0)
            container.addChildNode(brim)

            let crownGeo = SCNCylinder(radius: 0.14, height: 0.2)
            crownGeo.materials = [hatMat.copy() as! SCNMaterial]
            let crown = SCNNode(geometry: crownGeo)
            crown.position = SCNVector3(0, 0.88, 0)
            container.addChildNode(crown)

            // Red band
            let bandGeo = SCNCylinder(radius: 0.145, height: 0.025)
            let bandMat = SCNMaterial()
            bandMat.diffuse.contents = NSColor.systemRed.withAlphaComponent(0.7)
            bandGeo.materials = [bandMat]
            let band = SCNNode(geometry: bandGeo)
            band.position = SCNVector3(0, 0.81, 0)
            container.addChildNode(band)

        case .pirateHat:
            // Tricorn-style: 3 tilted brim segments
            let hatMat = SCNMaterial()
            hatMat.diffuse.contents = NSColor(white: 0.1, alpha: 1)
            hatMat.specular.contents = NSColor(white: 0.15, alpha: 1)

            let crownGeo = SCNCylinder(radius: 0.18, height: 0.15)
            crownGeo.materials = [hatMat]
            let crown = SCNNode(geometry: crownGeo)
            crown.position = SCNVector3(0, 0.87, 0)
            container.addChildNode(crown)

            // Brim flaps (3 rotated cylinders)
            for i in 0..<3 {
                let flapGeo = SCNCylinder(radius: 0.22, height: 0.02)
                flapGeo.materials = [hatMat.copy() as! SCNMaterial]
                let flap = SCNNode(geometry: flapGeo)
                flap.position = SCNVector3(0, 0.78, 0)
                flap.eulerAngles = SCNVector3(Float(i) * Float.pi / 6, Float(i) * Float.pi * 2 / 3, 0)
                container.addChildNode(flap)
            }

            // Skull emblem
            let skullGeo = SCNSphere(radius: 0.03)
            let skullMat = SCNMaterial()
            skullMat.diffuse.contents = NSColor.white
            skullMat.emission.contents = NSColor.white.withAlphaComponent(0.3)
            skullGeo.materials = [skullMat]
            let skull = SCNNode(geometry: skullGeo)
            skull.position = SCNVector3(0, 0.85, 0.17)
            container.addChildNode(skull)

        case .crown:
            let crownGeo = SCNCylinder(radius: 0.2, height: 0.06)
            let crownMat = SCNMaterial()
            crownMat.diffuse.contents = NSColor.systemYellow
            crownMat.specular.contents = NSColor.white
            crownMat.shininess = 60
            crownMat.emission.contents = NSColor.systemYellow.withAlphaComponent(0.2)
            crownGeo.materials = [crownMat]
            let base = SCNNode(geometry: crownGeo)
            base.position = SCNVector3(0, 0.8, 0)
            container.addChildNode(base)

            // Crown points
            for i in 0..<5 {
                let pointGeo = SCNCone(topRadius: 0, bottomRadius: 0.03, height: 0.1)
                pointGeo.materials = [crownMat.copy() as! SCNMaterial]
                let angle = Float(i) * Float.pi * 2 / 5
                let point = SCNNode(geometry: pointGeo)
                point.position = SCNVector3(0.12 * cos(angle), 0.88, 0.12 * sin(angle))
                container.addChildNode(point)

                // Gem on top
                let gemGeo = SCNSphere(radius: 0.015)
                let gemMat = SCNMaterial()
                gemMat.diffuse.contents = NSColor.red
                gemMat.emission.contents = NSColor.red.withAlphaComponent(0.5)
                gemGeo.materials = [gemMat]
                let gem = SCNNode(geometry: gemGeo)
                gem.position = SCNVector3(0, 0.06, 0)
                point.addChildNode(gem)
            }

        case .helmet:
            // Greek-style plumed helmet
            let helmGeo = SCNSphere(radius: 0.28)
            let helmMat = SCNMaterial()
            helmMat.diffuse.contents = NSColor(red: 0.75, green: 0.65, blue: 0.45, alpha: 1)
            helmMat.specular.contents = NSColor.white
            helmMat.shininess = 50
            helmGeo.materials = [helmMat]
            let helm = SCNNode(geometry: helmGeo)
            helm.position = SCNVector3(0, 0.55, -0.02)
            helm.scale = SCNVector3(1, 0.8, 1)
            container.addChildNode(helm)

            // Plume
            let plumeGeo = SCNCylinder(radius: 0.025, height: 0.25)
            let plumeMat = SCNMaterial()
            plumeMat.diffuse.contents = NSColor.systemRed.withAlphaComponent(0.9)
            plumeMat.emission.contents = NSColor.systemRed.withAlphaComponent(0.15)
            plumeGeo.materials = [plumeMat]
            let plume = SCNNode(geometry: plumeGeo)
            plume.position = SCNVector3(0, 0.85, 0)
            container.addChildNode(plume)

        case .catEars:
            // Two triangular ears
            let earMat = SCNMaterial()
            earMat.diffuse.contents = NSColor(white: 0.95, alpha: 1)
            earMat.specular.contents = NSColor.white
            earMat.shininess = 80

            let innerMat = SCNMaterial()
            innerMat.diffuse.contents = NSColor.systemPink.withAlphaComponent(0.6)
            innerMat.emission.contents = NSColor.systemPink.withAlphaComponent(0.15)

            for side in [-1, 1] {
                let earGeo = SCNCone(topRadius: 0, bottomRadius: 0.1, height: 0.18)
                earGeo.materials = [earMat]
                let ear = SCNNode(geometry: earGeo)
                ear.position = SCNVector3(Float(side) * 0.15, 0.82, 0)
                ear.eulerAngles = SCNVector3(0.1, 0, Float(side) * 0.15)
                container.addChildNode(ear)

                // Inner ear
                let innerGeo = SCNCone(topRadius: 0, bottomRadius: 0.06, height: 0.1)
                innerGeo.materials = [innerMat]
                let inner = SCNNode(geometry: innerGeo)
                inner.position = SCNVector3(0, 0.02, 0.03)
                ear.addChildNode(inner)
            }

        case .glasses:
            // Two circles + bridge
            let glassMat = SCNMaterial()
            glassMat.diffuse.contents = NSColor(white: 0.2, alpha: 1)
            glassMat.specular.contents = NSColor.white
            glassMat.shininess = 80

            for side in [-1, 1] {
                let lensGeo = SCNTorus(ringRadius: 0.07, pipeRadius: 0.008)
                lensGeo.materials = [glassMat]
                let lens = SCNNode(geometry: lensGeo)
                lens.position = SCNVector3(Float(side) * 0.09, 0.52, 0.28)
                container.addChildNode(lens)
            }

            // Bridge
            let bridgeGeo = SCNCylinder(radius: 0.005, height: 0.06)
            bridgeGeo.materials = [glassMat]
            let bridge = SCNNode(geometry: bridgeGeo)
            bridge.position = SCNVector3(0, 0.52, 0.28)
            bridge.eulerAngles = SCNVector3(0, 0, Float.pi / 2)
            container.addChildNode(bridge)

        case .sunglasses:
            let glassMat = SCNMaterial()
            glassMat.diffuse.contents = NSColor(white: 0.05, alpha: 1)
            glassMat.specular.contents = NSColor.white
            glassMat.shininess = 100
            glassMat.emission.contents = NSColor(white: 0.02, alpha: 1)

            for side in [-1, 1] {
                let lensGeo = SCNCylinder(radius: 0.08, height: 0.01)
                lensGeo.materials = [glassMat]
                let lens = SCNNode(geometry: lensGeo)
                lens.position = SCNVector3(Float(side) * 0.09, 0.52, 0.28)
                container.addChildNode(lens)
            }

            let bridgeGeo = SCNCylinder(radius: 0.005, height: 0.06)
            bridgeGeo.materials = [glassMat]
            let bridge = SCNNode(geometry: bridgeGeo)
            bridge.position = SCNVector3(0, 0.52, 0.28)
            bridge.eulerAngles = SCNVector3(0, 0, Float.pi / 2)
            container.addChildNode(bridge)

        case .eyepatch:
            let patchGeo = SCNCylinder(radius: 0.07, height: 0.01)
            let patchMat = SCNMaterial()
            patchMat.diffuse.contents = NSColor(white: 0.1, alpha: 1)
            patchGeo.materials = [patchMat]
            let patch = SCNNode(geometry: patchGeo)
            patch.position = SCNVector3(-0.09, 0.52, 0.28)
            container.addChildNode(patch)

            // Strap
            let strapGeo = SCNCylinder(radius: 0.004, height: 0.35)
            strapGeo.materials = [patchMat]
            let strap = SCNNode(geometry: strapGeo)
            strap.position = SCNVector3(-0.09, 0.55, 0.15)
            strap.eulerAngles = SCNVector3(Float.pi / 3, 0, 0)
            container.addChildNode(strap)

        case .bow:
            // Kawaii hair bow on top-right
            let bowMat = SCNMaterial()
            bowMat.diffuse.contents = NSColor.systemPink
            bowMat.emission.contents = NSColor.systemPink.withAlphaComponent(0.2)
            bowMat.specular.contents = NSColor.white
            bowMat.shininess = 60

            for side in [-1, 1] {
                let wingGeo = SCNSphere(radius: 0.06)
                wingGeo.materials = [bowMat]
                let wing = SCNNode(geometry: wingGeo)
                wing.position = SCNVector3(Float(side) * 0.06, 0.82, 0.05)
                wing.scale = SCNVector3(1, 0.6, 0.5)
                container.addChildNode(wing)
            }

            let centerGeo = SCNSphere(radius: 0.025)
            centerGeo.materials = [bowMat]
            let center = SCNNode(geometry: centerGeo)
            center.position = SCNVector3(0.12, 0.82, 0.05)
            container.addChildNode(center)

        case .boots:
            // Small boots at the bottom of the orb (decorative)
            let bootMat = SCNMaterial()
            bootMat.diffuse.contents = NSColor(red: 0.55, green: 0.35, blue: 0.15, alpha: 1)
            bootMat.specular.contents = NSColor(white: 0.2, alpha: 1)

            for side in [-1, 1] {
                let bootGeo = SCNCylinder(radius: 0.06, height: 0.08)
                bootGeo.materials = [bootMat]
                let boot = SCNNode(geometry: bootGeo)
                boot.position = SCNVector3(Float(side) * 0.12, -0.42, 0.06)
                container.addChildNode(boot)

                // Sole
                let soleGeo = SCNCylinder(radius: 0.07, height: 0.02)
                let soleMat = SCNMaterial()
                soleMat.diffuse.contents = NSColor(white: 0.15, alpha: 1)
                soleGeo.materials = [soleMat]
                let sole = SCNNode(geometry: soleGeo)
                sole.position = SCNVector3(0, -0.05, 0.01)
                boot.addChildNode(sole)
            }
        }

        return container
    }

    // MARK: - Lighting

    private func setupLighting() {
        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.color = NSColor(white: 0.45, alpha: 1)
        ambient.light?.castsShadow = false
        rootNode.addChildNode(ambient)

        let key = SCNNode()
        key.light = SCNLight()
        key.light?.type = .omni
        key.light?.color = NSColor.white
        key.light?.intensity = 1400
        key.position = SCNVector3(2, 3, 2.5)
        rootNode.addChildNode(key)

        let fill = SCNNode()
        fill.light = SCNLight()
        fill.light?.type = .omni
        fill.light?.color = NSColor(white: 0.5, alpha: 1)
        fill.light?.intensity = 500
        fill.position = SCNVector3(-2, 1, 2)
        rootNode.addChildNode(fill)

        let rim = SCNNode()
        rim.light = SCNLight()
        rim.light?.type = .omni
        rim.light?.color = NSColor.systemPurple.withAlphaComponent(0.4)
        rim.light?.intensity = 400
        rim.position = SCNVector3(0, 0, -3)
        rim.name = "rimLight"
        rootNode.addChildNode(rim)
    }

    private func setupCamera() {
        let camera = SCNCamera()
        camera.fieldOfView = 35
        camera.zNear = 0.1
        camera.zFar = 100
        let cameraNode = SCNNode()
        cameraNode.camera = camera
        cameraNode.position = SCNVector3(0, 0.25, 2.2)
        rootNode.addChildNode(cameraNode)
    }

    private func applyAccentColor() {
        let c = accentColor

        // Eye color
        if let mat = leftEyeNode.geometry?.firstMaterial {
            mat.diffuse.contents = c
            mat.emission.contents = c.withAlphaComponent(0.8)
        }
        if let mat = rightEyeNode.geometry?.firstMaterial {
            mat.diffuse.contents = c
            mat.emission.contents = c.withAlphaComponent(0.8)
        }

        // Mouth
        if let mat = mouthNode.geometry?.firstMaterial {
            mat.diffuse.contents = c
            mat.emission.contents = c.withAlphaComponent(0.6)
        }

        // Eye halos
        if let leftHalo = leftEyeNode.childNodes.first,
           let mat = leftHalo.geometry?.firstMaterial {
            mat.diffuse.contents = c.withAlphaComponent(0.15)
            mat.emission.contents = c.withAlphaComponent(0.1)
        }
        if let rightHalo = rightEyeNode.childNodes.first,
           let mat = rightHalo.geometry?.firstMaterial {
            mat.diffuse.contents = c.withAlphaComponent(0.15)
            mat.emission.contents = c.withAlphaComponent(0.1)
        }

        // Rings
        if let mat = ringNode.geometry?.firstMaterial {
            mat.diffuse.contents = c.withAlphaComponent(0.7)
            mat.emission.contents = c.withAlphaComponent(0.5)
        }
        if let mat = innerRingNode.geometry?.firstMaterial {
            mat.diffuse.contents = c.withAlphaComponent(0.4)
            mat.emission.contents = c.withAlphaComponent(0.25)
        }

        // Rim light
        if let rim = rootNode.childNodes.first(where: { $0.name == "rimLight" }) {
            rim.light?.color = c.withAlphaComponent(0.4)
        }
    }

    // MARK: - Animation Management

    private func clearAnimations(for state: AvatarState) {
        switch state {
        case .idle:
            headNode.removeAction(forKey: "blink")
        case .thinking:
            headNode.removeAction(forKey: "think_tilt")
            visorNode.removeAction(forKey: "think_pulse")
            leftEyeNode.removeAction(forKey: "think_scan")
            rightEyeNode.removeAction(forKey: "think_scan")
            headNode.runAction(SCNAction.rotateTo(x: 0, y: 0, z: 0, duration: 0.3, usesShortestUnitArc: true))
            leftEyeNode.runAction(SCNAction.move(to: SCNVector3(-0.09, 0.52, 0.27), duration: 0.3))
            rightEyeNode.runAction(SCNAction.move(to: SCNVector3(0.09, 0.52, 0.27), duration: 0.3))
        case .speaking:
            mouthNode.removeAction(forKey: "speak_mouth")
            headNode.removeAction(forKey: "speak_bob")
            headNode.runAction(SCNAction.rotateTo(x: 0, y: 0, z: 0, duration: 0.3, usesShortestUnitArc: true))
            mouthNode.runAction(SCNAction.scale(to: 1, duration: 0.2))
        case .toolUse:
            headNode.removeAction(forKey: "tool_look")
            orbNode.removeAction(forKey: "tool_pulse")
            headNode.runAction(SCNAction.rotateTo(x: 0, y: 0, z: 0, duration: 0.3, usesShortestUnitArc: true))
        case .error:
            headNode.removeAction(forKey: "error_shake")
            headNode.runAction(SCNAction.rotateTo(x: 0, y: 0, z: 0, duration: 0.3, usesShortestUnitArc: true))
            leftEyeNode.runAction(SCNAction.scale(to: 1, duration: 0.2))
            rightEyeNode.runAction(SCNAction.scale(to: 1, duration: 0.2))
        }
    }

    private func applyAnimations(for state: AvatarState) {
        switch state {
        case .idle:
            // Periodic blink
            let closeEyes = SCNAction.customAction(duration: 0.15) { node, _ in
                node.scale = SCNVector3(1, 0.1, 1)
            }
            let openEyes = SCNAction.customAction(duration: 0.15) { node, _ in
                node.scale = SCNVector3(1, 1, 1)
            }
            let wait = SCNAction.wait(duration: 3.5)
            let blink = SCNAction.sequence([wait, closeEyes, openEyes])
            leftEyeNode.runAction(SCNAction.repeatForever(blink), forKey: "blink")
            rightEyeNode.runAction(SCNAction.repeatForever(SCNAction.sequence([wait, closeEyes, openEyes])), forKey: "blink")

        case .thinking:
            // Head tilt
            let tiltR = SCNAction.rotateTo(x: 0, y: 0, z: 0.15, duration: 1.0, usesShortestUnitArc: true)
            let tiltL = SCNAction.rotateTo(x: 0, y: 0, z: -0.1, duration: 1.0, usesShortestUnitArc: true)
            headNode.runAction(SCNAction.repeatForever(SCNAction.sequence([tiltR, tiltL])), forKey: "think_tilt")

            // Visor pulse (glow cycling)
            let brighten = SCNAction.customAction(duration: 1.5) { node, elapsed in
                let t = elapsed / 1.5
                let alpha = 0.02 + 0.06 * sin(Float(t) * Float.pi)
                node.geometry?.firstMaterial?.emission.contents = NSColor(white: 0, alpha: CGFloat(alpha))
            }
            visorNode.runAction(SCNAction.repeatForever(brighten), forKey: "think_pulse")

            // Eye scan (slight horizontal drift)
            let scanR = SCNAction.moveBy(x: 0.02, y: 0, z: 0, duration: 1.2)
            let scanL = SCNAction.moveBy(x: -0.02, y: 0, z: 0, duration: 1.2)
            leftEyeNode.runAction(SCNAction.repeatForever(SCNAction.sequence([scanR, scanL])), forKey: "think_scan")
            rightEyeNode.runAction(SCNAction.repeatForever(SCNAction.sequence([scanR, scanL])), forKey: "think_scan")

        case .speaking:
            // Mouth LED animation
            let open = SCNAction.scale(to: 2.0, duration: 0.06)
            let close = SCNAction.scale(to: 0.5, duration: 0.06)
            let pause = SCNAction.wait(duration: 0.04)
            mouthNode.runAction(SCNAction.repeatForever(SCNAction.sequence([open, close, pause])), forKey: "speak_mouth")

            // Subtle head bob
            let down = SCNAction.moveBy(x: 0, y: -0.02, z: 0, duration: 0.35)
            let up = SCNAction.moveBy(x: 0, y: 0.02, z: 0, duration: 0.35)
            headNode.runAction(SCNAction.repeatForever(SCNAction.sequence([down, up])), forKey: "speak_bob")

        case .toolUse:
            // Head looking down at terminal
            headNode.runAction(SCNAction.rotateTo(x: 0.2, y: 0, z: 0, duration: 0.3, usesShortestUnitArc: true), forKey: "tool_look")

            // Orb subtle pulse
            let pulse = SCNAction.customAction(duration: 1.0) { node, elapsed in
                let t = elapsed / 1.0
                let s = 1.0 + 0.02 * sin(Float(t) * Float.pi * 2)
                node.scale = SCNVector3(s, s, s)
            }
            orbNode.runAction(SCNAction.repeatForever(pulse), forKey: "tool_pulse")

        case .error:
            // Wide eyes
            leftEyeNode.runAction(SCNAction.scale(to: 1.4, duration: 0.15))
            rightEyeNode.runAction(SCNAction.scale(to: 1.4, duration: 0.15))

            // Head shake
            let shakeR = SCNAction.rotateBy(x: 0, y: 0, z: 0.2, duration: 0.08)
            let shakeL = SCNAction.rotateBy(x: 0, y: 0, z: -0.2, duration: 0.08)
            headNode.runAction(SCNAction.repeatForever(SCNAction.sequence([shakeR, shakeL])), forKey: "error_shake")

            // Flash mouth red
            if let mat = mouthNode.geometry?.firstMaterial {
                mat.diffuse.contents = NSColor.systemRed
                mat.emission.contents = NSColor.systemRed.withAlphaComponent(0.8)
            }
        }
    }
}
