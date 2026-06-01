# Wiki Graph 3D (SceneKit) — Implementation Plan

**Option B** from the graph-fluidity discussion: render the LLM Wiki knowledge graph in
true 3D using native **SceneKit**, with a `2D ⇄ 3D` toggle. Fully GPU-accelerated,
no WKWebView, native trackpad orbit/zoom/pan, matching the fluidity + haptic goals.

---

## 1. Goal

- Add a 3D force-directed rendering of `WikiGraph` alongside the existing 2D `Canvas` view.
- A toggle in the controls overlay flips between **2D** (current `graphCanvas`) and **3D** (`SCNView`).
- Preserve all existing behavior: node selection → detail panel, wiki picker, color-by-type,
  degree-based sizing, hover/selection highlighting.
- Native feel: SceneKit camera controls for orbit/zoom/pan; haptics on node grab/select.

### Non-goals (v1)
- Dragging nodes in 3D (orbit + select only; node-drag stays a 2D feature).
- VR/AR. Edge labels in 3D. Curved/bowed edges in 3D (straight cylinders are fine).

---

## 2. Current Architecture (reference)

| Component | File | Notes |
|---|---|---|
| Model | `Sources/HermesNative/Models/WikiGraph.swift` | `WikiGraph { pages: [WikiPage], links: [WikiLink] }` |
| ViewModel | `Sources/HermesNative/ViewModels/WikiGraphViewModel.swift` | `@MainActor ObservableObject`; 2D force sim; `SimNode { id, position: CGPoint, velocity, isDragging, type, label }`; `color(for:)`; `degrees`; `zoom`/`panOffset`; `selectedNodeIndex`/`hoveredNodeIndex`; `tick()` 60Hz |
| 2D View | `Sources/HermesNative/Views/Wiki/WikiGraphView.swift` | Single `Canvas`; `GraphMouseInterceptor` (NSView) for pan/drag/zoom/hover; controls overlay; node detail panel |
| 3D precedent | `Sources/HermesNative/Views/Skills/SkillGraph3DView.swift` | WKWebView canvas projection — shows the *interaction shape* we want, but we'll do it natively in SceneKit |

The 2D force sim already has all the physics we need; we extend it to a third axis.

---

## 3. High-Level Approach

1. **Extend the force simulation to 3D** in `WikiGraphViewModel` (add `z` to positions/velocities;
   make repulsion/spring/centering 3D-aware). Gate the 3D math behind the active mode so the 2D
   path is untouched when in 2D.
2. **Build a SceneKit scene** (`WikiGraph3DView`) that mirrors `simNodes`/`simLinks`:
   spheres for nodes, thin cylinders (or line geometry) for edges, billboarded text labels.
3. **Drive the scene from the sim** — on each tick, update `SCNNode.position` for moved nodes.
4. **Camera + selection** — `allowsCameraControl` for orbit/zoom/pan; `hitTest` on tap to select.
5. **Toggle** — `@State viewMode: GraphViewMode` in `WikiGraphView`; swap `graphCanvas` ↔ `WikiGraph3DView`.

---

## 4. Detailed Changes

### 4.1 ViewModel — 3D force simulation
`Sources/HermesNative/ViewModels/WikiGraphViewModel.swift`

- Add a 3D position store. Two clean options:
  - **(preferred)** Add `var position3D: SIMD3<Float>` and `var velocity3D: SIMD3<Float>` to `SimNode`,
    keeping the existing 2D `position: CGPoint` for the 2D Canvas path.
  - Or generalize to SIMD3 everywhere and project z→0 for 2D. (Bigger diff; defer.)
- Add `@Published var is3D: Bool = false`.
- Add `setup3DSimulation()` — seed `position3D` on a sphere/Fibonacci-lattice (reuse the seeding
  idea from `SkillGraph3DView` line ~133: golden-angle spiral + z bands).
