import XCTest

final class RallyUITests: XCTestCase {
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
