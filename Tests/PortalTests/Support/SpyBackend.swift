import Combine
import Foundation
@testable import Portal

/// A test backend: the `AgentBackend` requirements no spy ever exercises get
/// one inert answer here instead of a copy per spy.
internal protocol SpyBackend: AgentBackend {}

extension SpyBackend {
    internal var sessionInfoPublisher: AnyPublisher<SessionInfo?, Never> {
        Just<SessionInfo?>(nil).eraseToAnyPublisher()
    }
}