- Add `tick3D()` mirroring `tick()` but in SIMD3:
  - Repulsion: O(n²) over pairs, `chargeConstant / distSq` capped by `maxRepulsionForce`.
  - Springs: `(dist - springLength) * springConstant` along the 3D edge vector.
  - Centering: pull mean toward origin (no `canvasSize` needed in 3D; center at `(0,0,0)`).
  - Euler integrate with `friction`, `maxVelocity`, scaled by annealing `alpha`.
  - Reuse existing constants; reuse `alpha`/`alphaDecay`/`alphaMin`/`dragReheat` annealing.
- In the 60Hz driver, call `is3D ? tick3D() : tick()`.
- Keep `color(for:)` and `degrees` (sizing) unchanged — both modes reuse them.

> Tuning: 3D repulsion spreads nodes more than 2D; bump `springLength` ~1.3× and `centerPull`
> slightly when `is3D` so the cloud stays readable. Add `private let springLength3D`, `centerPull3D`.

### 4.2 New view — `WikiGraph3DView`
`Sources/HermesNative/Views/Wiki/WikiGraph3DView.swift` (new)

- `NSViewRepresentable` (macOS) / `UIViewRepresentable` (iOS) wrapping `SCNView`.
- `makeNSView`: configure `SCNView`
  - `scene = SCNScene()`, transparent background (`backgroundColor = .clear`),
    `allowsCameraControl = true`, `antialiasingMode = .multisampling4X`,
    `rendersContinuously = false` (we trigger redraws via node updates while `alpha` is hot).
  - Camera node with `SCNCamera` (perspective), positioned back along +z; soft ambient + one
    omni light for depth shading.
- **Node geometry**: one `SCNSphere` per node, radius from degree centrality
  (`4 + sqrt(degree) * k`), material `diffuse = color(for: type)`, slight `emission` for glow.
  Wrap each in an `SCNNode` named with the wiki page `id` (for hit-testing).
- **Edge geometry**: thin `SCNCylinder` (or a custom `SCNGeometry` line) between node centers,
  low-opacity accent color. Cheaper alternative for many edges: a single `SCNGeometry` built from
  line primitives (`SCNGeometryPrimitiveType.line`) rebuilt when topology changes.
- **Labels**: `SCNText` (or `SCNBillboardConstraint`-pinned plane) above each node; cull/scale by
  distance so far labels fade (match 2D viewport culling behavior).
- **Coordinator** holds maps `[pageID: SCNNode]` so per-tick updates are O(n) position writes,
  not a scene rebuild.

### 4.3 Sync loop (sim → scene)
- In `updateNSView`, diff `viewModel.simNodes`:
  - On topology change (graph reload): rebuild node/edge nodes.
  - On position change (every hot tick): write `node.position = SCNVector3(pos3D)`; if using
    line geometry for edges, rebuild the line buffer (or update only while `alpha` hot).
- Use the existing 60Hz `.onReceive(timer)` already in `WikiGraphView`; it calls `viewModel.tick()`
  which we route to `tick3D()` when `is3D`. SceneKit redraws when node transforms change.

### 4.4 Selection + hit-testing
- Add a tap/click recognizer on the `SCNView`:
  - macOS: `NSClickGestureRecognizer`; iOS: `UITapGestureRecognizer`.
  - `scnView.hitTest(point, options:)` → first result's node name → map to page id → set
    `viewModel.selectedNodeIndex` and open the detail panel (reuse existing `nodeDetailPanel`).
- Haptic on select (macOS `NSHapticFeedbackManager.perform(.alignment, ...)`).
- Highlight selected/neighbors: bump emission/scale on selected node + connected nodes; dim others
  (mirror `highlightAnchor` logic from the 2D path).

### 4.5 Toggle wiring
`Sources/HermesNative/Views/Wiki/WikiGraphView.swift`

- Add `enum GraphViewMode { case twoD, threeD }` and `@State private var viewMode: GraphViewMode = .twoD`.
- In the `ZStack`, switch content:
  ```swift
  if viewMode == .threeD {
      WikiGraph3DView(viewModel: viewModel)
  } else {
      graphCanvas
      #if os(macOS)
      GraphMouseInterceptor(...)   // 2D-only mouse pipeline
      #endif
  }
  ```
