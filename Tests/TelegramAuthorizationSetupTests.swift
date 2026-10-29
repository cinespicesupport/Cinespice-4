import XCTest
@testable import TeveeStreaming

final class TelegramAuthorizationSetupTests: XCTestCase {
    func testInitialUpdateAndStateQueryCannotConfigureTwice() throws {
        var setup = TelegramAuthorizationSetup()
        setup.observe("authorizationStateWaitTdlibParameters")
        let attempt = try XCTUnwrap(setup.begin(hasCredentials: true))
        setup.observe("authorizationStateWaitTdlibParameters")
        XCTAssertNil(setup.begin(hasCredentials: true))
        XCTAssertFalse(setup.finish(attempt, succeeded: true))
        // A delayed initial snapshot must not configure the same client again.
        setup.observe("authorizationStateWaitTdlibParameters")
        XCTAssertNil(setup.begin(hasCredentials: true))
    }

    func testSetupCannotStartWithoutCredentialsOrInAnotherState() {
        var setup = TelegramAuthorizationSetup()
        XCTAssertNil(setup.begin(hasCredentials: true))
        setup.observe("authorizationStateWaitTdlibParameters")
        XCTAssertNil(setup.begin(hasCredentials: false))
        setup.observe("authorizationStateWaitPhoneNumber")
        XCTAssertNil(setup.begin(hasCredentials: true))
    }

    func testGenuineSetupFailureCanBeRetried() throws {
        var setup = TelegramAuthorizationSetup()
        setup.observe("authorizationStateWaitTdlibParameters")
        let attempt = try XCTUnwrap(setup.begin(hasCredentials: true))
        XCTAssertTrue(setup.finish(attempt, succeeded: false))
        let retry = try XCTUnwrap(setup.begin(hasCredentials: true))
        XCTAssertNotEqual(attempt, retry)
        XCTAssertFalse(setup.finish(attempt, succeeded: false))
        XCTAssertNil(setup.begin(hasCredentials: true))
        XCTAssertFalse(setup.finish(retry, succeeded: true))
    }

    func testLateFailureDoesNotReplaceAnAdvancedLoginScreen() throws {
        for state in ["authorizationStateWaitPhoneNumber", "authorizationStateWaitCode", "authorizationStateReady"] {
            var setup = TelegramAuthorizationSetup()
            setup.observe("authorizationStateWaitTdlibParameters")
            let attempt = try XCTUnwrap(setup.begin(hasCredentials: true))
            let queriedRevision = setup.revision
            setup.observe(state)
            XCTAssertNotEqual(setup.revision, queriedRevision, "An old query must be discarded")
            XCTAssertFalse(setup.finish(attempt, succeeded: false))
            XCTAssertEqual(setup.state, state)
        }
    }

    func testClosedClientStartsFreshAndIgnoresAnOldCompletion() throws {
        var setup = TelegramAuthorizationSetup()
        setup.observe("authorizationStateWaitTdlibParameters")
        let old = try XCTUnwrap(setup.begin(hasCredentials: true))
        setup.reset()
        setup.observe("authorizationStateWaitTdlibParameters")
        let current = try XCTUnwrap(setup.begin(hasCredentials: true))
        XCTAssertFalse(setup.finish(old, succeeded: false))
        XCTAssertNil(setup.begin(hasCredentials: true))
        XCTAssertFalse(setup.finish(current, succeeded: true))
    }
}
