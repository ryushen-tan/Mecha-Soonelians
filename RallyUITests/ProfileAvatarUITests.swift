import XCTest

final class ProfileAvatarUITests: XCTestCase {
    @MainActor func testMatchedNameShowsAIAvatarAndSwitchesViews() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-jelly-still"]
        app.launch()
        XCTAssertTrue(app.buttons["playButton"].waitForExistence(timeout: 10))
        app.buttons["playButton"].tap()
        app.buttons["createTab"].tap()
        let name = app.textFields["nicknameInput"]
        name.tap()
        name.typeText("Kai Song")
        let avatar = app.buttons["profilePhotoPreview"]
        XCTAssertTrue(avatar.waitForExistence(timeout: 5))
        avatar.tap()
        let image = app.images["profileAvatarImage"]
        XCTAssertTrue(image.waitForExistence(timeout: 5))
        XCTAssertEqual(image.label, "Front avatar view for Kai Song")
        let front = XCTAttachment(screenshot: app.screenshot())
        front.name = "AI avatar front view"
        front.lifetime = .keepAlways
        add(front)
        app.segmentedControls.buttons["Angle"].tap()
        XCTAssertEqual(image.label, "Angle avatar view for Kai Song")
        app.segmentedControls.buttons["Back"].tap()
        XCTAssertEqual(image.label, "Back avatar view for Kai Song")
        let rotated = XCTAttachment(screenshot: app.screenshot())
        rotated.name = "AI avatar back view"
        rotated.lifetime = .keepAlways
        add(rotated)
        app.buttons["Done"].tap()
        XCTAssertTrue(avatar.waitForExistence(timeout: 5))
        name.tap()
        name.typeText("x")
        XCTAssertFalse(avatar.exists, "Changing to an unmatched name must remove the previous avatar")
    }
}
