import Foundation

/// Generates a self-contained HTML document that renders a 3D model via
/// Three.js + GLTFLoader (loaded from CDN). The artifact content JSON may
/// carry the model inline as base64 or reference a URL.
///
/// Artifact content schema:
///   {
///     "format": "glb" | "gltf" | "usdz",
///     "data": "<base64-encoded GLB/GLTF binary>",
///     "url": "https://…/model.glb",        // alternative to data
///     "background": "#1a1a2e",               // optional
///     "autoRotate": true                      // optional, default true
///   }
enum Model3DTemplate {

    /// Parse the artifact content JSON and extract model parameters.
    static func parse(_ content: String) -> Model3DSpec? {
        guard let data = content.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let format = (json["format"] as? String ?? "glb").lowercased()
        let modelData = json["data"] as? String
        let modelURL = json["url"] as? String
        guard modelData != nil || modelURL != nil else { return nil }

        return Model3DSpec(
            format: format,
            base64Data: modelData,
            url: modelURL,
            background: json["background"] as? String ?? "#1a1a2e",
            autoRotate: json["autoRotate"] as? Bool ?? true
        )
    }

    /// Build the complete HTML document.
    static func render(_ spec: Model3DSpec) -> String {
        let modelSource = modelSourceJS(spec)
        let modelURI = modelDataURI(spec)

        return """
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1">
        <style>
            * { margin: 0; padding: 0; box-sizing: border-box; }
            html, body { width: 100%; height: 100%; overflow: hidden; background: \(spec.background); }
            #canvas-container { width: 100%; height: 100%; }
            #loading {
                position: absolute; top: 50%; left: 50%; transform: translate(-50%, -50%);
                color: #888; font-family: -apple-system, sans-serif; font-size: 13px;
            }
            #error {
                position: absolute; top: 50%; left: 50%; transform: translate(-50%, -50%);
                color: #e55; font-family: -apple-system, sans-serif; font-size: 13px;
                text-align: center; max-width: 80%; display: none;
            }
        </style>
        </head>
        <body>
        <div id="canvas-container"></div>
        <div id="loading">Loading model…</div>
        <div id="error"></div>
        <script type="importmap">
        {
          "imports": {
            "three": "https://cdn.jsdelivr.net/npm/three@0.169.0/build/three.module.js",
            "three/addons/": "https://cdn.jsdelivr.net/npm/three@0.169.0/examples/jsm/"
          }
        }
        </script>
        <script type="module">
        import * as THREE from 'three';
        import { OrbitControls } from 'three/addons/controls/OrbitControls.js';
        import { GLTFLoader } from 'three/addons/loaders/GLTFLoader.js';
        import { RGBELoader } from 'three/addons/loaders/RGBELoader.js';

        const container = document.getElementById('canvas-container');
        const loadingEl = document.getElementById('loading');
        const errorEl = document.getElementById('error');

        // Scene
        const scene = new THREE.Scene();
        scene.background = new THREE.Color('\(spec.background)');

        // Camera — position will be auto-adjusted after model loads
        const camera = new THREE.PerspectiveCamera(45, container.clientWidth / container.clientHeight, 0.01, 1000);
        camera.position.set(3, 2, 5);

        // Renderer
        const renderer = new THREE.WebGLRenderer({ antialias: true, preserveDrawingBuffer: true });
        renderer.setSize(container.clientWidth, container.clientHeight);
        renderer.setPixelRatio(Math.min(window.devicePixelRatio, 2));
        renderer.toneMapping = THREE.ACESFilmicToneMapping;
        renderer.toneMappingExposure = 1.0;
        renderer.outputColorSpace = THREE.SRGBColorSpace;
        container.appendChild(renderer.domElement);

        // Controls
        const controls = new OrbitControls(camera, renderer.domElement);
        controls.enableDamping = true;
        controls.dampingFactor = 0.08;
        controls.autoRotate = \(spec.autoRotate ? "true" : "false");
        controls.autoRotateSpeed = 1.0;

        // Lighting — three-point setup
        const hemi = new THREE.HemisphereLight(0xffffff, 0x444444, 1.2);
        hemi.position.set(0, 20, 0);
        scene.add(hemi);

        const keyLight = new THREE.DirectionalLight(0xffffff, 2.0);
        keyLight.position.set(5, 10, 7);
        scene.add(keyLight);

        const fillLight = new THREE.DirectionalLight(0x99ccff, 0.6);
        fillLight.position.set(-5, 3, -5);
        scene.add(fillLight);

        const rimLight = new THREE.DirectionalLight(0xffffff, 0.8);
        rimLight.position.set(0, 5, -10);
        scene.add(rimLight);

        // Ground grid (subtle)
        const grid = new THREE.GridHelper(20, 20, 0x333333, 0x222222);
        grid.position.y = -0.01;
        scene.add(grid);

        // Load the model
        const loader = new GLTFLoader();
        \(modelSource)

        function onLoad(gltf) {
            const model = gltf.scene || gltf.scenes[0];
            if (!model) { onError('Model contained no scene'); return; }

            // Auto-frame: compute bounding box, fit camera
            const box = new THREE.Box3().setFromObject(model);
            const size = box.getSize(new THREE.Vector3());
            const center = box.getCenter(new THREE.Vector3());
            const maxDim = Math.max(size.x, size.y, size.z) || 1;
            const fov = camera.fov * (Math.PI / 180);
            let cameraZ = Math.abs(maxDim / 2 / Math.tan(fov / 2));
            cameraZ *= 1.8; // padding
            camera.position.set(center.x + cameraZ * 0.5, center.y + cameraZ * 0.4, center.z + cameraZ);
            camera.lookAt(center);
            controls.target.copy(center);
            controls.minDistance = maxDim * 0.3;
            controls.maxDistance = cameraZ * 5;
            controls.update();

            scene.add(model);
            loadingEl.style.display = 'none';
        }

        function onError(msg) {
            loadingEl.style.display = 'none';
            errorEl.textContent = msg || 'Failed to load model';
            errorEl.style.display = 'block';
            console.error('[model3d]', msg);
        }

        // Animation loop
        function animate() {
            requestAnimationFrame(animate);
            controls.update();
            renderer.render(scene, camera);
        }
        animate();

        // Resize
        window.addEventListener('resize', () => {
            camera.aspect = container.clientWidth / container.clientHeight;
            camera.updateProjectionMatrix();
            renderer.setSize(container.clientWidth, container.clientHeight);
        });
        </script>
        </body>
        </html>
        """
    }

