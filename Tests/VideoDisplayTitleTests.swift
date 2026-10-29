import XCTest
@testable import TeveeStreaming

final class VideoDisplayTitleTests: XCTestCase {
    private func video(_ filename: String, id: Int64 = 1) -> TelegramVideo {
        TelegramVideo(messageID: id, chatID: 1, fileID: 1, title: filename, size: 1,
                      mimeType: "video/x-matroska", duration: 0, localPath: "",
                      downloadedBytes: 0, isDownloaded: false, fileName: filename)
    }

    func testRequestedFilenameAndSeparatorVariants() {
        let expected = "Demon Slayer - Kimetsu no Yaiba Infinity C"
        for filename in [
            "Tg @StreamersHub Demon Slayer - Kimetsu no Yaiba Infinity C.mkv",
            "Tg_@StreamersHub_Demon_Slayer_-_Kimetsu_no_Yaiba_Infinity_C.mkv",
            "[TG @StreamersHub] Demon Slayer - Kimetsu no Yaiba Infinity C.mkv MKV",
            "Tg_@Streamers-Hub_Demon_Slayer_-_Kimetsu_no_Yaiba_Infinity_C.MKV"
        ] { XCTAssertEqual(video(filename).displayTitle, expected, filename) }
    }

    func testKeepsMeaningfulEpisodeNumbersAccentsAndPunctuation() {
        XCTAssertEqual(video("Tg_@StreamersHub_Attack_on_Titan_S03E01_1080p.mkv").displayTitle, "Attack on Titan S03E01 1080p")
        XCTAssertEqual(video("Spider-Man.No.Way.Home.(2021).mp4").displayTitle, "Spider-Man No Way Home (2021)")
        XCTAssertEqual(video("L'été_d'Omar.mkv").displayTitle, "L'été d'Omar")
        XCTAssertEqual(video("Telegram_Story.mkv").displayTitle, "Telegram Story")
        XCTAssertEqual(video("A.Movie.unrecognized").displayTitle, "A Movie unrecognized")
        XCTAssertEqual(video("TG @Other_Channel My_Film.mov").displayTitle, "My Film")
        XCTAssertEqual(video("Tg @StreamersHub .mkv").displayTitle, "Untitled video")
    }

    func testDisplayCleanupDoesNotMutateStoredOrExportFilename() throws {
        let original = "Tg @StreamersHub Demon_Slayer.mkv"
        let value = video(original)
        XCTAssertEqual(value.displayTitle, "Demon Slayer")
        let restored = try JSONDecoder().decode(TelegramVideo.self, from: JSONEncoder().encode(value))
        XCTAssertEqual(restored.fileName, original)
        XCTAssertEqual(restored.title, original)
        XCTAssertEqual(restored.id, value.id)
    }

    func testTitleSortingUsesWhatTheUserSeesAndReleaseYearsStayRaw() {
        let z = video("Tg @StreamersHub Zebra_2024.mkv", id: 1)
        let a = video("Alpha_2023.mkv", id: 2)
        XCTAssertEqual(LibraryOrder.titleAscending.sort([z, a]).map(\.id), [a.id, z.id])
        XCTAssertEqual(LibraryOrder.latestRelease.sort([a, z]).map(\.id), [z.id, a.id])
    }
}
