import XCTest

final class MechaSooneliansUITests: XCTestCase {
    @MainActor func testFigureSetupFollowsAvatarAndBlocksEntryUntilReady() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-jelly-still", "-personalCharacterID", "missing-test-character"]
        app.launch()
        XCTAssertTrue(app.buttons["playButton"].waitForExistence(timeout: 8))
        app.buttons["playButton"].tap()
        XCTAssertFalse(app.staticTexts["characterSetupTitle"].exists)
        app.buttons["createTab"].tap()
        let nickname = app.textFields["nicknameInput"]
        nickname.tap(); nickname.typeText("Kai\n")
        XCTAssertTrue(nickname.exists, "Keyboard submission cannot bypass the figure requirement.")
        for _ in 0..<3 where !app.buttons["figureGalleryButton"].isHittable { app.swipeUp() }
        XCTAssertFalse(app.buttons["confirmEntryButton"].isEnabled)
        let identity = XCTAttachment(screenshot: app.screenshot())
        identity.name = "Avatar and required figure"; identity.lifetime = .keepAlways; add(identity)
        app.buttons["figureGalleryButton"].tap()
        XCTAssertTrue(app.buttons["addFigureButton"].waitForExistence(timeout: 5))
        let gallery = XCTAttachment(screenshot: app.screenshot())
        gallery.name = "3D figure gallery"; gallery.lifetime = .keepAlways; add(gallery)
        app.buttons["addFigureButton"].tap()
        XCTAssertTrue(app.buttons["scanCharacterSetupButton"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["importCharacterSetupButton"].exists)
        XCTAssertFalse(app.otherElements["figureGenerationHeader"].exists)
        let capture = XCTAttachment(screenshot: app.screenshot())
        capture.name = "New 3D figure"; capture.lifetime = .keepAlways; add(capture)
    }

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
        XCTAssertTrue(app.buttons["makePlayerButton"].waitForExistence(timeout: 5))
    }

    @MainActor func testJellyNavigationAndInputValidation() {
        let app = jellyApp()
        XCTAssertTrue(app.buttons["studioTab"].exists)
        XCTAssertTrue(app.buttons["playButton"].waitForExistence(timeout: 5))
        let sound = app.buttons["soundButton"]
        let previous = sound.value as? String
        sound.tap()
        XCTAssertNotEqual(sound.value as? String, previous)
        sound.tap()
        app.buttons["playButton"].tap()
        XCTAssertFalse(app.buttons["joinRoomButton"].isEnabled)
        let code = app.textFields["roomCodeInput"]
        code.tap(); code.typeText("1234567")
        XCTAssertEqual(code.value as? String, "123456")
        app.buttons["joinRoomButton"].tap()
        XCTAssertTrue(app.textFields["nicknameInput"].exists)
        XCTAssertFalse(app.buttons["confirmEntryButton"].isEnabled)
        app.buttons["backToCodeButton"].tap()
        app.buttons["createTab"].tap()
        XCTAssertFalse(app.staticTexts["Room size"].exists)
        app.textFields["nicknameInput"].tap()
        app.textFields["nicknameInput"].typeText("Kai")
        app.buttons["Pink avatar"].tap()
        XCTAssertTrue(app.buttons["confirmEntryButton"].isEnabled)
        app.buttons["backToCodeButton"].tap()
        app.buttons["backToSceneButton"].tap()
        XCTAssertTrue(app.buttons["playButton"].exists)
        app.buttons["refillButton"].tap()
        XCTAssertTrue(app.buttons["playButton"].exists)
    }

    @MainActor func testJellyHostLobbyScrollStartAndEnd() async throws {
        try await requireServer()
        let app = jellyApp()
        app.buttons["playButton"].tap()
        app.buttons["createTab"].tap()
        app.textFields["nicknameInput"].tap()
        app.textFields["nicknameInput"].typeText("UI Host")
        app.buttons["confirmEntryButton"].tap()
        let codeLabel = app.staticTexts["lobbyRoomCode"]
        XCTAssertTrue(codeLabel.waitForExistence(timeout: 10))
        let code = codeLabel.label.filter(\.isNumber)
        XCTAssertEqual(code.count, 6)
        XCTAssertFalse(app.buttons["startSessionButton"].isEnabled)
        for index in 1...6 {
            let guest = try await request("rooms/\(code)/join", method: "POST", body: ["name": "Guest \(index)", "avatar": index % 6])
            _ = try await request("rooms/\(code)/me", method: "PATCH", token: guest["token"] as? String, body: ["ready": true])
        }
        XCTAssertTrue(app.staticTexts["7 players"].waitForExistence(timeout: 10))
        let list = app.scrollViews["playerList"]
        list.swipeUp()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Guest 6'")).firstMatch.isHittable)
        capture(app, "Jelly host with seven players")
        app.buttons["startSessionButton"].tap()
        XCTAssertTrue(app.staticTexts["Game on!"].waitForExistence(timeout: 10))
        app.buttons["openStudioButton"].tap()
        XCTAssertTrue(app.buttons["makePlayerButton"].waitForExistence(timeout: 5))
        app.buttons["Done"].tap()
        app.buttons["Back to lobby"].tap()
        XCTAssertTrue(app.buttons["startSessionButton"].waitForExistence(timeout: 10))
        app.buttons["leaveRoomButton"].tap()
        app.alerts.buttons["End room"].tap()
        XCTAssertTrue(app.textFields["roomCodeInput"].waitForExistence(timeout: 10))
    }

    @MainActor func testJellyGuestJoinsRealRoomAndReceivesStart() async throws {
        try await requireServer()
        let host = try await request("rooms", method: "POST", body: ["name": "API Host", "avatar": 1])
        let room = try XCTUnwrap(host["room"] as? [String: Any])
        let code = try XCTUnwrap(room["code"] as? String)
        let token = try XCTUnwrap(host["token"] as? String)
        let app = jellyApp()
        app.buttons["playButton"].tap()
        app.textFields["roomCodeInput"].tap()
        app.textFields["roomCodeInput"].typeText(code)
        app.buttons["joinRoomButton"].tap()
        app.textFields["nicknameInput"].tap()
        app.textFields["nicknameInput"].typeText("UI Guest")
        app.buttons["confirmEntryButton"].tap()
        XCTAssertTrue(app.buttons["readyButton"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.buttons["readyButton"].label, "Ready")
        XCTAssertEqual(app.buttons["readyButton"].value as? String, "Not ready")
        app.buttons["readyButton"].tap()
        let ready = NSPredicate(format: "label == 'Un-ready'")
        await fulfillment(of: [XCTNSPredicateExpectation(predicate: ready, object: app.buttons["readyButton"])], timeout: 10)
        app.buttons["readyButton"].tap()
        let notReady = NSPredicate(format: "label == 'Ready'")
        await fulfillment(of: [XCTNSPredicateExpectation(predicate: notReady, object: app.buttons["readyButton"])], timeout: 10)
        app.buttons["readyButton"].tap()
        await fulfillment(of: [XCTNSPredicateExpectation(predicate: ready, object: app.buttons["readyButton"])], timeout: 10)
        capture(app, "Jelly guest waiting room")
        _ = try await request("rooms/\(code)", method: "PATCH", token: token, body: ["status": "started"])
        XCTAssertTrue(app.staticTexts["Game on!"].waitForExistence(timeout: 10))
        app.buttons["leaveRoomButton"].tap()
        app.alerts.buttons["Leave room"].tap()
        XCTAssertTrue(app.textFields["roomCodeInput"].waitForExistence(timeout: 10))
        _ = try await request("rooms/\(code)/leave", method: "POST", token: token)
    }

    @MainActor private func jellyApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-jelly-still", "-server-url", "http://localhost:3000"]
        app.launch()
        XCTAssertTrue(app.buttons["playButton"].waitForExistence(timeout: 5))
        return app
    }

    @MainActor private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }

    private func requireServer() async throws {
        do { _ = try await request("health") }
        catch { throw XCTSkip("Run the Rally server on localhost:3000 for lobby integration UI tests.") }
    }

    private func request(_ path: String, method: String = "GET", token: String? = nil, body: [String: Any]? = nil) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "http://localhost:3000/" + path)!)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = try XCTUnwrap(response as? HTTPURLResponse).statusCode
        guard (200..<300).contains(status) else { throw NSError(domain: "RallyUITests", code: status) }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
