public actor LiveRouter {
    public private(set) var current: EngineRouter

    public init(_ router: EngineRouter) {
        current = router
    }

    public func set(_ router: EngineRouter) {
        current = router
    }

    public func modelAllowed(_ language: Language) -> Bool {
        current.typing(language) == .model
    }
}
