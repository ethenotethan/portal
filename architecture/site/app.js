(() => {
  "use strict";

  const payload = window.PORTAL_ARCHITECTURE;
  if (!payload || !payload.model) {
    document.body.innerHTML = '<main class="view active"><h1>Architecture data is unavailable.</h1><p>Run <code>make architecture</code>.</p></main>';
    return;
  }

  const model = payload.model;
  const behavior = model.behavior || {};
  const executionDomains = behavior.execution_domains || [];
  const taskSites = behavior.task_sites || [];
  const resources = behavior.resources || [];
  const operations = behavior.operations || [];
  const pockets = behavior.pockets || [];
  const scenarios = behavior.scenarios || [];
  const interplay = model.interplay || { nodes: [], edges: [], clusters: [] };
  const interplayNodeById = new Map(interplay.nodes.map((node) => [node.id, node]));
  // A resource/operation inherits its colour from the owning type's role, so the
  // free-form graph still reads as "this pool belongs to a transport" without any
  // column to say so.
  const interplayRoleByOwnerType = new Map();
  interplay.nodes.forEach((node) => {
    if (node.kind !== "owner") return;
    const roles = node.roles || [];
    interplayRoleByOwnerType.set(
      node.label,
      roles.includes("engine") ? "engine" : roles.includes("transport") ? "transport" : "other"
    );
  });
  // Declared before the render sequence below so renderInterplay() (called in
  // init) can close over them without hitting the const temporal dead zone.
  const INTERPLAY_ROLE_COLORS = {
    hub: "#8b83ff",
    seam: "#a58bff",
    transport: "#5ca8d8",
    endpoint: "#e7a84b",
    engine: "#70b98d",
    subscriber: "#d16f86",
    caller: "#7ec8b0",
    other: "#6d6a68"
  };
  const INTERPLAY_ROLE_LABELS = {
    hub: "Interplay hub",
    seam: "Backend seam",
    transport: "Connection-pool transport",
    caller: "Calling surface",
    endpoint: "Queried endpoints",
    engine: "On-device engine",
    subscriber: "Event subscribers",
    other: "Supporting owner"
  };
  const INTERPLAY_ROLE_RANK = { hub: 0, seam: 1, transport: 2, caller: 3, endpoint: 4, engine: 5, subscriber: 6, other: 7 };
  // Friendly module names for the well-known product namespaces, and the label of
  // the factored-out shared region. Declared in this top const block (like the
  // role maps) so renderInterplay(), called during init, reads them without
  // hitting the temporal dead zone.
  const INTERPLAY_FEATURE_NAMES = {
    prompt: "Chat", messages: "Chat", model: "Chat", clarify: "Chat", approval: "Chat",
    execute: "Chat", image: "Chat", interrupt: "Chat", voice: "Chat",
    wiki: "Wiki", cron: "CRON", feed: "Feed", files: "Files", code: "Code",
    commands: "Skills", skills: "Skills", session: "Session", config: "Config",
    gateway: "Gateway", activity: "Activity", workflows: "Workflows"
  };
  const INTERPLAY_SHARED_GROUP = "Shared core";
  const INTERPLAY_KIND_RANK = { hub: 0, seam: 0, owner: 0, resource: 1, endpoint: 1, subscriber: 1, operation: 2 };
  const specifications = payload.specifications || [];
  const componentById = new Map(model.components.map((component) => [component.id, component]));
  const layerById = new Map(model.layers.map((layer) => [layer.id, layer]));
  const layerColors = {
    experience: "#e7a84b",
    orchestration: "#8b83ff",
    integration: "#5ca8d8",
    foundation: "#70b98d",
    external: "#d16f86"
  };
  const repositoryBase = `https://github.com/${model.repository}/blob/main/`;
  let selectedComponentId = null;
  let positions = new Map();
  let selectedInterplayId = null;
  let interplayPositions = new Map();
  // Pan/zoom state for the free-form graph: the SVG fills its frame and we move a
  // viewBox window over the content, so click-drag pans, the wheel zooms, and a
  // node can be dragged to a new resting place. Content bounds anchor "fit".
  let interplayViewBox = null;
  let interplayContentBounds = { width: 0, height: 0 };

  document.getElementById("source-hash").textContent = model.source_tree_sha256.slice(0, 9);
  renderStats();
  renderLegend();
  renderGraph();
  renderInterplay();
  renderExecution();
  renderConnections();
  renderScenarios();
  renderSpecifications();
  renderInventory();
  wireNavigation();
  wireControls();

  function renderStats() {
    const values = [
      [model.inventory.swift_files.toLocaleString(), "Swift files"],
      [model.inventory.swift_lines.toLocaleString(), "Lines"],
      [model.components.length.toLocaleString(), "Components"],
      [model.edges.filter((edge) => edge.authority === "specified").length.toLocaleString(), "Arch. links"]
    ];
    const container = document.getElementById("stats");
    container.replaceChildren(...values.map(([value, label]) => {
      const item = element("div", "stat");
      item.append(element("span", "stat-value", value), element("span", "stat-label", label));
      return item;
    }));
  }

  function renderLegend() {
    const legend = document.getElementById("legend");
    legend.replaceChildren(...model.layers.map((layer) => {
      const item = element("div", "legend-item");
      const swatch = element("span", "legend-swatch");
      swatch.style.setProperty("--legend-color", layerColors[layer.id]);
      item.append(swatch, document.createTextNode(layer.label));
      return item;
    }));
  }

  function graphEdges() {
    const mode = document.getElementById("edge-mode").value;
    if (mode === "all") return model.edges;
    return model.edges.filter((edge) => edge.authority === "specified");
  }

  function renderGraph() {
    const svg = document.getElementById("architecture-graph");
    const width = 1160;
    const height = Math.max(680, ...model.layers.map((layer) => {
      const count = model.components.filter((component) => component.layer === layer.id).length;
      return 94 + count * 94;
    }));
    svg.setAttribute("viewBox", `0 0 ${width} ${height}`);
    svg.textContent = "";
    positions = new Map();

    const marginX = 24;
    const columnWidth = 210;
    const columnGap = 20;
    const nodeWidth = 190;
    const nodeHeight = 66;
    const startY = 72;
    const nodeGap = 28;

    model.layers.forEach((layer, layerIndex) => {
      const x = marginX + layerIndex * (columnWidth + columnGap);
      const label = svgElement("text", {
        x, y: 28, class: "graph-layer-label"
      });
      label.textContent = `${String(layer.order + 1).padStart(2, "0")} / ${layer.label.toUpperCase()}`;
      svg.append(label);
      const rule = svgElement("line", {
        x1: x, x2: x + nodeWidth, y1: 44, y2: 44, class: "graph-layer-rule"
      });
      svg.append(rule);

      const layerComponents = model.components.filter((component) => component.layer === layer.id);
      layerComponents.forEach((component, componentIndex) => {
        const y = startY + componentIndex * (nodeHeight + nodeGap);
        positions.set(component.id, { x, y, width: nodeWidth, height: nodeHeight });
      });
    });

    const edgeGroup = svgElement("g", { class: "edges" });
    graphEdges().forEach((edge) => {
      const source = positions.get(edge.source);
      const target = positions.get(edge.target);
      if (!source || !target) return;
      const sx = source.x + source.width;
      const sy = source.y + source.height / 2;
      const tx = target.x;
      const ty = target.y + target.height / 2;
      const bend = Math.max(38, Math.abs(tx - sx) * 0.42);
      const path = svgElement("path", {
        d: `M ${sx} ${sy} C ${sx + bend} ${sy}, ${tx - bend} ${ty}, ${tx} ${ty}`,
        class: `graph-edge ${edge.authority === "observed" ? "reference" : "specified"}`,
        "data-source": edge.source,
        "data-target": edge.target
      });
      edgeGroup.append(path);
    });
    svg.append(edgeGroup);

    const nodeGroup = svgElement("g", { class: "nodes" });
    model.components.forEach((component) => {
      const position = positions.get(component.id);
      const group = svgElement("g", {
        class: "graph-node",
        tabindex: "0",
        role: "button",
        "aria-label": `${component.label}, ${layerById.get(component.layer).label}`,
        "data-component": component.id,
        transform: `translate(${position.x} ${position.y})`
      });
      group.style.setProperty("--node-color", layerColors[component.layer]);
      group.append(svgElement("rect", { width: position.width, height: position.height }));
      group.append(svgElement("line", { x1: 0, x2: 0, y1: 8, y2: position.height - 8, class: "node-rule" }));
      const kicker = svgElement("text", { x: 15, y: 17, class: "node-kicker" });
      kicker.textContent = component.external ? "EXTERNAL" : layerById.get(component.layer).label.toUpperCase();
      const title = svgElement("text", { x: 15, y: 38, class: "node-title" });
      title.textContent = component.label;
      const meta = svgElement("text", { x: 15, y: 55, class: "node-meta" });
      meta.textContent = component.external
        ? "runtime boundary"
        : `${component.file_count} files · ${component.declaration_count} declarations`;
      group.append(kicker, title, meta);
      group.addEventListener("click", () => selectComponent(component.id));
      group.addEventListener("keydown", (event) => {
        if (event.key === "Enter" || event.key === " ") {
          event.preventDefault();
          selectComponent(component.id);
        }
      });
      nodeGroup.append(group);
    });
    svg.append(nodeGroup);
    applyGraphState();
    if (selectedComponentId) renderInspector(componentById.get(selectedComponentId));
  }

  function selectComponent(componentId) {
    selectedComponentId = componentId;
    renderInspector(componentById.get(componentId));
    applyGraphState();
  }

  function applyGraphState() {
    const query = document.getElementById("graph-search").value.trim().toLowerCase();
    const connected = new Set();
    if (selectedComponentId) {
      connected.add(selectedComponentId);
      graphEdges().forEach((edge) => {
        if (edge.source === selectedComponentId) connected.add(edge.target);
        if (edge.target === selectedComponentId) connected.add(edge.source);
      });
    }

    document.querySelectorAll(".graph-node").forEach((node) => {
      const component = componentById.get(node.dataset.component);
      const searchable = [
        component.label,
        component.description,
        component.layer,
        ...component.declarations,
        ...component.files
      ].join(" ").toLowerCase();
      const queryMismatch = query && !searchable.includes(query);
      const selectionMismatch = selectedComponentId && !connected.has(component.id);
      node.classList.toggle("selected", component.id === selectedComponentId);
      node.classList.toggle("dimmed", Boolean(queryMismatch || selectionMismatch));
    });

    document.querySelectorAll(".graph-edge").forEach((edge) => {
      const active = selectedComponentId &&
        (edge.dataset.source === selectedComponentId || edge.dataset.target === selectedComponentId);
      edge.classList.toggle("active", Boolean(active));
      edge.classList.toggle("dimmed", Boolean(selectedComponentId && !active));
    });
  }

  function renderInspector(component) {
    const inspector = document.getElementById("inspector");
    inspector.style.setProperty("--component-color", layerColors[component.layer]);
    inspector.textContent = "";

    const badge = element("span", "inspector-badge", `${layerById.get(component.layer).label} · ${component.external ? "external" : "source-owned"}`);
    const title = element("h3", "", component.label);
    const description = element("p", "", component.semantic?.summary || component.description);
    inspector.append(badge, title, description);

    const metrics = element("div", "inspector-metrics");
    [[component.file_count, "Files"], [component.line_count.toLocaleString(), "Lines"], [component.declaration_count, "Types"]].forEach(([value, label]) => {
      const metric = element("div", "inspector-metric");
      metric.append(element("strong", "", String(value)), element("span", "", label));
      metrics.append(metric);
    });
    inspector.append(metrics);

    const relationships = graphEdges().filter(
      (edge) => edge.source === component.id || edge.target === component.id
    );
    if (relationships.length) {
      const section = inspectorSection("Relationships");
      relationships.slice(0, 12).forEach((edge) => {
        const outbound = edge.source === component.id;
        const peer = componentById.get(outbound ? edge.target : edge.source);
        const row = element("div", "relationship");
        row.append(
          element("strong", "", `${outbound ? "→" : "←"} ${peer.label}`),
          element("span", "", `${edge.type.replaceAll("_", " ")} · ${edge.authority}`)
        );
        section.append(row);
      });
      inspector.append(section);
    }

    if (component.semantic?.responsibilities?.length) {
      inspector.append(chipSection("Synthesized responsibilities", component.semantic.responsibilities));
    }
    if (component.declarations.length) {
      inspector.append(chipSection("Declarations", component.declarations.slice(0, 24)));
    }
    if (component.files.length) {
      const section = inspectorSection("Source evidence");
      const list = element("ul", "evidence-list");
      component.files.slice(0, 18).forEach((path) => {
        const link = document.createElement("a");
        link.href = repositoryBase + path;
        link.target = "_blank";
        link.rel = "noreferrer";
        link.textContent = path.replace("Sources/Portal/", "");
        const item = document.createElement("li");
        item.append(link);
        list.append(item);
      });
      section.append(list);
      inspector.append(section);
    }

    if (!component.external && component.layer === "integration") {
      inspector.append(codeGraphReference(component));
    }
  }

  // The interactive code knowledge graph of a service's code — modules, types
  // and functions with import/call flow — lives in the Portal app, which builds
  // it on demand from the service's source files (Cron dataflow → select the
  // service → "View code graph"). The static Observatory references it rather
  // than re-deriving it here, so the generated site stays dependency-free and
  // byte-deterministic. Shown for integration-layer (service) components only.
  function codeGraphReference(component) {
    const section = inspectorSection("Code graph");
    section.append(element(
      "p",
      "code-graph-reference",
      `An interactive code knowledge graph of ${component.label}’s ${component.file_count} ` +
      `source file(s) — modules, types and functions with import/call flow — is available in the ` +
      `Portal app: open the Cron dataflow view, select this service, and choose “View code graph.”`
    ));
    return section;
  }

  function inspectorSection(title) {
    const section = element("section", "inspector-section");
    section.append(element("h4", "", title));
    return section;
  }

  function chipSection(title, values) {
    const section = inspectorSection(title);
    const list = element("div", "chip-list");
    values.forEach((value) => list.append(element("span", "chip", value)));
    section.append(list);
    return section;
  }

  function sourceSort(left, right) {
    const leftEvidence = left.evidence || {};
    const rightEvidence = right.evidence || {};
    return String(leftEvidence.path || "").localeCompare(String(rightEvidence.path || "")) ||
      Number(leftEvidence.line || 0) - Number(rightEvidence.line || 0) ||
      String(left.id || "").localeCompare(String(right.id || ""));
  }

  function componentLabel(componentId) {
    return componentById.get(componentId)?.label || componentId || "Unassigned";
  }

  function interplayNodeRole(node) {
    if (node.kind === "hub") return "hub";
    if (node.kind === "seam") return "seam";
    if (node.kind === "endpoint") return "endpoint";
    if (node.kind === "subscriber") return "subscriber";
    if (node.kind === "caller") return "caller";
    if (node.kind === "owner") return interplayRoleByOwnerType.get(node.label) || "other";
    return interplayRoleByOwnerType.get(node.owner_type) || "other";
  }

  function interplayNodeSize(node) {
    if (node.kind === "operation") return { width: 158, height: 38 };
    if (node.kind === "endpoint") return { width: 150, height: 46 };
    const label = node.label || "";
    return { width: Math.max(132, Math.min(206, label.length * 7.6 + 34)), height: 48 };
  }

  // Feature-module placement: each product feature (Chat, CRON, Wiki, Skills, …)
  // becomes its own bounded, labelled region holding its calling surface plus the
  // namespaces only that feature calls. Everything genuinely shared — the single
  // GatewayClient/CentaurClient and pools, cross-feature namespaces (session,
  // config, files…), the AgentBackend seam, the on-device engines, the event bus
  // and its subscribers — is factored out into one SHARED CORE the features depend
  // on. Deterministic: feature keys come from the call graph, packing from sorted
  // order, no PRNG. INTERPLAY_FEATURE_NAMES / INTERPLAY_SHARED_GROUP live in the
  // top const block to stay clear of the temporal dead zone during init.
  function interplayFeatureName(namespace) {
    if (INTERPLAY_FEATURE_NAMES[namespace]) return INTERPLAY_FEATURE_NAMES[namespace];
    if (!namespace) return "Other";
    return namespace.charAt(0).toUpperCase() + namespace.slice(1);
  }

  // Assign every node to a group id. A caller lands in the feature of its most
  // distinctive namespace (fewest callers, lexicographic tie-break). An endpoint
  // joins a feature only when every caller invoking it lives in that one feature;
  // endpoints spanning features (session, config, files) plus every
  // transport/seam/engine/bus/subscriber node fall into the shared core.
  function assignInterplayGroups(nodes, edges) {
    const nodeById = new Map(nodes.map((node) => [node.id, node]));
    const invokedBy = new Map();        // endpointId -> Set(callerId)
    const callerEndpoints = new Map();  // callerId   -> Set(endpointId)
    edges.forEach((edge) => {
      if (edge.relation !== "invokes") return;
      if (!invokedBy.has(edge.target)) invokedBy.set(edge.target, new Set());
      invokedBy.get(edge.target).add(edge.source);
      if (!callerEndpoints.has(edge.source)) callerEndpoints.set(edge.source, new Set());
      callerEndpoints.get(edge.source).add(edge.target);
    });
    const callerFeature = new Map();
    nodes.forEach((node) => {
      if (interplayNodeRole(node) !== "caller") return;
      const candidates = Array.from(callerEndpoints.get(node.id) || []).map((ep) => ({
        label: (nodeById.get(ep) || {}).label || "",
        count: (invokedBy.get(ep) || new Set()).size || 99
      }));
      candidates.sort((a, b) => a.count - b.count || a.label.localeCompare(b.label));
      callerFeature.set(node.id, candidates.length ? interplayFeatureName(candidates[0].label) : INTERPLAY_SHARED_GROUP);
    });
    const group = new Map();
    nodes.forEach((node) => {
      const role = interplayNodeRole(node);
      if (role === "caller") { group.set(node.id, callerFeature.get(node.id) || INTERPLAY_SHARED_GROUP); return; }
      if (role === "endpoint") {
        const features = new Set(Array.from(invokedBy.get(node.id) || []).map((id) => callerFeature.get(id)).filter(Boolean));
        group.set(node.id, features.size === 1 ? Array.from(features)[0] : INTERPLAY_SHARED_GROUP);
        return;
      }
      group.set(node.id, INTERPLAY_SHARED_GROUP);
    });
    return group;
  }

  function layoutInterplayGrouped(nodes, edges) {
    const size = new Map(nodes.map((node) => [node.id, interplayNodeSize(node)]));
    const group = assignInterplayGroups(nodes, edges);
    const kindRank = (node) => {
      const role = interplayNodeRole(node);
      if (role === "caller") return 0;
      if (role === "endpoint") return 1;
      if (role === "transport") return 2;
      if (role === "seam") return 3;
      if (role === "engine") return 4;
      return 5;
    };
    const byGroup = new Map();
    nodes.forEach((node) => {
      const g = group.get(node.id);
      if (!byGroup.has(g)) byGroup.set(g, []);
      byGroup.get(g).push(node);
    });
    byGroup.forEach((list) => list.sort((a, b) =>
      kindRank(a) - kindRank(b) || (a.label || "").localeCompare(b.label || "") || a.id.localeCompare(b.id)));

    const PAD = 20;
    const HEADER = 30;
    const GAP = 14;
    function layoutGroup(list, cols) {
      const place = new Map();
      let x = PAD;
      let y = PAD + HEADER;
      let rowH = 0;
      let maxRight = PAD;
      let col = 0;
      let prevRank = null;
      list.forEach((node) => {
        const s = size.get(node.id);
        const rank = kindRank(node);
        const wrap = col >= cols || (prevRank === 0 && rank !== 0); // callers get their own top row
        if (wrap) { col = 0; x = PAD; y += rowH + GAP; rowH = 0; }
        place.set(node.id, { x: x + s.width / 2, y: y + s.height / 2 });
        x += s.width + GAP;
        maxRight = Math.max(maxRight, x - GAP);
        rowH = Math.max(rowH, s.height);
        col += 1;
        prevRank = rank;
      });
      return { w: maxRight + PAD, h: y + rowH + PAD, place };
    }

    const laid = new Map();
    byGroup.forEach((list, g) => {
      const cols = g === INTERPLAY_SHARED_GROUP ? 6 : Math.max(2, Math.min(4, Math.ceil(Math.sqrt(list.length))));
      laid.set(g, layoutGroup(list, cols));
    });

    // Feature modules shelf-pack in a wrapping row; the shared core spans a full
    // shelf of its own beneath them.
    const BOX_GAP = 40;
    const shared = laid.get(INTERPLAY_SHARED_GROUP);
    const targetWidth = Math.max(shared ? shared.w : 0, 1280);
    const featureOrder = Array.from(byGroup.keys())
      .filter((g) => g !== INTERPLAY_SHARED_GROUP)
      .sort((a, b) => laid.get(b).h - laid.get(a).h || a.localeCompare(b));
    const groupBoxes = [];
    let cx = 0;
    let cy = 0;
    let shelfH = 0;
    featureOrder.forEach((g) => {
      const box = laid.get(g);
      if (cx > 0 && cx + box.w > targetWidth) { cx = 0; cy += shelfH + BOX_GAP; shelfH = 0; }
      groupBoxes.push({ label: g, x: cx, y: cy, w: box.w, h: box.h, place: box.place });
      cx += box.w + BOX_GAP;
      shelfH = Math.max(shelfH, box.h);
    });
    if (shared) {
      cy += shelfH + BOX_GAP;
      groupBoxes.push({ label: INTERPLAY_SHARED_GROUP, x: 0, y: cy, w: shared.w, h: shared.h, place: shared.place });
    }

    const positions = new Map();
    groupBoxes.forEach((box) => {
      box.place.forEach((rel, id) => positions.set(id, { x: box.x + rel.x, y: box.y + rel.y }));
    });
    positions.groupBoxes = groupBoxes.map((box) => ({ label: box.label, x: box.x, y: box.y, w: box.w, h: box.h }));
    return positions;
  }

  function renderInterplay() {
    const svg = document.getElementById("interplay-graph");
    if (!svg) return;
    svg.textContent = "";
    interplayPositions = new Map();

    if (!interplay.nodes.length) {
      svg.setAttribute("viewBox", "0 0 600 120");
      const note = svgElement("text", { x: 24, y: 60, class: "graph-layer-label" });
      note.textContent = "No interplay resources were extracted from this source tree.";
      svg.append(note);
      return;
    }

    const nodeRole = new Map();
    interplay.nodes.forEach((node) => nodeRole.set(node.id, interplayNodeRole(node)));

    // Position every node with the deterministic feature-module layout, then
    // translate the whole graph so its top-left corner sits at the margin.
    const layout = layoutInterplayGrouped(interplay.nodes, interplay.edges);
    const groupBoxes = layout.groupBoxes || [];
    let minX = Infinity;
    let minY = Infinity;
    let maxX = -Infinity;
    let maxY = -Infinity;
    interplay.nodes.forEach((node) => {
      const size = interplayNodeSize(node);
      const center = layout.get(node.id);
      const x = center.x - size.width / 2;
      const y = center.y - size.height / 2;
      interplayPositions.set(node.id, { x, y, width: size.width, height: size.height });
      minX = Math.min(minX, x);
      minY = Math.min(minY, y);
      maxX = Math.max(maxX, x + size.width);
      maxY = Math.max(maxY, y + size.height);
    });
    // The module hulls extend past the node centres, so fold their extents into the
    // bounds too before centring the whole diagram.
    groupBoxes.forEach((box) => {
      minX = Math.min(minX, box.x);
      minY = Math.min(minY, box.y);
      maxX = Math.max(maxX, box.x + box.w);
      maxY = Math.max(maxY, box.y + box.h);
    });
    const margin = 48;
    const shiftX = margin - minX;
    const shiftY = margin - minY;
    interplayPositions.forEach((position) => {
      position.x += shiftX;
      position.y += shiftY;
    });
    groupBoxes.forEach((box) => { box.x += shiftX; box.y += shiftY; });
    const width = Math.ceil(maxX - minX + margin * 2);
    const height = Math.ceil(maxY - minY + margin * 2);
    // The SVG fills its frame; a viewBox window pans/zooms over the content. Start
    // fitted to the whole graph so the first paint shows everything.
    interplayContentBounds = { width, height };
    interplayViewBox = { x: 0, y: 0, w: width, h: height };
    svg.setAttribute("preserveAspectRatio", "xMidYMid meet");
    svg.style.width = "100%";
    svg.style.minWidth = "0";
    svg.style.removeProperty("height"); // height is governed by CSS (72vh / fullscreen)
    applyInterplayViewBox();

    // Each product feature (Chat, CRON, Wiki, Skills…) is drawn as a bounded,
    // labelled module holding its surface and the namespaces only it calls; the
    // shared core sits in its own wider hull beneath them. The hulls render behind
    // everything so edges and nodes read on top.
    const groupLayer = svgElement("g", { class: "interplay-groups" });
    groupBoxes.forEach((box) => {
      const shared = box.label === INTERPLAY_SHARED_GROUP;
      const hull = svgElement("g", {
        class: `interplay-group${shared ? " shared" : ""}`,
        "data-group": box.label
      });
      const rect = svgElement("rect", {
        x: box.x,
        y: box.y,
        width: box.w,
        height: box.h,
        rx: 16,
        ry: 16,
        class: "interplay-group-rect"
      });
      const label = svgElement("text", {
        x: box.x + 18,
        y: box.y + 20,
        class: "interplay-group-label"
      });
      label.textContent = box.label;
      hull.append(rect, label);
      groupLayer.append(hull);
    });
    svg.append(groupLayer);

    const edgeGroup = svgElement("g", { class: "edges" });
    interplay.edges.forEach((edge) => {
      const source = interplayPositions.get(edge.source);
      const target = interplayPositions.get(edge.target);
      if (!source || !target) return;
      const path = svgElement("path", {
        d: interplayLinkPath(source, target),
        class: `interplay-edge ${edge.class}`,
        "data-source": edge.source,
        "data-target": edge.target
      });
      const title = svgElement("title", {});
      title.textContent = edge.relation;
      path.append(title);
      edgeGroup.append(path);
    });
    svg.append(edgeGroup);

    const nodeGroup = svgElement("g", { class: "nodes" });
    interplay.nodes.forEach((node) => {
      const position = interplayPositions.get(node.id);
      if (!position) return;
      const role = nodeRole.get(node.id) || "other";
      const group = svgElement("g", {
        class: "interplay-node",
        tabindex: "0",
        role: "button",
        "aria-label": `${node.label}, ${INTERPLAY_ROLE_LABELS[role]}`,
        "data-node": node.id,
        "data-kind": node.kind,
        transform: `translate(${position.x} ${position.y})`
      });
      group.style.setProperty("--node-color", INTERPLAY_ROLE_COLORS[role]);
      const rect = svgElement("rect", { width: position.width, height: position.height, rx: 6 });
      if (node.kind === "operation") rect.setAttribute("class", "operation");
      else if (node.kind === "endpoint") rect.setAttribute("class", "endpoint");
      else if (node.kind === "caller") rect.setAttribute("class", "caller");
      if (node.overlay_prose) rect.setAttribute("data-explained", "true");
      group.append(rect);
      group.append(svgElement("line", { x1: 0, x2: 0, y1: 6, y2: position.height - 6, class: "node-rule" }));
      const kicker = svgElement("text", { x: 11, y: 15, class: "node-kicker" });
      kicker.textContent = interplayKicker(node);
      const title = svgElement("text", { x: 11, y: 29, class: "node-title" });
      title.textContent = node.label;
      group.append(kicker, title);
      if (node.kind !== "operation") {
        const meta = svgElement("text", { x: 11, y: 41, class: "node-meta" });
        meta.textContent = interplayNodeMeta(node);
        group.append(meta);
      }
      wireInterplayNodeDrag(svg, group, node.id);
      group.addEventListener("keydown", (event) => {
        if (event.key === "Enter" || event.key === " ") {
          event.preventDefault();
          selectInterplayNode(node.id);
        }
      });
      nodeGroup.append(group);
    });
    svg.append(nodeGroup);

    wireInterplayPanZoom(svg);
    renderInterplayLegend();
    applyInterplayState();
    if (selectedInterplayId) renderInterplayInspector(interplayNodeById.get(selectedInterplayId));
  }

  // ---- Pan / zoom / drag over the free-form graph ---------------------------
  function applyInterplayViewBox() {
    const svg = document.getElementById("interplay-graph");
    if (!svg || !interplayViewBox) return;
    const { x, y, w, h } = interplayViewBox;
    svg.setAttribute("viewBox", `${x.toFixed(2)} ${y.toFixed(2)} ${w.toFixed(2)} ${h.toFixed(2)}`);
  }

  // Fit the whole graph back into view — the escape hatch after panning away.
  function fitInterplayView() {
    if (!interplayContentBounds.width) return;
    interplayViewBox = { x: 0, y: 0, w: interplayContentBounds.width, h: interplayContentBounds.height };
    applyInterplayViewBox();
  }

  // Convert a client (screen) point to content coordinates via the live CTM, so
  // dragging tracks the cursor exactly at any zoom/pan.
  function interplayClientToContent(svg, clientX, clientY) {
    const ctm = svg.getScreenCTM();
    if (!ctm) return { x: clientX, y: clientY };
    const point = svg.createSVGPoint();
    point.x = clientX;
    point.y = clientY;
    const mapped = point.matrixTransform(ctm.inverse());
    return { x: mapped.x, y: mapped.y };
  }

  function redrawInterplayEdgesFor(nodeId) {
    document.querySelectorAll(".interplay-edge").forEach((path) => {
      if (path.dataset.source !== nodeId && path.dataset.target !== nodeId) return;
      const source = interplayPositions.get(path.dataset.source);
      const target = interplayPositions.get(path.dataset.target);
      if (source && target) path.setAttribute("d", interplayLinkPath(source, target));
    });
  }

  function wireInterplayNodeDrag(svg, group, nodeId) {
    let offsetX = 0;
    let offsetY = 0;
    let moved = false;
    let dragging = false;
    group.addEventListener("pointerdown", (event) => {
      if (event.button !== 0) return;
      event.stopPropagation(); // keep the background pan handler from also firing
      const position = interplayPositions.get(nodeId);
      if (!position) return;
      const start = interplayClientToContent(svg, event.clientX, event.clientY);
      offsetX = start.x - position.x;
      offsetY = start.y - position.y;
      moved = false;
      dragging = true;
      group.setPointerCapture(event.pointerId);
      group.classList.add("dragging");
    });
    group.addEventListener("pointermove", (event) => {
      if (!dragging) return;
      const position = interplayPositions.get(nodeId);
      const point = interplayClientToContent(svg, event.clientX, event.clientY);
      const nextX = point.x - offsetX;
      const nextY = point.y - offsetY;
      if (Math.abs(nextX - position.x) > 0.5 || Math.abs(nextY - position.y) > 0.5) moved = true;
      position.x = nextX;
      position.y = nextY;
      group.setAttribute("transform", `translate(${nextX} ${nextY})`);
      redrawInterplayEdgesFor(nodeId);
    });
    const end = (event) => {
      if (!dragging) return;
      dragging = false;
      group.classList.remove("dragging");
      if (group.hasPointerCapture(event.pointerId)) group.releasePointerCapture(event.pointerId);
      if (!moved) selectInterplayNode(nodeId); // a drag that never moved is a click
    };
    group.addEventListener("pointerup", end);
    group.addEventListener("pointercancel", end);
  }

  function wireInterplayPanZoom(svg) {
    if (svg.dataset.panzoom === "on") return; // wire the frame once, not per render
    svg.dataset.panzoom = "on";
    const scroll = document.getElementById("interplay-scroll");
    let panning = false;
    let startX = 0;
    let startY = 0;
    let originX = 0;
    let originY = 0;
    svg.addEventListener("pointerdown", (event) => {
      if (event.button !== 0 || !interplayViewBox) return;
      panning = true;
      startX = event.clientX;
      startY = event.clientY;
      originX = interplayViewBox.x;
      originY = interplayViewBox.y;
      svg.setPointerCapture(event.pointerId);
      if (scroll) scroll.classList.add("panning");
    });
    svg.addEventListener("pointermove", (event) => {
      if (!panning || !interplayViewBox) return;
      const rect = svg.getBoundingClientRect();
      const scaleX = interplayViewBox.w / (rect.width || 1);
      const scaleY = interplayViewBox.h / (rect.height || 1);
      interplayViewBox.x = originX - (event.clientX - startX) * scaleX;
      interplayViewBox.y = originY - (event.clientY - startY) * scaleY;
      applyInterplayViewBox();
    });
    const stop = (event) => {
      if (!panning) return;
      panning = false;
      if (svg.hasPointerCapture(event.pointerId)) svg.releasePointerCapture(event.pointerId);
      if (scroll) scroll.classList.remove("panning");
    };
    svg.addEventListener("pointerup", stop);
    svg.addEventListener("pointercancel", stop);
    svg.addEventListener("wheel", (event) => {
      if (!interplayViewBox) return;
      event.preventDefault();
      const rect = svg.getBoundingClientRect();
      const px = (event.clientX - rect.left) / (rect.width || 1);
      const py = (event.clientY - rect.top) / (rect.height || 1);
      const anchorX = interplayViewBox.x + px * interplayViewBox.w;
      const anchorY = interplayViewBox.y + py * interplayViewBox.h;
      const factor = event.deltaY > 0 ? 1.1 : 1 / 1.1;
      const minW = interplayContentBounds.width * 0.2;
      const maxW = interplayContentBounds.width * 3;
      const nextW = Math.max(minW, Math.min(maxW, interplayViewBox.w * factor));
      const ratio = nextW / interplayViewBox.w;
      interplayViewBox.w = nextW;
      interplayViewBox.h *= ratio;
      interplayViewBox.x = anchorX - px * interplayViewBox.w;
      interplayViewBox.y = anchorY - py * interplayViewBox.h;
      applyInterplayViewBox();
    }, { passive: false });
  }

  function toggleInterplayFullscreen() {
    const workspace = document.getElementById("interplay-workspace");
    if (!workspace) return;
    if (document.fullscreenElement === workspace) {
      document.exitFullscreen && document.exitFullscreen();
    } else if (workspace.requestFullscreen) {
      workspace.requestFullscreen().catch(() => {});
    }
  }

  // Where the center→toward ray leaves a node's box, so links touch the border
  // instead of vanishing under the card.
  function interplayBoxExit(box, towardX, towardY) {
    const cx = box.x + box.width / 2;
    const cy = box.y + box.height / 2;
    const ex = towardX - cx;
    const ey = towardY - cy;
    if (ex === 0 && ey === 0) return { x: cx, y: cy };
    const halfW = box.width / 2 + 2;
    const halfH = box.height / 2 + 2;
    const scale = 1 / Math.max(Math.abs(ex) / halfW, Math.abs(ey) / halfH);
    return { x: cx + ex * scale, y: cy + ey * scale };
  }

  function interplayLinkPath(source, target) {
    const scx = source.x + source.width / 2;
    const scy = source.y + source.height / 2;
    const tcx = target.x + target.width / 2;
    const tcy = target.y + target.height / 2;
    const start = interplayBoxExit(source, tcx, tcy);
    const end = interplayBoxExit(target, scx, scy);
    const mx = (start.x + end.x) / 2;
    const my = (start.y + end.y) / 2;
    // Bow the link slightly perpendicular to its run so parallel edges fan apart.
    const nx = -(end.y - start.y);
    const ny = end.x - start.x;
    const nlen = Math.hypot(nx, ny) || 1;
    const bow = Math.min(26, nlen * 0.12);
    const cx = mx + (nx / nlen) * bow;
    const cy = my + (ny / nlen) * bow;
    return `M ${start.x.toFixed(1)} ${start.y.toFixed(1)} Q ${cx.toFixed(1)} ${cy.toFixed(1)} ${end.x.toFixed(1)} ${end.y.toFixed(1)}`;
  }

  function interplayKicker(node) {
    if (node.kind === "hub") return "HUB";
    if (node.kind === "seam") return "SEAM";
    if (node.kind === "endpoint") return node.protocol === "jsonrpc" ? "JSON-RPC" : "REST";
    if (node.kind === "subscriber") return "SUBSCRIBER";
    if (node.kind === "caller") return (componentLabel(node.component) || "CALLER").toUpperCase();
    if (node.kind === "owner") return (node.roles || []).join(" · ").toUpperCase() || "OWNER";
    return String(node.sub_kind || node.kind).replace(/_/g, " ").toUpperCase();
  }

  function interplayBusSubscriberCount(node) {
    return interplay.edges.filter((edge) => edge.source === node.id && edge.relation === "notifies").length;
  }

  function interplayNodeMeta(node) {
    if (node.kind === "owner") return componentLabel(node.component);
    if (node.kind === "seam") return "conformed by both transports";
    if (node.kind === "hub") return componentLabel(node.component);
    if (node.kind === "endpoint") {
      const noun = node.protocol === "jsonrpc" ? "method" : "route";
      return `${node.method_count} ${noun}${node.method_count === 1 ? "" : "s"}`;
    }
    if (node.kind === "subscriber") return "binds eventStream";
    if (node.kind === "caller") {
      const count = (node.namespaces || []).length;
      return `queries ${count} namespace${count === 1 ? "" : "s"}`;
    }
    if (node.sub_kind === "event_bus") return `fan-out · ${interplayBusSubscriberCount(node)} subscribers`;
    if (node.sub_kind === "stream_cursor") return `${node.owner_type} · SSE replay`;
    if (node.overlay_prose) return `${node.owner_type} · explained`;
    return node.owner_type || "";
  }

  function renderInterplayLegend() {
    const legend = document.getElementById("interplay-legend");
    if (!legend) return;
    const roles = Object.keys(INTERPLAY_ROLE_LABELS)
      .filter((role) => interplay.nodes.some((node) => interplayNodeRole(node) === role))
      .sort((left, right) => INTERPLAY_ROLE_RANK[left] - INTERPLAY_ROLE_RANK[right]);
    const items = roles.map((role) => {
      const item = element("div", "legend-item");
      const swatch = element("span", "legend-swatch");
      swatch.style.setProperty("--legend-color", INTERPLAY_ROLE_COLORS[role]);
      item.append(swatch, document.createTextNode(INTERPLAY_ROLE_LABELS[role]));
      return item;
    });
    // The three edge classes read differently in a free-form graph, so name them.
    const edgeClasses = [
      ["interplay", "var(--accent)", "Interplay wiring"],
      ["usage", "#7ec8b0", "Page invokes namespace"],
      ["lifecycle", "#55545a", "Lifecycle"],
      ["structure", "var(--line-strong)", "Structure"]
    ];
    edgeClasses.forEach(([klass, color, label]) => {
      if (!interplay.edges.some((edge) => edge.class === klass)) return;
      const item = element("div", "legend-item");
      const swatch = element("span", "legend-swatch");
      swatch.style.setProperty("--legend-color", color);
      item.append(swatch, document.createTextNode(label));
      items.push(item);
    });
    legend.replaceChildren(...items);
  }

  function selectInterplayNode(nodeId) {
    selectedInterplayId = nodeId;
    renderInterplayInspector(interplayNodeById.get(nodeId));
    applyInterplayState();
  }

  function applyInterplayState() {
    const input = document.getElementById("interplay-search");
    const query = input ? input.value.trim().toLowerCase() : "";
    const connected = new Set();
    if (selectedInterplayId) {
      connected.add(selectedInterplayId);
      interplay.edges.forEach((edge) => {
        if (edge.source === selectedInterplayId) connected.add(edge.target);
        if (edge.target === selectedInterplayId) connected.add(edge.source);
      });
    }
    document.querySelectorAll(".interplay-node").forEach((element) => {
      const node = interplayNodeById.get(element.dataset.node);
      if (!node) return;
      const searchable = [node.label, node.kind, node.sub_kind, node.owner_type, node.component, node.overlay_prose]
        .concat((node.methods || []).map((entry) => entry.method))
        .concat(node.namespaces || [])
        .filter(Boolean).join(" ").toLowerCase();
      const queryMismatch = query && !searchable.includes(query);
      const selectionMismatch = selectedInterplayId && !connected.has(node.id);
      element.classList.toggle("selected", node.id === selectedInterplayId);
      element.classList.toggle("dimmed", Boolean(queryMismatch || selectionMismatch));
    });
    document.querySelectorAll(".interplay-edge").forEach((edge) => {
      const active = selectedInterplayId &&
        (edge.dataset.source === selectedInterplayId || edge.dataset.target === selectedInterplayId);
      edge.classList.toggle("active", Boolean(active));
      edge.classList.toggle("dimmed", Boolean(selectedInterplayId && !active));
    });
  }

  function renderInterplayInspector(node) {
    const inspector = document.getElementById("interplay-inspector");
    if (!inspector || !node) return;
    const role = interplayNodeRole(node);
    const container = element("div");
    container.style.setProperty("--component-color", INTERPLAY_ROLE_COLORS[role] || INTERPLAY_ROLE_COLORS.other);

    const badge = element("span", "inspector-badge", interplayKicker(node));
    const heading = element("h3", "", node.label);
    container.append(badge, heading);

    const summary = element("p", "", interplayInspectorSummary(node));
    container.append(summary);

    const metrics = interplayInspectorMetrics(node);
    if (metrics.length) {
      const grid = element("div", "inspector-metrics");
      metrics.forEach(([value, label]) => {
        const cell = element("div", "inspector-metric");
        cell.append(element("strong", "", String(value)));
        cell.append(element("span", "", label));
        grid.append(cell);
      });
      container.append(grid);
    }

    if (node.overlay_prose) {
      const proseSection = element("section", "inspector-section");
      proseSection.append(element("h4", "", "Curated overlay"));
      proseSection.append(element("p", "", node.overlay_prose));
      container.append(proseSection);
    }

    if (node.kind === "endpoint" && Array.isArray(node.methods) && node.methods.length) {
      const methodsSection = element("section", "inspector-section");
      const noun = node.protocol === "jsonrpc" ? "Methods" : "Routes";
      methodsSection.append(element("h4", "", `${noun} (${node.methods.length})`));
      const list = element("ul", "evidence-list");
      node.methods
        .slice()
        .sort((left, right) => (left.line - right.line) || left.method.localeCompare(right.method))
        .forEach((entry) => {
          const li = document.createElement("li");
          const link = sourceLink({ path: node.path, line: entry.line });
          link.textContent = `${entry.method}  ·  :${entry.line}`;
          li.append(link);
          list.append(li);
        });
      methodsSection.append(list);
      container.append(methodsSection);
    }

    // Endpoints now record who queries them — the caller perspective the rollup
    // otherwise collapses. Each caller deep-links to its own declaration.
    if (node.kind === "endpoint") {
      const callers = interplay.edges
        .filter((edge) => edge.target === node.id && edge.relation === "invokes")
        .map((edge) => interplayNodeById.get(edge.source))
        .filter(Boolean)
        .sort((left, right) => left.label.localeCompare(right.label));
      if (callers.length) {
        const section = element("section", "inspector-section");
        section.append(element("h4", "", `Called by (${callers.length})`));
        const list = element("ul", "evidence-list");
        callers.forEach((caller) => {
          const li = document.createElement("li");
          const link = sourceLink({ path: caller.path, line: caller.line || 1 });
          link.textContent = `${caller.label}  ·  ${componentLabel(caller.component)}`;
          li.append(link);
          list.append(li);
        });
        section.append(list);
        container.append(section);
      }
    }

    if (node.kind === "caller" && Array.isArray(node.namespaces) && node.namespaces.length) {
      const section = element("section", "inspector-section");
      section.append(element("h4", "", `Invokes (${node.namespaces.length})`));
      const chips = element("div", "chip-list");
      node.namespaces.forEach((namespace) => chips.append(element("span", "chip", namespace)));
      section.append(chips);
      container.append(section);
    }

    const relations = interplay.edges.filter((edge) => edge.source === node.id || edge.target === node.id);
    if (relations.length) {
      const relSection = element("section", "inspector-section");
      relSection.append(element("h4", "", "Graph relations"));
      relations
        .slice()
        .sort((left, right) => left.class.localeCompare(right.class) || left.relation.localeCompare(right.relation))
        .forEach((edge) => {
          const otherId = edge.source === node.id ? edge.target : edge.source;
          const other = interplayNodeById.get(otherId);
          const row = element("div", "relationship");
          const direction = edge.source === node.id ? "→" : "←";
          row.append(element("strong", "", `${edge.relation} ${direction} ${other ? other.label : otherId}`));
          row.append(element("span", "", `${edge.class} edge`));
          relSection.append(row);
        });
      container.append(relSection);
    }

    if (node.path) {
      const evidenceSection = element("section", "inspector-section");
      evidenceSection.append(element("h4", "", "Source"));
      const list = element("ul", "evidence-list");
      const li = document.createElement("li");
      li.append(sourceLink({ path: node.path, line: node.line || 1 }));
      list.append(li);
      evidenceSection.append(list);
      container.append(evidenceSection);
    }

    inspector.replaceChildren(container);
  }

  // Compact headline numbers for the inspector metrics grid, per node kind.
  function interplayInspectorMetrics(node) {
    if (node.kind === "endpoint") {
      const callers = interplay.edges.filter((edge) => edge.target === node.id && edge.relation === "invokes").length;
      const noun = node.protocol === "jsonrpc" ? "Methods" : "Routes";
      return [[node.method_count, noun], [callers, "Callers"], [node.protocol === "jsonrpc" ? "JSON-RPC" : "REST", "Protocol"]];
    }
    if (node.kind === "caller") {
      return [[(node.namespaces || []).length, "Namespaces"], [componentLabel(node.component), "Surface"]];
    }
    if (node.sub_kind === "event_bus") return [[interplayBusSubscriberCount(node), "Subscribers"]];
    if (node.kind === "owner") return [[(node.roles || []).length, "Roles"]];
    return [];
  }

  function interplayInspectorSummary(node) {
    if (node.kind === "seam") return "The protocol both network transports conform to—the seam a hub binds to reach either backend.";
    if (node.kind === "hub") return `A construction that wires a network transport and an on-device engine together, owned by ${componentLabel(node.component)}.`;
    if (node.kind === "owner") return `A source owner type in ${componentLabel(node.component)} holding ${(node.roles || []).join(" and ")} resources.`;
    if (node.kind === "operation") {
      const detached = node.detached_off_main ? " Runs inside a Task.detached closure, off the owning actor." : "";
      return `A lifecycle operation on ${node.owner_type}.${detached}`;
    }
    if (node.kind === "endpoint") {
      const noun = node.protocol === "jsonrpc" ? "method" : "route";
      const kindLabel = node.protocol === "jsonrpc" ? "JSON-RPC namespace" : "REST endpoint group";
      return `The ${node.label} ${kindLabel} that ${node.owner_type} queries across ${node.method_count} ${noun}${node.method_count === 1 ? "" : "s"}. Each call correlates a request through the transport's in-flight pool.`;
    }
    if (node.kind === "subscriber") {
      return `${node.label} subscribes to the AgentBackend eventStream fan-out—the uncorrelated push leg, delivered independently of any request it made.`;
    }
    if (node.kind === "caller") {
      const namespaces = node.namespaces || [];
      return `A ${componentLabel(node.component)} surface that queries ${namespaces.length} namespace${namespaces.length === 1 ? "" : "s"}—${namespaces.join(", ")}—through the transport, resolved from its call sites. This is the caller perspective the transport's namespace rollup otherwise collapses.`;
    }
    if (node.sub_kind === "event_bus") {
      return `The Combine subject the backend seam publishes events onto—the uncorrelated push leg, fanned out to ${interplayBusSubscriberCount(node)} subscribers.`;
    }
    if (node.sub_kind === "stream_cursor") {
      return `The SSE replay cursor ${node.owner_type} carries so a dropped stream resumes from the last delivered event id.`;
    }
    return `A ${String(node.sub_kind || "").replace(/_/g, " ")} owned by ${node.owner_type}.`;
  }

  function sourceLink(evidence) {
    const link = document.createElement("a");
    link.className = "source-link";
    link.href = `${repositoryBase}${evidence.path}#L${evidence.line}`;
    link.target = "_blank";
    link.rel = "noreferrer";
    link.textContent = `${evidence.path}:${evidence.line}`;
    return link;
  }

  function emptyState(message) {
    return element("p", "empty-state", message);
  }

  function recordRow(record, details = []) {
    const row = element("article", "behavior-row");
    const heading = element("h4", "", record.label || record.kind || "Observed item");
    const metadata = element("p", "behavior-meta");
    const values = [record.kind, ...details, record.rule_id].filter(Boolean);
    metadata.textContent = values.join(" · ");
    row.append(heading, metadata);
    if (record.evidence) {
      const provenance = element("p", "provenance");
      provenance.append(element("span", "", "Static source · "), sourceLink(record.evidence));
      row.append(provenance);
    }
    return row;
  }

  function behaviorGroup(title, subtitle = "") {
    const section = element("section", "behavior-group");
    section.append(element("h3", "", title));
    if (subtitle) section.append(element("p", "group-note", subtitle));
    return section;
  }

  function renderExecution() {
    const container = document.getElementById("execution-content");
    const records = [
      ...executionDomains.map((item) => ({ ...item, displayClass: "Execution domain" })),
      ...taskSites.map((item) => ({ ...item, displayClass: "Task evidence" }))
    ].sort((left, right) =>
      String(left.component || "").localeCompare(String(right.component || "")) || sourceSort(left, right)
    );
    if (!records.length) {
      container.replaceChildren(emptyState("No execution domains or task sites matched the deterministic rules."));
      return;
    }
    const grouped = new Map();
    records.forEach((record) => {
      const key = record.component || "unassigned";
      if (!grouped.has(key)) grouped.set(key, []);
      grouped.get(key).push(record);
    });
    const sections = [...grouped.entries()].map(([componentId, items]) => {
      const section = behaviorGroup(componentLabel(componentId));
      const list = element("div", "behavior-list");
      items.forEach((item) => {
        const context = [
          item.displayClass,
          item.enclosing_type && `type ${item.enclosing_type}`,
          item.enclosing_function && `function ${item.enclosing_function}`,
          item.kind === "task_cancellation" && "cancellation evidence"
        ].filter(Boolean);
        list.append(recordRow(item, context));
      });
      section.append(list);
      return section;
    });
    container.replaceChildren(...sections);
  }

  function renderConnections() {
    const container = document.getElementById("connections-content");
    const resourceById = new Map(resources.map((item) => [item.id, item]));
    const taskById = new Map(taskSites.map((item) => [item.id, item]));
    const operationById = new Map(operations.map((item) => [item.id, item]));
    const orderedPockets = [...pockets].sort((left, right) =>
      String(left.component || "").localeCompare(String(right.component || "")) ||
      String(left.owner_type || "").localeCompare(String(right.owner_type || "")) ||
      String(left.id || "").localeCompare(String(right.id || ""))
    );
    if (!orderedPockets.length) {
      container.replaceChildren(emptyState("No static connection or stream pockets matched the deterministic rules."));
      return;
    }
    const cards = orderedPockets.map((pocket) => {
      const card = behaviorGroup(
        pocket.owner_type || componentLabel(pocket.component),
        `${componentLabel(pocket.component)} · ${pocket.confidence || "mechanically grouped"}`
      );
      card.append(element("p", "derivation", pocket.derivation || "Static source grouping."));
      const ownedResources = (pocket.resource_ids || []).map((id) => resourceById.get(id)).filter(Boolean).sort(sourceSort);
      const handles = (pocket.task_handle_ids || []).map((id) => taskById.get(id)).filter(Boolean).sort(sourceSort);
      const lifecycle = (pocket.operation_ids || []).map((id) => operationById.get(id)).filter(Boolean).sort(sourceSort);
      const collections = [
        ["Owned resources", ownedResources, (item) => [item.cardinality]],
        ["Stored task handles", handles, (item) => [item.enclosing_type && `type ${item.enclosing_type}`]],
        ["Lifecycle operations", lifecycle, (item) => [item.resource_label && `resource ${item.resource_label}`]]
      ];
      collections.forEach(([title, items, details]) => {
        const block = element("section", "pocket-section");
        block.append(element("h4", "", `${title} (${items.length})`));
        if (items.length) items.forEach((item) => block.append(recordRow(item, details(item))));
        else block.append(emptyState("None observed."));
        card.append(block);
      });
      return card;
    });
    container.replaceChildren(...cards);
  }

  function renderScenarios() {
    const container = document.getElementById("scenarios-content");
    const operationById = new Map(operations.map((item) => [item.id, item]));
    const orderedScenarios = [...scenarios].sort((left, right) =>
      String(left.component || "").localeCompare(String(right.component || "")) ||
      String(left.owner_type || "").localeCompare(String(right.owner_type || "")) ||
      String(left.id || "").localeCompare(String(right.id || ""))
    );
    if (!orderedScenarios.length) {
      container.replaceChildren(emptyState("No source-ordered lifecycle scenarios were derived."));
      return;
    }
    const cards = orderedScenarios.map((scenario) => {
      const card = behaviorGroup(
        scenario.owner_type || componentLabel(scenario.component),
        componentLabel(scenario.component)
      );
      card.append(element("p", "derivation", scenario.derivation || "Source-ordered static evidence."));
      const sequence = element("ol", "scenario-sequence");
      (scenario.operation_ids || []).map((id) => operationById.get(id)).filter(Boolean).forEach((operation) => {
        const item = document.createElement("li");
        item.append(recordRow(operation, [operation.resource_label && `resource ${operation.resource_label}`]));
        sequence.append(item);
      });
      if (sequence.children.length) card.append(sequence);
      else card.append(emptyState("No linked operations remain in this scenario."));
      return card;
    });
    container.replaceChildren(...cards);
  }

  function renderSpecifications() {
    const list = document.getElementById("spec-list");
    list.replaceChildren(...specifications.map((specification, index) => {
      const button = element("button", `document-link${index === 0 ? " active" : ""}`, specification.title);
      button.type = "button";
      button.dataset.specification = specification.id;
      button.addEventListener("click", () => showSpecification(specification.id));
      return button;
    }));
    if (specifications.length) showSpecification(specifications[0].id);
  }

  function showSpecification(specificationId) {
    const specification = specifications.find((item) => item.id === specificationId);
    if (!specification) return;
    document.querySelectorAll(".document-link").forEach((button) => {
      button.classList.toggle("active", button.dataset.specification === specificationId);
    });
    const documentElement = document.getElementById("spec-document");
    documentElement.innerHTML = `<div class="authority-note">Specified · reviewed through pull requests · ${escapeHTML(specification.path)}</div>${markdownToHTML(specification.markdown)}`;
  }

  function markdownToHTML(markdown) {
    const lines = markdown.split("\n");
    const output = [];
    let listType = null;

    const closeList = () => {
      if (listType) output.push(`</${listType}>`);
      listType = null;
    };

    lines.forEach((rawLine) => {
      const line = rawLine.trimEnd();
      const heading = /^(#{1,3})\s+(.+)$/.exec(line);
      const unordered = /^[-*]\s+(.+)$/.exec(line);
      const ordered = /^\d+\.\s+(.+)$/.exec(line);
      if (heading) {
        closeList();
        const level = heading[1].length;
        output.push(`<h${level}>${inlineMarkdown(heading[2])}</h${level}>`);
      } else if (unordered || ordered) {
        const targetType = unordered ? "ul" : "ol";
        if (listType !== targetType) {
          closeList();
          output.push(`<${targetType}>`);
          listType = targetType;
        }
        output.push(`<li>${inlineMarkdown((unordered || ordered)[1])}</li>`);
      } else if (!line.trim()) {
        closeList();
      } else {
        closeList();
        output.push(`<p>${inlineMarkdown(line)}</p>`);
      }
    });
    closeList();
    return output.join("\n");
  }

  function inlineMarkdown(value) {
    return escapeHTML(value)
      .replace(/`([^`]+)`/g, "<code>$1</code>")
      .replace(/\*\*([^*]+)\*\*/g, "<strong>$1</strong>");
  }

  function renderInventory(query = "") {
    const normalized = query.trim().toLowerCase();
    const body = document.getElementById("inventory-body");
    const rows = model.components.filter((component) => {
      if (component.external) return false;
      if (!normalized) return true;
      return [component.label, component.layer, ...component.files, ...component.declarations]
        .join(" ").toLowerCase().includes(normalized);
    }).map((component) => {
      const row = document.createElement("tr");
      row.tabIndex = 0;
      row.addEventListener("click", () => openComponentFromInventory(component.id));
      row.addEventListener("keydown", (event) => {
        if (event.key === "Enter") openComponentFromInventory(component.id);
      });
      const name = element("td", "component-name", component.label);
      const layer = element("td", "layer-pill", layerById.get(component.layer).label);
      layer.style.setProperty("--layer-color", layerColors[component.layer]);
      row.append(
        name,
        layer,
        element("td", "", component.file_count.toLocaleString()),
        element("td", "", component.line_count.toLocaleString()),
        element("td", "", component.declaration_count.toLocaleString())
      );
      return row;
    });
    body.replaceChildren(...rows);
  }

  function openComponentFromInventory(componentId) {
    activateView("graph");
    selectComponent(componentId);
    const node = document.querySelector(`[data-component="${CSS.escape(componentId)}"]`);
    node?.focus();
  }

  function wireNavigation() {
    document.querySelectorAll(".nav-item").forEach((button) => {
      button.addEventListener("click", () => activateView(button.dataset.view));
    });
  }

  function activateView(viewName) {
    document.querySelectorAll(".nav-item").forEach((button) => {
      button.classList.toggle("active", button.dataset.view === viewName);
    });
    document.querySelectorAll(".view").forEach((view) => view.classList.remove("active"));
    document.getElementById(`${viewName}-view`).classList.add("active");
  }

  function wireControls() {
    document.getElementById("graph-search").addEventListener("input", applyGraphState);
    document.getElementById("edge-mode").addEventListener("change", renderGraph);
    document.getElementById("reset-graph").addEventListener("click", () => {
      selectedComponentId = null;
      document.getElementById("graph-search").value = "";
      document.getElementById("inspector").innerHTML = '<div class="inspector-empty"><span class="inspector-index">01</span><h3>Select a component</h3><p>Inspect responsibility, source ownership, declarations, relationships, and evidence.</p></div>';
      applyGraphState();
    });
    document.getElementById("inventory-search").addEventListener("input", (event) => renderInventory(event.target.value));
    const interplaySearch = document.getElementById("interplay-search");
    if (interplaySearch) interplaySearch.addEventListener("input", applyInterplayState);
    const resetInterplay = document.getElementById("reset-interplay");
    if (resetInterplay) {
      resetInterplay.addEventListener("click", () => {
        selectedInterplayId = null;
        if (interplaySearch) interplaySearch.value = "";
        const inspector = document.getElementById("interplay-inspector");
        if (inspector) {
          const empty = element("div", "inspector-empty");
          empty.append(element("span", "inspector-index", "◇"));
          empty.append(element("h3", "", "Select a node"));
          empty.append(element("p", "", "Inspect a connection pool, an on-device engine, the AgentBackend seam, or the hub that wires them—with its curated prose and exact source line."));
          inspector.replaceChildren(empty);
        }
        fitInterplayView(); // reset the pan/zoom window back to the whole graph too
        applyInterplayState();
      });
    }
    const interplayFullscreen = document.getElementById("interplay-fullscreen");
    if (interplayFullscreen) interplayFullscreen.addEventListener("click", toggleInterplayFullscreen);
    // Re-fit when entering/leaving fullscreen so the graph fills the new frame.
    document.addEventListener("fullscreenchange", () => {
      const workspace = document.getElementById("interplay-workspace");
      if (!workspace) return;
      workspace.classList.toggle("is-fullscreen", document.fullscreenElement === workspace);
      requestAnimationFrame(fitInterplayView);
    });
  }

  function element(tag, className = "", text = "") {
    const node = document.createElement(tag);
    if (className) node.className = className;
    if (text !== "") node.textContent = text;
    return node;
  }

  function svgElement(tag, attributes) {
    const node = document.createElementNS("http://www.w3.org/2000/svg", tag);
    Object.entries(attributes).forEach(([key, value]) => node.setAttribute(key, String(value)));
    return node;
  }

  function escapeHTML(value) {
    return String(value).replace(/[&<>"]/g, (character) => ({
      "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;"
    })[character]);
  }
})();
