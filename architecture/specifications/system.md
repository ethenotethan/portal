# System architecture

Portal is a native macOS and iOS client for a single agent backend, the harness. The application is organized around the dependency direction documented in `docs/architecture-rules.md`:

**Models → Services → ViewModels → Views**

Dependencies point toward models and service contracts. Views render observable state and do not reach through a ViewModel to a concrete transport.

## Runtime actors

- **Portal application** owns presentation, local state, and persistence.
- **Harness gateway** exposes the Ethen-managed WebSocket JSON-RPC runtime and full agent surface.
- **Device services** provide Keychain, files, notifications, media, and platform frameworks.

## Backend seam

`AgentBackend` is the interface consumed by chat orchestration. The harness gateway normalizes its events into `GatewayEvent`, so chat orchestration renders one event stream rather than a transport.

## Presentation domains

The primary product domains are chat, operations, wiki, living artifacts, and thought-graph exploration. Each domain may have presentation and orchestration nodes in the architecture graph. Shared models, services, and utilities remain visible as foundations rather than being duplicated under each feature.

## Artifact intent seam

Living artifacts are not only rendered; they can declare actions that dispatch real backend work. That contract is its own integration component rather than an implementation detail of artifact rendering, because it carries a security boundary: artifact-authored declarations and inert markup on one side, gateway-resolved handlers and native-only confirmation and navigation on the other.

Sessions author and revise artifacts; crons maintain them on a schedule. `artifact-intents` is where the dispatch, revision pinning, and maintainer references live. See `architecture/specifications/artifact-intents.md`.

## Wiki source seam

The wiki reads from knowledge sources whose capabilities differ: a source may record an edit history and may report the ingestion event log behind a page. `wiki-sources` holds the capability markers those surfaces gate on, so a wiki affordance appears because the source conforms rather than because the code recognized a backend. See `architecture/specifications/wiki.md`.

## Graph semantics

The interactive graph is a higher-order architectural map, not a raw file-import graph. Nodes represent components with a coherent responsibility. Edges represent meaningful compile-time or runtime relationships and retain source evidence. File and declaration inventories remain available as drill-down evidence.
