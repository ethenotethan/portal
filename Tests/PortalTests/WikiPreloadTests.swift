import Foundation
import Testing

@Suite("Wiki registry preload")
internal struct WikiPreloadTests {
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    @Test("Connecting preloads both the default graph and named wiki registry")
    internal func connectionPreloadsGraphAndWikiRegistry() throws {
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Sources/Portal/Views/ContentView.swift"),
            encoding: .utf8
        )
        let start = try #require(source.range(of: ".onChange(of: gatewayClientWrapper.isConnected)"))
        let tail = source[start.lowerBound...]
        let end = try #require(tail.range(of: ".onChange(of: settings.isConfigured)"))
        let connectionHandler = tail[..<end.lowerBound]

        #expect(connectionHandler.contains("wikiViewModel.load(client:"))
        #expect(connectionHandler.contains("wikiViewModel.discoverWikis(client:"))
    }

    @Test("A gateway switch invalidates an in-flight wiki registry response")
    internal func gatewaySwitchInvalidatesWikiDiscovery() throws {
        let interaction = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/Portal/ViewModels/WikiGraphViewModel+Interaction.swift"
            ),
            encoding: .utf8
        )
        let viewModel = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Sources/Portal/ViewModels/WikiGraphViewModel.swift"),
            encoding: .utf8
        )
        let discoveryStart = try #require(interaction.range(of: "func discoverWikis(client:"))
        let discovery = interaction[discoveryStart.lowerBound...]
        let resetStart = try #require(viewModel.range(of: "internal func resetForGatewaySwitch()"))
        let resetTail = viewModel[resetStart.lowerBound...]
        let resetEnd = try #require(resetTail.range(of: "func navigate(to path:"))
        let reset = resetTail[..<resetEnd.lowerBound]

        #expect(discovery.contains("isCurrentWikiDiscovery(generation)"))
        #expect(viewModel.contains("generation == wikiDiscoveryGeneration"))
        #expect(reset.contains("wikiDiscoveryGeneration += 1"))
    }
}
