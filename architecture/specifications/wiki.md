# The wiki as a knowledge system

A wiki in Portal is not a document viewer pointed at a folder of markdown. It is a knowledge base something else is actively writing: ingestion pipelines turn pull requests, tickets, documents, chat directives and usage rollups into raw *events*, and agents turn those events into typed, wikilinked pages. The client's job is to make both halves legible — the pages, and where they came from.

That split is why the wiki has an events surface at all. A page reader alone answers "what does the wiki say"; only the event log answers "on what evidence, and how recently".

## One surface, not a set of screens

The graph *is* the wiki home. There is no separate index page: with nothing selected the surface is a full-bleed force-directed graph, and selecting a page opens the reader over a graph that stays alive underneath it. The folder tree, the changeset drawer and the reader are all presentations layered on that one surface, sharing one selection plane, so a node highlight, a sidebar row and the open page can never disagree about what is being read.

The rendering choice — a 2D canvas or a SceneKit 3D layout — is a toggle on that one surface rather than a second mode with its own state.

The sibling runtime graph may classify a data reference as `wiki:<path>`. That
classification is a navigation contract, not merely a color: its inspector
offers the page as a destination, resolves the reference to the Markdown path,
then hands the shared wiki selection plane that path before switching surfaces.
The reader therefore arrives on the referenced entry while the wiki graph,
folder tree, and reader remain synchronized.

## Capability markers, not backend checks

The wiki reads from the harness gateway's `wiki.*` RPCs. A wiki surface still gates its affordances on protocol conformance rather than on a hard-coded assumption, so the seam survives a source that serves less:

- **`WikiSource`** is the floor — fetch the graph, fetch a page.
- **`WikiChangesetSource`** marks a source that records edit history. The timeline drawer with its git-style inline diffs shows only for sources that conform.
- **`WikiEventLogSource`** marks a source that can say what flowed *in*. The event plot and feed gate on this.

This is the same principle as the `AgentBackend` seam for chat: a capability is evidence of supported behavior, never a request to emulate what a source cannot do. A view asks whether the source conforms; it never asks which source it is talking to.

## Fields that are absent, not faked

The event log fills one row type, and a field with no value is left nil or empty rather than invented. The event → changeset → page edge is reported off one index read so provenance can be walked without a second round trip. Every view that shows an enrichment checks first, so a missing affordance means the source has nothing to show rather than a bug.

The same honesty applies to time. An event carries both an event time and an ingest time, and a flag for the case where the pipeline only ever knew the latter. Those events are still real — the feed lists them and the legend counts them — but a plot has no x for them, so the surface counts what it left out instead of quietly dropping it. An event whose timestamp falls outside the requested window is counted too: the client's window and the server's filtering can disagree, and saying so is what turns "the plot is empty" into "these events sit outside this window".

## Architectural consequence

The wiki spans presentation (`wiki-ui`), its own orchestration state (`wiki-state`), and fetch surfaces that live with the transport. What the graph cannot show is that the capability protocols — not a backend identity — are the seam. A source that grows or loses a capability changes only which markers it conforms to, and the surfaces follow from that alone.
