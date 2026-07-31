(() => {
  "use strict";

  const payload = window.PORTAL_ARCHITECTURE;
  if (!payload || !payload.model) {
    document.body.innerHTML = '<main class="view active"><h1>Architecture data is unavailable.</h1><p>Run <code>make architecture</code>.</p></main>';
    return;
  }

  const model = payload.model;
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

  document.getElementById("source-hash").textContent = model.source_tree_sha256.slice(0, 9);
  renderStats();
  renderLegend();
  renderGraph();
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
