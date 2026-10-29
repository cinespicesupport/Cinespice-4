import Foundation

/// TDLib can deliver the same initial state through an update and a state query.
/// Configure once per client, and let newer authorization states own the UI.
struct TelegramAuthorizationSetup {
    private(set) var state: String?
    private(set) var revision = 0
    private var pending: UUID?
    private var configured = false

    mutating func observe(_ state: String) {
        self.state = state
        revision += 1
    }

    mutating func begin(hasCredentials: Bool) -> UUID? {
        guard hasCredentials, state == "authorizationStateWaitTdlibParameters",
              pending == nil, !configured else { return nil }
        let attempt = UUID()
        pending = attempt
        return attempt
    }

    /// Returns whether a failure still belongs to the current setup screen.
    mutating func finish(_ attempt: UUID, succeeded: Bool) -> Bool {
        guard pending == attempt else { return false }
        pending = nil
        if succeeded { configured = true }
        return !succeeded && state == "authorizationStateWaitTdlibParameters"
    }

    mutating func reset() { self = Self() }
}
