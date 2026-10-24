import XCTest

/// Runs only against the disposable localhost server seeded by scripts/smoke-fixture.mjs.
final class StudyFlowTests: XCTestCase {
    private let api = SmokeAPI()

    override func setUpWithError() throws {
        continueAfterFailure = false
        executionTimeAllowance = 60
    }

    @MainActor
    func testAskClaudeDragPersistsAPageRegion() async throws {
        let notebook = try await fixture()
        let page = try XCTUnwrap(notebook.pages.first)
        let existing = Set((page.doubts ?? []).map(\.id))
        try await api.setView(notebook: notebook.id, page: page.id)
        let app = launch()
        defer { app.terminate() }
        try openFirstPage(app, pageId: page.id)
        app.buttons["editor.askClaude"].tap()
        let selection = app.buttons["doubt.selection"]
        try requireReady(selection, timeout: 5)
        let bounds = selection.frame
        selection.coordinate(withNormalizedOffset: CGVector(dx: 0.20, dy: 0.25))
            .press(forDuration: 0.1, thenDragTo: selection.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.42)))
        guard app.staticTexts["Question marked. In Claude, say “check my doubts.”"].waitForExistence(timeout: 10) else {
            XCTFail("The question-marked confirmation did not appear after the drag")
            throw SmokeError.notReady
        }
        let saved: SmokeDoubt = try await eventually {
            let current: SmokeNotebook = try await self.api.request("notebooks/\(notebook.id)")
            return current.pages.first?.doubts?.first { !existing.contains($0.id) }
        }
        XCTAssertEqual(saved.pageId, page.id)
        // At initial fit, 1000 page units span the overlay width. The drag spans 25% of that width.
        XCTAssertEqual(saved.region.x, 200, accuracy: 12)
        XCTAssertEqual(saved.region.w, 250, accuracy: 12)
        let expectedHeight = Double(bounds.height * 0.17 / (bounds.width / 1000))
        XCTAssertEqual(saved.region.h, expectedHeight, accuracy: 15)
        XCTAssertGreaterThanOrEqual(saved.region.y, 0)
        XCTAssertLessThanOrEqual(saved.region.y + saved.region.h, 1414)
    }

    @MainActor
    func testHiddenHintTapPersistsRevealAndRemovesChip() async throws {
        let notebook = try await fixture()
        let page = try XCTUnwrap(notebook.pages.first)
        let hint = try XCTUnwrap(page.claudeLayer.first { $0.type == "hint" && $0.revealed != true }, "Seed an unrevealed hint before this test")
        try await api.setView(notebook: notebook.id, page: page.id)
        let app = launch()
        defer { app.terminate() }
        try openFirstPage(app, pageId: page.id)
        let chip = app.buttons["hint.\(hint.id)"]
        guard chip.waitForExistence(timeout: 5) else {
            print(app.debugDescription)
            XCTFail("Hidden hint button is missing from the accessibility hierarchy")
            return
        }
        for _ in 0..<3 {
            if chip.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(chip.isHittable)
        chip.tap()
        let revealed: SmokeItem = try await eventually {
            let current: SmokeNotebook = try await self.api.request("notebooks/\(notebook.id)")
            return current.pages.first?.claudeLayer.first { $0.id == hint.id && $0.revealed == true }
        }
        XCTAssertEqual(revealed.text, hint.text)
        let removed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: chip)
        await fulfillment(of: [removed], timeout: 5)
    }

    @MainActor
    func testHandwritingSearchOpensMatchingPage() async throws {
        let notebook = try await fixture()
        XCTAssertGreaterThanOrEqual(notebook.pages.count, 2)
        // A bottom-of-page match on a nonfinal page must keep Claude targeted at that page.
        let page = notebook.pages[0]
        try await api.setView(notebook: notebook.id, page: notebook.pages[1].id)
        let phrase = "nucleophilic substitution verification"
        try await api.seedHandwriting(pageId: page.id, text: phrase)
        let app = launch(autoopen: false)
        defer { app.terminate() }
        let search = app.textFields["library.search"]
        try requireReady(search)
        search.tap()
        search.typeText(phrase)
        let hit = app.staticTexts[phrase]
        try requireReady(hit)
        hit.tap()
        try requireReady(app.buttons["editor.pages"])
        let view: SmokeView
        do {
            view = try await eventually {
                let list: SmokeList = try await self.api.request("notebooks")
                return list.view.pageId == page.id ? list.view : nil
            }
        } catch {
            let latest: SmokeList? = try? await api.request("notebooks")
            print("Search target page \(page.id); server view notebook=\(latest?.view.notebookId ?? "nil") page=\(latest?.view.pageId ?? "nil"); navigation bars=\(app.navigationBars.allElementsBoundByIndex.map(\.identifier))")
            throw error
        }
        XCTAssertEqual(view.notebookId, notebook.id)
        XCTAssertTrue(app.navigationBars["\(notebook.title) · 1/\(notebook.pages.count)"].waitForExistence(timeout: 5))
        try await api.seedHandwriting(pageId: page.id, text: nil)
    }

    @MainActor
    func testScratchPadOpensInOneTapAndCanBeKeptInAFolder() async throws {
        let before: SmokeList = try await api.request("notebooks")
        let existing = Set(before.notebooks.map(\.id))
        let folder: SmokeFolder = try await api.request("folders", method: "POST", body: ["name": "Kept in CI"])
        let app = launch(autoopen: false)
        defer { app.terminate() }
        let tile = app.buttons["library.newScratch"]
        XCTAssertTrue(tile.waitForExistence(timeout: 10))
        tile.tap()
        XCTAssertTrue(app.buttons["editor.pages"].waitForExistence(timeout: 10))
        let pad: SmokeNotebook = try await eventually {
            let list: SmokeList = try await self.api.request("notebooks")
            return list.notebooks.first { !existing.contains($0.id) && $0.scratch == true }
        }
        XCTAssertNotNil(pad.expiresAt)
        XCTAssertNil(pad.folderId)
        let keep = app.buttons["editor.keep"]
        XCTAssertTrue(keep.waitForExistence(timeout: 5))
        keep.tap()
        let target = app.buttons["picker.folder.\(folder.id)"]
        XCTAssertTrue(target.waitForExistence(timeout: 5))
        target.tap()
        app.buttons["picker.confirm"].tap()
        let kept: SmokeNotebook = try await eventually {
            let current: SmokeNotebook = try await self.api.request("notebooks/\(pad.id)")
            return current.scratch == nil && current.folderId == folder.id ? current : nil
        }
        XCTAssertNil(kept.expiresAt)
        // Once kept, the editor stops offering to keep it.
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: keep)
        await fulfillment(of: [gone], timeout: 10)
        let _: SmokeOK = try await api.request("notebooks/\(pad.id)", method: "DELETE")
        let _: SmokeOK = try await api.request("folders/\(folder.id)", method: "DELETE")
    }

    private func fixture() async throws -> SmokeNotebook {
        let list: SmokeList = try await api.request("notebooks")
        return try XCTUnwrap(list.notebooks.first { $0.title == "Organic chemistry" }, "Run scripts/smoke-fixture.mjs first")
    }

    @MainActor
    private func launch(autoopen: Bool = true) -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment = [
            "CLAUDEBOOK_SERVER": api.base.absoluteString,
            "CLAUDEBOOK_SECRET": api.secret,
            "CLAUDEBOOK_AUTOOPEN": autoopen ? "1" : "0",
            "CLAUDEBOOK_TEST_STROKE": "0",
            "CLAUDEBOOK_TEST_SCROLL": "",
        ]
        app.launch()
        return app
    }

    @MainActor
    private func openFirstPage(_ app: XCUIApplication, pageId: String) throws {
        let pages = app.buttons["editor.pages"]
        // The toolbar appears before the async notebook load enables its controls.
        try requireReady(pages)
        pages.tap()
        let first = app.buttons["page.\(pageId)"]
        try requireReady(first, timeout: 5)
        first.tap()
        try requireReady(app.buttons["editor.askClaude"], timeout: 5)
    }

    @MainActor
    private func requireReady(_ element: XCUIElement, timeout: TimeInterval = 10) throws {
        let ready = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND enabled == true AND hittable == true"),
            object: element)
        guard XCTWaiter.wait(for: [ready], timeout: timeout) == .completed else {
            XCTFail("UI control did not become ready: \(element.identifier)")
            throw SmokeError.notReady
        }
    }

    private func eventually<T>(_ probe: () async throws -> T?) async throws -> T {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if let value = try await probe() { return value }
            try await Task.sleep(for: .milliseconds(150))
        }
        XCTFail("Server state did not change within 10 seconds")
        throw SmokeError.timeout
    }
}