    // MARK: - Private helpers

    /// Generates the JS line(s) that initiate the model load.
    private static func modelSourceJS(_ spec: Model3DSpec) -> String {
        if let uri = modelDataURI(spec) {
            return "loader.load('\(uri.jsEscaped)', onLoad, undefined, (e) => onError(e.message || 'Load failed'));"
        } else if let url = spec.url {
            return "loader.load('\(url.jsEscaped)', onLoad, undefined, (e) => onError(e.message || 'Load failed'));"
        }
        return "onError('No model data or URL provided');"
    }

    /// If the spec carries inline base64 data, build a data URI for it.
    private static func modelDataURI(_ spec: Model3DSpec) -> String? {
        guard let base64 = spec.base64Data, !base64.isEmpty else { return nil }
        let mime = spec.format == "gltf" ? "model/gltf+json" : "model/gltf-binary"
        return "data:\(mime);base64,\(base64)"
    }
}

// MARK: - Spec

struct Model3DSpec: Equatable {
    let format: String       // "glb" | "gltf" | "usdz"
    let base64Data: String?
    let url: String?
    let background: String
    let autoRotate: Bool
}

// MARK: - String escaping

private extension String {
    /// Escape for safe inclusion in a single-quoted JS string literal.
    var jsEscaped: String {
        replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
    }
}
