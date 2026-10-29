import Foundation
import XCTest
@testable import TeveeStreaming

final class NoticeHistoryTests: XCTestCase {
    func fixture() throws -> [[String: Any]] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "notice-history", withExtension: "json", subdirectory: "Fixtures"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]])
    }
    func testHistoryKeepsReadMessagesAndClearPreventsOutOfOrderResurrection() throws {
        let messages = try fixture()
        var history = NoticeHistory()
        history.ingest(messages[0]); history.ingest(messages[1]); history.ingest(messages[0])
        XCTAssertEqual(history.ordered.compactMap { $0["id"] as? Int64 }, [20,10])
        // A new broadcast delivered before the older clear is still retained.
        history.ingest(messages[3]); history.ingest(messages[2])
        XCTAssertEqual(history.ordered.compactMap { $0["id"] as? Int64 }, [40])
        history.ingest(messages[0]); history.ingest(messages[1]); history.ingest(messages[2])
        XCTAssertEqual(history.messages.count,1)
        history.remove([40]); XCTAssertTrue(history.ordered.isEmpty)
    }
    func testSelectedDeletePreservesOtherCampaignsAndBlocksLatePages() throws {
        let values = try fixture()
        var history = NoticeHistory()
        history.ingest(values[0]); history.ingest(values[1]); history.ingest(values[3])
        history.ingest(values[4]); history.ingest(values[0]); history.ingest(values[1])
        XCTAssertEqual(history.ordered.compactMap { $0["id"] as? Int64 }, [40])
        // Reconstructing history newest first must produce the same result.
        var reloaded = NoticeHistory()
        reloaded.ingest(values[4]); reloaded.ingest(values[3]); reloaded.ingest(values[1]); reloaded.ingest(values[0])
        XCTAssertEqual(reloaded.ordered.compactMap { $0["id"] as? Int64 }, [40])
        XCTAssertEqual(reloaded.clearedThrough, 0)
    }
    func testOnlyValidAnnouncementMarkersAreAccepted() throws {
        var messages = try fixture()
        var history = NoticeHistory()
        messages[0].removeValue(forKey: "reply_markup")
        history.ingest(messages[0]); XCTAssertTrue(history.messages.isEmpty)
        messages[1]["reply_markup"] = ["@type":"replyMarkupInlineKeyboard", "rows":[[["type":["@type":"inlineKeyboardButtonTypeCallback", "data":"!!!!"]]]]]
        history.ingest(messages[1]); XCTAssertTrue(history.messages.isEmpty)
    }
}
