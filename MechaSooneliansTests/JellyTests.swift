import AVFoundation
import SpriteKit
import XCTest
@testable import MechaSoonelians

final class JellyTests: XCTestCase {
    @MainActor func testBundledReferenceAssetsAndFontsAreUsableOffline() throws {
        for pose in 1...8 {
            let url = try XCTUnwrap(Bundle.main.url(forResource: "pose-\(pose)", withExtension: "png", subdirectory: "JellyAssets/sprites"))
            XCTAssertNotNil(UIImage(contentsOfFile: url.path))
        }
        let music = try XCTUnwrap(Bundle.main.url(forResource: "bgm", withExtension: "mp3", subdirectory: "JellyAssets/audio"))
        XCTAssertGreaterThan(try AVAudioPlayer(contentsOf: music).duration, 1)
        XCTAssertNotNil(UIFont(name: "Outfit-Thin_ExtraBold", size: 24))
        XCTAssertNotNil(UIFont(name: "Nunito-Regular", size: 18))
    }

    @MainActor func testReducedMotionHasImmediateVisiblePlayAndRefillsAtDifferentSizes() {
        for size in [CGSize(width: 320, height: 568), CGSize(width: 402, height: 874), CGSize(width: 1024, height: 768)] {
            let state = JellySceneState()
            state.scene.size = size
            state.scene.configure(reducedMotion: true, suspended: false)
            XCTAssertTrue(state.filled)
            XCTAssertGreaterThan(state.count, 20)
            XCTAssertTrue(CGRect(origin: .zero, size: size).contains(state.playPosition.frame))
            let originalCount = state.count
            state.scene.refill()
            XCTAssertEqual(state.count, originalCount, "Refill must replace the pile, not accumulate bodies")
            XCTAssertFalse(state.tiltEnabled)
        }
    }
}
