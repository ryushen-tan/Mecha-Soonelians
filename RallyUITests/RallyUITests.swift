import XCTest

final class RallyUITests: XCTestCase {
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
