import XCTest
@testable import TeveeStreaming

final class HTTPVideoResponseTests: XCTestCase {
    private func response(_ headers: String = "", size: Int64 = 100, method: String = "GET", path: String = "/session") -> HTTPVideoResponse {
        HTTPVideoResponse.make(request: "\(method) \(path) HTTP/1.1\r\n\(headers)\r\n", path: "/session", size: size, mimeType: "video/mp4")
    }

    func testFullAndEmptyRepresentations() {
        let full = response()
        XCTAssertEqual(full.status, "200 OK")
        XCTAssertEqual(full.length, 100)
        XCTAssertTrue(full.sendsBody)
        let empty = response(size: 0)
        XCTAssertEqual(empty.length, 0)
        XCTAssertFalse(empty.sendsBody)
    }

    func testBoundedOpenEndedAndSuffixRanges() {
        for (range, start, length) in [("10-19", 10, 10), ("90-", 90, 10), ("-20", 80, 20), ("-200", 0, 100), ("95-1000", 95, 5)] {
            let result = response("rAnGe: bytes=\(range)\r\n")
            XCTAssertEqual(result.status, "206 Partial Content", range)
            XCTAssertEqual(result.start, Int64(start), range)
            XCTAssertEqual(result.length, Int64(length), range)
            XCTAssertTrue(String(decoding: result.headers, as: UTF8.self).contains("Content-Range: bytes \(start)-\(start + length - 1)/100"))
        }
    }

    func testUnsatisfiableRangesNeverBecomeFullDownloads() {
        for range in ["100-", "900-999", "50-10", "-0"] {
            let result = response("Range: bytes=\(range)\r\n")
            XCTAssertEqual(result.status, "416 Range Not Satisfiable", range)
            XCTAssertFalse(result.sendsBody)
            XCTAssertTrue(String(decoding: result.headers, as: UTF8.self).contains("Content-Range: bytes */100"))
        }
        XCTAssertEqual(response("Range: bytes=0-\r\n", size: 0).status, "416 Range Not Satisfiable")
    }

    func testMalformedAndMultipleRangesAreRejected() {
        for value in ["bytes=", "bytes=--", "bytes=abc-1", "bytes=1-no", "bytes=+1-5", "items=1-2", "bytes=0-1,4-5", "bytes=9223372036854775808-", "bytes=1-2\r\nRange: bytes=3-4"] {
            XCTAssertEqual(response("Range: \(value)\r\n").status, "400 Bad Request", value)
        }
    }

    func testHeadMethodsAndSessionPath() {
        let head = response("Range: bytes=10-19\r\n", method: "HEAD")
        XCTAssertEqual(head.status, "200 OK")
        XCTAssertEqual(head.length, 100)
        XCTAssertFalse(head.sendsBody)
        XCTAssertEqual(response(method: "POST").status, "405 Method Not Allowed")
        XCTAssertEqual(response(path: "/old-session").status, "404 Not Found")
    }

    func testLargeFileLengthDoesNotOverflow() {
        let result = response("Range: bytes=0-9223372036854775807\r\n", size: Int64.max)
        XCTAssertEqual(result.status, "206 Partial Content")
        XCTAssertEqual(result.length, Int64.max)
    }
}

/// Synthetic scheduling fixtures only; these tests do not connect to Telegram.
private actor ReadProbe {
    private var active: [Int32: Int] = [:]
    private(set) var overlap = false
    func begin(_ file: Int32) {
        active[file, default: 0] += 1
        if active[file, default: 0] > 1 { overlap = true }
    }
    func end(_ file: Int32) { active[file, default: 0] -= 1 }
}

final class TelegramRangeReaderTests: XCTestCase {
    func testConcurrentReadsForOneFileAreSerialized() async throws {
        let reader = TelegramRangeReader()
        let probe = ReadProbe()
        try await withThrowingTaskGroup(of: Data.self) { group in
            for value in 0..<12 {
                group.addTask {
                    try await reader.read(fileID: 1) {
                        await probe.begin(1)
                        try await Task.sleep(nanoseconds: 2_000_000)
                        await probe.end(1)
                        return Data([UInt8(value)])
                    }
                }
            }
            var results: Set<Data> = []
            for try await value in group { results.insert(value) }
            XCTAssertEqual(results.count, 12)
        }
        let overlap = await probe.overlap
        XCTAssertFalse(overlap)
    }

    func testFailureDoesNotPoisonNextRead() async throws {
        let reader = TelegramRangeReader()
        do {
            _ = try await reader.read(fileID: 1) { throw CocoaError(.fileReadUnknown) }
            XCTFail("Expected read failure")
        } catch { }
        let value = try await reader.read(fileID: 1) { Data([42]) }
        XCTAssertEqual(value, Data([42]))
    }