- On toggle, set `viewModel.is3D = (viewMode == .threeD)` and call `setup3DSimulation()` /
  `setupSimulation()` (re-seed + reheat `alpha`) so layout settles in the new dimensionality.
- Add a segmented control / button to the existing controls overlay (`controlsOverlay`,
  next to the zoom buttons): `2D | 3D`.
- Keep zoom buttons working in 2D; in 3D, defer zoom to SceneKit camera (hide or repurpose them).

---

## 5. Platform Notes
- `SCNView` exists on both macOS (AppKit) and iOS (UIKit) — wrap with `#if os(macOS)` /
  `#else` like `SkillGraph3DView` and `GraphMouseInterceptor` already do.
- `import SceneKit` (and `import simd` for SIMD3 math).
- `allowsCameraControl` gives free orbit (drag), zoom (pinch/scroll), pan (two-finger) for free —
  no custom gesture code needed for the camera.

---

## 6. Performance
- Graphs are ~20–150 nodes; O(n²) repulsion is fine at 60Hz (same as 2D today).
- Reuse the annealing early-out: once `alpha < alphaMin` and nothing is dragging, `tick3D()`
  returns immediately → SceneKit stops redrawing (set `rendersContinuously = false`).
- Prefer a single line-primitive `SCNGeometry` for edges over N cylinder nodes when edges > ~200.
- Cap label rendering: only show labels for selected node + neighbors, or within a distance
  threshold (mirrors 2D viewport culling).

---

## 7. Milestones
1. **Sim**: add `position3D`/`velocity3D` to `SimNode`, `is3D`, `setup3DSimulation()`, `tick3D()`.
   Unit-test that the 3D layout converges (`alpha` decays, positions stabilize).
2. **Scene**: `WikiGraph3DView` renders spheres + edges from `simNodes`/`simLinks`, camera + lights.
3. **Sync**: per-tick position updates via coordinator node map; reload rebuilds.
4. **Selection**: hit-test → `selectedNodeIndex` → detail panel; haptic feedback.
5. **Toggle**: `GraphViewMode`, overlay control, re-seed on switch.
6. **Polish**: highlight selected/neighbors, distance-faded labels, 3D tuning constants.

---

## 8. Testing
- **Unit (SwiftTesting, `Tests/HermesNativeTests`)**: feed a small `WikiGraph`, run N `tick3D()`
  iterations, assert positions are finite, non-overlapping beyond a threshold, and `alpha` decays.
- **Build**: macOS + iOS Simulator must compile (CI: Lint, Build, Swift Tests, iOS Sim, TestFlight).
- **Manual**: toggle 2D↔3D, orbit/zoom, select node opens correct page, reload re-seeds cleanly.

---

## 9. Risks / Mitigations
- **Edge rebuild cost** while animating → use line-primitive geometry or only rebuild edges while
  `alpha` is hot; freeze when settled.
- **Camera vs. selection gesture conflict** → use a click/tap recognizer (discrete) so it coexists
  with `allowsCameraControl` drag.
- **Two sims drifting** → 3D and 2D positions are independent stores; switching re-seeds, so no
  attempt to map 2D↔3D coordinates (intentional).
- **Label clutter in 3D** → distance/selection-based culling.

---

## 10. Estimated Effort
~Half a day. Sim extension (2h) · SceneKit scene + sync (2–3h) · selection + toggle + polish (1–2h).

---

## 11. Files Touched
- **New:** `Sources/HermesNative/Views/Wiki/WikiGraph3DView.swift`
- **Edit:** `Sources/HermesNative/ViewModels/WikiGraphViewModel.swift` (3D sim)
- **Edit:** `Sources/HermesNative/Views/Wiki/WikiGraphView.swift` (toggle + mode switch)
- **Edit (optional):** `Tests/HermesNativeTests/` (3D convergence test)
- Regenerate `HermesNative.xcodeproj` via `xcodegen generate` after adding the new file.
