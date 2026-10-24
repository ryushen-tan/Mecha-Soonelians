import XCTest

final class RallyUITests: XCTestCase {
    @MainActor func testGeneratedHumanWheelPaintingAndSave() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing"]
        app.launch()
        app.buttons["studioTab"].tap()
        let character = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'character_'")).firstMatch
        for _ in 0..<4 where !character.isHittable { app.swipeUp() }
        guard character.exists else { throw XCTSkip("Generate a human once before running the real-human UI test.") }
        let characterID = character.identifier
        character.tap()
        let wheel = app.buttons["poseWheelButton"]
        XCTAssertTrue(wheel.waitForExistence(timeout: 30))
        let enabled = NSPredicate(format: "enabled == true")
        expectation(for: enabled, evaluatedWith: wheel)
        waitForExpectations(timeout: 30)
        wheel.tap()
        XCTAssertTrue(app.buttons["poseChoice_stand"].waitForExistence(timeout: 5))
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Real human pose wheel"
        attachment.lifetime = .keepAlways
        add(attachment)
        app.buttons["poseChoice_stand"].tap()
        app.segmentedControls.buttons["Paint"].tap()
        let canvas = app.webViews.firstMatch
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.48)).press(forDuration: 0.1,
            thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.55)))
        let undo = app.buttons["Undo paint"]
        expectation(for: enabled, evaluatedWith: undo)
        waitForExpectations(timeout: 10)
        undo.tap()
        XCTAssertTrue(app.buttons["Redo paint"].isEnabled)
        app.buttons["Redo paint"].tap()
        app.buttons["save3DCharacterButton"].tap()
        XCTAssertTrue(app.staticTexts["Character, paint and pose saved"].waitForExistence(timeout: 30))
        app.navigationBars.buttons.firstMatch.tap()
        app.buttons[characterID].tap()
        XCTAssertTrue(app.buttons["poseWheelButton"].waitForExistence(timeout: 30))
        let saved = XCTAttachment(screenshot: app.screenshot())
        saved.name = "Reopened painted human"
        saved.lifetime = .keepAlways
        add(saved)
    }

    @MainActor func testStudioOpensHumanDepthEditorAndPoseControls() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing"]
        app.launch()
        app.buttons["studioTab"].tap()
        app.buttons["makePlayerButton"].tap()
        XCTAssertTrue(app.staticTexts["Find your people."].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["studioTab"].exists)
        let edit = app.buttons["playerPrimaryAction"]
        let enabled = NSPredicate(format: "enabled == true")
        expectation(for: enabled, evaluatedWith: edit)
        waitForExpectations(timeout: 40)
        app.segmentedControls.buttons["Depth"].tap()
        XCTAssertFalse(app.staticTexts["No depth attached"].exists)
        edit.tap()
        XCTAssertTrue(app.staticTexts["Pose rig"].exists)
        XCTAssertTrue(app.buttons["Wave"].exists)
        app.buttons["Wave"].tap()
        edit.tap()
        XCTAssertTrue(app.alerts["Player editor"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.alerts.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Saved'")).firstMatch.exists)
        app.alerts.buttons["OK"].tap()
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.buttons["studioTab"].waitForExistence(timeout: 5))
    }

    @MainActor func testJoinAndCreateNavigationMatchesApprovedPreview() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing"]
        app.launch()
        XCTAssertTrue(app.buttons["joinTab"].exists)
        XCTAssertTrue(app.buttons["createTab"].exists)
        XCTAssertFalse(app.buttons["joinRoomButton"].isEnabled)
        XCTAssertFalse(app.buttons["Server settings"].exists)
        app.buttons["createTab"].tap()
        XCTAssertTrue(app.textFields["nicknameInput"].exists)
        XCTAssertFalse(app.buttons["confirmEntryButton"].isEnabled)
        XCTAssertFalse(app.staticTexts["Room size"].exists)
        app.textFields["nicknameInput"].tap()
        app.textFields["nicknameInput"].typeText("Kai")
        XCTAssertTrue(app.buttons["confirmEntryButton"].isEnabled)
        app.buttons["joinTab"].tap()
        XCTAssertTrue(app.textFields["roomCodeInput"].exists)
    }
}
