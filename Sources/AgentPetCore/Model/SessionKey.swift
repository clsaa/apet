public struct SessionKey: Hashable {
    public let agent: String
    public let root: String
    public let sessionId: String
    public init(agent: String, root: String, sessionId: String) {
        self.agent = agent; self.root = root; self.sessionId = sessionId
    }
    public init(event: AgentEvent) {
        self.init(agent: event.agent, root: event.root, sessionId: event.sessionId)
    }
}
