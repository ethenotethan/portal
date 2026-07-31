# Boundaries and authority

## Architectural authority

The repository distinguishes three kinds of architectural information:

1. **Observed facts** are deterministically derived from source files, declarations, references, and manifests.
2. **Synthesized claims** are agent-produced interpretations backed by source evidence and a source commit.
3. **Specifications** are human-reviewed statements of intended behavior and architectural constraints.

Observed behavior does not become normative merely because an agent describes it. Changes to specifications and architectural rules require ordinary pull-request review.

## Layer boundary

Views depend on ViewModels or explicit backend protocols. They must not call through to the raw gateway client. Services remain presentation-independent. Models remain value-oriented and do not import application services or SwiftUI.

The enforced rules and exceptions live in `docs/architecture-rules.md`. This portal explains those rules but does not replace their CI enforcement.

## Backend boundary

`AgentBackend` is the seam between conversation orchestration and concrete agent platforms. Hermes and Centaur adapters may differ in transport and capability, while the UI consumes normalized events and declared capabilities.

Backend-specific management features may use dedicated service surfaces outside the chat seam. Such paths must remain explicit in the graph rather than being presented as generic backend behavior.

## Publication boundary

Architecture artifacts are proposed through pull requests. Merging to the repository's default branch is the publication boundary. GitHub Pages serves only merged architecture state; an autonomous agent cannot publish or approve its own architectural changes.

## Evidence boundary

Generated claims must cite repository-relative source paths. The architecture compiler rejects missing evidence files, unknown component IDs, malformed semantic records, and graph edges whose endpoints do not exist.