private enum SmokeError: Error { case unsafeHost, response(Int), timeout, notReady }
private struct SmokeList: Decodable { var notebooks: [SmokeNotebook]; var view: SmokeView }
private struct SmokeView: Decodable { var notebookId: String?; var pageId: String? }
private struct SmokeNotebook: Decodable { var id: String; var title: String; var pages: [SmokePage]; var folderId: String?; var scratch: Bool?; var expiresAt: String? }
private struct SmokeFolder: Decodable { var id: String; var name: String }
private struct SmokePage: Decodable { var id: String; var claudeLayer: [SmokeItem]; var doubts: [SmokeDoubt]? }
private struct SmokeItem: Decodable { var id: String; var type: String; var text: String?; var revealed: Bool? }
private struct SmokeDoubt: Decodable { var id: String; var pageId: String; var region: SmokeRegion }
private struct SmokeRegion: Decodable { var x: Double; var y: Double; var w: Double; var h: Double }
private struct SmokeOK: Decodable { var ok: Bool }

private struct SmokeAPI {
    private static let env = ProcessInfo.processInfo.environment
    let base = URL(string: SmokeAPI.env["TEST_RUNNER_CLAUDEBOOK_SERVER"] ?? SmokeAPI.env["CLAUDEBOOK_SERVER"] ?? SmokeAPI.env["BASE"] ?? "http://127.0.0.1:8787")!
    let secret = SmokeAPI.env["TEST_RUNNER_CLAUDEBOOK_SECRET"] ?? SmokeAPI.env["CLAUDEBOOK_SECRET"] ?? SmokeAPI.env["SECRET"] ?? "smoke-test-secret-0123456789"

    func request<T: Decodable>(_ path: String, method: String = "GET", body: [String: Any]? = nil) async throws -> T {
        guard base.host == "127.0.0.1" else { throw SmokeError.unsafeHost }
        var request = URLRequest(url: base.appending(path: "api").appending(path: path))
        request.httpMethod = method
        request.timeoutInterval = 3
        request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw SmokeError.response(status) }
        return try JSONDecoder().decode(T.self, from: data)
    }

    func setView(notebook: String, page: String) async throws {
        let _: SmokeView = try await request("view", method: "POST", body: ["notebookId": notebook, "pageId": page])
    }

    func seedHandwriting(pageId: String, text: String?) async throws {
        let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/l9sAAAAASUVORK5CYII="
        let boxes: [[String: Any]] = text.map { [["text": $0, "x": 120, "y": 1200, "w": 650, "h": 45]] } ?? []
        let _: SmokeOK = try await request("pages/\(pageId)/snapshot", method: "PUT", body: ["png": png, "textBoxes": boxes])
    }
}