    func testCancellationPropagatesAndQueueRecovers() async throws {
        let reader = TelegramRangeReader()
        let task = Task {
            try await reader.read(fileID: 1) {
                try await Task.sleep(nanoseconds: 5_000_000_000)
                return Data([1])
            }
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        let result = try await reader.read(fileID: 1) { Data([2]) }
        XCTAssertEqual(result, Data([2]))
    }
}

/// Synthetic TDLib-shaped JSON, round-tripped through JSONSerialization so
/// NSNumber bridging matches the actual C JSON response parser.
final class TelegramVideoTests: XCTestCase {
    private func message(document: Bool = false, filename: String = "fixture.mkv", mime: String = "video/x-matroska", complete: Bool = false) throws -> [String: Any] {
        let key = document ? "document" : "video"
        let value: [String: Any] = ["id": 123, "content": ["@type": document ? "messageDocument" : "messageVideo",
            "caption": ["text": ""], key: ["file_name": filename, "mime_type": mime, "duration": 60,
                key: ["id": 17, "size": 1000, "local": ["path": "", "downloaded_size": 200, "is_downloading_completed": complete]]]]]
        return try XCTUnwrap(JSONSerialization.jsonObject(with: JSONSerialization.data(withJSONObject: value)) as? [String: Any])
    }

    func testNativeVideoMetadataDoesNotImplyCompleteDownload() throws {
        let video = try XCTUnwrap(TelegramVideo.from(message: message(), chatID: 42))
        XCTAssertEqual(video.fileID, 17)
        XCTAssertEqual(video.messageID, 123)
        XCTAssertEqual(video.title, "fixture.mkv")
        XCTAssertEqual(video.size, 1000)
        XCTAssertEqual(video.downloadedBytes, 200)
        XCTAssertFalse(video.isDownloaded)
    }

    func testVideoDocumentsAreRecognizedByMimeOrExtension() throws {
        XCTAssertNotNil(TelegramVideo.from(message: try message(document: true, filename: "fixture.bin"), chatID: 42))
        XCTAssertNotNil(TelegramVideo.from(message: try message(document: true, filename: "FIXTURE.MKV", mime: "application/octet-stream"), chatID: 42))
        XCTAssertNil(TelegramVideo.from(message: try message(document: true, filename: "notes.pdf", mime: "application/pdf"), chatID: 42))
    }

    func testIdentitiesIncludeTheChatAndInvalidMessagesAreIgnored() throws {
        let fixture = try message()
        XCTAssertNotEqual(TelegramVideo.from(message: fixture, chatID: 1)?.id, TelegramVideo.from(message: fixture, chatID: 2)?.id)
        XCTAssertNil(TelegramVideo.from(message: [:], chatID: 1))
    }

    func testCompletionFlagAndFilenameArePreservedWithSeparateCaption() throws {
        var fixture = try message(complete: true)
        var content = try XCTUnwrap(fixture["content"] as? [String: Any])
        content["caption"] = ["text": "Synthetic caption"]
        fixture["content"] = content
        let video = try XCTUnwrap(TelegramVideo.from(message: fixture, chatID: 42))
        XCTAssertTrue(video.isDownloaded)
        XCTAssertEqual(video.title, "fixture.mkv")
        XCTAssertEqual(video.fileName, "fixture.mkv")
        XCTAssertEqual(video.caption, "Synthetic caption")
    }
}

final class StreamReadPolicyTests: XCTestCase {
    func testPartialCacheBecomesPlayableBeforeTheWholeReadIsReady() {
        XCTAssertEqual(StreamReadPolicy.readyCount(available: 128 * 1024, requested: 1024 * 1024), 128 * 1024)
        XCTAssertEqual(StreamReadPolicy.readyCount(available: 0, requested: 1024 * 1024), 0)
        XCTAssertEqual(StreamReadPolicy.readyCount(available: 1024, requested: 1024 * 1024), 0)
    }
    func testFinalRangeAndInvalidCountsNeverOverread() {
        XCTAssertEqual(StreamReadPolicy.readyCount(available: Int64.max, requested: 17), 17)
        XCTAssertEqual(StreamReadPolicy.readyCount(available: 16, requested: 17), 0)
        XCTAssertEqual(StreamReadPolicy.readyCount(available: 17, requested: 17), 17)
        XCTAssertEqual(StreamReadPolicy.readyCount(available: -1, requested: 17), 0)
        XCTAssertEqual(StreamReadPolicy.readyCount(available: 100, requested: -1), 0)
    }
    func testPartialReadsCoverTheEntireResponseWithoutGaps() {
        let total = 2 * 1024 * 1024 + 17
        var position = 0
        var reads = 0
        while position < total {
            let requested = min(1024 * 1024, total - position)
            let available = min(128 * 1024, total - position)
            let count = StreamReadPolicy.readyCount(available: Int64(available), requested: requested)
            XCTAssertGreaterThan(count, 0)
            guard count > 0 else { return }
            position += count; reads += 1
        }
        XCTAssertEqual(position, total)
        XCTAssertEqual(reads, 17)
    }
}
