import XCTest
import UIKit
import Combine
@testable import Rally

final class StudioTests: XCTestCase {
    @MainActor func testSelfieTimerCountsDownFiveSecondsAndCapturesOnlyOnce() async throws {
        let timer = PersonCaptureTimer { try await Task.sleep(for: .milliseconds(10)) }
        var values: [Int] = []
        let observation = timer.$secondsRemaining.compactMap { $0 }.sink { values.append($0) }
        defer { observation.cancel() }
        let captured = expectation(description: "Photo captured after countdown")
        var captures = 0
        timer.start { captures += 1; captured.fulfill() }
        timer.start { XCTFail("Repeated taps must not create another capture.") }
        XCTAssertEqual(timer.secondsRemaining, 5)
        XCTAssertEqual(captures, 0)
        await fulfillment(of: [captured], timeout: 2)
        XCTAssertEqual(values, [5, 4, 3, 2, 1])
        XCTAssertEqual(captures, 1)
        XCTAssertNil(timer.secondsRemaining)
    }

    @MainActor func testCancellingOrLeavingSelfieTimerNeverCapturesAndCanRestart() async throws {
        let timer = PersonCaptureTimer { try await Task.sleep(for: .milliseconds(20)) }
        timer.start { XCTFail("A cancelled timer must not take a photo.") }
        timer.cancel()
        XCTAssertNil(timer.secondsRemaining)
        let captured = expectation(description: "Restarted timer captures")
        timer.start { captured.fulfill() }
        await fulfillment(of: [captured], timeout: 2)
        XCTAssertNil(timer.secondsRemaining)
    }

    @MainActor func testSelfieTimerUsesFiveRealSecondsByDefault() async throws {
        let timer = PersonCaptureTimer()
        let started = ContinuousClock.now
        let captured = expectation(description: "Five-second timer captures")
        timer.start {
            XCTAssertGreaterThanOrEqual(started.duration(to: .now), .seconds(5))
            captured.fulfill()
        }
        await fulfillment(of: [captured], timeout: 8)
    }

    func testIncompleteCaptureWarnsBeforePaidGeneration() throws {
        let image = try XCTUnwrap(UIGraphicsImageRenderer(size: CGSize(width: 10, height: 10)).image { _ in }.cgImage)
        let cropped = HumanDetection(id: 1, bounds: CGRect(x: 0.2, y: 0.1, width: 0.6, height: 0.9), joints: [], cutout: image, mask: image)
        XCTAssertNotNil(cropped.generationWarning)
        let joints = ["leftAnkle", "rightAnkle", "leftWrist", "rightWrist"].map { BodyJoint(name: $0, point: CGPoint(x: 0.5, y: 0.5), confidence: 1) }
        let complete = HumanDetection(id: 1, bounds: CGRect(x: 0.2, y: 0.1, width: 0.6, height: 0.8), joints: joints, cutout: image, mask: image)
        XCTAssertNil(complete.generationWarning)
    }

    func testLibraryIgnoresIncompleteAndHiddenExports() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let preview = UIGraphicsImageRenderer(size: CGSize(width: 10, height: 10)).image { context in
            UIColor.green.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 10, height: 10))
        }
        for name in ["complete", "incomplete", ".saving-hidden"] {
            let folder = directory.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try preview.pngData()?.write(to: folder.appendingPathComponent("cutout.png"))
            if name != "incomplete" { try Data("{}".utf8).write(to: folder.appendingPathComponent("rig.json")) }
        }
        XCTAssertEqual(SavedPlayer.load(from: directory).map(\.id), ["complete"])
        XCTAssertTrue(SavedPlayer.load(from: directory.appendingPathComponent("missing")).isEmpty)
    }

    func testRigPreservesArmLengthAndPropagatesParentRotation() throws {
        let joints = [
            BodyJoint(name: "rightShoulder", point: CGPoint(x: 0.2, y: 0.2), confidence: 1),
            BodyJoint(name: "rightElbow", point: CGPoint(x: 0.5, y: 0.2), confidence: 1),
            BodyJoint(name: "rightWrist", point: CGPoint(x: 0.8, y: 0.2), confidence: 1)
        ]
        let rig = BodyRig(joints: joints, imageSize: CGSize(width: 100, height: 100))
        XCTAssertEqual(rig.bones.count, 2)
        XCTAssertEqual(rig.posedPoints(angles: [:]), rig.points)
        let posed = rig.posedPoints(angles: ["rightUpperArm": 90])
        let wrist = try XCTUnwrap(posed["rightWrist"])
        let elbow = try XCTUnwrap(posed["rightElbow"])
        XCTAssertEqual(wrist.x, 20, accuracy: 0.001)
        XCTAssertEqual(wrist.y, 80, accuracy: 0.001)
        XCTAssertEqual(hypot(wrist.x - elbow.x, wrist.y - elbow.y), 30, accuracy: 0.001)
    }
}
