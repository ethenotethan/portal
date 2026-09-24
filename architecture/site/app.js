(() => {
  "use strict";

  const payload = window.PORTAL_ARCHITECTURE;
  if (!payload || !payload.model) {
    document.body.innerHTML = '<main class="view active"><h1>Architecture data is unavailable.</h1><p>Run <code>make architecture</code>.</p></main>';
    return;
  }

  const model = payload.model;
  const behavior = model.behavior || {};
  const taskSites = behavior.task_sites || [];
  const resources = behavior.resources || [];
  const operations = behavior.operations || [];
  const pockets = behavior.pockets || [];
  const interplay = model.interplay || { nodes: [], edges: [], clusters: [] };
  const ci = model.ci || { workflows: [], jobs: [], edges: [], triggers: [], merge: { inputs: [] }, ratchets: [], architectural: { lint_rules: [], tests: [], invariants: [], runs_in: [] }, static_checks: [], summary: {} };
  // CI gate tables live up here too: renderGates() runs during init.
  const GATE_FAMILY_COLORS = {
    behavior: "#70b98d", posture: "#e7a84b", build: "#5ca8d8", publication: "#8b83ff",
    release: "#d16f86", maintenance: "#8d8a88", trigger: "#8b83ff", merge: "#70b98d"
  };
  const GATE_FAMILY_LABELS = {
    behavior: "Tests · does it work?", posture: "Ratchet · did a metric get worse?", build: "Build · does it build?",
    publication: "Pages · do generated artifacts match?", release: "Release · after merge", maintenance: "Maintenance · by hand"
  };
  const GATE_FAMILY_ORDER = ["behavior", "posture", "build", "publication", "release", "maintenance"];
  const GATE = { nodeW: 200, nodeH: 56, colGap: 84, rowGap: 16, lanePadX: 22, lanePadY: 18, laneHead: 34, laneGap: 22, triggerW: 154, mergeW: 118 };
  const gateJobById = new Map(ci.jobs.map((job) => [job.id, job]));
  const gateWorkflowById = new Map(ci.workflows.map((workflow) => [workflow.id, workflow]));
  let selectedGateId = null;
  let gateLayout = null;
  // The transport is one in-memory construction with two legs: the request leg
  // (the transport core with its pool, lock and socket) and the push leg (the
  // event stream). It is drawn as a container holding both; the core is collapsed
  // by default and expands on click to show what it owns.
  const TRANSPORT_NODE_ID = "transport:core";
  (() => {
    const core = interplay.nodes.find((node) => node.kind === "owner" && (node.roles || []).includes("transport"));
    const bus = interplay.nodes.find((node) => node.kind === "resource" && node.sub_kind === "event_bus");
    if (core && bus && !interplay.nodes.some((node) => node.id === TRANSPORT_NODE_ID)) {
      interplay.nodes.push({
        id: TRANSPORT_NODE_ID, kind: "transport", label: "Transport", component: core.component,
        owner_type: null, page: "shared", core_id: core.id, bus_id: bus.id, path: core.path, line: core.line
      });
    }
  })();
  // ---- History: the same map at every commit (opt-in artifact) -------------
  // history.js is written by scripts/build_architecture_history.py: today's
  // extractor run at every first-parent commit that touched the app source, delta-
  // encoded. Without it (or with fewer than two points) this page is the map of one
  // revision. With it, nodes and edges some past commit had and the head does not
  // are folded into the drawn set flagged `hist`, so one layout serves every slider
  // position and nothing reshuffles mid-slide. Until the reader touches the slider
  // those historical-only entities are drawn absent: the page a reader lands on is
  // identical whether or not a history was built beside it.
  const HISTORY = (() => {
    const raw = window.PORTAL_ARCHITECTURE_HISTORY;
    const usable = raw && Array.isArray(raw.snapshots) && raw.snapshots.length >= 2 &&
      Array.isArray(raw.nodes) && Array.isArray(raw.edges);
    return usable ? raw : null;
  })();
  // The compiler keys every node for diffing across commits (ids hash the declaring
  // line for resources; the key does not). Trigger edges key by page id.
  const historyKeyOf = (node) => (node && (node.history_key || node.id)) || "";
  const headNodeById = new Map(interplay.nodes.map((node) => [node.id, node]));
  const edgeHistoryKey = (edge, byId) => `${historyKeyOf(byId.get(edge.source))}|${historyKeyOf(byId.get(edge.target))}|${edge.relation}`;
  const headEdgeKeys = new Set(interplay.edges.map((edge) => edgeHistoryKey(edge, headNodeById)));
  const drawNodes = interplay.nodes.slice();
  const drawEdges = interplay.edges.slice();
  const idByHistoryKey = new Map(interplay.nodes.map((node) => [historyKeyOf(node), node.id]));
  if (HISTORY) {
    HISTORY.nodes.forEach((meta) => {
      if (meta.kind === "page" || idByHistoryKey.has(meta.k)) return;
      const node = { ...meta, id: meta.k, history_key: meta.k, hist: true, path: null, line: 0 };
      delete node.k;
      drawNodes.push(node);
      idByHistoryKey.set(meta.k, node.id);
    });
    HISTORY.edges.forEach(([sourceIndex, targetIndex, relation, klass]) => {
      const source = HISTORY.nodes[sourceIndex];
      const target = HISTORY.nodes[targetIndex];
      if (!source || !target || relation === "triggers") return; // trigger edges are aggregated at draw time
      if (headEdgeKeys.has(`${source.k}|${target.k}|${relation}`)) return;
      if (!idByHistoryKey.has(source.k) || !idByHistoryKey.has(target.k)) return;
      drawEdges.push({ source: idByHistoryKey.get(source.k), target: idByHistoryKey.get(target.k), relation, class: klass, hist: true });
    });
  }
  const interplayNodeById = new Map(drawNodes.map((node) => [node.id, node]));
  // The reader's position, replayed rather than looked up: one mutable set of live
  // node keys and edge keys, stepped forward by a point's additions and removals or
  // backward by undoing them. Removals apply before additions in both directions.
  // Inert until touched: loading the page draws the head revision; the first drag or
  // play engages it, and from then on the point governs the picture.
  const TL = (() => {
    if (!HISTORY) return null;
    const P = HISTORY.snapshots;
    const N = HISTORY.nodes;
    const E = HISTORY.edges;
    const ekey = (index) => { const e = E[index]; return `${N[e[0]].k}|${N[e[1]].k}|${e[2]}`; };
    const nodes = new Set();
    const edges = new Set();
    let i = -1;
    let engaged = false;
    const fwd = (p) => {
      (p.nd || []).forEach((x) => nodes.delete(N[x].k)); (p.ed || []).forEach((x) => edges.delete(ekey(x)));
      (p.na || []).forEach((x) => nodes.add(N[x].k)); (p.ea || []).forEach((x) => edges.add(ekey(x)));
    };
    const back = (p) => {
      (p.na || []).forEach((x) => nodes.delete(N[x].k)); (p.ea || []).forEach((x) => edges.delete(ekey(x)));
      (p.nd || []).forEach((x) => nodes.add(N[x].k)); (p.ed || []).forEach((x) => edges.add(ekey(x)));
    };
    // What this commit took away, kept apart: the picture ghosts it, which is the
    // difference between "this is not here" and "this commit removed this".
    let goneAt = -1;
    let goneNodes = new Set();
    let goneEdges = new Set();
    const ghosts = () => {
      if (goneAt === i) return;
      goneAt = i;
      const p = P[i];
      goneNodes = new Set((p.nd || []).map((x) => N[x].k));
      goneEdges = new Set((p.ed || []).map(ekey));
    };
    return {
      count: P.length,
      last: P.length - 1,
      failed: (HISTORY.failed || []).length,
      get i() { return i; },
      get engaged() { return engaged; },
      point: () => P[i] || P[P.length - 1],
      prev: () => P[i - 1] || null,
      live: (key) => nodes.has(key),
      liveEdge: (key) => edges.has(key),
      gone: (key) => (ghosts(), goneNodes.has(key)),
      goneEdge: (key) => (ghosts(), goneEdges.has(key)),
      added: () => (P[i].na || []).map((x) => N[x]),
      removed: () => (P[i].nd || []).map((x) => N[x]),
      edgeDelta: () => ({ added: (P[i].ea || []).length, removed: (P[i].ed || []).length }),
      go(n, byReader) {
        if (byReader) engaged = true;
        n = Math.max(0, Math.min(P.length - 1, n | 0));
        while (i < n) fwd(P[++i]);
        while (i > n) back(P[i--]);
        return i;
      },
      disengage() { engaged = false; this.go(P.length - 1); }
    };
  })();
  if (TL) TL.go(TL.last);
  const expandedOwners = new Set(); // owners whose pool/lock/socket/sections are shown
  // A resource/operation inherits its colour from the owning type's role, so the
  // free-form graph still reads as "this pool belongs to a transport" without any
  // column to say so.
  const interplayRoleByOwnerType = new Map();
  interplay.nodes.forEach((node) => {
    if (node.kind !== "owner") return;
    const roles = node.roles || [];
    interplayRoleByOwnerType.set(
      node.label,
      roles.includes("engine") ? "engine" : roles.includes("transport") ? "transport" : roles.includes("pool") ? "pool" : "other"
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
    provider: "#d0b36b",
    machine: "#b48ad6",
    client: "#8fb3d9",
    section: "#d3a83a",
    store: "#c9a3d9",
    pool: "#7fa7c9",
    external: "#e0704f",
    other: "#6d6a68"
  };
  const INTERPLAY_ROLE_LABELS = {
    hub: "Interplay hub",
    seam: "Backend seam",
    transport: "Connection-pool transport",
    caller: "Calling surface",
    provider: "Config provider (constructed at launch)",
    machine: "State machine (enum-typed lifecycle state)",
    endpoint: "Queried endpoints",
    engine: "On-device engine",
    subscriber: "Event subscribers",
    client: "Client extension file",
    section: "Critical section (lock-guarded steps)",
    store: "Data store",
    pool: "Continuation-pool owner",
    external: "External system",
    other: "Supporting owner"
  };
  const INTERPLAY_ROLE_RANK = { hub: 0, seam: 1, transport: 2, pool: 3, section: 4, caller: 5, provider: 5.5, machine: 5.7, endpoint: 6, client: 7, engine: 8, store: 9, external: 10, subscriber: 11, other: 12 };
  // Zones inside the application hull are the app's navigation pages, declared
  // in architecture/config.json with their root views; the compiler tags each
  // type-labelled node with the page whose view tree reaches it.
  const interplayPages = interplay.pages || [];
  const PAGE_LABEL = new Map(interplayPages.map((page) => [page.id, page.label]));
  const PAGE_RANK = new Map(interplayPages.map((page, index) => [page.label, index]));
  const triggers = interplay.triggers || []; // read during init by drawTriggerEdges
  // Invariant tables live up here, beside the page tables, so renderInvariants()
  // (called during init) reads them outside the temporal dead zone.
  const invariants = interplay.invariants || [];
  const INVARIANT_KIND_TEXT = {
    single_transport: "Exactly the declared transport owners conform to the backend seam.",
    surfaces_hold_transport: "Every calling surface holds a reference to the core (or the seam), so all pages compete for the same pool and socket.",
    pool_guarded_by_lock: "Every pool mutation happens under the lock; continuations resume and frames are written outside it.",
    pool_lifecycle_observed: "The register, resolve and remove rules still match the source, so the pool cannot silently look idle.",
    operations_resolve_scope: "Every extracted operation resolves to an enclosing function, so critical sections lose no steps.",
    endpoints_dispatched_by_transport: "Every namespace box is dispatched by a transport core.",
    pages_populated: "Every declared navigation page owns at least one construct.",
    stores_mapped: "Every store the extractor recognises appears on the map, so the Data stores view and the System map cannot disagree.",
    triggers_observed: "Every page's views drive at least one surface through an observed action or lifecycle hook, and enough triggers are attributed for the first hop to be trusted.",
    launch_zoned: "The App entry points construct the objects that exist before any page; a store read only at launch sits in the App launch zone, and the declared provider configures the transport core.",
    flows_traceable: "Every declared system flow is a path over edges the map draws; a step whose edge disappeared, or fewer flows than declared, fails the build until the flow is updated.",
    machines_complete: "Every state machine's states match what is declared and every state is entered by some transition; a new, renamed or orphaned state changes the construction and must be declared."
  };

  const INTERPLAY_SHARED_GROUP = "Shared core";
  // Declared external systems (config-specified, source-attributed) sit in their
  // own hull beneath the shared core; endpoint boxes hang off the gateway there.
  const INTERPLAY_EXTERNAL_GROUP = "External systems";
  // The application boundary: one hull around every code group (feature modules
  // and the shared core). External systems sit outside it.
  const INTERPLAY_APP_GROUP = `${(model.repository || "portal").split("/").pop()} application`;
  // Live objects holding process-lifetime state (the transport core with its pool,
  // lock and socket; engines no single page owns) are in-memory constructions,
  // not shared code. They get their own hull inside the application boundary.
  const INTERPLAY_MEMORY_GROUP = "In-memory constructions";
  const INTERPLAY_KIND_RANK = { hub: 0, seam: 0, owner: 0, external: 0, client: 0, store: 0, provider: 0, machine: 1, resource: 1, endpoint: 1, subscriber: 1, section: 1, operation: 2 };
  const externals = model.externals || { systems: [], edges: [] };
  const stores = model.stores || { items: [] };
  const EXTERNAL_CATEGORY_LABELS = {
    backend: "Backend",
    network: "Network edge",
    "ml-runtime": "ML runtime",
    "on-device-engine": "On-device engine",
    "platform-service": "Platform service",
    "platform-storage": "Platform storage",
    "platform-framework": "Platform framework",
    "third-party-api": "Third-party API"
  };
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
  let selectedInterplayId = null;
  let selectedFlowId = null; // a traced system flow: its steps light up like a selection's path
  const openFlows = new Set(); // flows the reader has expanded; survives the re-render tracing causes
  const flows = interplay.flows || [];
  const flowById = new Map(flows.map((flow) => [flow.id, flow]));
  // Journey tables live up here because renderFlows() runs during init.
  const JOURNEY_TITLES = { launch: "1 · Starting the app", chat_turn: "2 · A chat turn", page: "3 · Entering and using a page" };
  const MERMAID_ASYNC = new Set(["notifies", "provides", "publish", "declares", "replays-into", "persists-to"]);
  let mermaidRenderSeq = 0;
  let interplayPositions = new Map();
  // Pan/zoom state for the free-form graph: the SVG fills its frame and we move a
  // viewBox window over the content, so click-drag pans, the wheel zooms, and a
  // node can be dragged to a new resting place. Content bounds anchor "fit".
  let interplayViewBox = null;
  let interplayContentBounds = { width: 0, height: 0 };

  document.getElementById("source-hash").textContent = model.source_tree_sha256.slice(0, 9);
  renderInterplay();
  setEdgesColoured(edgesColoured());
  renderInvariants();
  renderFlows();
  renderTimeline();
  renderConnections();
  renderExternals();
  renderStores();
  renderInventory();
  renderGates();
  wireNavigation();
  wireControls();

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
    if (node.kind === "provider") return "provider";
    if (node.kind === "machine") return "machine";
    if (node.kind === "external") return "external";
    if (node.kind === "transport") return "transport";
    if (node.kind === "client") return "client";
    if (node.kind === "section") return "section";
    if (node.kind === "store") return "store";
    if (node.kind === "owner") return interplayRoleByOwnerType.get(node.label) || "other";
    return interplayRoleByOwnerType.get(node.owner_type) || "other";
  }

  // A backend external that endpoint boxes are served by is drawn as a container
  // in the External systems hull: a header bar with the namespaces it serves inside.
  function isInterplayBar(node) {
    return isGatewayContainer(node) || node.kind === "transport";
  }
  function isGatewayContainer(node) {
    return node.kind === "external" && node.sub_kind === "backend" &&
      interplay.edges.some((edge) => edge.target === node.id && edge.relation === "served-by");
  }
  // The transport core is drawn as a box that owns its pool, lock, socket, session
  // and critical sections: one special object taking control of shared resources.
  // An owner holding stored resources (the transport core, a pool owner) is drawn
  // collapsed; clicking it expands an inner hull with its resources and sections.
  function isTransportContainer(node) {
    return node.kind === "owner" && ((node.roles || []).includes("transport") || (node.roles || []).includes("pool"));
  }
  function ownerMemberIds(owner) {
    return new Set(drawNodes
      .filter((node) => ["resource", "section", "operation", "machine"].includes(node.kind) &&
        node.owner_type === owner.label && node.component === owner.component && node.sub_kind !== "event_bus")
      .map((node) => node.id));
  }
  function isTransportCore(node) {
    return node.kind === "owner" && (node.roles || []).includes("transport");
  }
  function containerMemberIds(container) {
    if (isGatewayContainer(container)) {
      return new Set(interplay.edges
        .filter((edge) => edge.relation === "served-by" && edge.target === container.id)
        .map((edge) => edge.source));
    }
    if (container.kind === "transport") return new Set([container.core_id, container.bus_id]);
    return new Set();
  }

  function isBusSpine(node) {
    return node.kind === "resource" && node.sub_kind === "event_bus";
  }
  function isPushEdge(edge) {
    return ["notifies", "provides", "publish", "declares", "replays-into"].includes(edge.relation);
  }

  function interplayNodeSize(node) {
    if (node.kind === "operation") return { width: 158, height: 38 };
    if (isTransportContainer(node) || isBusSpine(node)) return { width: 236, height: 48 };
    if (node.kind === "section") return { width: Math.max(150, Math.min(220, (node.label || "").length * 7.6 + 60)), height: 48 };
    if (node.kind === "endpoint") return { width: 150, height: 46 };
    if (node.kind === "provider") return { width: 206, height: 48 }; // room for the init/configures meta line
    if (node.kind === "machine") return { width: Math.max(170, Math.min(230, (node.label || "").length * 6.4 + 40)), height: 48 };
    const label = node.label || "";
    return { width: Math.max(132, Math.min(206, label.length * 7.6 + 34)), height: 48 };
  }

  // Page placement: each navigation page (declared in config with its root
  // views) becomes a bounded, labelled zone; everything reached from more than
  // one page, or from none, is factored out into one SHARED CORE the pages depend
  // on. Deterministic: membership comes from the compiler's reachability tags,
  // packing from the declared page order, no PRNG. The page tables live in the
  // top const block to stay clear of the temporal dead zone during init.
  // Assign every node to a zone. Zones are the app's navigation pages: every
  // type-labelled node (caller, hub, subscriber, owner, seam) carries the page
  // whose view tree reaches it, computed by the compiler. From there membership
  // propagates along evidence: an endpoint or client file joins a page when every
  // caller reaching it is on that one page; resources and operations follow
  // their owner. Anything reached from more than one page, or from none, is
  // genuinely shared and stays in the shared core. Transports are shared by
  // construction. Externals orbit the application.
  function assignInterplayGroups(nodes, edges) {
    const invokedBy = new Map();        // endpointId -> Set(callerId)
    edges.forEach((edge) => {
      if (edge.relation !== "invokes") return;
      if (!invokedBy.has(edge.target)) invokedBy.set(edge.target, new Set());
      invokedBy.get(edge.target).add(edge.source);
    });
    // A type-labelled node's zone is the navigation page that reaches it.
    const pageZone = (node) => (node.page && PAGE_LABEL.has(node.page) ? PAGE_LABEL.get(node.page) : INTERPLAY_SHARED_GROUP);
    const callerFeature = new Map();
    nodes.forEach((node) => {
      if (interplayNodeRole(node) === "caller") callerFeature.set(node.id, pageZone(node));
    });
    const isFeature = (g) => Boolean(g) && ![INTERPLAY_SHARED_GROUP, INTERPLAY_EXTERNAL_GROUP, INTERPLAY_MEMORY_GROUP].includes(g);
    const single = (set) => (set.size === 1 ? Array.from(set)[0] : INTERPLAY_SHARED_GROUP);
    const barIds = new Set(nodes.filter(isInterplayBar).map((node) => node.id));
    const servedByBar = new Set(
      edges.filter((edge) => edge.relation === "served-by" && barIds.has(edge.target)).map((edge) => edge.source)
    );
    const endpointFeatures = new Map(); // endpointId -> Set(feature) of the callers reaching it
    nodes.forEach((node) => {
      if (interplayNodeRole(node) !== "endpoint") return;
      endpointFeatures.set(node.id, new Set(
        Array.from(invokedBy.get(node.id) || []).map((id) => callerFeature.get(id)).filter(isFeature)
      ));
    });

    const group = new Map();
    // 1. Callers, endpoints (inside their gateway when served by one), externals.
    nodes.forEach((node) => {
      const role = interplayNodeRole(node);
      if (role === "caller") group.set(node.id, callerFeature.get(node.id) || INTERPLAY_SHARED_GROUP);
      else if (role === "endpoint") {
        group.set(node.id, servedByBar.has(node.id) ? INTERPLAY_EXTERNAL_GROUP : single(endpointFeatures.get(node.id) || new Set()));
      } else if (role === "external") group.set(node.id, INTERPLAY_EXTERNAL_GROUP);
    });
    // 2. Client files: the page that declares ownership of a namespace they wrap;
    //    otherwise the single page whose callers reach the endpoints they implement.
    nodes.forEach((node) => {
      if (node.kind !== "client") return;
      const owningPages = new Set();
      interplayPages.forEach((page) => {
        if ((page.namespaces || []).some((ns) => (node.namespaces || []).includes(ns))) owningPages.add(page.label);
      });
      if (owningPages.size === 1) { group.set(node.id, Array.from(owningPages)[0]); return; }
      const features = new Set();
      edges.forEach((edge) => {
        if (edge.source !== node.id || edge.relation !== "implements") return;
        (endpointFeatures.get(edge.target) || new Set()).forEach((feature) => features.add(feature));
      });
      group.set(node.id, single(features));
    });
    // 3. Hubs, subscribers, owners and the seam: the page that reaches the type.
    //    An owner that holds stored resources and belongs to no single page is an
    //    in-memory construction (the transport core always is).
    // Ownership is read from the whole model, not the drawn subset: a collapsed
    // owner hides its resources from the canvas but still holds them.
    const holdsResources = new Set(interplay.nodes.filter((n) => n.kind === "resource" && n.owner_type && n.sub_kind !== "event_bus").map((n) => `${n.component}|${n.owner_type}`));
    nodes.forEach((node) => {
      if (!["hub", "subscriber", "owner", "seam", "store", "provider"].includes(node.kind)) return;
      const inMemoryStore = Boolean(node.store) && ((node.store.persistence || ["unobserved"])[0] === "unobserved");
      if (node.kind === "owner") {
        // An owner holding stored resources (transport, pool owner, on-device engine)
        // is an in-memory construction wherever its page is.
        if (holdsResources.has(`${node.component}|${node.label}`) || (node.roles || []).includes("transport")) {
          group.set(node.id, INTERPLAY_MEMORY_GROUP);
          return;
        }
        group.set(node.id, pageZone(node));
        return;
      }
      if (inMemoryStore) { group.set(node.id, INTERPLAY_MEMORY_GROUP); return; }
      group.set(node.id, pageZone(node));
    });
    // 5. The transport construction and the event stream sit in the in-memory hull.
    //    Other resources and operations follow their owner.
    nodes.forEach((node) => { if (isBusSpine(node) || node.kind === "transport") group.set(node.id, INTERPLAY_MEMORY_GROUP); });
    const ownerGroup = new Map();
    nodes.forEach((node) => {
      if (node.kind === "owner") ownerGroup.set(`${node.component}|${node.label}`, group.get(node.id));
    });
    nodes.forEach((node) => {
      if (group.has(node.id)) return;
      group.set(node.id, ownerGroup.get(`${node.component}|${node.owner_type}`) || INTERPLAY_SHARED_GROUP);
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
      if (role === "client") return 2;
      if (role === "transport") return 3;
      if (role === "section") return 3;
      if (role === "seam") return 4;
      if (role === "engine") return 5;
      if (role === "external") return 7;
      if (role === "store") return 6;
      return 6;
    };
    const byGroup = new Map();
    // Every declared page is a zone, even one that owns no interplay construct
    // exclusively: the breakdown is the navigation, not just what happened to land.
    interplayPages.forEach((page) => byGroup.set(page.label, []));
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
      const containers = [];
      const inList = new Set(list.map((node) => node.id));
      const bars = list.filter(isInterplayBar);
      const barIds = new Set(bars.map((bar) => bar.id));
      const containedBy = new Map(); // member id -> container id
      bars.forEach((bar) => containerMemberIds(bar).forEach((id) => { if (inList.has(id)) containedBy.set(id, bar.id); }));
      // Expanded owners: their resources and sections are drawn in an inner hull
      // directly beneath the owner box, wherever the owner sits.
      const expanded = list.filter((node) => isTransportContainer(node) && expandedOwners.has(node.id));
      expanded.forEach((owner) => ownerMemberIds(owner).forEach((id) => { if (inList.has(id)) containedBy.set(id, owner.id); }));
      const rest = list.filter((node) => !barIds.has(node.id) && !containedBy.has(node.id));
      const INSET = 16;
      const HEADER_H = 40;
      let y = PAD + HEADER;
      let maxRight = PAD;

      function grid(items, startX, startY, columns) {
        let x = startX;
        let gy = startY;
        let rowH = 0;
        let right = startX;
        let col = 0;
        let prevRank = null;
        items.forEach((node) => {
          const s = size.get(node.id);
          const rank = kindRank(node);
          const wrap = col >= columns || (prevRank === 0 && rank !== 0); // callers get their own top row
          if (wrap) { col = 0; x = startX; gy += rowH + GAP; rowH = 0; }
          place.set(node.id, { x: x + s.width / 2, y: gy + s.height / 2 });
          x += s.width + GAP;
          right = Math.max(right, x - GAP);
          rowH = Math.max(rowH, s.height);
          col += 1;
          prevRank = rank;
        });
        return { bottom: items.length ? gy + rowH : startY - GAP, right };
      }

      // The inner hull of an expanded owner: its members gridded beneath it.
      function expandOwners(items, startX, startY, columns) {
        let cursor = startY;
        let right = startX;
        items.filter((node) => expandedOwners.has(node.id) && isTransportContainer(node)).forEach((owner) => {
          const members = list
            .filter((node) => containedBy.get(node.id) === owner.id)
            .sort((a, b) => kindRank(a) - kindRank(b) || (a.label || "").localeCompare(b.label || ""));
          if (!members.length) return;
          const top = cursor + GAP;
          const inner = grid(members, startX + INSET, top + INSET, columns);
          const bottom = inner.bottom + INSET;
          containers.push({ nodeId: owner.id, top, bottom, left: startX, right: inner.right + INSET, kind: "owner" });
          right = Math.max(right, inner.right + INSET);
          cursor = bottom;
        });
        return { bottom: cursor, right };
      }

      // Containers (a gateway boundary, the transport construction): a header in the
      // top-left corner, their members gridded inside, expanded owners beneath.
      bars.forEach((bar) => {
        const top = y;
        const members = list
          .filter((node) => containedBy.get(node.id) === bar.id)
          .sort((a, b) => (a.label || "").localeCompare(b.label || "") || a.id.localeCompare(b.id));
        const inner = grid(members, PAD + INSET, top + HEADER_H + GAP, cols);
        const nested = expandOwners(members, PAD + INSET, inner.bottom, cols);
        const bottom = Math.max(inner.bottom, nested.bottom) + INSET;
        containers.push({ nodeId: bar.id, top, bottom, left: PAD, right: null, kind: bar.kind === "transport" ? "transport" : "gateway" });
        maxRight = Math.max(maxRight, inner.right + INSET, nested.right + INSET);
        y = bottom + GAP;
      });
      const restBox = grid(rest, PAD, y, cols);
      const restNested = expandOwners(rest, PAD, restBox.bottom, cols);
      maxRight = Math.max(maxRight, restBox.right, restNested.right);
      y = Math.max(y - GAP, restBox.bottom, restNested.bottom);

      // With the group's width known, stretch full-width containers across it; the
      // container node itself is the hull's label, sitting in its top-left corner.
      const width = maxRight - PAD;
      containers.forEach((container) => {
        const node = nodes.find((candidate) => candidate.id === container.nodeId);
        container.x = container.left;
        container.y = container.top;
        container.w = container.right === null ? width : container.right - container.left;
        container.h = container.bottom - container.top;
        if (container.kind !== "owner") {
          const labelWidth = Math.max(180, Math.min(320, ((node && node.label) || "").length * 7.6 + 90));
          place.set(container.nodeId, { x: PAD + 6 + labelWidth / 2, y: container.top + 4 + 15, width: labelWidth, height: 30 });
        }
      });
      return { w: maxRight + PAD, h: y + PAD, place, containers };
    }

    const laid = new Map();
    byGroup.forEach((list, g) => {
      const cols = (g === INTERPLAY_SHARED_GROUP || g === INTERPLAY_EXTERNAL_GROUP || g === INTERPLAY_MEMORY_GROUP)
        ? 6 : Math.max(2, Math.min(4, Math.ceil(Math.sqrt(list.length))));
      laid.set(g, layoutGroup(list, cols));
    });

    // Radial layout: the in-memory constructions sit in the centre with the shared
    // core beneath them, and the pages ring them in declared order (top, right,
    // bottom, left, round-robin). Externals orbit outside the application hull.
    const BOX_GAP = 40;
    const SIDE_GAP = 56;
    const RING_GAP = 56;
    const shared = laid.get(INTERPLAY_SHARED_GROUP);
    const memory = laid.get(INTERPLAY_MEMORY_GROUP);
    const pageOrder = Array.from(byGroup.keys())
      .filter((g) => ![INTERPLAY_SHARED_GROUP, INTERPLAY_EXTERNAL_GROUP, INTERPLAY_MEMORY_GROUP].includes(g))
      .sort((a, b) => (PAGE_RANK.get(a) ?? 99) - (PAGE_RANK.get(b) ?? 99) || a.localeCompare(b));
    const ring = { top: [], right: [], bottom: [], left: [] };
    const sideOrder = ["top", "right", "bottom", "left"];
    pageOrder.forEach((g, index) => ring[sideOrder[index % 4]].push(g));
    const rowW = (list) => list.reduce((w, g) => w + laid.get(g).w, 0) + Math.max(0, list.length - 1) * BOX_GAP;
    const rowH = (list) => list.reduce((h, g) => Math.max(h, laid.get(g).h), 0);
    const colW = (list) => list.reduce((w, g) => Math.max(w, laid.get(g).w), 0);
    const colH = (list) => list.reduce((h, g) => h + laid.get(g).h, 0) + Math.max(0, list.length - 1) * BOX_GAP;
    const centerW = Math.max(memory ? memory.w : 0, shared ? shared.w : 0, 480);
    const centerH = (memory ? memory.h : 0) + (shared ? shared.h + (memory ? BOX_GAP : 0) : 0);
    const leftW = colW(ring.left);
    const rightW = colW(ring.right);
    const middleH = Math.max(centerH, colH(ring.left), colH(ring.right));
    const totalW = leftW + (leftW ? RING_GAP : 0) + centerW + (rightW ? RING_GAP : 0) + rightW;
    const groupBoxes = [];
    const pushPage = (g, x, y) => {
      const box = laid.get(g);
      groupBoxes.push({ label: g, x, y, w: box.w, h: box.h, place: box.place, containers: box.containers });
    };
    let cursor = (totalW - rowW(ring.top)) / 2;
    ring.top.forEach((g) => { pushPage(g, cursor, 0); cursor += laid.get(g).w + BOX_GAP; });
    const midY = rowH(ring.top) + (ring.top.length ? RING_GAP : 0);
    cursor = midY + (middleH - colH(ring.left)) / 2;
    ring.left.forEach((g) => { pushPage(g, 0, cursor); cursor += laid.get(g).h + BOX_GAP; });
    const centerX = leftW + (leftW ? RING_GAP : 0);
    let centerY = midY + (middleH - centerH) / 2;
    if (memory) {
      groupBoxes.push({ label: INTERPLAY_MEMORY_GROUP, kind: "memory", x: centerX + (centerW - memory.w) / 2, y: centerY, w: memory.w, h: memory.h, place: memory.place, containers: memory.containers });
      centerY += memory.h + BOX_GAP;
    }
    if (shared) {
      groupBoxes.push({ label: INTERPLAY_SHARED_GROUP, x: centerX + (centerW - shared.w) / 2, y: centerY, w: shared.w, h: shared.h, place: shared.place, containers: shared.containers });
    }
    cursor = midY + (middleH - colH(ring.right)) / 2;
    ring.right.forEach((g) => { pushPage(g, centerX + centerW + RING_GAP, cursor); cursor += laid.get(g).h + BOX_GAP; });
    cursor = (totalW - rowW(ring.bottom)) / 2;
    const bottomY = midY + middleH + (ring.bottom.length ? RING_GAP : 0);
    ring.bottom.forEach((g) => { pushPage(g, cursor, bottomY); cursor += laid.get(g).w + BOX_GAP; });
    const targetWidth = Math.max(totalW, 1280);

    // Application boundary around every code group: the hub everything external orbits.
    const APP_PAD = 26;
    const APP_HEADER = 22;
    let appBox = null;
    if (groupBoxes.length) {
      const minX = Math.min(...groupBoxes.map((box) => box.x));
      const minY = Math.min(...groupBoxes.map((box) => box.y));
      const maxX = Math.max(...groupBoxes.map((box) => box.x + box.w));
      const maxY = Math.max(...groupBoxes.map((box) => box.y + box.h));
      appBox = {
        label: INTERPLAY_APP_GROUP, kind: "app",
        x: minX - APP_PAD, y: minY - APP_PAD - APP_HEADER,
        w: maxX - minX + APP_PAD * 2, h: maxY - minY + APP_PAD * 2 + APP_HEADER,
        place: new Map()
      };
      groupBoxes.unshift(appBox); // outermost, drawn first
    }

    const positions = new Map();
    const placeGroup = (box) => box.place.forEach((rel, id) => {
      positions.set(id, { x: box.x + rel.x, y: box.y + rel.y, width: rel.width, height: rel.height });
    });
    groupBoxes.forEach(placeGroup);

    // External systems float around the application hull rather than sitting in a
    // hull of their own. A gateway boundary (with the namespace boxes it serves)
    // hangs beneath the application; every other external node sits beside it,
    // level with the nodes it links to, on the side those nodes lean toward.
    const externalNodes = byGroup.get(INTERPLAY_EXTERNAL_GROUP) || [];
    const anchor = appBox || { x: 0, y: 0, w: targetWidth, h: rowH(ring.top) + middleH + rowH(ring.bottom) };
    const gatewayMembers = externalNodes.filter((node) => isInterplayBar(node) || interplayNodeRole(node) === "endpoint");
    if (gatewayMembers.length) {
      const block = layoutGroup(gatewayMembers, 6);
      const box = {
        label: "", kind: "free",
        x: anchor.x + (anchor.w - block.w) / 2, y: anchor.y + anchor.h + BOX_GAP,
        w: block.w, h: block.h, place: block.place, containers: block.containers
      };
      groupBoxes.push(box);
      placeGroup(box);
    }
    const floating = externalNodes.filter((node) => !gatewayMembers.includes(node));
    const sides = { left: [], right: [] };
    floating.forEach((node) => {
      const linked = edges
        .filter((edge) => edge.source === node.id || edge.target === node.id)
        .map((edge) => positions.get(edge.source === node.id ? edge.target : edge.source))
        .filter(Boolean);
      const meanX = linked.length ? linked.reduce((sum, point) => sum + point.x, 0) / linked.length : anchor.x + anchor.w;
      const meanY = linked.length ? linked.reduce((sum, point) => sum + point.y, 0) / linked.length : anchor.y + anchor.h / 2;
      (meanX < anchor.x + anchor.w / 2 ? sides.left : sides.right).push({ node, y: meanY });
    });
    Object.entries(sides).forEach(([side, items]) => {
      items.sort((a, b) => a.y - b.y || a.node.id.localeCompare(b.node.id));
      let cursor = -Infinity;
      items.forEach((item) => {
        const s = size.get(item.node.id);
        const top = Math.max(item.y - s.height / 2, cursor, anchor.y);
        const x = side === "left"
          ? anchor.x - SIDE_GAP - s.width / 2
          : anchor.x + anchor.w + SIDE_GAP + s.width / 2;
        positions.set(item.node.id, { x, y: top + s.height / 2 });
        cursor = top + s.height + GAP;
      });
    });

    positions.groupBoxes = groupBoxes.map((box) => ({
      label: box.label, kind: box.kind || "group", x: box.x, y: box.y, w: box.w, h: box.h,
      containers: (box.containers || []).map((container) => ({
        nodeId: container.nodeId, kind: container.kind, x: box.x + container.x, y: box.y + container.y, w: container.w, h: container.h
      }))
    }));
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
    drawNodes.forEach((node) => nodeRole.set(node.id, interplayNodeRole(node)));

    // Lifecycle operations are actions, not constructions: they are not drawn as
    // boxes. They stay in the model and are listed on their owner's inspector.
    const hidden = new Set();
    drawNodes.forEach((node) => {
      if (isTransportContainer(node) && !expandedOwners.has(node.id)) ownerMemberIds(node).forEach((id) => hidden.add(id));
    });
    // The union of the head revision and every historical point: one layout for
    // the whole walk. Historical-only nodes are drawn absent until the slider moves.
    const drawable = drawNodes.filter((node) => node.kind !== "operation" && !hidden.has(node.id));

    // Position every drawn node with the deterministic page layout, then
    // translate the whole graph so its top-left corner sits at the margin.
    const layout = layoutInterplayGrouped(drawable, drawEdges);
    const groupBoxes = layout.groupBoxes || [];
    let minX = Infinity;
    let minY = Infinity;
    let maxX = -Infinity;
    let maxY = -Infinity;
    drawable.forEach((node) => {
      const size = interplayNodeSize(node);
      const center = layout.get(node.id);
      const width = center.width || size.width;
      const height = center.height || size.height;
      const x = center.x - width / 2;
      const y = center.y - height / 2;
      interplayPositions.set(node.id, { x, y, width, height });
      minX = Math.min(minX, x);
      minY = Math.min(minY, y);
      maxX = Math.max(maxX, x + width);
      maxY = Math.max(maxY, y + height);
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
    groupBoxes.forEach((box) => {
      box.x += shiftX;
      box.y += shiftY;
      (box.containers || []).forEach((container) => { container.x += shiftX; container.y += shiftY; });
    });
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
      const appHull = box.kind === "app";
      const memoryHull = box.kind === "memory";
      if (box.kind !== "free") {
        const hull = svgElement("g", {
          class: `interplay-group${shared ? " shared" : ""}${appHull ? " app" : ""}${memoryHull ? " memory" : ""}`,
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
      }
      // A gateway boundary: the same hull schema, hanging beneath the application
      // hull and enclosing every namespace box the gateway serves. Its label is the
      // gateway node itself, rendered in the top-left corner.
      (box.containers || []).forEach((container) => {
        const boundary = svgElement("g", { class: `interplay-group ${container.kind}`, "data-container": container.nodeId });
        boundary.append(svgElement("rect", {
          x: container.x, y: container.y, width: container.w, height: container.h,
          rx: 12, ry: 12, class: "interplay-group-rect"
        }));
        groupLayer.append(boundary);
      });
    });
    svg.append(groupLayer);
    // Gateway label nodes render beneath edges and ordinary nodes.
    const containerGroup = svgElement("g", { class: "nodes containers" });
    svg.append(containerGroup);

    // Arrowheads: one marker per edge class (coloured like the edge) plus the
    // active marker used while an edge is highlighted.
    const defs = svgElement("defs", {});
    const MARKER_COLORS = {
      structure: "#8a8a92", lifecycle: "#55545a", interplay: "#8b83ff", usage: "#7ec8b0",
      push: "#d16f86", boundary: "#e0704f", trigger: "#9fd18b", ghost: "#d9a441",
      active: getComputedStyle(document.documentElement).getPropertyValue("--edge-active").trim() || "#f2f2f4",
      quiet: getComputedStyle(document.documentElement).getPropertyValue("--edge-quiet").trim() || "#5a585d"
    };
    Object.entries(MARKER_COLORS).forEach(([name, color]) => {
      const marker = svgElement("marker", {
        id: `arrow-${name}`, viewBox: "0 0 10 10", refX: 9, refY: 5, markerWidth: 7, markerHeight: 7,
        orient: "auto-start-reverse", markerUnits: "userSpaceOnUse"
      });
      marker.append(svgElement("path", { d: "M 0 0 L 10 5 L 0 10 z", fill: color }));
      defs.append(marker);
    });
    svg.append(defs);
    const edgeGroup = svgElement("g", { class: "edges" });
    const labelGroup = svgElement("g", { class: "edge-labels" });
    drawTriggerEdges(edgeGroup, groupBoxes);
    drawEdges.forEach((edge) => {
      const source = interplayPositions.get(edge.source);
      const target = interplayPositions.get(edge.target);
      if (!source || !target) return;
      const targetNode = interplayNodeById.get(edge.target);
      const hkey = edgeHistoryKey(edge, interplayNodeById);
      if (edge.relation === "served-by" && targetNode && isInterplayBar(targetNode)) return; // drawn as containment
      if ((edge.relation === "owns" || edge.relation === "operates") && isTransportContainer(interplayNodeById.get(edge.source) || {})) return; // containment
      if (["implements", "invokes", "extends"].includes(edge.relation)) return; // data for the inspector; the drawn flow is surface → client file → core → namespace
      const edgeClass = isPushEdge(edge) ? "push" : edge.class;
      const path = svgElement("path", {
        d: interplayLinkPath(source, target),
        class: `interplay-edge ${edgeClass}${edge.relation === "provides" ? " feed" : ""}`,
        "marker-end": `url(#arrow-${edgeClass})`,
        "data-source": edge.source,
        "data-target": edge.target,
        "data-relation": edge.relation,
        "data-hkey": hkey,
        "data-hist": edge.hist ? "true" : "false"
      });
      // The relation name, shown only while the edge is highlighted.
      const mid = interplayLinkMidpoint(source, target);
      const label = svgElement("text", {
        x: mid.x.toFixed(1), y: mid.y.toFixed(1), class: "interplay-edge-label",
        "data-source": edge.source, "data-target": edge.target, "data-relation": edge.relation,
        "data-hkey": hkey, "data-hist": edge.hist ? "true" : "false"
      });
      label.textContent = edge.relation.replace(/-/g, " ");
      labelGroup.append(label);
      const title = svgElement("title", {});
      const sourceNode = interplayNodeById.get(edge.source);
      title.textContent = edge.relation === "notifies"
        ? `notifies · ${subscriptionLabel(targetNode)}`
        : edge.relation === "calls" && sourceNode && targetNode
          ? `calls · ${triggerProvenance(sourceNode, targetNode)}`
          : edge.relation;
      path.append(title);
      edgeGroup.append(path);
    });
    svg.append(edgeGroup);
    svg.append(labelGroup);

    const nodeGroup = svgElement("g", { class: "nodes" });
    drawable.forEach((node) => {
      const position = interplayPositions.get(node.id);
      if (!position) return;
      const role = nodeRole.get(node.id) || "other";
      const group = svgElement("g", {
        class: `interplay-node${node.hist ? " hist" : ""}`,
        tabindex: node.hist ? "-1" : "0",
        role: "button",
        "aria-label": `${node.label}, ${INTERPLAY_ROLE_LABELS[role]}`,
        "data-node": node.id,
        "data-kind": node.kind,
        "data-pipe": isInterplayBar(node) ? "true" : "false",
        transform: `translate(${position.x} ${position.y})`
      });
      group.style.setProperty("--node-color", INTERPLAY_ROLE_COLORS[role]);
      const rect = svgElement("rect", { width: position.width, height: position.height, rx: 6 });
      if (node.kind === "operation") rect.setAttribute("class", "operation");
      else if (node.kind === "endpoint") rect.setAttribute("class", "endpoint");
      else if (node.kind === "caller") rect.setAttribute("class", "caller");
      else if (node.kind === "external") rect.setAttribute("class", isInterplayBar(node) ? "hull-label" : "external");
      else if (node.kind === "transport") rect.setAttribute("class", "hull-label");
      else if (isTransportContainer(node)) rect.setAttribute("class", `core${expandedOwners.has(node.id) ? " expanded" : ""}`);
      else if (node.kind === "client") rect.setAttribute("class", "client");
      else if (node.kind === "section") rect.setAttribute("class", "section");
      else if (node.kind === "store") rect.setAttribute("class", "store");
      else if (node.kind === "provider") rect.setAttribute("class", "provider");
      else if (node.kind === "machine") rect.setAttribute("class", "machine");
      else if (isBusSpine(node)) rect.setAttribute("class", "bus");
      if (node.overlay_prose) rect.setAttribute("data-explained", "true");
      group.append(rect);
      if (!isInterplayBar(node)) {
        group.append(svgElement("line", { x1: 0, x2: 0, y1: 6, y2: position.height - 6, class: "node-rule" }));
      }
      const kicker = svgElement("text", { x: 11, y: 15, class: "node-kicker" });
      kicker.textContent = interplayKicker(node);
      const title = svgElement("text", { x: 11, y: 29, class: "node-title" });
      title.textContent = node.label;
      group.append(kicker, title);
      if (node.kind !== "operation" && !isInterplayBar(node)) {
        const meta = svgElement("text", { x: 11, y: 41, class: "node-meta" });
        meta.textContent = interplayNodeMeta(node);
        group.append(meta);
      }
      const isContainer = isInterplayBar(node);
      if (node.hist) {
        // Present at some earlier commit, not in the head revision: the inspector
        // and the inventory have nothing to say about it, so it is not selectable.
        const note = svgElement("title", {});
        note.textContent = `${node.label} · present at an earlier commit, not in the head revision`;
        group.append(note);
      } else if (isContainer) {
        group.addEventListener("click", (event) => {
          event.stopPropagation();
          selectInterplayNode(node.id);
        });
      } else if (isTransportContainer(node)) {
        // Collapsed by default; a click expands the owner's resources and sections.
        group.addEventListener("click", (event) => {
          event.stopPropagation();
          if (expandedOwners.has(node.id)) expandedOwners.delete(node.id); else expandedOwners.add(node.id);
          selectedInterplayId = node.id;
          renderInterplay();
          renderInterplayInspector(node);
        });
      } else {
        wireInterplayNodeDrag(svg, group, node.id);
      }
      if (!node.hist) {
        group.addEventListener("keydown", (event) => {
          if (event.key === "Enter" || event.key === " ") {
            event.preventDefault();
            selectInterplayNode(node.id);
          }
        });
      }
      (isContainer ? containerGroup : nodeGroup).append(group);
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

  // Where an edge's label sits: the control point of its quadratic bow.
  function interplayLinkMidpoint(source, target) {
    const scx = source.x + source.width / 2;
    const scy = source.y + source.height / 2;
    const tcx = target.x + target.width / 2;
    const tcy = target.y + target.height / 2;
    const start = interplayBoxExit(source, tcx, tcy);
    const end = interplayBoxExit(target, scx, scy);
    const mx = (start.x + end.x) / 2;
    const my = (start.y + end.y) / 2;
    const nx = -(end.y - start.y);
    const ny = end.x - start.x;
    const nlen = Math.hypot(nx, ny) || 1;
    const bow = Math.min(26, nlen * 0.12);
    return { x: mx + (nx / nlen) * bow * 0.5, y: my + (ny / nlen) * bow * 0.5 - 4 };
  }

  // The request path a selection lights up. A surface highlights its calls into
  // client files, their routes into the core, and the core's dispatches to the
  // namespaces the surface invokes; a client file likewise; the core lights up
  // everything it holds together. Anything else highlights its direct edges.
  function flowEdgeKeys(nodeId) {
    const node = interplayNodeById.get(nodeId);
    const key = (edge) => `${edge.source}|${edge.target}|${edge.relation}`;
    const keys = new Set();
    interplay.edges.forEach((edge) => {
      if (edge.source === nodeId || edge.target === nodeId) keys.add(key(edge));
    });
    if (!node) return keys;
    const core = interplay.nodes.find((n) => n.kind === "owner" && (n.roles || []).includes("transport"));
    const endpointsFor = (namespaces) => interplay.nodes.filter((n) => n.kind === "endpoint" && namespaces.includes(n.label)).map((n) => n.id);
    if (node.kind === "caller" && core) {
      const clientIds = interplay.edges.filter((e) => e.source === nodeId && e.relation === "calls").map((e) => e.target);
      interplay.edges.forEach((edge) => {
        if (edge.relation === "routes-through" && clientIds.includes(edge.source)) keys.add(key(edge));
        if (edge.relation === "dispatches" && edge.source === core.id && endpointsFor(node.namespaces || []).includes(edge.target)) keys.add(key(edge));
      });
    }
    if (node.kind === "client" && core) {
      interplay.edges.forEach((edge) => {
        if (edge.relation === "dispatches" && edge.source === core.id && endpointsFor(node.namespaces || []).includes(edge.target)) keys.add(key(edge));
      });
    }
    return keys;
  }

  function interplayKicker(node) {
    if (node.kind === "hub") return "HUB";
    if (node.kind === "seam") return "SEAM";
    if (node.kind === "endpoint") return node.protocol === "jsonrpc" ? "JSON-RPC" : "REST";
    if (node.kind === "subscriber") return "SUBSCRIBER";
    if (node.kind === "caller") return (componentLabel(node.component) || "CALLER").toUpperCase();
    if (node.kind === "external") return String(node.sub_kind || "system").replace(/-/g, " ").toUpperCase();
    if (node.kind === "client") return "CLIENT FILE";
    if (node.kind === "provider") return "PROVIDER · LAUNCH";
    if (node.kind === "machine") return "STATE MACHINE";
    if (node.kind === "section") return "CRITICAL SECTION";
    if (node.kind === "transport") return "IN-MEMORY · TRANSPORT";
    if (isTransportCore(node)) return "REQUEST LEG · TRANSPORT CORE";
    if (isTransportContainer(node)) return "POOL OWNER";
    if (node.kind === "store") {
      const persistence = (node.store && node.store.persistence) || [];
      return `DATA STORE · ${persistence.length && persistence[0] !== "unobserved" ? persistence.join(" / ").toUpperCase() : "IN-MEMORY"}`;
    }
    if (node.kind === "owner") return (node.roles || []).join(" · ").toUpperCase() || "OWNER";
    if (isBusSpine(node)) return "PUSH LEG · EVENT STREAM";
    return String(node.sub_kind || node.kind).replace(/_/g, " ").toUpperCase();
  }

  // Triggers: page → surface. Aggregated per pair, labelled with counts; the
  // individual actions live on the surface's inspector.
  function surfaceNodeFor(label) {
    const order = ["caller", "subscriber", "hub", "store", "owner", "provider"];
    const candidates = interplay.nodes.filter((node) => node.label === label && order.includes(node.kind));
    candidates.sort((a, b) => order.indexOf(a.kind) - order.indexOf(b.kind));
    return candidates[0] || null;
  }
  function triggerSummary(list) {
    const ua = list.filter((t) => t.kind === "user_action").length;
    const lc = list.filter((t) => t.kind === "lifecycle").length;
    const la = list.filter((t) => t.kind === "launch").length;
    return [ua && `${ua} user action${ua === 1 ? "" : "s"}`, lc && `${lc} lifecycle hook${lc === 1 ? "" : "s"}`, la && `constructed at launch by ${la} entry point${la === 1 ? "" : "s"}`].filter(Boolean).join(" · ") || "no observed trigger";
  }
  function drawTriggerEdges(edgeGroup, groupBoxes) {
    const boxByLabel = new Map(groupBoxes.map((box) => [box.label, box]));
    const grouped = new Map();
    triggers.forEach((trigger) => {
      if (!trigger.page || !PAGE_LABEL.has(trigger.page)) return;
      const target = surfaceNodeFor(trigger.surface);
      if (!target) return;
      const key = `${PAGE_LABEL.get(trigger.page)}|${target.id}`;
      if (!grouped.has(key)) grouped.set(key, { page: PAGE_LABEL.get(trigger.page), targetId: target.id, list: [] });
      grouped.get(key).list.push(trigger);
    });
    // Page → surface pairs some earlier commit had and the head does not: drawn
    // absent, so the slider can bring them back.
    const pageIdByLabel = new Map(interplayPages.map((page) => [page.label, page.id]));
    const headTriggerKeys = new Set(Array.from(grouped.values()).map((entry) =>
      `page:${pageIdByLabel.get(entry.page)}|${historyKeyOf(interplayNodeById.get(entry.targetId))}|triggers`));
    if (HISTORY) {
      HISTORY.edges.forEach(([sourceIndex, targetIndex, relation]) => {
        const source = HISTORY.nodes[sourceIndex];
        const target = HISTORY.nodes[targetIndex];
        if (relation !== "triggers" || !source || !target || source.kind !== "page") return;
        const key = `${source.k}|${target.k}|triggers`;
        const pageLabel = PAGE_LABEL.get(source.page);
        const targetId = idByHistoryKey.get(target.k);
        if (headTriggerKeys.has(key) || !pageLabel || !targetId) return;
        grouped.set(key, { page: pageLabel, targetId, list: [], hist: true });
      });
    }
    grouped.forEach((entry) => {
      const box = boxByLabel.get(entry.page);
      const target = interplayPositions.get(entry.targetId);
      if (!box || !target) return;
      const source = { x: box.x + 18, y: box.y + 22, width: 1, height: 1 };
      const hkey = `page:${pageIdByLabel.get(entry.page)}|${historyKeyOf(interplayNodeById.get(entry.targetId))}|triggers`;
      const path = svgElement("path", {
        d: interplayLinkPath(source, target),
        class: "interplay-edge trigger",
        "marker-end": "url(#arrow-trigger)",
        "data-source": `page:${entry.page}`,
        "data-target": entry.targetId,
        "data-relation": "triggers",
        "data-hkey": hkey,
        "data-hist": entry.hist ? "true" : "false"
      });
      const title = svgElement("title", {});
      title.textContent = entry.hist
        ? `${entry.page} triggered ${interplayNodeById.get(entry.targetId).label} at an earlier commit`
        : `${entry.page} triggers ${interplayNodeById.get(entry.targetId).label}: ${triggerSummary(entry.list)}`;
      path.append(title);
      edgeGroup.append(path);
      const mid = interplayLinkMidpoint(source, target);
      const label = svgElement("text", {
        x: mid.x.toFixed(1), y: mid.y.toFixed(1), class: "interplay-edge-label",
        "data-source": `page:${entry.page}`, "data-target": entry.targetId, "data-relation": "triggers",
        "data-hkey": hkey, "data-hist": entry.hist ? "true" : "false"
      });
      const allLaunch = entry.list.length && entry.list.every((t) => t.kind === "launch");
      label.textContent = entry.hist ? "triggered · earlier commit" : allLaunch ? `constructs · ${entry.list.length} entry point${entry.list.length === 1 ? "" : "s"}` : `triggers · ${triggerSummary(entry.list)}`;
      const labels = edgeGroup.parentNode ? edgeGroup.parentNode.querySelector(".edge-labels") : null;
      (labels || edgeGroup).append(label);
    });
  }
  function triggersFor(node) {
    return triggers.filter((t) => t.surface === node.label);
  }
  function triggerProvenance(callerNode, clientNode) {
    const reaching = triggersFor(callerNode).filter((t) => t.namespaces.some((ns) => (clientNode.namespaces || []).includes(ns)));
    if (!reaching.length) return "no observed trigger reaches this file";
    const counts = new Map();
    reaching.forEach((t) => counts.set(t.api, (counts.get(t.api) || 0) + 1));
    return "fired by " + Array.from(counts.entries()).map(([api, n]) => `${api}${n > 1 ? ` ×${n}` : ""}`).join(", ");
  }

  function subscriptionLabel(node) {
    const sub = node && node.subscription;
    if (!sub) return "direct";
    if (sub.mode === "batched") return `batched · ${sub.batch_ms} ms / ${sub.batch_count} on ${sub.scheduler}`;
    return sub.scheduler ? `direct on ${sub.scheduler}` : "direct on the publishing thread";
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
    if (node.kind === "subscriber") return subscriptionLabel(node);
    if (node.kind === "store") {
      const artifacts = (node.store && node.store.artifacts) || [];
      return artifacts.length ? artifacts.join(", ") : "no artifact literal";
    }
    if (node.kind === "external") {
      return isInterplayBar(node) && node.protocol
        ? `${node.protocol} · ${node.file_count} file(s) · ${node.hit_count} hit(s)`
        : `${node.file_count} file(s) · ${node.hit_count} hit(s)`;
    }
    if (node.kind === "client") {
      const count = (node.namespaces || []).length;
      return `${count} namespace${count === 1 ? "" : "s"}`;
    }
    if (node.kind === "provider") {
      const loads = (node.loads || []).length;
      return `init reads ${loads} store${loads === 1 ? "" : "s"}${(node.configures || []).length ? " · configures core" : ""}`;
    }
    if (node.kind === "machine") {
      const machine = node.machine || { states: [], transitions: [] };
      return `${machine.states.length} states · ${machine.transitions.length} transitions`;
    }
    if (node.kind === "section") {
      const guarded = (node.steps || []).filter((step) => step.guarded).length;
      return `${(node.lock_labels || []).join(", ")} · ${(node.steps || []).length} steps · ${guarded} under lock`;
    }
    if (isTransportContainer(node)) {
      const owned = ownerMemberIds(node).size;
      const holders = interplay.edges.filter((edge) => edge.target === node.id && edge.relation === "holds").length;
      const held = holders ? ` · held by ${holders} surface${holders === 1 ? "" : "s"}` : "";
      return `${owned} owned resource${owned === 1 ? "" : "s"} · ${expandedOwners.has(node.id) ? "click to collapse" : "click to expand"}${held}`;
    }
    if (node.kind === "caller") {
      const count = (node.namespaces || []).length;
      return `queries ${count} namespace${count === 1 ? "" : "s"}`;
    }
    if (node.sub_kind === "event_bus") {
      return `${interplayBusSubscriberCount(node)} subscribers · declared by ${node.owner_type}`;
    }
    if (node.sub_kind === "stream_cursor") return `${node.owner_type} · SSE replay`;
    if (node.overlay_prose) return `${node.owner_type} · explained`;
    return node.owner_type || "";
  }

  function renderInterplayLegend() {
    const legend = document.getElementById("interplay-legend-items");
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
    // Edges: quiet by default (one stroke, dashes hint the kind); the switch below
    // restores the per-relationship palette. The swatches follow whichever is on.
    const coloured = edgesColoured();
    const edgeClasses = [
      ["interplay", "var(--accent)", "Interplay wiring", true],
      ["usage", "#7ec8b0", "Surface calls a client file · holds the core", false],
      ["push", "#d16f86", "Push leg: event fan-out", false],
      ["trigger", "#9fd18b", "Page triggers a surface (user action / lifecycle)", false],
      ["boundary", "#e0704f", "Crosses an external boundary", false],
      ["lifecycle", "#55545a", "Lifecycle", false],
      ["structure", "var(--line-strong)", "Structure", true]
    ];
    const edges = element("div", "legend-edges");
    edgeClasses.forEach(([klass, color, label, solid]) => {
      if (!interplay.edges.some((edge) => edge.class === klass)) return;
      const item = element("div", "legend-item");
      const swatch = element("span", `legend-swatch${solid ? " solid" : ""}`);
      swatch.style.setProperty("--legend-color", coloured ? color : "var(--edge-quiet)");
      item.append(swatch, document.createTextNode(label));
      edges.append(item);
    });
    const switchRow = element("label", "legend-switch");
    const input = document.createElement("input");
    input.type = "checkbox";
    input.id = "edge-colour-toggle";
    input.checked = coloured;
    input.addEventListener("change", () => { setEdgesColoured(input.checked); renderInterplayLegend(); });
    switchRow.append(input, document.createTextNode("Colour edges by relationship"));
    legend.replaceChildren(...items, switchRow, edges);
  }

  const EDGE_COLOUR_KEY = "portal.architecture.edgesColoured";
  function edgesColoured() {
    try { return window.localStorage.getItem(EDGE_COLOUR_KEY) === "1"; } catch (_error) { return false; }
  }
  function setEdgesColoured(on) {
    try { window.localStorage.setItem(EDGE_COLOUR_KEY, on ? "1" : "0"); } catch (_error) { /* storage unavailable */ }
    const svg = document.getElementById("interplay-graph");
    if (svg) svg.classList.toggle("edges-coloured", on);
  }

  // ---- Semantic enrichment: described constructs and system flows ---------------
  // Both are LLM-written and compiler-validated (architecture/semantic/*.json); the
  // site only displays them. A record is drawn as a labelled table; a flow is a
  // path over drawn edges that the reader can trace on the map.
  const SEMANTIC_FIELD_LABELS = {
    medium: "Medium", location: "Location", record_type: "Record types", keyed_by: "Keyed by", written_when: "Written",
    read_when: "Read", readers: "Readers", writers: "Writers", retention: "Retention", failure_mode: "On failure", sensitive: "Sensitive",
    protocol: "Protocol", auth: "Auth", direction: "Direction", failure_visible_as: "Failure visible as", namespaces_or_apis: "Namespaces / APIs",
    concurrency_model: "Concurrency", reconnect_policy: "Reconnect", backpressure: "Backpressure", shared_by: "Shared by",
    settles_by: "Settles by", cancellation: "Cancellation", runtime: "Runtime", model_ids: "Models", memory_floor_gb: "Memory floor (GB)",
    loaded_when: "Loaded", unloaded_when: "Unloaded", supplies: "Supplies", configures: "Configures", loads: "Loads",
    wraps: "Wraps", error_mapping: "Errors", purpose: "Purpose", request_shape: "Request", response_shape: "Response",
    idempotent: "Idempotent", streams: "Streams", entry_triggers: "Entry triggers", owns_state_in: "Owns state in",
    state: "State", reacts_to: "Reacts to", conformers: "Conformers"
  };
  function semanticValue(value) {
    const nameOf = (key) => { const id = idByHistoryKey.get(key); const node = id ? interplayNodeById.get(id) : null; return node ? node.label : (PAGE_LABEL.get(key) || key); };
    if (Array.isArray(value)) return value.map((item) => (typeof item === "string" && item.includes(":") ? nameOf(item) : String(item).replace(/_/g, " "))).join(", ") || "—";
    if (typeof value === "boolean") return value ? "yes" : "no";
    if (typeof value === "string") return value.includes(":") && idByHistoryKey.has(value) ? nameOf(value) : value.replace(/_/g, " ");
    return String(value);
  }
  function describedSection(semantic) {
    const section = element("section", "inspector-section described");
    const head = element("h4", "", "Described");
    if (semantic.stale) head.append(element("span", "stale-badge", `stale · files changed since ${String(semantic.source_revision).slice(0, 9)}`));
    section.append(head, element("p", "", semantic.summary));
    const fields = Object.entries(semantic.fields || {});
    if (fields.length) {
      const table = element("dl", "described-table");
      fields.forEach(([name, value]) => {
        table.append(element("dt", "", SEMANTIC_FIELD_LABELS[name] || name.replace(/_/g, " ")));
        table.append(element("dd", "", semanticValue(value)));
      });
      section.append(table);
    }
    if ((semantic.open_questions || []).length) {
      const questions = element("ul", "evidence-list");
      semantic.open_questions.forEach((question) => questions.append(element("li", "", `? ${question}`)));
      section.append(element("p", "described-meta", "Open questions"), questions);
    }
    const evidence = element("ul", "evidence-list");
    (semantic.evidence || []).forEach((site) => { const li = document.createElement("li"); li.append(sourceLink(site)); evidence.append(li); });
    section.append(evidence);
    section.append(element("p", "described-meta", `Written by ${semantic.model} at ${String(semantic.source_revision).slice(0, 9)}; validated against the map on every build.`));
    return section;
  }
  // A state machine as a Mermaid state diagram generated from its extracted
  // transitions, plus the transitions as a table with source links. A transition
  // whose origin the code does not test first starts from "any state".
  function machineMermaid(node) {
    const machine = node.machine || { states: [], transitions: [] };
    const lines = ["stateDiagram-v2"];
    const seenAny = machine.transitions.some((t) => !t.from);
    if (seenAny) lines.push('  state "any state" as anyState');
    if (machine.initial) lines.push(`  [*] --> ${machine.initial}`);
    const seen = new Set();
    machine.transitions.forEach((t) => {
      const froms = t.from && t.from.length ? t.from : ["anyState"];
      froms.forEach((from) => {
        const key = `${from}|${t.to}|${t.function}`;
        if (seen.has(key)) return;
        seen.add(key);
        lines.push(`  ${from} --> ${t.to}: ${mermaidLabel(t.function)}()`);
      });
    });
    return lines.join("\n");
  }
  function machineSection(node) {
    const machine = node.machine || { states: [], transitions: [], dead_states: [] };
    const section = element("section", "inspector-section");
    section.append(element("h4", "", `States (${machine.states.length}) and transitions (${machine.transitions.length})`));
    const diagram = element("div", "flow-diagram");
    diagram.dataset.source = machineMermaid(node);
    diagram.dataset.state = "pending";
    diagram.textContent = diagram.dataset.source;
    section.append(diagram);
    const states = element("p", "described-meta", machine.states.map((s) => s.name + (s.payload ? "(…)" : "")).join(" · "));
    section.append(states);
    if ((machine.dead_states || []).length) section.append(element("p", "described-meta", `Never entered by any transition: ${machine.dead_states.join(", ")}`));
    const list = element("ul", "evidence-list");
    machine.transitions.forEach((t) => {
      const li = document.createElement("li");
      const link = sourceLink({ path: t.path, line: t.line });
      link.textContent = `${(t.from && t.from.length) ? t.from.join(" | ") : "any"} → ${t.to}  ·  ${t.function}()  ·  ${t.path.split("/").pop()}:${t.line}`;
      li.append(link);
      list.append(li);
    });
    section.append(list);
    if (machine.enum_path) {
      const decl = element("p", "described-meta");
      decl.append(document.createTextNode("Enum declared at "), sourceLink({ path: machine.enum_path, line: machine.enum_line || 1 }));
      section.append(decl);
    }
    setTimeout(renderMermaidDiagrams, 0);
    return section;
  }
  function machineLinksSection(ids) {
    const section = element("section", "inspector-section");
    section.append(element("h4", "", `State machine${ids.length === 1 ? "" : "s"}`));
    const list = element("div", "chip-list");
    ids.forEach((id) => {
      const machine = interplayNodeById.get(id);
      if (!machine) return;
      const button = document.createElement("button");
      button.type = "button";
      button.className = "timeline-chip selectable";
      button.textContent = `${machine.label} · ${(machine.machine || {}).states.length} states`;
      button.addEventListener("click", () => selectInterplayNode(id));
      list.append(button);
    });
    section.append(list);
    return section;
  }
  function flowLinksSection(ids) {
    const section = element("section", "inspector-section");
    section.append(element("h4", "", `Appears in ${ids.length} system flow${ids.length === 1 ? "" : "s"}`));
    const list = element("div", "chip-list");
    ids.forEach((id) => {
      const flow = flowById.get(id);
      if (!flow) return;
      const button = document.createElement("button");
      button.type = "button";
      button.className = "timeline-chip selectable";
      button.textContent = flow.title;
      button.addEventListener("click", () => traceFlow(id));
      list.append(button);
    });
    section.append(list);
    return section;
  }
  function traceFlow(id) {
    const flow = flowById.get(id);
    if (!flow) return;
    selectedFlowId = id;
    selectedInterplayId = null;
    renderFlowInspector(flow);
    applyInterplayState();
    renderFlows();
    const workspace = document.getElementById("interplay-workspace");
    if (workspace && workspace.scrollIntoView) workspace.scrollIntoView({ behavior: "smooth", block: "start" });
  }
  function clearFlow() {
    selectedFlowId = null;
    applyInterplayState();
    renderFlows();
  }
  function renderFlowInspector(flow) {
    const inspector = document.getElementById("interplay-inspector");
    if (!inspector) return;
    const container = element("div");
    const close = document.createElement("button");
    close.type = "button";
    close.className = "inspector-close";
    close.setAttribute("aria-label", "Stop tracing");
    close.textContent = "×";
    close.addEventListener("click", clearFlow);
    container.append(close);
    container.style.setProperty("--component-color", INTERPLAY_ROLE_COLORS.interplay || INTERPLAY_ROLE_COLORS.hub);
    container.append(element("span", "inspector-badge", `SYSTEM FLOW · ${flow.status.toUpperCase()}`), element("h3", "", flow.title), element("p", "", flow.summary));
    const nameOf = (key) => { const id = idByHistoryKey.get(key); const node = id ? interplayNodeById.get(id) : null; return node ? node.label : (key.startsWith("page:") ? `${PAGE_LABEL.get(key.slice(5)) || key.slice(5)} (page)` : key); };
    const steps = element("ol", "inspector-steps");
    flow.steps.forEach((step) => {
      const li = document.createElement("li");
      li.append(element("span", "step-path", `${nameOf(step.from)} → ${step.relation.replace(/-/g, " ")} → ${nameOf(step.to)}`));
      if (step.note) li.append(element("span", "step-note", step.note));
      steps.append(li);
    });
    const section = element("section", "inspector-section");
    section.append(element("h4", "", `Steps (${flow.steps.length})`), steps);
    container.append(section);
    if (flow.trigger) {
      const trigger = triggers.find((t) => t.id === flow.trigger);
      if (trigger) container.append(element("p", "described-meta", `Starts from ${trigger.api} in ${trigger.view || "?"} · ${trigger.method}() · ${PAGE_LABEL.get(trigger.page) || trigger.page}`));
    }
    if (flow.outcome) container.append(element("p", "", flow.outcome));
    if ((flow.problems || []).length) {
      const problems = element("ul", "evidence-list");
      flow.problems.forEach((problem) => problems.append(element("li", "", problem)));
      container.append(element("p", "described-meta", "Broken: the map no longer has these edges"), problems);
    }
    const evidence = element("ul", "evidence-list");
    (flow.evidence || []).forEach((site) => { const li = document.createElement("li"); li.append(sourceLink(site)); evidence.append(li); });
    container.append(evidence, element("p", "described-meta", `Written by ${flow.model} at ${String(flow.source_revision).slice(0, 9)}; every step is checked against the map on every build.`));
    inspector.replaceChildren(container);
  }
  // The flows: the user's journeys, rendered inline as Mermaid sequence diagrams
  // beneath the invariants. Participants are the nodes a flow's steps touch;
  // messages are the steps; the user (or the App at launch) is the first
  // participant when a flow starts from a trigger. Each diagram is generated from
  // the validated steps, so it can only show wiring the map has. Mermaid itself
  // is loaded by index.html; until it arrives (or if it never does) the diagram's
  // source is shown as text.
  function mermaidLabel(text) {
    return String(text).replace(/[;:#<>"`]/g, " ").replace(/\s+/g, " ").trim();
  }
  function flowMermaid(flow) {
    const participants = new Map();
    const alias = (key) => {
      if (!participants.has(key)) {
        let label;
        if (key.startsWith("page:")) {
          const pageId = key.slice(5);
          label = pageId === "launch" ? "App entry points" : `User on ${PAGE_LABEL.get(pageId) || pageId}`;
        } else {
          const id = idByHistoryKey.get(key);
          const node = id ? interplayNodeById.get(id) : null;
          label = node ? node.label : key.split(":").pop();
        }
        participants.set(key, { alias: `p${participants.size}`, label });
      }
      return participants.get(key).alias;
    };
    const lines = ["sequenceDiagram", "  autonumber"];
    const messages = [];
    const trigger = flow.trigger ? triggers.find((t) => t.id === flow.trigger) : null;
    flow.steps.forEach((step) => {
      const from = alias(step.from);
      const to = alias(step.to);
      const arrow = MERMAID_ASYNC.has(step.relation) ? "-->>" : "->>";
      let text = step.relation.replace(/-/g, " ");
      if (step.relation === "triggers" && trigger) text = `${trigger.api} · ${trigger.method}()${trigger.view ? ` in ${trigger.view}` : ""}`;
      if (step.note) text += ` · ${step.note}`;
      messages.push(`  ${from}${arrow}${to}: ${mermaidLabel(text)}`);
    });
    participants.forEach(({ alias: name, label }) => lines.push(`  participant ${name} as ${mermaidLabel(label)}`));
    return lines.concat(messages).join("\n");
  }
  async function renderMermaidDiagrams() {
    const mermaid = window.__mermaid;
    if (!mermaid) return;
    // Only blocks the reader can see: a diagram inside a collapsed flow waits for
    // its expansion (the toggle handler calls back here), so the page never pays
    // for diagrams nobody opened.
    const blocks = Array.from(document.querySelectorAll(".flow-diagram[data-state='pending']"))
      .filter((block) => { const details = block.closest("details"); return !details || details.open; });
    for (const block of blocks) {
      block.dataset.state = "rendering";
      try {
        const { svg } = await mermaid.render(`flow-svg-${mermaidRenderSeq += 1}`, block.dataset.source);
        block.innerHTML = svg; // Mermaid's own SVG output; the source was generated here from validated steps
        block.dataset.state = "rendered";
      } catch (_error) {
        block.dataset.state = "failed";
        block.textContent = block.dataset.source;
      }
    }
  }
  window.addEventListener("mermaid-ready", renderMermaidDiagrams);
  function renderFlows() {
    const host = document.getElementById("flows-list");
    const lede = document.getElementById("flows-lede");
    if (!host || !lede) return;
    if (!flows.length) {
      lede.textContent = "No system flows are declared yet. They are written by scripts/architecture_agent.py --flows, one journey at a time, and validated step by step against this map.";
      host.replaceChildren();
      return;
    }
    const traceable = flows.filter((flow) => flow.status === "traceable").length;
    lede.textContent = `${flows.length} flows across three journeys, ${traceable} tracing fully over edges on this map. Each is written by a model from the graph and validated step by step on every build; the diagrams are generated from those steps, so they can only show wiring the map has.`;
    const groups = new Map();
    flows.forEach((flow) => {
      const groupKey = flow.journey === "page" ? `page:${flow.page}` : (flow.journey || "other");
      if (!groups.has(groupKey)) groups.set(groupKey, []);
      groups.get(groupKey).push(flow);
    });
    const sections = [];
    let pageIndex = 0;
    groups.forEach((list, groupKey) => {
      const section = element("section", "journey");
      let title;
      if (groupKey.startsWith("page:")) {
        pageIndex += 1;
        title = `${JOURNEY_TITLES.page}${pageIndex === 1 ? "" : ""} · ${PAGE_LABEL.get(groupKey.slice(5)) || groupKey.slice(5)}`;
      } else {
        title = JOURNEY_TITLES[groupKey] || groupKey;
      }
      section.append(element("h4", "journey-title", title));
      list.forEach((flow) => {
        // Collapsed by default: the header and one-line summary are the disclosure;
        // the diagram and the numbered procedure render on first expansion.
        const article = element("details", `flow${flow.id === selectedFlowId ? " tracing" : ""}`);
        article.id = `flow-${flow.id}`;
        article.open = openFlows.has(flow.id) || flow.id === selectedFlowId;
        const disclosure = element("summary", "flow-disclosure");
        const head = element("div", "flow-head");
        head.append(element("h5", "", flow.title));
        if (flow.interaction) head.append(element("span", "flow-interaction", flow.interaction));
        if (flow.status !== "traceable") head.append(element("span", "invariant-status violated", "BROKEN"));
        head.append(element("span", "flow-steps-count", `${flow.steps.length} steps`));
        disclosure.append(head, element("p", "flow-summary", flow.summary));
        article.append(disclosure);
        const body = element("div", "flow-body");
        article.append(body);
        article.addEventListener("toggle", () => {
          if (article.open) { openFlows.add(flow.id); renderMermaidDiagrams(); } else openFlows.delete(flow.id);
        });
        const diagram = element("div", "flow-diagram");
        diagram.dataset.source = flowMermaid(flow);
        diagram.dataset.state = "pending";
        diagram.textContent = diagram.dataset.source;
        body.append(diagram);
        // The same steps as a numbered procedure: who does what to whom, and what it
        // means for the user. Numbers match the diagram's.
        const trigger = flow.trigger ? triggers.find((t) => t.id === flow.trigger) : null;
        const nameOf = (key) => {
          if (key.startsWith("page:")) return key === "page:launch" ? "App entry points" : `User on ${PAGE_LABEL.get(key.slice(5)) || key.slice(5)}`;
          const id = idByHistoryKey.get(key);
          const node = id ? interplayNodeById.get(id) : null;
          return node ? node.label : key.split(":").pop();
        };
        const procedure = element("ol", "flow-procedure");
        flow.steps.forEach((step) => {
          const li = document.createElement("li");
          let verb = step.relation.replace(/-/g, " ");
          if (step.relation === "triggers" && trigger) verb = `${trigger.api} · ${trigger.method}()${trigger.view ? ` in ${trigger.view}` : ""}`;
          li.append(element("strong", "", nameOf(step.from)), document.createTextNode(` ${verb} `), element("strong", "", nameOf(step.to)));
          if (step.note) li.append(element("span", "step-note", step.note));
          procedure.append(li);
        });
        body.append(procedure);
        if (flow.outcome) body.append(element("p", "flow-outcome", `Outcome: ${flow.outcome}`));
        const meta = element("p", "flow-meta");
        meta.append(document.createTextNode(`${flow.steps.length} steps · written by ${flow.model} at ${String(flow.source_revision).slice(0, 9)} · `));
        const trace = document.createElement("a");
        trace.href = "#systemmap";
        trace.className = "flow-trace";
        trace.textContent = flow.id === selectedFlowId ? "stop tracing on the map" : "trace on the map";
        trace.addEventListener("click", (event) => { event.preventDefault(); if (flow.id === selectedFlowId) clearFlow(); else traceFlow(flow.id); });
        meta.append(trace);
        body.append(meta);
        section.append(article);
      });
      sections.push(section);
    });
    host.replaceChildren(...sections);
    renderMermaidDiagrams();
  }

  // The invariants, as text at the foot of the System map: what each pins, why it
  // is declared, its status and how much the last build checked. Reading them
  // never touches the graph.
  function renderInvariants() {
    const list = document.getElementById("invariants-list");
    const lede = document.getElementById("invariants-lede");
    if (!list || !lede) return;
    const holding = invariants.filter((item) => item.status === "holds").length;
    lede.textContent = `${holding} of ${invariants.length} declared constructions hold on this build. Each is declared in architecture/interplay/invariants.json with a reason and checked by scripts/build_architecture.py; a violation fails the build rather than redrawing the map.`;
    list.replaceChildren(...invariants.map((item) => {
      const li = element("li", "invariant");
      const head = element("div", "invariant-head");
      head.append(
        element("span", `invariant-status ${item.status}`, item.status === "holds" ? "HOLDS" : "VIOLATED"),
        element("strong", "", item.id),
        element("span", "invariant-meta", `${item.kind.replace(/_/g, " ")} · ${item.checked} checked`)
      );
      li.append(head, element("p", "", INVARIANT_KIND_TEXT[item.kind] || item.kind), element("p", "invariant-why", item.why));
      return li;
    }));
  }

  function selectInterplayNode(nodeId) {
    selectedInterplayId = nodeId;
    selectedFlowId = null;
    renderInterplayInspector(interplayNodeById.get(nodeId));
    applyInterplayState();
  }

  function applyInterplayState() {
    const flow = selectedFlowId ? flowById.get(selectedFlowId) : null;
    const focusing = Boolean(selectedInterplayId || flow);
    const inspectorPanel = document.getElementById("interplay-inspector");
    if (inspectorPanel) inspectorPanel.hidden = !focusing;
    const workspace = document.getElementById("interplay-workspace");
    if (workspace) workspace.classList.toggle("has-inspector", focusing);
    const input = document.getElementById("interplay-search");
    const query = input ? input.value.trim().toLowerCase() : "";
    // A selection is a claim about a node the reader can see; sliding past the
    // commit it was added in would leave the claim pointing at nothing.
    if (selectedInterplayId && !timelineNodeState(interplayNodeById.get(selectedInterplayId)).live) {
      selectedInterplayId = null;
      if (inspectorPanel) inspectorPanel.hidden = true;
      if (workspace) workspace.classList.remove("has-inspector");
    }
    const connected = new Set();
    const activeKeys = selectedInterplayId ? flowEdgeKeys(selectedInterplayId) : new Set();
    if (selectedInterplayId) {
      connected.add(selectedInterplayId);
      interplay.edges.forEach((edge) => {
        if (activeKeys.has(`${edge.source}|${edge.target}|${edge.relation}`)) { connected.add(edge.source); connected.add(edge.target); }
      });
    }
    // A flow's steps are edges named by history key, which is exactly what every
    // drawn edge carries in data-hkey; the step number replaces the relation label.
    const flowSteps = new Map();
    if (flow) {
      flow.steps.forEach((step, index) => {
        flowSteps.set(`${step.from}|${step.to}|${step.relation}`, index + 1);
        [step.from, step.to].forEach((key) => { const id = idByHistoryKey.get(key); if (id) connected.add(id); });
      });
    }
    document.querySelectorAll(".interplay-node").forEach((element) => {
      const node = interplayNodeById.get(element.dataset.node);
      if (!node) return;
      const searchable = [node.label, node.kind, node.sub_kind, node.owner_type, node.component, node.overlay_prose, node.description, node.protocol, node.store && node.store.persistence.join(" ")]
        .concat(Array.isArray(node.methods) ? node.methods.map((entry) => entry.method) : Object.keys(node.methods || {}))
        .concat(node.namespaces || [])
        .filter(Boolean).join(" ").toLowerCase();
      const queryMismatch = query && !searchable.includes(query);
      const selectionMismatch = focusing && !connected.has(node.id);
      element.classList.toggle("selected", node.id === selectedInterplayId);
      element.classList.toggle("dimmed", Boolean(queryMismatch || selectionMismatch));
      // What the reader's position lacks is absent; what this commit removed is ghosted.
      const when = timelineNodeState(node);
      element.classList.toggle("absent", !when.live && !when.gone);
      element.classList.toggle("ghost", when.gone);
    });
    document.querySelectorAll(".interplay-edge, .interplay-edge-label").forEach((edge) => {
      const direct = selectedInterplayId && (edge.dataset.source === selectedInterplayId || edge.dataset.target === selectedInterplayId);
      const step = flowSteps.get(edge.dataset.hkey);
      const active = focusing && (Boolean(direct) || activeKeys.has(`${edge.dataset.source}|${edge.dataset.target}|${edge.dataset.relation}`) || Boolean(step));
      edge.classList.toggle("active", active);
      if (edge.classList.contains("interplay-edge-label")) {
        if (!edge.dataset.label) edge.dataset.label = edge.textContent;
        edge.textContent = step ? `${step}. ${edge.dataset.relation.replace(/-/g, " ")}` : edge.dataset.label;
      }
      const when = timelineEdgeState(edge);
      edge.classList.toggle("absent", !when.live && !when.gone);
      edge.classList.toggle("ghost", when.gone && !edge.classList.contains("interplay-edge-label"));
      edge.classList.toggle("dimmed", Boolean(focusing && !active));
    });
  }

  // ---- The history slider ----------------------------------------------------
  // Whether a drawn thing is part of the picture at the reader's position. Untouched,
  // that is the head revision: historical-only entities are absent. The transport
  // container is virtual (built here, never in a snapshot) and follows its members.
  function travelling() {
    return Boolean(TL && TL.engaged);
  }
  function timelineNodeState(node) {
    if (!node || node.kind === "transport") return { live: true, gone: false };
    if (!travelling()) return { live: !node.hist, gone: false };
    const key = historyKeyOf(node);
    return { live: TL.live(key), gone: TL.gone(key) };
  }
  function timelineEdgeState(element) {
    const key = element.dataset.hkey;
    if (!key) return { live: true, gone: false };
    if (!travelling()) return { live: element.dataset.hist !== "true", gone: false };
    return { live: TL.liveEdge(key), gone: TL.goneEdge(key) };
  }
  const TIMELINE_PLAY_MS = 140; // ~7 points a second: fast enough to read a shape moving, slow enough to see a commit
  let timelineTimer = null;
  function renderTimeline() {
    const bar = document.getElementById("timeline");
    if (!bar) return;
    if (!TL) { bar.hidden = true; return; }
    bar.hidden = false;
    const range = document.getElementById("timeline-range");
    range.max = String(TL.last);
    range.value = String(TL.i);
    // The sparkline is the node count at every point, so the reader sees where the
    // shape grew before dragging there.
    const spark = document.getElementById("timeline-spark");
    if (spark) {
      spark.textContent = "";
      const counts = HISTORY.snapshots.map((point) => point.counts.nodes);
      const peak = Math.max(1, ...counts);
      const points = counts.map((count, index) => `${((index / Math.max(1, counts.length - 1)) * 100).toFixed(2)},${(100 - (count / peak) * 100).toFixed(2)}`);
      spark.setAttribute("viewBox", "0 0 100 100");
      spark.setAttribute("preserveAspectRatio", "none");
      spark.append(svgElement("polyline", { points: points.join(" ") }));
    }
    timelineSync();
  }
  function timelineGo(n) {
    TL.go(n, true);
    applyInterplayState();
    timelineSync();
  }
  function timelinePlay(on) {
    if (timelineTimer) { clearInterval(timelineTimer); timelineTimer = null; }
    if (on) {
      if (TL.i >= TL.last) TL.go(0, true);
      timelineTimer = setInterval(() => {
        if (TL.i >= TL.last) { timelinePlay(false); timelineSync(); return; }
        timelineGo(TL.i + 1);
      }, TIMELINE_PLAY_MS);
    }
    const button = document.getElementById("timeline-play");
    if (button) {
      button.textContent = on ? "❙❙" : "▶";
      button.title = on ? "Pause" : "Play the history forward";
      button.setAttribute("aria-pressed", String(on));
    }
  }
  function timelineSync() {
    if (!TL) return;
    const point = TL.point();
    const previous = TL.prev();
    const range = document.getElementById("timeline-range");
    if (range) range.value = String(TL.i);
    const scroll = document.getElementById("interplay-scroll");
    if (scroll) scroll.classList.toggle("travelling", TL.engaged && TL.i < TL.last);
    const set = (id, text) => { const node = document.getElementById(id); if (node) node.textContent = text; };
    set("timeline-date", point.date);
    set("timeline-pos", `commit ${TL.i + 1} of ${TL.count}`);
    const rev = document.getElementById("timeline-rev");
    if (rev) {
      rev.textContent = point.rev.slice(0, 9);
      rev.href = `https://github.com/${model.repository}/commit/${point.rev}`;
    }
    set("timeline-counts", `${point.counts.nodes} nodes · ${point.counts.edges} edges`);
    const delta = document.getElementById("timeline-delta");
    if (delta) {
      delta.textContent = "";
      if (previous) {
        const diff = (now, was, noun) => {
          const n = now - was;
          if (!n) return;
          delta.append(element("span", n > 0 ? "up" : "down", `${n > 0 ? "+" : "−"}${Math.abs(n)} ${noun}`));
        };
        diff(point.counts.nodes, previous.counts.nodes, "nodes");
        diff(point.counts.edges, previous.counts.edges, "edges");
      }
    }
    set("timeline-subject", point.subject);
    timelineDiff();
    timelineNote(point);
  }
  // The commit's own diff as chips. A node that survived to the head revision is
  // selectable; one that did not says so rather than pretending to be.
  const TIMELINE_CHIPS = 14;
  function timelineDiff() {
    const host = document.getElementById("timeline-diff");
    if (!host) return;
    host.textContent = "";
    if (!TL.engaged) return;
    const added = TL.added();
    const removed = TL.removed();
    const edges = TL.edgeDelta();
    if (!added.length && !removed.length && !edges.added && !edges.removed) {
      host.append(element("span", "timeline-quiet", "This commit changed the app without changing the shape of the map."));
      return;
    }
    let room = TIMELINE_CHIPS;
    const put = (meta, sign) => {
      if (room-- <= 0 || meta.kind === "page") return;
      const chip = element("span", `timeline-chip ${sign === "+" ? "add" : "del"}`, `${sign} ${meta.label || meta.k}`);
      const headId = idByHistoryKey.get(meta.k);
      const headNode = headId ? headNodeById.get(headId) : null;
      if (headNode) {
        chip.classList.add("selectable");
        chip.title = `${sign === "+" ? "Added" : "Removed"} by this commit. Click to select it on the map.`;
        chip.addEventListener("click", () => { TL.disengage(); timelinePlay(false); selectInterplayNode(headNode.id); timelineSync(); });
      } else {
        chip.classList.add("dead");
        chip.title = `${sign === "+" ? "Added" : "Removed"} by this commit. Not part of the head revision.`;
      }
      host.append(chip);
    };
    removed.forEach((meta) => put(meta, "−"));
    added.forEach((meta) => put(meta, "+"));
    const over = added.length + removed.length - TIMELINE_CHIPS;
    if (over > 0) host.append(element("span", "timeline-quiet", `+${over} more`));
    if (edges.added || edges.removed) {
      host.append(element("span", "timeline-quiet", `${edges.removed ? `−${edges.removed} ` : ""}${edges.added ? `+${edges.added} ` : ""}edges`));
    }
  }
  // What a reader has to be told rather than shown: the point is drawn with today's
  // config and overlay, the inspector describes the head, and where the axis has holes.
  function timelineNote(point) {
    const note = document.getElementById("timeline-note");
    if (!note) return;
    const parts = [];
    const first = HISTORY.snapshots[0];
    const last = HISTORY.snapshots[TL.last];
    if (!TL.engaged) {
      parts.push(`Drag to walk ${TL.count} commits of history (${first.date} → ${last.date}). The graph moves; the inspector and the other views always describe the head revision.`);
    } else {
      parts.push("Derived by running today's extractor at this commit with today's config and overlay.");
      const fidelity = point.fidelity || {};
      const violated = (point.invariants && point.invariants.violated) || [];
      if (fidelity.externals_unmatched) parts.push(`${fidelity.externals_unmatched} declared external system${fidelity.externals_unmatched === 1 ? "" : "s"} matched nothing here.`);
      if (fidelity.page_roots_missing) parts.push(`${fidelity.page_roots_missing} page root view${fidelity.page_roots_missing === 1 ? " did" : "s did"} not exist yet.`);
      if (violated.length) parts.push(`${violated.length} invariant${violated.length === 1 ? "" : "s"} did not hold: ${violated.join(", ")}.`);
      if (TL.i < TL.last) parts.push("Dashed amber is what this commit removed.");
    }
    if (TL.failed) {
      parts.push(`${TL.failed} commit${TL.failed === 1 ? "" : "s"} in this range could not be processed by today's extractor and ${TL.failed === 1 ? "is" : "are"} not on the axis; what ${TL.failed === 1 ? "it" : "they"} changed shows up on the next point.`);
    }
    if (last.tree !== model.source_tree_sha256) {
      parts.push("The newest point was derived from a different source tree than this map, so the last point and the map may differ.");
    }
    note.textContent = parts.join(" ");
  }
  function wireTimeline() {
    const bar = document.getElementById("timeline");
    if (!bar || !TL) return;
    const range = document.getElementById("timeline-range");
    if (range) range.addEventListener("input", () => { timelinePlay(false); timelineGo(Number(range.value)); });
    const play = document.getElementById("timeline-play");
    if (play) play.addEventListener("click", () => timelinePlay(!timelineTimer));
    const now = document.getElementById("timeline-now");
    if (now) {
      now.addEventListener("click", () => {
        timelinePlay(false);
        TL.disengage();
        applyInterplayState();
        timelineSync();
      });
    }
    const toggle = document.getElementById("timeline-toggle");
    if (toggle) {
      const key = "portal.architecture.timelineCollapsed";
      const apply = (collapsed) => {
        bar.classList.toggle("collapsed", collapsed);
        toggle.setAttribute("aria-expanded", String(!collapsed));
      };
      let collapsed = false;
      try { collapsed = window.localStorage.getItem(key) === "1"; } catch (_error) { collapsed = false; }
      apply(collapsed);
      toggle.addEventListener("click", () => {
        collapsed = !bar.classList.contains("collapsed");
        apply(collapsed);
        try { window.localStorage.setItem(key, collapsed ? "1" : "0"); } catch (_error) { /* storage unavailable */ }
      });
    }
  }


  function renderInterplayInspector(node) {
    const inspector = document.getElementById("interplay-inspector");
    if (!inspector || !node) return;
    const role = interplayNodeRole(node);
    const container = element("div");
    const close = document.createElement("button");
    close.type = "button";
    close.className = "inspector-close";
    close.setAttribute("aria-label", "Close inspector");
    close.textContent = "×";
    close.addEventListener("click", () => {
      selectedInterplayId = null;
      applyInterplayState();
    });
    container.append(close);
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

    if (node.semantic) container.append(describedSection(node.semantic));
    if (node.kind === "machine") container.append(machineSection(node));
    if ((node.machines || []).length) container.append(machineLinksSection(node.machines));
    if ((node.flows || []).length) container.append(flowLinksSection(node.flows));

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
          const link = sourceLink({ path: entry.path || node.path, line: entry.line });
          const stem = (entry.path || node.path || "").split("/").pop().replace(/\.swift$/, "");
          link.textContent = `${entry.method}  ·  ${stem}:${entry.line}`;
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

    const mine = triggersFor(node);
    if (mine.length && ["caller", "subscriber", "hub", "owner", "store", "provider"].includes(node.kind)) {
      const section = element("section", "inspector-section");
      section.append(element("h4", "", `Triggers (${mine.length}) · ${triggerSummary(mine)}`));
      const list = element("ul", "evidence-list");
      mine.slice(0, 40).forEach((trigger) => {
        const li = document.createElement("li");
        const link = sourceLink({ path: trigger.path, line: trigger.line });
        const reaches = trigger.namespaces.length ? `  →  ${trigger.namespaces.join(", ")}` : "";
        link.textContent = `${trigger.api} in ${trigger.view || "?"}  ·  ${trigger.method}()${reaches}  ·  ${PAGE_LABEL.get(trigger.page) || "unplaced"}:${trigger.line}`;
        li.append(link);
        list.append(li);
      });
      section.append(list);
      container.append(section);
    }

    if ((node.configures || []).length) {
      const section = element("section", "inspector-section");
      section.append(element("h4", "", "Configures the transport"));
      const list = element("ul", "evidence-list");
      node.configures.slice(0, 12).forEach((entry) => {
        const li = document.createElement("li");
        const link = sourceLink({ path: entry.path, line: entry.line });
        link.textContent = `${entry.via || "?"}.${entry.method}(…: ${node.label})  ·  ${entry.path}:${entry.line}`;
        li.append(link);
        list.append(li);
      });
      section.append(list);
      container.append(section);
    }

    if (node.store) {
      const section = element("section", "inspector-section");
      section.append(element("h4", "", "Persistence"));
      const persistence = (node.store.persistence || []).join(", ");
      const artifacts = (node.store.artifacts || []).join(", ");
      section.append(element("p", "", `${persistence === "unobserved" ? "In-memory (no persistence API observed in the type, its extensions, or namesake helpers)" : `Mechanism: ${persistence}`}${artifacts ? ` · artifacts: ${artifacts}` : ""}`));
      const list = element("ul", "evidence-list");
      const li = document.createElement("li");
      li.append(sourceLink({ path: node.store.path, line: node.store.line || 1 }));
      list.append(li);
      section.append(list);
      container.append(section);
    }

    if (isBusSpine(node)) {
      const taps = interplay.edges
        .filter((edge) => edge.source === node.id && edge.relation === "notifies")
        .map((edge) => interplayNodeById.get(edge.target))
        .filter(Boolean)
        .sort((left, right) => left.label.localeCompare(right.label));
      const section = element("section", "inspector-section");
      section.append(element("h4", "", `Subscribers (${taps.length})`));
      const list = element("ul", "evidence-list");
      taps.forEach((tap) => {
        const li = document.createElement("li");
        const sub = tap.subscription || {};
        const link = sourceLink({ path: sub.path || tap.path, line: sub.line || tap.line || 1 });
        link.textContent = `${tap.label}  ·  ${PAGE_LABEL.get(tap.page) || "shared"}  ·  ${subscriptionLabel(tap)}`;
        li.append(link);
        list.append(li);
      });
      section.append(list);
      container.append(section);
    }

    if ((node.kind === "subscriber" || node.kind === "hub") && node.subscription) {
      const section = element("section", "inspector-section");
      section.append(element("h4", "", "Event bus binding"));
      const li = document.createElement("li");
      const link = sourceLink({ path: node.subscription.path || node.path, line: node.subscription.line || node.line || 1 });
      link.textContent = `${subscriptionLabel(node)}  ·  :${node.subscription.line}`;
      const list = element("ul", "evidence-list");
      list.append(li); li.append(link);
      section.append(list);
      container.append(section);
    }

    if (node.kind === "owner") {
      const ops = interplay.nodes
        .filter((candidate) => candidate.kind === "operation" && candidate.owner_type === node.label && candidate.component === node.component)
        .sort((left, right) => (left.line || 0) - (right.line || 0));
      if (ops.length) {
        const section = element("section", "inspector-section");
        section.append(element("h4", "", `Lifecycle operations (${ops.length})`));
        const list = element("ul", "evidence-list");
        ops.forEach((op) => {
          const li = document.createElement("li");
          const link = sourceLink({ path: op.path, line: op.line || 1 });
          link.textContent = `${String(op.sub_kind || op.kind).replace(/_/g, " ")}  ·  ${op.label}${op.detached_off_main ? "  ·  Task.detached" : ""}  ·  :${op.line}`;
          li.append(link);
          list.append(li);
        });
        section.append(list);
        container.append(section);
      }
    }

    if (node.kind === "section" && Array.isArray(node.steps) && node.steps.length) {
      const section = element("section", "inspector-section");
      section.append(element("h4", "", `Steps in source order (${node.steps.length})`));
      const list = element("ul", "evidence-list");
      node.steps.forEach((step, index) => {
        const li = document.createElement("li");
        const link = sourceLink({ path: node.path, line: step.line });
        link.textContent = `${index + 1}. ${step.kind.replace(/_/g, " ")}  ·  ${step.label}${step.guarded ? "  ·  under lock" : ""}  ·  :${step.line}`;
        li.append(link);
        list.append(li);
      });
      section.append(list);
      container.append(section);
    }

    if (node.kind === "owner" && (node.roles || []).includes("transport")) {
      const holders = interplay.edges
        .filter((edge) => edge.target === node.id && edge.relation === "holds")
        .map((edge) => interplayNodeById.get(edge.source))
        .filter(Boolean)
        .sort((left, right) => left.label.localeCompare(right.label));
      if (holders.length) {
        const section = element("section", "inspector-section");
        section.append(element("h4", "", `Held by (${holders.length} surfaces, concurrent access)`));
        const chips = element("div", "chip-list");
        holders.forEach((holder) => chips.append(element("span", "chip", `${holder.label} · ${PAGE_LABEL.get(holder.page) || "shared"}`)));
        section.append(chips);
        container.append(section);
      }
    }

    if (node.kind === "external" && Array.isArray(node.usage) && node.usage.length) {
      const section = element("section", "inspector-section");
      section.append(element("h4", "", `Used by components (${node.usage.length})`));
      const chips = element("div", "chip-list");
      node.usage.forEach((usage) => chips.append(element("span", "chip", `${componentLabel(usage.component)} · ${usage.hit_count}`)));
      section.append(chips);
      container.append(section);
    }

    if ((node.kind === "caller" || node.kind === "client") && Array.isArray(node.namespaces) && node.namespaces.length) {
      const section = element("section", "inspector-section");
      const verb = node.kind === "client" ? "Implements" : "Invokes";
      section.append(element("h4", "", `${verb} (${node.namespaces.length})`));
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
    if (node.kind === "external") {
      const links = interplay.edges.filter((edge) => edge.target === node.id && edge.class === "boundary").length;
      return [[node.hit_count, "Hits"], [node.file_count, "Files"], [links, "Links"]];
    }
    if (node.kind === "endpoint") {
      const callers = interplay.edges.filter((edge) => edge.target === node.id && edge.relation === "invokes").length;
      const noun = node.protocol === "jsonrpc" ? "Methods" : "Routes";
      return [[node.method_count, noun], [callers, "Callers"], [node.protocol === "jsonrpc" ? "JSON-RPC" : "REST", "Protocol"]];
    }
    if (node.kind === "caller") {
      return [[(node.namespaces || []).length, "Namespaces"], [componentLabel(node.component), "Surface"]];
    }
    if (node.kind === "provider") {
      return [[(node.loads || []).length, "Loads in init"], [(node.configures || []).length, "Configures"], [componentLabel(node.component), "Owner"]];
    }
    if (node.kind === "machine") {
      const machine = node.machine || { states: [], transitions: [], dead_states: [] };
      return [[machine.states.length, "States"], [machine.transitions.length, "Transitions"], [machine.dead_states.length, "Never entered"]];
    }
    if (node.kind === "client") {
      const endpoints = interplay.edges.filter((edge) => edge.source === node.id && edge.relation === "implements").length;
      return [[(node.namespaces || []).length, "Namespaces"], [endpoints, "Endpoints"], [node.owner_type, "Extends"]];
    }
    if (node.kind === "section") {
      const guarded = (node.steps || []).filter((step) => step.guarded).length;
      return [[(node.steps || []).length, "Steps"], [guarded, "Under lock"], [(node.lock_labels || []).join(", ") || "—", "Lock"]];
    }
    if (node.kind === "owner" && (node.roles || []).includes("transport")) {
      const holders = interplay.edges.filter((edge) => edge.target === node.id && edge.relation === "holds").length;
      return [[(node.roles || []).length, "Roles"], [holders, "Held by"]];
    }
    if (node.sub_kind === "event_bus") return [[interplayBusSubscriberCount(node), "Subscribers"]];
    if (node.kind === "owner") return [[(node.roles || []).length, "Roles"]];
    return [];
  }

  function interplayInspectorSummary(node) {
    if (node.kind === "external") {
      const protocol = node.protocol ? ` Protocol: ${node.protocol}.` : "";
      return `${node.description}${protocol} The description is specified in architecture/config.json; the links, files and hit counts are observed from source signatures.`;
    }
    if (node.kind === "section") {
      const sequence = (node.steps || []).map((step) => step.kind.replace(/_/g, " ")).join(" → ");
      return `${node.owner_type}.${node.label}(): a lock-guarded critical section over ${(node.guarded_resources || []).join(", ") || "no shared resource"}. Steps in source order: ${sequence}. Source order is not a claim about runtime interleaving.`;
    }
    if (node.kind === "store") {
      const persistence = (node.store && node.store.persistence) || [];
      return persistence[0] === "unobserved"
        ? `${node.label} is an in-memory store: a construction holding state for the app's lifetime with no persistence API observed.`
        : `${node.label} is a data store persisting through ${persistence.join(" and ")}.`;
    }
    if (node.kind === "client") {
      return `The ${node.label}.swift extension of ${node.owner_type}: the file that implements the ${(node.namespaces || []).join(", ")} namespace call sites. Namespace boxes reach the core transport through it.`;
    }
    if (node.kind === "machine") {
      const machine = node.machine || {};
      const unknown = machine.unknown_from || 0;
      return `${node.owner_type}'s lifecycle state: the stored property ${machine.property} typed as the ${machine.enum} enum${machine.initial ? `, starting as ${machine.initial}` : ""}. Every transition below is an assignment of a case in the source, attributed to the function that performs it; ${unknown ? `${unknown} of them leave a state the code does not test first, so their origin is drawn as "any state"` : "each leaves a state the code tests first"}.`;
    }
    if (node.kind === "provider") {
      const via = (node.configures || [])[0];
      return `Constructed by the App entry points at launch, before any page exists. Its initialiser reads ${(node.loads || []).join(", ") || "no store"}${via ? `, and it is handed to ${via.via}.${via.method}() to configure what the transport connects with` : ""}. It is not a page surface: it holds no transport and invokes no namespace.`;
    }
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
    if (node.kind === "transport") {
      const core = interplayNodeById.get(node.core_id) || {};
      const holders = interplay.edges.filter((edge) => edge.target === node.core_id && edge.relation === "holds").length;
      const bus = interplayNodeById.get(node.bus_id);
      return `One in-memory construction with two legs. The request leg is ${core.label}: every page holds it (${holders} surfaces) and every call rides its pool, lock and socket; click it to expand what it owns. The push leg is the event stream: everything the gateway pushes is posted onto it once and read by ${bus ? interplayBusSubscriberCount(bus) : 0} subscribers in their pages.`;
    }
    if (node.sub_kind === "event_bus") {
      return `The push leg of the transport. Every server-initiated event the core parses is posted onto this Combine subject once, declared by the ${node.owner_type} seam, and read by ${interplayBusSubscriberCount(node)} subscribers in their pages regardless of which page's call, if any, provoked it. It hooks into no method: it is written to and read from. Each tap below records how the subscriber schedules delivery.`;
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

  function boundaryComponentLabel(componentId) {
    return componentById.get(componentId)?.label || componentId || "unassigned";
  }

  function renderExternals() {
    const container = document.getElementById("externals-content");
    const systems = [...externals.systems].sort((left, right) =>
      String(left.category).localeCompare(String(right.category)) || String(left.label).localeCompare(String(right.label))
    );
    if (!systems.length) {
      container.replaceChildren(emptyState("No external systems are declared in architecture/config.json."));
      return;
    }
    const grouped = new Map();
    systems.forEach((system) => {
      if (!grouped.has(system.category)) grouped.set(system.category, []);
      grouped.get(system.category).push(system);
    });
    const sections = [...grouped.entries()].map(([category, items]) => {
      const section = behaviorGroup(EXTERNAL_CATEGORY_LABELS[category] || category, `${items.length} system(s)`);
      const list = element("div", "behavior-list");
      items.forEach((system) => list.append(externalCard(system)));
      section.append(list);
      return section;
    });
    container.replaceChildren(...sections);
  }

  function externalCard(system) {
    const card = element("article", "behavior-row");
    card.append(element("h4", "", system.label));
    const meta = element("p", "behavior-meta");
    meta.textContent = [
      system.protocol,
      `${system.hit_count} hit(s) in ${system.file_count} file(s)`,
      system.component && `graph node ${boundaryComponentLabel(system.component)}`,
      "swift.boundary.external_signature"
    ].filter(Boolean).join(" · ");
    card.append(meta);
    card.append(element("p", "derivation", `${system.description} Description is specified in config; usage below is observed.`));
    const used = element("div", "chip-list");
    (system.usage || []).forEach((usage) => {
      used.append(element("span", "chip", `${boundaryComponentLabel(usage.component)} · ${usage.hit_count}`));
    });
    card.append(used);
    const list = element("ul", "evidence-list");
    (system.usage || []).flatMap((usage) => (usage.evidence || []).slice(0, 3)).slice(0, 12).forEach((evidence) => {
      const item = document.createElement("li");
      item.append(sourceLink(evidence), element("span", "", ` ${evidence.excerpt || ""}`));
      list.append(item);
    });
    card.append(list);
    return card;
  }

  function renderStores() {
    const container = document.getElementById("stores-content");
    const items = [...stores.items].sort((left, right) =>
      String(left.component || "").localeCompare(String(right.component || "")) || sourceSort(left, right)
    );
    if (!items.length) {
      container.replaceChildren(emptyState("No store, cache, inventory, or ledger types matched the deterministic rules."));
      return;
    }
    const grouped = new Map();
    items.forEach((item) => {
      const key = item.component || "unassigned";
      if (!grouped.has(key)) grouped.set(key, []);
      grouped.get(key).push(item);
    });
    const sections = [...grouped.entries()].map(([componentId, records]) => {
      const section = behaviorGroup(boundaryComponentLabel(componentId), `${records.length} store type(s)`);
      const list = element("div", "behavior-list");
      records.forEach((record) => {
        const artifacts = (record.artifacts || []).map((artifact) => artifact.label);
        const storeNode = interplay.nodes.find((node) => node.label === record.type_name && node.store);
        const described = storeNode && storeNode.semantic ? storeNode.semantic : null;
        const fields = (described && described.fields) || {};
        const row = recordRow(record, [
          `persistence ${(record.persistence || []).join(", ")}`,
          artifacts.length ? `artifacts ${artifacts.join(", ")}` : null,
          fields.medium ? `medium ${semanticValue(fields.medium)}` : null,
          (fields.record_type || []).length ? `records ${fields.record_type.join(", ")}` : null,
          fields.keyed_by ? `keyed by ${fields.keyed_by}` : null,
          (fields.written_when || []).length ? `written ${semanticValue(fields.written_when)}` : null,
          (fields.read_when || []).length ? `read ${semanticValue(fields.read_when)}` : null
        ].filter(Boolean));
        if (described) {
          const summary = element("p", "derivation described-summary", described.summary);
          if (described.stale) summary.prepend(element("span", "stale-badge", "stale"));
          row.append(summary);
        }
        const mechanisms = record.mechanisms || [];
        if (mechanisms.length) {
          const block = element("ul", "evidence-list");
          mechanisms.slice(0, 6).forEach((mechanism) => {
            const item = document.createElement("li");
            item.append(element("span", "", `${mechanism.kind}${mechanism.via ? ` via ${mechanism.via}` : ""} · `), sourceLink(mechanism.evidence));
            block.append(item);
          });
          row.append(block);
        } else {
          row.append(element("p", "derivation", record.derivation || "No persistence API observed."));
        }
        list.append(row);
      });
      section.append(list);
      return section;
    });
    container.replaceChildren(...sections);
  }

  // ── CI gates ──────────────────────────────────────────────────────────────
  // The pipeline as a circuit. A pull request is the input signal; every job
  // that runs on pull requests is a gate the signal must pass; `needs` and
  // artifact hand-offs are wires between gates; all of them feed one AND gate,
  // the merge. What runs only after a merge sits downstream of that gate; what
  // runs by hand sits in its own band. Layout is a fixed-column circuit: each
  // workflow is a lane, depth in its `needs` graph is the column.

  function gateDepth(job, seen = new Set()) {
    if (!job.needs.length) return 0;
    if (seen.has(job.id)) return 0;
    seen.add(job.id);
    return 1 + Math.max(...job.needs.map((id) => (gateJobById.has(id) ? gateDepth(gateJobById.get(id), seen) : 0)));
  }

  function gateFamilyRank(family) {
    const index = GATE_FAMILY_ORDER.indexOf(family);
    return index === -1 ? GATE_FAMILY_ORDER.length : index;
  }

  function layoutGates() {
    const nodes = new Map();
    const lanes = [];
    const wires = [];
    const roleOf = (job) => job.role;
    const gateWorkflows = ci.workflows
      .filter((workflow) => workflow.jobs.some((id) => roleOf(gateJobById.get(id)) === "gate"))
      .sort((left, right) => gateFamilyRank(left.family) - gateFamilyRank(right.family) || left.name.localeCompare(right.name));
    const jobsX0 = 24 + GATE.triggerW + GATE.colGap;
    let maxDepth = 0;
    let y = 16;
    const bandTop = y;
    gateWorkflows.forEach((workflow) => {
      const jobs = workflow.jobs.map((id) => gateJobById.get(id)).filter((job) => roleOf(job) === "gate");
      const byDepth = new Map();
      jobs.forEach((job) => {
        const depth = gateDepth(job);
        maxDepth = Math.max(maxDepth, depth);
        if (!byDepth.has(depth)) byDepth.set(depth, []);
        byDepth.get(depth).push(job);
      });
      const rows = Math.max(...[...byDepth.values()].map((list) => list.length));
      const laneH = GATE.laneHead + GATE.lanePadY + rows * GATE.nodeH + (rows - 1) * GATE.rowGap + GATE.lanePadY;
      const lane = { id: workflow.id, label: `${workflow.label} · ${workflow.name}`, question: workflow.question, family: workflow.family, x: jobsX0 - GATE.lanePadX, y, h: laneH, kind: "gate", rail: y + laneH - 10 };
      lanes.push(lane);
      byDepth.forEach((list, depth) => {
        list.forEach((job, row) => {
          nodes.set(job.id, {
            id: job.id, kind: "job", job, family: workflow.family,
            x: jobsX0 + depth * (GATE.nodeW + GATE.colGap), y: y + GATE.laneHead + GATE.lanePadY + row * (GATE.nodeH + GATE.rowGap),
            w: GATE.nodeW, h: GATE.nodeH
          });
        });
      });
      y += laneH + GATE.laneGap;
    });
    const bandBottom = y - GATE.laneGap;
    const laneRight = jobsX0 + (maxDepth + 1) * (GATE.nodeW + GATE.colGap) - GATE.colGap + GATE.lanePadX;
    lanes.forEach((lane) => { lane.w = laneRight - lane.x; });
    const bandMid = (bandTop + bandBottom) / 2;
    // The pull-request trigger, centred on the gate band.
    nodes.set("trigger:pull_request", { id: "trigger:pull_request", kind: "trigger", family: "trigger", label: "pull_request → main", x: 24, y: bandMid - 27, w: GATE.triggerW, h: 54 });
    // The merge: one AND gate, one input pin per gate job.
    const inputs = ci.merge.inputs.filter((id) => nodes.has(id));
    const mergeH = Math.max(88, inputs.length * 13 + 26);
    const mergeX = laneRight + GATE.colGap + 26;
    const merge = { id: "merge:main", kind: "merge", family: "merge", label: "Mergeable → main", x: mergeX, y: bandMid - mergeH / 2, w: GATE.mergeW, h: mergeH, inputs };
    nodes.set(merge.id, merge);
    // After the merge: post-merge jobs, split above and below the AND gate so the
    // `needs` wire from a gate to a post-merge job can pass the gate cleanly.
    const postJobs = ci.jobs.filter((job) => job.role === "post-merge" || job.role === "disabled");
    const postX = mergeX + GATE.mergeW + GATE.colGap + 10;
    const above = postJobs.filter((job) => job.needs.length);
    const below = postJobs.filter((job) => !job.needs.length);
    above.forEach((job, index) => {
      nodes.set(job.id, { id: job.id, kind: "job", job, family: job.family, x: postX, y: merge.y - 26 - (above.length - index) * (GATE.nodeH + GATE.rowGap), w: GATE.nodeW, h: GATE.nodeH });
    });
    below.forEach((job, index) => {
      nodes.set(job.id, { id: job.id, kind: "job", job, family: job.family, x: postX, y: merge.y + mergeH + 26 + index * (GATE.nodeH + GATE.rowGap), w: GATE.nodeW, h: GATE.nodeH });
    });
    if (postJobs.length) {
      const ys = postJobs.map((job) => nodes.get(job.id)).flatMap((node) => [node.y, node.y + node.h]);
      const top = Math.min(...ys, merge.y) - GATE.laneHead - 6;
      const bottom = Math.max(...ys, merge.y + merge.h) + GATE.lanePadY;
      lanes.push({ id: "after-merge", label: "After the merge", question: "Push to main or a tag; never a pull request.", family: "release", kind: "after-merge", x: postX - GATE.lanePadX, y: top, w: GATE.nodeW + GATE.lanePadX * 2, h: bottom - top });
    }
    // Manual band: workflow_dispatch → jobs no event fires.
    const manualJobs = ci.jobs.filter((job) => job.role === "manual");
    let manualBottom = bandBottom;
    if (manualJobs.length) {
      const top = Math.max(bandBottom, ...lanes.map((lane) => lane.y + lane.h)) + GATE.laneGap + 8;
      const laneH = GATE.laneHead + GATE.lanePadY + manualJobs.length * GATE.nodeH + (manualJobs.length - 1) * GATE.rowGap + GATE.lanePadY;
      lanes.push({ id: "manual", label: "Manual", question: "Dispatched from the Actions tab; nothing in the pipeline waits on these.", family: "maintenance", kind: "manual", x: jobsX0 - GATE.lanePadX, y: top, w: laneRight - (jobsX0 - GATE.lanePadX), h: laneH });
      manualJobs.forEach((job, index) => {
        nodes.set(job.id, { id: job.id, kind: "job", job, family: job.family, x: jobsX0, y: top + GATE.laneHead + GATE.lanePadY + index * (GATE.nodeH + GATE.rowGap), w: GATE.nodeW, h: GATE.nodeH });
      });
      nodes.set("trigger:workflow_dispatch", { id: "trigger:workflow_dispatch", kind: "trigger", family: "trigger", label: "workflow_dispatch", x: 24, y: top + laneH / 2 - 27, w: GATE.triggerW, h: 54 });
      manualBottom = top + laneH;
    }
    // Wires. Every wire is an orthogonal path from a source pin to a target pin.
    const trunkPR = 24 + GATE.triggerW + GATE.colGap / 2;
    const trunkMerge = mergeX - GATE.colGap / 2 - 6;
    const pinY = new Map();
    inputs.forEach((id, index) => pinY.set(id, merge.y + 13 + index * ((mergeH - 26) / Math.max(1, inputs.length - 1) || 0)));
    ci.edges.forEach((edge) => {
      const source = nodes.get(edge.source);
      const target = nodes.get(edge.target);
      if (!source || !target) return;
      const sy = source.y + source.h / 2;
      const ty = target.y + target.h / 2;
      let d;
      if (edge.kind === "trigger") {
        d = `M ${source.x + source.w} ${sy} H ${trunkPR} V ${ty} H ${target.x}`;
        if (edge.source === "trigger:workflow_dispatch") d = `M ${source.x + source.w} ${sy} H ${trunkPR} V ${ty} H ${target.x}`;
      } else if (edge.kind === "gates") {
        const lane = lanes.find((item) => item.id === source.job.workflow);
        const gapX = source.x + source.w + 24;
        const railY = lane ? lane.rail : sy;
        d = `M ${source.x + source.w} ${sy} H ${gapX} V ${railY} H ${trunkMerge} V ${pinY.get(edge.source) ?? ty} H ${target.x}`;
      } else if (edge.kind === "release") {
        const outX = source.x + source.w + 34;
        d = `M ${source.x + source.w} ${sy} H ${outX} V ${ty} H ${target.x}`;
      } else {
        const gapX = source.x + source.w + (edge.kind === "artifact" ? 40 : 24);
        const offset = edge.kind === "artifact" ? 9 : 0;
        d = `M ${source.x + source.w} ${sy + offset} H ${gapX} V ${ty + offset} H ${target.x}`;
      }
      // An artifact label sits above its dashed wire in the gap before the consumer;
      // it is drawn only while a connected gate is selected (the inspector lists it too).
      const gapX = source.x + source.w + 40;
      wires.push({ ...edge, d, labelAt: edge.kind === "artifact" ? { x: (gapX + target.x) / 2, y: ty + 9 - 4 } : null });
    });
    const width = Math.max(...[...nodes.values()].map((node) => node.x + node.w), ...lanes.map((lane) => lane.x + lane.w)) + 24;
    const height = Math.max(manualBottom, ...lanes.map((lane) => lane.y + lane.h)) + 24;
    return { nodes, lanes, wires, width, height, pinY };
  }

  function renderGates() {
    const svg = document.getElementById("gates-graph");
    if (!svg) return;
    if (!ci.jobs.length) {
      svg.replaceChildren();
      const content = document.getElementById("gates-content");
      if (content) content.replaceChildren(emptyState("No workflows were read from .github/workflows."));
      return;
    }
    gateLayout = layoutGates();
    const { nodes, lanes, wires, width, height } = gateLayout;
    svg.setAttribute("viewBox", `0 0 ${width} ${height}`);
    svg.setAttribute("width", String(width));
    svg.setAttribute("height", String(height));
    svg.replaceChildren();
    const laneGroup = svgElement("g", { class: "gate-lanes" });
    lanes.forEach((lane) => {
      const group = svgElement("g", { class: `gate-lane ${lane.kind}` });
      group.append(svgElement("rect", { class: `gate-lane-rect ${lane.kind}`, x: lane.x, y: lane.y, width: lane.w, height: lane.h, rx: 10 }));
      const label = svgElement("text", { class: "gate-lane-label", x: lane.x + 14, y: lane.y + 16, fill: GATE_FAMILY_COLORS[lane.family] || "" });
      label.textContent = lane.label;
      const question = svgElement("text", { class: "gate-lane-question", x: lane.x + 14, y: lane.y + 29 });
      question.textContent = lane.question;
      group.append(label, question);
      laneGroup.append(group);
    });
    const wireGroup = svgElement("g", { class: "gate-wires" });
    wires.forEach((wire) => {
      const path = svgElement("path", { class: `gate-wire ${wire.kind}`, d: wire.d, "data-source": wire.source, "data-target": wire.target });
      wireGroup.append(path);
      if (wire.labelAt) {
        const text = svgElement("text", { class: "gate-wire-label", x: wire.labelAt.x, y: wire.labelAt.y, "text-anchor": "middle", "data-source": wire.source, "data-target": wire.target });
        text.textContent = wire.label;
        wireGroup.append(text);
      }
    });
    const nodeGroup = svgElement("g", { class: "gate-nodes" });
    nodes.forEach((node) => nodeGroup.append(gateNodeElement(node)));
    svg.append(laneGroup, wireGroup, nodeGroup);
    renderGateStats();
    renderGateLegend();
    renderGateSections();
    applyGateState();
  }

  function gateNodeElement(node) {
    const color = GATE_FAMILY_COLORS[node.family] || GATE_FAMILY_COLORS.maintenance;
    const classes = ["gate-node", node.kind];
    if (node.kind === "job" && node.job.role === "disabled") classes.push("disabled");
    const group = svgElement("g", { class: classes.join(" "), transform: `translate(${node.x} ${node.y})`, tabindex: 0, role: "button", "data-gate": node.id, style: `--node-color:${color}` });
    if (node.kind === "merge") {
      const flat = node.w * 0.46;
      const r = node.h / 2;
      group.append(svgElement("path", { class: "gate-body", d: `M 0 0 H ${flat} A ${r} ${r} 0 0 1 ${flat} ${node.h} H 0 Z` }));
      node.inputs.forEach((id) => {
        const y = gateLayout.pinY.get(id) - node.y;
        group.append(svgElement("line", { class: "gate-pin", x1: -8, y1: y, x2: 0, y2: y }));
      });
      group.append(svgElement("line", { class: "gate-pin", x1: flat + r, y1: r, x2: flat + r + 12, y2: r }));
      const and = svgElement("text", { class: "gate-and", x: flat * 0.55, y: r - 4, "text-anchor": "middle" });
      and.textContent = "AND";
      const title = svgElement("text", { class: "gate-title", x: flat * 0.55, y: r + 12, "text-anchor": "middle" });
      title.textContent = `${node.inputs.length} gates`;
      const meta = svgElement("text", { class: "gate-meta", x: flat * 0.55, y: r + 25, "text-anchor": "middle" });
      meta.textContent = "→ main";
      group.append(and, title, meta);
      group.setAttribute("aria-label", `${node.label}: ${node.inputs.length} gates must pass`);
    } else if (node.kind === "trigger") {
      group.append(svgElement("rect", { class: "gate-body", x: 0, y: 0, width: node.w, height: node.h, rx: 27 }));
      group.append(svgElement("line", { class: "gate-pin", x1: node.w, y1: node.h / 2, x2: node.w + 10, y2: node.h / 2 }));
      const kicker = svgElement("text", { class: "gate-kicker", x: 18, y: 20 });
      kicker.textContent = "TRIGGER";
      const title = svgElement("text", { class: "gate-title", x: 18, y: 38 });
      title.textContent = node.label;
      group.append(kicker, title);
      group.setAttribute("aria-label", `Trigger ${node.label}`);
    } else {
      const job = node.job;
      group.append(svgElement("rect", { class: "gate-body", x: 0, y: 0, width: node.w, height: node.h, rx: 7 }));
      group.append(svgElement("line", { class: "gate-pin", x1: -10, y1: node.h / 2, x2: 0, y2: node.h / 2 }));
      group.append(svgElement("line", { class: "gate-pin", x1: node.w, y1: node.h / 2, x2: node.w + 10, y2: node.h / 2 }));
      if (job.condition) {
        // A conditional gate: the output carries an `if`, drawn as a diamond on the pin.
        group.append(svgElement("path", { class: "gate-condition", d: `M ${node.w + 10} ${node.h / 2 - 5} l 5 5 l -5 5 l -5 -5 Z` }));
      }
      const kickerParts = [(gateWorkflowById.get(job.workflow) || {}).label || job.workflow];
      if (job.needs.length > 1) kickerParts.push("AND");
      if (job.role === "disabled") kickerParts.push("DISABLED");
      if (job.condition && job.role !== "disabled") kickerParts.push("IF");
      const kicker = svgElement("text", { class: "gate-kicker", x: 14, y: 17 });
      kicker.textContent = kickerParts.join(" · ").toUpperCase();
      const title = svgElement("text", { class: "gate-title", x: 14, y: 34 });
      title.textContent = job.name.length > 30 ? `${job.name.slice(0, 29)}…` : job.name;
      const meta = svgElement("text", { class: "gate-meta", x: 14, y: 48 });
      meta.textContent = [job.runs_on, `${job.step_count} steps`, job.pins.length ? `pinned ${job.pins.map((pin) => pin.value).join(", ")}` : null].filter(Boolean).join(" · ");
      group.append(kicker, title, meta);
      group.setAttribute("aria-label", `${job.name}, ${job.role} in ${job.workflow}`);
    }
    group.addEventListener("click", () => selectGate(node.id));
    group.addEventListener("keydown", (event) => {
      if (event.key === "Enter" || event.key === " ") { event.preventDefault(); selectGate(node.id); }
    });
    return group;
  }

  function selectGate(nodeId) {
    selectedGateId = selectedGateId === nodeId ? null : nodeId;
    applyGateState();
    renderGateInspector(selectedGateId ? gateLayout.nodes.get(selectedGateId) : null);
  }

  function gateMatchesQuery(node, query) {
    if (!query) return true;
    const haystack = node.kind === "job"
      ? [node.job.id, node.job.name, node.job.workflow, node.job.runs_on, ...node.job.scripts, ...node.job.artifacts_out, ...node.job.artifacts_in, ...node.job.steps.map((step) => step.name)].join(" ")
      : node.label || node.id;
    return haystack.toLowerCase().includes(query);
  }

  function applyGateState() {
    const svg = document.getElementById("gates-graph");
    if (!svg || !gateLayout) return;
    const query = (document.getElementById("gates-search")?.value || "").trim().toLowerCase();
    const connected = new Set();
    if (selectedGateId) {
      connected.add(selectedGateId);
      gateLayout.wires.forEach((wire) => {
        if (wire.source === selectedGateId) connected.add(wire.target);
        if (wire.target === selectedGateId) connected.add(wire.source);
      });
    }
    svg.querySelectorAll(".gate-node").forEach((element) => {
      const id = element.dataset.gate;
      const node = gateLayout.nodes.get(id);
      const matches = gateMatchesQuery(node, query);
      element.classList.toggle("selected", id === selectedGateId);
      element.classList.toggle("dimmed", (selectedGateId && !connected.has(id)) || (query && !matches));
    });
    svg.querySelectorAll(".gate-wire, .gate-wire-label").forEach((element) => {
      const touches = element.dataset.source === selectedGateId || element.dataset.target === selectedGateId;
      element.classList.toggle("active", Boolean(selectedGateId) && touches);
      element.classList.toggle("dimmed", Boolean(selectedGateId) && !touches);
    });
  }

  function gateJobButton(jobId, label = jobId) {
    const button = element("button", "gate-job", label);
    button.type = "button";
    button.addEventListener("click", () => {
      if (!gateLayout || !gateLayout.nodes.has(jobId)) return;
      selectedGateId = jobId;
      applyGateState();
      renderGateInspector(gateLayout.nodes.get(jobId));
      document.getElementById("gates-workspace")?.scrollIntoView({ behavior: "smooth", block: "start" });
    });
    return button;
  }

  function renderGateInspector(node) {
    const inspector = document.getElementById("gates-inspector");
    if (!inspector) return;
    if (!node) {
      inspector.hidden = true;
      inspector.replaceChildren();
      return;
    }
    inspector.hidden = false;
    const color = GATE_FAMILY_COLORS[node.family] || GATE_FAMILY_COLORS.maintenance;
    const badge = element("span", "inspector-badge");
    badge.style.setProperty("--component-color", color);
    const sections = [];
    if (node.kind === "merge") {
      badge.textContent = "merge · AND";
      sections.push(element("h3", "", node.label));
      sections.push(element("p", "", `${node.inputs.length} jobs run on every pull request. All of them must pass for the change to be mergeable; a red gate anywhere holds the signal. GitHub's required-checks list is repository configuration and is not read here, so this is the set of gates that run, not a proof of which are required.`));
      const section = element("div", "inspector-section");
      section.append(element("h4", "", "Inputs"));
      const chips = element("div", "chip-list");
      node.inputs.forEach((id) => chips.append(gateJobButton(id, (gateJobById.get(id) || {}).name || id)));
      section.append(chips);
      sections.push(section);
    } else if (node.kind === "trigger") {
      badge.textContent = "trigger";
      sections.push(element("h3", "", node.label));
      const trigger = ci.triggers.find((item) => item.id === node.id);
      sections.push(element("p", "", node.id === "trigger:pull_request"
        ? "A pull request against main is the input signal. Every workflow listening to pull_request starts its root jobs; a job whose condition excludes pull requests is drawn after the merge instead."
        : "Started by hand from the Actions tab. Nothing in the pipeline waits on these jobs, so they are drawn in their own band."));
      if (trigger) {
        const section = element("div", "inspector-section");
        section.append(element("h4", "", "Workflows listening"));
        const chips = element("div", "chip-list");
        trigger.workflows.forEach((id) => chips.append(element("span", "chip", (gateWorkflowById.get(id) || {}).name || id)));
        section.append(chips);
        sections.push(section);
      }
    } else {
      const job = node.job;
      const workflow = gateWorkflowById.get(job.workflow) || {};
      badge.textContent = `${workflow.label || job.workflow} · ${job.role}`;
      sections.push(element("h3", "", job.name));
      sections.push(element("p", "", [
        `${workflow.name || job.workflow} / ${job.key}`,
        job.runs_on ? `runs on ${job.runs_on}` : null,
        job.role === "gate" ? "runs on pull requests and gates the merge" : job.role === "post-merge" ? "runs after a merge (or tag); never on a pull request" : job.role === "manual" ? "runs only when dispatched" : "disabled: its condition is `false`"
      ].filter(Boolean).join(" · ")));
      if (job.condition) sections.push(element("p", "derivation", `if: ${job.condition}`));
      const metrics = element("div", "inspector-metrics");
      [[job.step_count, "steps"], [job.needs.length, "needs"], [job.artifacts_out.length + job.artifacts_in.length, "artifacts"]].forEach(([value, label]) => {
        const metric = element("div", "inspector-metric");
        metric.append(element("strong", "", String(value)), element("span", "", label));
        metrics.append(metric);
      });
      sections.push(metrics);
      const declared = ci.ratchets.filter((ratchet) => ratchet.job === job.id);
      if (declared.length) {
        const section = element("div", "inspector-section");
        section.append(element("h4", "", "Declared ratchets"));
        declared.forEach((ratchet) => {
          const row = element("div", "relationship");
          row.append(element("strong", "", ratchet.title), element("span", "", `${ratchet.source_path} · ${ratchet.floor}`));
          section.append(row);
        });
        sections.push(section);
      }
      if (ci.architectural.runs_in.includes(job.id)) {
        const section = element("div", "inspector-section");
        section.append(element("h4", "", "Architectural checks"));
        section.append(element("p", "", job.id === "tests/swift-lint"
          ? `${ci.architectural.lint_rules.length} custom SwiftLint rules run here under --strict against the frozen baseline.`
          : job.id === "tests/swift-test"
            ? `${ci.architectural.tests.length} ArchitectureTests run inside this suite.`
            : `${ci.architectural.invariants.length} System-map invariants are checked by the architecture compiler here.`));
        sections.push(section);
      }
      if (job.needs.length || job.artifacts_in.length || job.artifacts_out.length) {
        const section = element("div", "inspector-section");
        section.append(element("h4", "", "Wiring"));
        const chips = element("div", "chip-list");
        job.needs.forEach((id) => chips.append(gateJobButton(id, `needs ${(gateJobById.get(id) || {}).name || id}`)));
        job.artifacts_in.forEach((name) => chips.append(element("span", "chip", `downloads ${name}`)));
        job.artifacts_out.forEach((name) => chips.append(element("span", "chip", `uploads ${name}`)));
        section.append(chips);
        sections.push(section);
      }
      if (job.pins.length) {
        const section = element("div", "inspector-section");
        section.append(element("h4", "", "Pinned tools"));
        const chips = element("div", "chip-list");
        job.pins.forEach((pin) => chips.append(element("span", "chip", `${pin.name} = ${pin.value}`)));
        section.append(chips);
        section.append(element("p", "derivation", "A pinned version keeps the baseline honest: a newer tool detects more and would fail CI on debt the baseline never recorded."));
        sections.push(section);
      }
      const steps = element("div", "inspector-section");
      steps.append(element("h4", "", "Steps"));
      const list = element("ol", "inspector-steps");
      job.steps.forEach((step) => {
        const item = document.createElement("li");
        item.append(element("span", "step-path", step.name));
        if (step.condition) item.append(element("span", "step-note", `if: ${step.condition}`));
        if (step.uses) item.append(element("span", "step-note", `uses ${step.uses}`));
        if (step.command) item.append(element("code", "step-command", step.command_lines > 1 ? `${step.command}  … (${step.command_lines} lines)` : step.command));
        (step.scripts || []).forEach((script) => {
          const note = element("span", "step-note");
          note.append(sourceLink({ path: script, line: 1 }));
          item.append(note);
        });
        list.append(item);
      });
      steps.append(list);
      sections.push(steps);
      const source = element("div", "inspector-section");
      source.append(element("h4", "", "Source"));
      const provenance = element("p", "provenance");
      provenance.append(element("span", "", "Workflow · "), sourceLink(job.evidence));
      source.append(provenance);
      sections.push(source);
    }
    inspector.replaceChildren(badge, ...sections);
  }

  function renderGateStats() {
    const container = document.getElementById("gates-stats");
    if (!container) return;
    const summary = ci.summary || {};
    const values = [
      [String(summary.workflows || 0), "Workflows"],
      [String(summary.gates || 0), "PR gates"],
      [String(summary.ratchets || 0), "Ratchets"],
      [String((summary.lint_rules || 0) + (summary.architecture_tests || 0) + (summary.invariants || 0)), "Arch. checks"],
      [String(summary.static_checks || 0), "Static checks"]
    ];
    container.replaceChildren(...values.map(([value, label]) => {
      const item = element("div", "stat");
      item.append(element("span", "stat-value", value), element("span", "stat-label", label));
      return item;
    }));
  }

  function renderGateLegend() {
    const legend = document.getElementById("gates-legend");
    if (!legend) return;
    const families = GATE_FAMILY_ORDER.filter((family) => ci.workflows.some((workflow) => workflow.family === family));
    legend.replaceChildren(...families.map((family) => {
      const item = element("div", "legend-item");
      const swatch = element("span", "legend-swatch");
      swatch.style.setProperty("--legend-color", GATE_FAMILY_COLORS[family]);
      item.append(swatch, element("span", "", GATE_FAMILY_LABELS[family] || family));
      return item;
    }), ...[["needs / artifact wire", "#7ec8b0"], ["gate → merge", GATE_FAMILY_COLORS.merge], ["after merge", GATE_FAMILY_COLORS.release]].map(([label, color]) => {
      const item = element("div", "legend-item");
      const swatch = element("span", "legend-swatch");
      swatch.style.setProperty("--legend-color", color);
      item.append(swatch, element("span", "", label));
      return item;
    }));
  }

  function formatGateCurrent(ratchet) {
    const current = ratchet.current || {};
    if (current.kind === "coverage") return `${Number(current.percent).toFixed(2)}% (${Number(current.covered).toLocaleString()} / ${Number(current.count).toLocaleString()})`;
    if (current.kind === "counters") return `${Object.keys(current.counts || {}).length} counters`;
    if (current.kind === "count") {
      const categories = Object.keys(current.counts || {}).length;
      return categories ? `${Number(current.total).toLocaleString()} in ${categories} ${ratchet.id === "lint" ? "rules" : "kinds"}` : Number(current.total).toLocaleString();
    }
    return "—";
  }

  function gateBreakdown(ratchet) {
    const current = ratchet.current || {};
    let pairs = [];
    if (current.kind === "coverage") pairs = Object.entries(current.layers || {}).map(([layer, item]) => [layer, `${Number(item.percent).toFixed(1)}%`]);
    else if (current.counts) pairs = Object.entries(current.counts).sort((left, right) => right[1] - left[1]).map(([key, value]) => [key, Number(value).toLocaleString()]);
    if (!pairs.length) return null;
    const details = document.createElement("details");
    details.append(element("summary", "", current.kind === "coverage" ? "by layer" : "breakdown"));
    const list = element("ul", "breakdown");
    pairs.forEach(([key, value]) => {
      const item = document.createElement("li");
      item.append(element("span", "", key), element("span", "", value));
      list.append(item);
    });
    details.append(list);
    return details;
  }

  function renderGateSections() {
    const container = document.getElementById("gates-content");
    if (!container) return;
    const sections = [];

    // 1 · Ratchets: metric floors read from the committed baselines.
    const ratchets = behaviorGroup("Ratchets", `${ci.ratchets.length} metric gates. Each compares the tree against a committed baseline: a FLOOR the whole tree may not fall below (relative to the base branch) and, where a metric is attributable to lines, a PATCH rule the change's added lines must meet. Baselines move to record improvement, never to admit a regression; the values here are what CI compares against, not a fresh measurement.`);
    const table = element("table", "gates-table");
    const head = document.createElement("thead");
    const headRow = document.createElement("tr");
    ["Gate", "CI check", "Current", "Floor (whole tree vs base)", "Patch (added lines)"].forEach((label) => headRow.append(element("th", "", label)));
    head.append(headRow);
    const body = document.createElement("tbody");
    ci.ratchets.forEach((ratchet) => {
      const row = document.createElement("tr");
      const gateCell = document.createElement("td");
      gateCell.append(element("span", "gate-name", ratchet.title), element("span", "gate-source", ratchet.source_path));
      gateCell.append(element("p", "derivation", ratchet.measures));
      const breakdown = gateBreakdown(ratchet);
      if (breakdown) gateCell.append(breakdown);
      const jobCell = document.createElement("td");
      const job = gateJobById.get(ratchet.job);
      jobCell.append(gateJobButton(ratchet.job, job ? `${(gateWorkflowById.get(job.workflow) || {}).label || job.workflow} / ${job.name}` : ratchet.job));
      if (job) jobCell.append(element("span", "gate-source", job.scripts.join(", ") || job.runs_on));
      const currentCell = element("td", "num", formatGateCurrent(ratchet));
      const floorCell = element("td", "", ratchet.floor);
      const patchCell = element("td", ratchet.patch ? "" : "floor-only", ratchet.patch || "floor-only");
      row.append(gateCell, jobCell, currentCell, floorCell, patchCell);
      body.append(row);
    });
    table.append(head, body);
    ratchets.append(table);
    sections.push(ratchets);

    // 2 · Architectural checks: rules about the shape of the code.
    const architectural = ci.architectural;
    const arch = behaviorGroup("Architectural checks", `${architectural.lint_rules.length} custom SwiftLint rules, ${architectural.tests.length} ArchitectureTests and ${architectural.invariants.length} System-map invariants. These do not track a number; they pin a shape (layer direction, no new singletons, one transport) and fail on the first violation. Grandfathered violations are frozen in the lint baseline, which the Quality ratchet keeps from growing.`);
    const runsIn = element("div", "gate-runs-in");
    runsIn.append(element("span", "group-note", "Runs in"));
    architectural.runs_in.forEach((id) => {
      const job = gateJobById.get(id);
      runsIn.append(gateJobButton(id, job ? `${(gateWorkflowById.get(job.workflow) || {}).label || job.workflow} / ${job.name}` : id));
    });
    arch.append(runsIn);
    const checkItem = (headParts, body, provenanceParts) => {
      const item = document.createElement("li");
      const head = element("div", "check-head");
      headParts.filter(Boolean).forEach((part) => head.append(part));
      if (provenanceParts && provenanceParts.length) {
        const provenance = element("p", "provenance");
        provenanceParts.forEach((part, index) => { if (index) provenance.append(element("span", "", " · ")); provenance.append(part); });
        head.append(provenance);
      }
      item.append(head);
      if (body) item.append(body);
      return item;
    };
    const rulesSection = element("div", "pocket-section");
    rulesSection.append(element("h4", "", `SwiftLint custom rules · ${architectural.lint_config}`));
    const rulesList = element("ul", "check-list");
    architectural.lint_rules.forEach((rule) => {
      rulesList.append(checkItem([
        element("code", "", rule.id),
        element("span", "chip", rule.severity),
        rule.baselined ? element("span", "chip", `${rule.baselined.toLocaleString()} baselined`) : null,
        rule.excluded_count ? element("span", "chip", `${rule.excluded_count} grandfathered file(s)`) : null
      ], rule.message ? element("p", "", rule.message) : null, [sourceLink(rule.evidence)]));
    });
    rulesSection.append(rulesList);
    arch.append(rulesSection);
    const testsSection = element("div", "pocket-section");
    testsSection.append(element("h4", "", `ArchitectureTests · ${architectural.tests_path}`));
    const testsList = element("ul", "check-list");
    architectural.tests.forEach((test) => {
      testsList.append(checkItem([element("strong", "", test.title)], null, [sourceLink(test.evidence)]));
    });
    testsSection.append(testsList);
    arch.append(testsSection);
    const invariantsSection = element("div", "pocket-section");
    invariantsSection.append(element("h4", "", "System-map invariants · architecture/interplay/invariants.json"));
    const invariantsList = element("ul", "check-list");
    architectural.invariants.forEach((item) => {
      invariantsList.append(checkItem([
        element("span", `invariant-status ${item.status}`, item.status === "holds" ? "HOLDS" : "VIOLATED"),
        element("code", "", item.id),
        element("span", "invariant-meta", item.kind.replace(/_/g, " "))
      ], item.why ? element("p", "", item.why) : null, []));
    });
    invariantsSection.append(invariantsList);
    invariantsSection.append(element("p", "group-note", "Checked by scripts/build_architecture.py on every build; the full list with what each pins is on the System map."));
    arch.append(invariantsSection);
    sections.push(arch);

    // 3 · Static compiler checks: regenerate and compare.
    const staticGroup = behaviorGroup("Static compiler checks", `${ci.static_checks.length} checks that recompile a committed artifact from the tree and fail when the two differ, or run the compiler's own tests. They ask neither "does it work" nor "did a number move": they ask whether what is published still describes this source.`);
    const staticList = element("ul", "check-list");
    ci.static_checks.forEach((check) => {
      const job = gateJobById.get(check.job);
      const body = element("div");
      body.append(element("code", "gate-command", check.command));
      staticList.append(checkItem([
        element("strong", "", check.name),
        element("span", "invariant-meta", job ? `${(gateWorkflowById.get(job.workflow) || {}).label || job.workflow} / ${job.name}` : check.job)
      ], body, [sourceLink(check.evidence), ...(check.scripts || []).map((script) => sourceLink({ path: script, line: 1 }))]));
    });
    staticGroup.append(staticList);
    sections.push(staticGroup);

    container.replaceChildren(...sections);
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
    activateView("systemmap");
    const search = document.getElementById("interplay-search");
    if (search) search.value = componentId;
    selectedInterplayId = null;
    applyInterplayState();
  }

  function wireNavigation() {
    document.querySelectorAll(".nav-item").forEach((button) => {
      button.addEventListener("click", () => {
        activateView(button.dataset.view);
        if (window.history && window.history.replaceState) window.history.replaceState(null, "", `#${button.dataset.view}`);
      });
    });
    // Deep-linkable views: /#interplay opens that view directly (#graph, the old
    // layered map, now lands on the system map too).
    const initial = window.location.hash.replace(/^#/, "").replace(/^(graph|interplay)$/, "systemmap");
    if (initial && document.getElementById(`${initial}-view`)) activateView(initial);
    // Deep-linkable selection: ?select=<node label or id> opens the map with that
    // node selected, its request path highlighted, and its inspector open.
    const wanted = new URLSearchParams(window.location.search).get("select");
    if (wanted) {
      const target = interplayNodeById.get(wanted) || interplay.nodes.find((node) => node.label === wanted);
      if (target) { activateView("systemmap"); selectInterplayNode(target.id); }
    }
  }

  function activateView(viewName) {
    document.querySelectorAll(".nav-item").forEach((button) => {
      button.classList.toggle("active", button.dataset.view === viewName);
    });
    document.querySelectorAll(".view").forEach((view) => view.classList.remove("active"));
    document.getElementById(`${viewName}-view`).classList.add("active");
  }

  // Light / dark. CSS tokens do almost all of it; the two exceptions are the
  // active arrowhead marker (an SVG fill set at render time) and Mermaid, which
  // bakes its theme into each rendered diagram, so open diagrams re-render.
  function applyTheme(theme, persist = true) {
    document.documentElement.dataset.theme = theme;
    if (persist) { try { window.localStorage.setItem("portal.architecture.theme", theme); } catch (_error) { /* storage unavailable */ } }
    const toggle = document.getElementById("theme-toggle");
    if (toggle) {
      const next = theme === "light" ? "dark" : "light";
      toggle.setAttribute("aria-label", `Switch to ${next} mode`);
      toggle.title = `Switch to ${next} mode`;
      toggle.firstElementChild.textContent = theme === "light" ? "☀" : "☾";
    }
    const rootStyle = getComputedStyle(document.documentElement);
    const activeArrow = document.querySelector("#arrow-active path");
    if (activeArrow) activeArrow.setAttribute("fill", rootStyle.getPropertyValue("--edge-active").trim() || "#f2f2f4");
    const quietArrow = document.querySelector("#arrow-quiet path");
    if (quietArrow) quietArrow.setAttribute("fill", rootStyle.getPropertyValue("--edge-quiet").trim() || "#5a585d");
    if (window.__mermaidInit) {
      window.__mermaidInit(theme);
      document.querySelectorAll(".flow-diagram[data-state='rendered'], .flow-diagram[data-state='failed']").forEach((block) => {
        block.dataset.state = "pending";
        block.textContent = block.dataset.source;
      });
      renderMermaidDiagrams();
    }
  }

  function wireTheme() {
    const toggle = document.getElementById("theme-toggle");
    if (!toggle) return;
    applyTheme(document.documentElement.dataset.theme === "light" ? "light" : "dark", false);
    toggle.addEventListener("click", () => applyTheme(document.documentElement.dataset.theme === "light" ? "dark" : "light"));
  }

  function wireControls() {
    wireTheme();
    document.getElementById("inventory-search").addEventListener("input", (event) => renderInventory(event.target.value));
    const gatesSearch = document.getElementById("gates-search");
    if (gatesSearch) gatesSearch.addEventListener("input", applyGateState);
    const resetGates = document.getElementById("reset-gates");
    if (resetGates) {
      resetGates.addEventListener("click", () => {
        selectedGateId = null;
        if (gatesSearch) gatesSearch.value = "";
        renderGateInspector(null);
        applyGateState();
      });
    }
    const interplaySearch = document.getElementById("interplay-search");
    if (interplaySearch) interplaySearch.addEventListener("input", applyInterplayState);
    const resetInterplay = document.getElementById("reset-interplay");
    if (resetInterplay) {
      resetInterplay.addEventListener("click", () => {
        selectedInterplayId = null;
        selectedFlowId = null;
        renderFlows();
        if (interplaySearch) interplaySearch.value = "";
        if (TL) { timelinePlay(false); TL.disengage(); timelineSync(); } // back to the head revision
        fitInterplayView(); // reset the pan/zoom window back to the whole graph too
        applyInterplayState();
      });
    }
    const legendToggle = document.getElementById("interplay-legend-toggle");
    const legendBox = document.getElementById("interplay-legend");
    if (legendToggle && legendBox) {
      const key = "portal.architecture.interplayLegendCollapsed";
      const apply = (collapsed) => {
        legendBox.classList.toggle("collapsed", collapsed);
        legendToggle.setAttribute("aria-expanded", String(!collapsed));
      };
      let collapsed = false;
      try { collapsed = window.localStorage.getItem(key) === "1"; } catch (_error) { collapsed = false; }
      apply(collapsed);
      legendToggle.addEventListener("click", () => {
        collapsed = !legendBox.classList.contains("collapsed");
        apply(collapsed);
        try { window.localStorage.setItem(key, collapsed ? "1" : "0"); } catch (_error) { /* storage unavailable */ }
      });
    }
    const interplayFullscreen = document.getElementById("interplay-fullscreen");
    if (interplayFullscreen) interplayFullscreen.addEventListener("click", toggleInterplayFullscreen);
    wireTimeline();
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
