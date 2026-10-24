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
        let mode = app.buttons["editorModeButton"]
        XCTAssertTrue(mode.waitForExistence(timeout: 30))
        mode.tap()
        app.buttons["editorPositionMode"].tap()
        let wheel = app.buttons["poseWheelButton"]
        XCTAssertTrue(wheel.waitForExistence(timeout: 30))
        let enabled = NSPredicate(format: "enabled == true")
        expectation(for: enabled, evaluatedWith: wheel)
        waitForExpectations(timeout: 30)
        let canvas = app.webViews.firstMatch
        XCTAssertGreaterThan(canvas.frame.height, app.frame.height * 0.9, "The room must fill the screen, not a small editor preview.")
        XCTAssertFalse(app.buttons["Attach to surface"].exists, "Advanced tools must stay out of the full-screen scene.")
        XCTAssertFalse(app.navigationBars["3D character"].exists)
        app.buttons["editorOptionsButton"].tap()
        app.buttons["editorToolsButton"].tap()
        XCTAssertTrue(app.buttons["Attach to surface"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.sliders["Body size"].exists)
        app.buttons["dismissEditorPanelButton"].tap()
        wheel.tap()
        XCTAssertTrue(app.buttons["poseChoice_stand"].waitForExistence(timeout: 5))
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Real human pose wheel"
        attachment.lifetime = .keepAlways
        add(attachment)
        app.buttons["Next pose wheel page"].tap()
        XCTAssertTrue(app.buttons["poseChoice_kneel"].exists)
        app.buttons["Next pose wheel page"].tap()
        app.buttons["poseChoice_stand"].tap()
        XCTAssertTrue(app.buttons["objectTransform_translate"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["objectTransform_rotate"].exists)
        XCTAssertTrue(app.buttons["objectTransform_scale"].exists)
        XCTAssertEqual(wheel.label, "Pose")
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Drag your person'")).firstMatch.waitForExistence(timeout: 5))
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.1,
            thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.56, dy: 0.48)))
        app.buttons["objectTransform_rotate"].tap()
        XCTAssertTrue(app.staticTexts["Drag the X / Y / Z rings to rotate"].waitForExistence(timeout: 5))
        app.buttons["objectTransform_scale"].tap()
        XCTAssertTrue(app.staticTexts["Drag a size handle · or drag your person up/down"].waitForExistence(timeout: 5))
        app.buttons["objectTransform_translate"].tap()
        let placement = XCTAttachment(screenshot: app.screenshot())
        placement.name = "Direct mesh selection and transform handles"
        placement.lifetime = .keepAlways
        add(placement)
        app.buttons["lockPlacementButton"].tap()
        XCTAssertTrue(app.buttons["save3DCharacterButton"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["poseWheelButton"].exists)
        let backdrop = XCTAttachment(screenshot: app.screenshot())
        backdrop.name = "Painting against the room wall"
        backdrop.lifetime = .keepAlways
        add(backdrop)
        XCTAssertFalse(app.buttons["Undo paint"].isEnabled)
        canvas.pinch(withScale: 1.6, velocity: 1)
        canvas.pinch(withScale: 0.625, velocity: -1)
        XCTAssertFalse(app.buttons["Undo paint"].isEnabled, "Pinching must never leave accidental paint marks.")
        app.buttons["editorOptionsButton"].tap()
        app.buttons["paintWallViewButton"].tap()
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.48)).press(forDuration: 0.1,
            thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.55)))
        let undo = app.buttons["Undo paint"]
        expectation(for: enabled, evaluatedWith: undo)
        waitForExpectations(timeout: 10)
        undo.tap()
        XCTAssertTrue(app.buttons["Redo paint"].isEnabled)
        app.buttons["Redo paint"].tap()
        app.buttons["paintColorsButton"].tap()
        XCTAssertTrue(app.staticTexts["Paint your disguise"].waitForExistence(timeout: 5))
        app.buttons["dismissEditorPanelButton"].tap()
        app.buttons["save3DCharacterButton"].tap()
        XCTAssertTrue(app.staticTexts["Character, paint and pose saved"].waitForExistence(timeout: 30))
        app.buttons["close3DEditorButton"].tap()
        app.buttons[characterID].tap()
        XCTAssertTrue(app.buttons["save3DCharacterButton"].waitForExistence(timeout: 30))
        let saved = XCTAttachment(screenshot: app.screenshot())
        saved.name = "Reopened painted human"
        saved.lifetime = .keepAlways
        add(saved)
        app.buttons["editorModeButton"].tap()
        app.buttons["editorPositionMode"].tap()
        XCTAssertTrue(app.buttons["poseWheelButton"].waitForExistence(timeout: 5))
        app.buttons["lockPlacementButton"].tap()
        XCTAssertTrue(app.buttons["save3DCharacterButton"].waitForExistence(timeout: 5))
        let restoredBackdrop = XCTAttachment(screenshot: app.screenshot())
        restoredBackdrop.name = "Reopened wall painting view"
        restoredBackdrop.lifetime = .keepAlways
        add(restoredBackdrop)
        app.buttons["close3DEditorButton"].tap()
        XCTAssertTrue(app.buttons["Close without saving"].waitForExistence(timeout: 5))
        app.buttons["keepEditingButton"].firstMatch.tap()
        XCTAssertTrue(app.buttons["save3DCharacterButton"].exists)
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
