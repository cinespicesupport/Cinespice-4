import XCTest
@testable import TeveeStreaming

final class PlayerPresentationTests: XCTestCase {
    func testLockLeavesThePictureClearUntilAnExplicitTapRevealsUnlock() {
        var lock = PlayerControlLock()
        lock.reveal(); XCTAssertFalse(lock.unlockVisible)
        lock.lock(); XCTAssertTrue(lock.locked); XCTAssertFalse(lock.unlockVisible)
        lock.reveal(); XCTAssertTrue(lock.unlockVisible); XCTAssertTrue(lock.locked)
        lock.hideUnlock(); XCTAssertTrue(lock.locked); XCTAssertFalse(lock.unlockVisible)
        lock.reveal(); lock.unlock(); XCTAssertFalse(lock.locked); XCTAssertFalse(lock.unlockVisible)
        lock.lock(); XCTAssertFalse(lock.unlockVisible)
    }
    func testLateSubtitleDiscoveryAutoSelectsARealIDAndKeepsVLCDefault() {
        let selection = SubtitleSelection()
        XCTAssertNil(selection.desired(available: [], current: -1))
        XCTAssertNil(selection.desired(available: [-1], current: -1))
        XCTAssertEqual(selection.desired(available: [-1,3,7], current: -1), 3)
        XCTAssertEqual(selection.desired(available: [0,7], current: -1), 0)
        XCTAssertNil(selection.desired(available: [-1,3,7], current: 7))
    }
    func testExplicitOffSurvivesDiscoveryAndImportCanEnableSubtitlesAgain() {
        var selection = SubtitleSelection()
        selection.select(-1)
        XCTAssertNil(selection.desired(available: [-1,3], current: -1))
        XCTAssertEqual(selection.desired(available: [-1,3,7], current: 7), -1)
        selection.imported()
        XCTAssertNil(selection.desired(available: [-1,3,7], current: 7))
        XCTAssertEqual(selection.desired(available: [-1,3,7], current: -1), 3)
    }
    func testTrackChoiceWaitsForItsIDAndNeverUsesAnArrayPositionAsAnID() {
        var selection = SubtitleSelection()
        selection.select(7)
        XCTAssertNil(selection.desired(available: [-1,3], current: -1))
        XCTAssertEqual(selection.desired(available: [-1,3,7], current: 3), 7)
        XCTAssertNil(selection.desired(available: [-1,3,7], current: 7))
    }
    func testPairedBitmapSubtitleImportAttachesTheIndexOnly() {
        let bitmap = URL(fileURLWithPath: "/tmp/movie.sub")
        let index = URL(fileURLWithPath: "/tmp/movie.idx")
        let text = URL(fileURLWithPath: "/tmp/other.sub")
        let srt = URL(fileURLWithPath: "/tmp/captions.srt")
        XCTAssertEqual(SubtitleAttachments.tracks(in: [bitmap,index,text,srt]), [index,text,srt])
        XCTAssertEqual(SubtitleAttachments.tracks(in: [bitmap]), [bitmap])
        XCTAssertEqual(SubtitleAttachments.tracks(in: [index,bitmap]), [index])
    }
    func testFitKeepsNativeRatioAndFillUsesRetinaPixelScale() throws {
        let fit = try XCTUnwrap(PlayerAspect.fit.layout(width: 400, height: 300, videoWidth: 1920, videoHeight: 1080, displayScale: 3))
        XCTAssertNil(fit.aspect); XCTAssertEqual(fit.scale, 0); XCTAssertEqual(fit.pictureHeight, 225)
        let fill = try XCTUnwrap(PlayerAspect.fill.layout(width: 400, height: 300, videoWidth: 1920, videoHeight: 1080, displayScale: 3))
        XCTAssertNil(fill.aspect); XCTAssertEqual(fill.scale, Float(300.0/1080*3), accuracy: 0.0001)
        XCTAssertEqual(fill.pictureHeight, 300)
        let rotated = try XCTUnwrap(PlayerAspect.fill.layout(width: 800, height: 350, videoWidth: 1920, videoHeight: 1080, displayScale: 2))
        XCTAssertEqual(rotated.scale, Float(800.0/1920*2), accuracy: 0.0001)
        XCTAssertEqual(rotated.pictureHeight, 450)
    }
    func testForcedRatiosResetFillScalingAndInvalidDimensionsWaitForVideo() throws {
        let classic = try XCTUnwrap(PlayerAspect.classic.layout(width: 400, height: 300, videoWidth: 1920, videoHeight: 1080, displayScale: 3))
        XCTAssertEqual(classic.aspect, "4:3"); XCTAssertEqual(classic.scale, 0); XCTAssertEqual(classic.pictureHeight, 300)
        XCTAssertNil(PlayerAspect.fill.layout(width: 0, height: 300, videoWidth: 1920, videoHeight: 1080, displayScale: 3))
        XCTAssertNil(PlayerAspect.fill.layout(width: 400, height: 300, videoWidth: 0, videoHeight: 0, displayScale: 3))
        XCTAssertNil(PlayerAspect.fit.layout(width: .nan, height: 300, videoWidth: 1920, videoHeight: 1080, displayScale: 3))
        XCTAssertNil(PlayerAspect.fill.layout(width: 400, height: 300, videoWidth: 1920, videoHeight: 1080, displayScale: .infinity))
    }
}
