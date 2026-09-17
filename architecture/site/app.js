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
  // Declared before the render sequence below so renderInterplay() (called in
  // init) can close over them without hitting the const temporal dead zone.
  const INTERPLAY_ROLE_COLORS = {
    hub: "#8b83ff",
    seam: "#a58bff",
    transport: "#5ca8d8",
    endpoint: "#e7a84b",
    engine: "#70b98d",
    subscriber: "#d16f86",
    other: "#6d6a68"
  };
  const INTERPLAY_ROLE_LABELS = {
    hub: "Interplay hub",
    seam: "Backend seam",
    transport: "Connection-pool transport",
    endpoint: "Queried endpoints",
    engine: "On-device engine",
    subscriber: "Event subscribers",
    other: "Supporting owner"
  };
  const INTERPLAY_ROLE_RANK = { hub: 0, seam: 1, transport: 2, endpoint: 3, engine: 4, subscriber: 5, other: 6 };
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

  function interplayClusterRole(cluster) {
    const nodes = cluster.node_ids.map((id) => interplayNodeById.get(id)).filter(Boolean);
    if (nodes.some((node) => node.kind === "hub")) return "hub";
    if (nodes.some((node) => node.kind === "seam")) return "seam";
    if (nodes.length && nodes.every((node) => node.kind === "endpoint")) return "endpoint";
    if (nodes.some((node) => node.kind === "subscriber")) return "subscriber";
    const owner = nodes.find((node) => node.kind === "owner");
    if (owner && (owner.roles || []).includes("transport")) return "transport";
    if (owner && (owner.roles || []).includes("engine")) return "engine";
    return "other";
  }

  function interplayNodeSize(node) {
    if (node.kind === "operation") return { width: 176, height: 40 };
    if (node.kind === "resource") return { width: 190, height: 50 };
    return { width: 200, height: 60 };
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
    const columns = interplay.clusters
      .map((cluster) => ({ cluster, role: interplayClusterRole(cluster) }))
      .sort((left, right) =>
        (INTERPLAY_ROLE_RANK[left.role] - INTERPLAY_ROLE_RANK[right.role]) ||
        left.cluster.id.localeCompare(right.cluster.id));

    const marginX = 28;
    const marginY = 64;
    const stdColumnWidth = 210;
    const columnGap = 56;
    const nodeGap = 18;
    // A transport can be queried on dozens of RPC namespaces / REST endpoints, so
    // those columns tile their nodes into a compact grid instead of one tall stack.
    const endpointCell = { width: 150, height: 46 };
    const endpointColGap = 14;
    let maxHeight = marginY;

    // First pass: lay out each column's nodes relative to the column's own origin
    // and record the column's intrinsic width/height.
    const laidColumns = columns.map((column) => {
      const nodes = column.cluster.node_ids
        .map((id) => interplayNodeById.get(id))
        .filter(Boolean)
        .sort((left, right) =>
          (INTERPLAY_KIND_RANK[left.kind] - INTERPLAY_KIND_RANK[right.kind]) ||
          ((left.line || 0) - (right.line || 0)) ||
          left.id.localeCompare(right.id));

      if (column.role === "endpoint") {
        const gridCols = Math.max(1, Math.ceil(nodes.length / 9));
        const placements = nodes.map((node, index) => ({
          node,
          x: (index % gridCols) * (endpointCell.width + endpointColGap),
          y: marginY + Math.floor(index / gridCols) * (endpointCell.height + nodeGap),
          width: endpointCell.width,
          height: endpointCell.height
        }));
        const width = gridCols * endpointCell.width + (gridCols - 1) * endpointColGap;
        const height = placements.reduce((max, p) => Math.max(max, p.y + p.height), marginY);
        return { column, placements, width, height };
      }

      let y = marginY;
      const placements = nodes.map((node) => {
        const size = interplayNodeSize(node);
        const placement = { node, x: 0, y, width: size.width, height: size.height };
        y += size.height + nodeGap;
        return placement;
      });
      return { column, placements, width: stdColumnWidth, height: y };
    });

    // Second pass: flow the columns left-to-right, resolving each node to an
    // absolute position the edge router and node renderer share.
    let cursorX = marginX;
    laidColumns.forEach((laid) => {
      laid.x = cursorX;
      laid.placements.forEach((placement) => {
        interplayPositions.set(placement.node.id, {
          x: cursorX + placement.x,
          y: placement.y,
          width: placement.width,
          height: placement.height
        });
        nodeRole.set(placement.node.id, laid.column.role);
      });
      cursorX += laid.width + columnGap;
      maxHeight = Math.max(maxHeight, laid.height);
    });

    const width = cursorX - columnGap + marginX;
    const height = Math.max(360, maxHeight + 24);
    svg.setAttribute("viewBox", `0 0 ${width} ${height}`);
    svg.style.minWidth = `${Math.max(width, 900)}px`;

    laidColumns.forEach((laid) => {
      const label = svgElement("text", { x: laid.x, y: 32, class: "graph-layer-label" });
      label.textContent = INTERPLAY_ROLE_LABELS[laid.column.role].toUpperCase();
      svg.append(label);
    });

    const edgeGroup = svgElement("g", { class: "edges" });
    interplay.edges.forEach((edge) => {
      const source = interplayPositions.get(edge.source);
      const target = interplayPositions.get(edge.target);
      if (!source || !target) return;
      const anchors = interplayEdgeAnchors(source, target);
      const path = svgElement("path", {
        d: `M ${anchors.sx} ${anchors.sy} C ${anchors.c1x} ${anchors.c1y}, ${anchors.c2x} ${anchors.c2y}, ${anchors.tx} ${anchors.ty}`,
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
      const compact = node.kind === "endpoint";
      const rect = svgElement("rect", { width: position.width, height: position.height, rx: 5 });
      if (node.kind === "operation") rect.setAttribute("class", "operation");
      else if (compact) rect.setAttribute("class", "endpoint");
      if (node.overlay_prose) rect.setAttribute("data-explained", "true");
      group.append(rect);
      group.append(svgElement("line", { x1: 0, x2: 0, y1: 6, y2: position.height - 6, class: "node-rule" }));
      const kicker = svgElement("text", { x: compact ? 11 : 13, y: compact ? 15 : 18, class: "node-kicker" });
      kicker.textContent = interplayKicker(node);
      const title = svgElement("text", {
        x: compact ? 11 : 13,
        y: node.kind === "operation" ? 30 : (compact ? 29 : 37),
        class: "node-title"
      });
      title.textContent = node.label;
      group.append(kicker, title);
      if (node.kind !== "operation") {
        const meta = svgElement("text", { x: compact ? 11 : 13, y: compact ? 41 : 52, class: "node-meta" });
        meta.textContent = interplayNodeMeta(node);
        group.append(meta);
      }
      group.addEventListener("click", () => selectInterplayNode(node.id));
      group.addEventListener("keydown", (event) => {
        if (event.key === "Enter" || event.key === " ") {
          event.preventDefault();
          selectInterplayNode(node.id);
        }
      });
      nodeGroup.append(group);
    });
    svg.append(nodeGroup);

    renderInterplayLegend(columns);
    applyInterplayState();
    if (selectedInterplayId) renderInterplayInspector(interplayNodeById.get(selectedInterplayId));
  }

  function interplayEdgeAnchors(source, target) {
    const sourceMidY = source.y + source.height / 2;
    const targetMidY = target.y + target.height / 2;
    if (target.x > source.x) {
      const sx = source.x + source.width;
      const tx = target.x;
      const bend = Math.max(30, (tx - sx) * 0.45);
      return { sx, sy: sourceMidY, tx, ty: targetMidY, c1x: sx + bend, c1y: sourceMidY, c2x: tx - bend, c2y: targetMidY };
    }
    if (target.x < source.x) {
      const sx = source.x;
      const tx = target.x + target.width;
      const bend = Math.max(30, (sx - tx) * 0.45);
      return { sx, sy: sourceMidY, tx, ty: targetMidY, c1x: sx - bend, c1y: sourceMidY, c2x: tx + bend, c2y: targetMidY };
    }
    const sx = source.x + source.width / 2;
    const tx = target.x + target.width / 2;
    const sy = source.y + source.height;
    const ty = target.y;
    const bend = Math.max(20, (ty - sy) * 0.5);
    return { sx, sy, tx, ty, c1x: sx, c1y: sy + bend, c2x: tx, c2y: ty - bend };
  }

  function interplayKicker(node) {
    if (node.kind === "hub") return "HUB";
    if (node.kind === "seam") return "SEAM";
    if (node.kind === "endpoint") return node.protocol === "jsonrpc" ? "JSON-RPC" : "REST";
    if (node.kind === "subscriber") return "SUBSCRIBER";
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
    if (node.sub_kind === "event_bus") return `fan-out · ${interplayBusSubscriberCount(node)} subscribers`;
    if (node.sub_kind === "stream_cursor") return `${node.owner_type} · SSE replay`;
    if (node.overlay_prose) return `${node.owner_type} · explained`;
    return node.owner_type || "";
  }

  function renderInterplayLegend(columns) {
    const legend = document.getElementById("interplay-legend");
    if (!legend) return;
    const seen = [];
    columns.forEach((column) => {
      if (!seen.includes(column.role)) seen.push(column.role);
    });
    legend.replaceChildren(...seen.map((role) => {
      const item = element("div", "legend-item");
      const swatch = element("span", "legend-swatch");
      swatch.style.setProperty("--legend-color", INTERPLAY_ROLE_COLORS[role]);
      item.append(swatch, document.createTextNode(INTERPLAY_ROLE_LABELS[role]));
      return item;
    }));
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
    const role = node.kind === "owner"
      ? ((node.roles || []).includes("engine") ? "engine" : (node.roles || []).includes("transport") ? "transport" : "other")
      : node.kind;
    const container = element("div");
    container.style.setProperty("--component-color", INTERPLAY_ROLE_COLORS[role] || INTERPLAY_ROLE_COLORS.other);

    const badge = element("span", "inspector-badge", interplayKicker(node));
    const heading = element("h3", "", node.label);
    container.append(badge, heading);

    const summary = element("p", "", interplayInspectorSummary(node));
    container.append(summary);

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
        applyInterplayState();
      });
    }
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
