import Testing
import Foundation
@testable import Portal

@Suite("Architecture revisions — architecture.history / diff wire shapes")
internal struct ArchitectureRevisionsDocumentTests {
    private func decode(_ json: String) throws -> AnyCodable {
        try JSONDecoder().decode(AnyCodable.self, from: Data(json.utf8))
    }

    internal static let historyJSON = """
    {"service": "arch:portal", "latest": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
     "runtime": {"graph_id": "launchd:portal", "provider": "launchd", "started_at": "2026-09-25T10:00:00+00:00", "pid": 4242, "revision": "bbbb"},
     "revisions": [
       {"revision": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "stored_at": "2026-09-24T09:00:00+00:00", "source": "local",
        "summary": {"nodes": 100, "edges": 300, "files": 370, "lines": 110000, "invariants": {"total": 12, "holds": 12, "violated": []}},
        "commit": {"sha": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "author": "ethen", "date": "2026-09-24T08:59:00+00:00", "subject": "genesis"}},
       {"revision": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", "stored_at": "2026-09-25T09:00:00+00:00", "source": "local",
        "summary": {"nodes": 155, "edges": 348, "files": 391, "lines": 119950, "invariants": {"total": 12, "holds": 11, "violated": ["x"]}},
        "contract": {"name": "hermes.architecture", "version": "1.0"},
        "check": {"status": "passed", "exit_code": 0, "output": "", "reason": "", "checked_at": "t", "revision": "bbbb", "duration_s": 3},
        "commit": {"sha": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", "author": "ethen", "date": "2026-09-25T08:00:00+00:00", "subject": "native renderers"},
        "commits_since_previous": [
          {"sha": "c1c1c1c1c1", "author": "ethen", "date": "d1", "subject": "one"},
          {"sha": "c2c2c2c2c2", "author": "claude", "date": "d2", "subject": "two"},
          {"author": "no sha"}
        ],
        "deployed": true, "deployed_at": "2026-09-25T09:00:00+00:00"},
       {"revision": "working-tree", "stored_at": "", "source": "local", "summary": {}},
       {"nope": true}
     ]}
    """

    internal static let diffJSON = """
    {"service": "arch:portal", "from": "aaaa", "to": "bbbb",
     "nodes": {"added": [{"id": "store:x:Foo", "history_key": "store:x:Foo", "kind": "store", "label": "Foo", "component": "x"},
                         {"id": "endpoint:1", "kind": "endpoint", "label": "chat"}],
               "removed": [{"id": "caller:y:Bar", "history_key": "caller:y:Bar", "kind": "caller", "label": "Bar"}, {"label": "no id"}]},
     "edges": {"added": [{"source": "a", "target": "b", "relation": "uses", "class": "usage"}], "removed": [{"source": "a"}]},
     "invariants": {"added": ["new-one"], "removed": [], "changed": [{"id": "pool-guarded", "from": "holds", "to": "violated"}]},
     "files": {"added": ["Sources/A.swift"], "removed": ["Sources/B.swift"], "changed": [{"path": "Sources/C.swift", "lines_from": 10, "lines_to": 25}]},
     "gates": {"jobs_added": ["ratchet/constraints"], "jobs_removed": [], "ratchets_added": ["constraints"], "ratchets_removed": []},
     "summary": {"from": {"nodes": 100}, "to": {"nodes": 155}},
     "git": {"commits": [{"sha": "c1c1c1c1c1c1", "author": "ethen", "date": "d", "subject": "s"}],
             "stat": [{"path": "Sources/C.swift", "additions": 20, "deletions": 5}, {"path": "img.png", "additions": null, "deletions": null}],
             "truncated": true}}
    """

    @Test("history decodes revisions, commits, deployment and runtime; malformed entries are skipped")
    internal func historyDecoding() throws {
        let history = try ArchitectureRevisionHistory.decodeGatewayValue(try decode(Self.historyJSON))
        #expect(history.service == "arch:portal")
        #expect(history.latest.hasPrefix("bbbb"))
        #expect(history.revisions.count == 3, "the entry without a revision is dropped")
        #expect(history.runtime?.provider == "launchd")
        #expect(history.runtime?.pid == 4242)
        #expect(history.runtime?.startedAt?.hasPrefix("2026-09-25") == true)
        let latest = try #require(history.entry(history.latest))
        #expect(latest.shortRevision == "bbbbbbbbb")
        #expect(latest.deployed)
        #expect(latest.deployedAt?.hasPrefix("2026-09-25") == true)
        #expect(latest.commit?.subject == "native renderers")
        #expect(latest.commit?.shortSHA == "bbbbbbbbb")
        #expect(latest.commitsSincePrevious.map(\.subject) == ["one", "two"], "a commit without a sha is dropped")
        #expect(latest.check?.passed == true)
        #expect(latest.contract?.version == "1.0")
        #expect(latest.summary.nodes == 155)
        #expect(latest.summary.violated == ["x"])
        let genesis = try #require(history.entry("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"))
        #expect(!genesis.deployed)
        #expect(genesis.deployedAt == nil)
        #expect(genesis.check == nil)
        #expect(genesis.contract == nil)
        #expect(genesis.commitsSincePrevious.isEmpty)
        let working = try #require(history.entry("working-tree"))
        #expect(working.shortRevision == "working-tree", "a non-hex revision stays whole")
        #expect(working.commit == nil)
        #expect(working.summary == .empty)
    }

