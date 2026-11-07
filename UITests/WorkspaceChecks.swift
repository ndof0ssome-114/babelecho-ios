import XCTest

final class WorkspaceChecks: XCTestCase {
    private var app: XCUIApplication!
    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--ui-test-fixture"]
        app.launch()
        XCTAssertTrue(app.textFields["Meeting title"].waitForExistence(timeout: 10))
    }
    /// iPhone shows a bottom UITabBar; iPad shows the tabs at the top, outside any tab bar.
    private func tab(_ name: String) -> XCUIElement {
        let bar = app.tabBars.buttons[name]
        return bar.exists ? bar : app.buttons[name].firstMatch
    }
    private func attachment(_ name: String) {
        let item = XCTAttachment(screenshot: app.screenshot())
        item.name = name
        item.lifetime = .keepAlways
        add(item)
    }
    func testTranscriptCopyAndSummarySwitch() {
        let copy = app.buttons["Copy all"]
        for _ in 0..<3 where !copy.isHittable { app.swipeUp() }
        XCTAssertTrue(app.staticTexts["Synthetic test transcript."].exists)
        copy.tap()
        XCTAssertTrue(app.buttons["Copied"].exists)
        app.buttons["panel-summary"].tap()
        XCTAssertTrue(app.staticTexts["Synthetic summary."].exists)
        XCTAssertTrue(app.buttons["Copy all"].exists)
        attachment("summary-and-copy")
    }
    func testProviderChangeClearsModelAndDraftSurvivesTabSwitch() {
        tab("Settings").tap()
        app.buttons.matching(NSPredicate(format: "label CONTAINS 'Summary' AND label CONTAINS 'deepseek' ")).firstMatch.tap()
        let field = app.textFields["model-summary"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertEqual(field.value as? String, "deepseek-flash")
        app.buttons["provider-summary"].tap()
        app.buttons["local"].tap()
        XCTAssertEqual(field.value as? String, "Model ID")
        field.tap()
        field.typeText("typed-custom-model")
        tab("History").tap()
        tab("Settings").tap()
        XCTAssertEqual(app.textFields["model-summary"].value as? String, "typed-custom-model")
        attachment("custom-model-draft")
    }
    func testDarkWorkspaceAndLocalPlayback() {
        app.terminate()
        app.launchArguments += ["--ui-test-dark"]
        app.launch()
        let play = app.buttons["Play audio"]
        for _ in 0..<4 where !play.isHittable { app.swipeUp() }
        XCTAssertTrue(app.staticTexts["00:04"].exists)
        play.tap()
        let pause = app.buttons["Pause audio"]
        XCTAssertTrue(pause.waitForExistence(timeout: 2))
        pause.tap()
        XCTAssertTrue(app.buttons["Play audio"].exists)
        attachment("dark-local-playback")
    }

    func testLargeTextPanelsRemainReachable() {
        app.terminate()
        app.launchArguments += ["--ui-test-large-text"]
        app.launch()
        let panel = app.buttons["panel-transcript"]
        for _ in 0..<6 where !panel.isHittable { app.swipeUp() }
        XCTAssertTrue(panel.isHittable)
        app.scrollViews["content-panels"].swipeLeft()
        let stats = app.buttons["panel-stats"]
        XCTAssertTrue(stats.isHittable)
        stats.tap()
        XCTAssertTrue(stats.isSelected)
        app.swipeUp()
        attachment("large-text-stats")
    }

    func testConsentCancelKeepsLocalMeetingAndDoesNotStartMicrophone() {
        app.buttons["Start recording"].tap()
        XCTAssertTrue(app.alerts["Recording and data use"].waitForExistence(timeout: 5))
        app.alerts.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["Start recording"].exists)
        XCTAssertFalse(app.buttons["Stop recording"].exists)
        tab("History").tap()
        XCTAssertTrue(app.staticTexts["Synthetic UI test"].exists)
        attachment("history-local-fixture")
    }
}
