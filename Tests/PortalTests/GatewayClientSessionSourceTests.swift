import Testing
@testable import Portal

@Suite("Gateway client session source")
internal struct GatewayClientSessionSourceTests {
    @Test("New Portal sessions identify the desktop client surface")
    @MainActor
    internal func createSessionParamsCarryDesktopSource() {
        let params = GatewayClient.sessionCreateParams(cols: 132)

        #expect(params["cols"]?.intValue == 132)
        #expect(params["source"]?.stringValue == "desktop")
    }
}