    @Test("the timeline is newest first by stored time, with position breaking ties; previous() walks it")
    internal func timelineOrdering() throws {
        let history = try ArchitectureRevisionHistory.decodeGatewayValue(try decode(Self.historyJSON))
        let ordered = history.newestFirst.map(\.shortRevision)
        #expect(ordered == ["bbbbbbbbb", "aaaaaaaaa", "working-tree"], "an empty stored_at sorts last")
        #expect(history.previous(of: history.latest)?.shortRevision == "aaaaaaaaa")
        #expect(history.previous(of: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")?.revision == "working-tree")
        #expect(history.previous(of: "working-tree") == nil)
        #expect(history.previous(of: "missing") == nil)
        #expect(ArchitectureRevisionHistory.empty.newestFirst.isEmpty)
        #expect(throws: GatewayError.self) {
            _ = try ArchitectureRevisionHistory.decodeGatewayValue(try decode("{\"service\": \"x\"}"))
        }
    }

    @Test("a diff decodes every section, groups constructions by kind, and summarises itself")
    internal func diffDecoding() throws {
        let diff = try ArchitectureRevisionDiff.decodeGatewayValue(try decode(Self.diffJSON))
        #expect(diff.from == "aaaa")
        #expect(diff.to == "bbbb")
        #expect(diff.nodesAdded.count == 2)
        #expect(diff.nodesAdded[1].historyKey == "endpoint:1", "history key falls back to the id")
        #expect(diff.nodesAdded[0].component == "x")
        #expect(diff.nodesRemoved.map(\.label) == ["Bar"], "a change without an id is dropped")
        #expect(diff.edgesAdded.first?.id == "a→uses→b")
        #expect(diff.edgesAdded.first?.edgeClass == "usage")
        #expect(diff.edgesRemoved.isEmpty, "an edge without a target is dropped")
        #expect(diff.invariantsAdded == ["new-one"])
        #expect(diff.invariantsChanged.first?.to == "violated")
        #expect(diff.filesAdded == ["Sources/A.swift"])
        #expect(diff.filesRemoved == ["Sources/B.swift"])
        #expect(diff.filesChanged.first?.delta == 15)
        #expect(diff.gates.jobsAdded == ["ratchet/constraints"])
        #expect(!diff.gates.isEmpty)
        #expect(diff.summaryFrom.nodes == 100)
        #expect(diff.summaryTo.nodes == 155)
        let git = try #require(diff.git)
        #expect(git.commits.count == 1)
        #expect(git.stat.count == 2)
        #expect(git.stat[1].isBinary)
        #expect(git.additions == 20)
        #expect(git.deletions == 5)
        #expect(git.truncated)
        #expect(!diff.isEmpty)
        #expect(diff.headline == "constructions +2 −1 · edges +1 −0 · 3 file(s) · invariants changed · gates changed")
        let grouped = ArchitectureRevisionDiff.byKind(diff.nodesAdded)
        #expect(grouped.map(\.kind) == ["endpoint", "store"])
        #expect(grouped[1].nodes.map(\.label) == ["Foo"])
    }

    @Test("an empty diff says so; a diff without a revision pair is an invalid response")
    internal func emptyDiff() throws {
        let diff = try ArchitectureRevisionDiff.decodeGatewayValue(try decode("{\"from\": \"a\", \"to\": \"b\"}"))
        #expect(diff.isEmpty)
        #expect(diff.headline == "No structural change")
        #expect(diff.gates == .empty)
        #expect(diff.git == nil)
        #expect(diff.summaryFrom == .empty)
        #expect(throws: GatewayError.self) {
            _ = try ArchitectureRevisionDiff.decodeGatewayValue(try decode("{\"from\": \"a\"}"))
        }
    }
}
