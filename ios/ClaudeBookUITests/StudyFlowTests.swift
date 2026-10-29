import XCTest

/// Runs only against the disposable localhost server seeded by scripts/smoke-fixture.mjs.
final class StudyFlowTests: XCTestCase {
    private let api = SmokeAPI()

    override func setUpWithError() throws {
        continueAfterFailure = false
        executionTimeAllowance = 60
    }

    @MainActor
    func testAddingAPageShowsItRightAwayAndSavesItInPlace() async throws {
        let notebook: SmokeNotebook = try await api.request("notebooks", method: "POST", body: ["title": "Add page flow", "pages": 2])
        try await api.setView(notebook: notebook.id, page: notebook.pages[0].id)
        let app = launch()
        defer { app.terminate() }
        XCTAssertTrue(app.navigationBars["Add page flow · 1/2"].waitForExistence(timeout: 10))
        let add = app.buttons["editor.addPage"]
        try requireReady(add)
        add.tap()
        // The page is made on the iPad, so the editor lands on it without waiting for the server.
        XCTAssertTrue(app.navigationBars["Add page flow · 2/3"].waitForExistence(timeout: 2), "The new page did not show up straight away")
        let added: SmokeNotebook = try await eventually {
            let current: SmokeNotebook = try await self.api.request("notebooks/\(notebook.id)")
            return current.pages.count == 3 ? current : nil
        }
        XCTAssertEqual(added.pages[0].id, notebook.pages[0].id)
        XCTAssertEqual(added.pages[2].id, notebook.pages[1].id)
        // The reload after the add must agree with what is on screen, not add or drop a page.
        try await Task.sleep(for: .seconds(1.5))
        XCTAssertTrue(app.navigationBars["Add page flow · 2/3"].exists)
        let settled: SmokeNotebook = try await api.request("notebooks/\(notebook.id)")
        XCTAssertEqual(settled.pages.map(\.id), added.pages.map(\.id))
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

    @MainActor
    func testNotebookRenameAndDeleteConfirmationsUseTheirCapturedNotebook() async throws {
        let notebook: SmokeNotebook = try await api.request("notebooks", method: "POST", body: ["title": "CRUD", "pages": 1])
        let app = launch(autoopen: false)
        defer { app.terminate() }
        let card = app.buttons["notebook.\(notebook.id)"]
        try requireCRUDReady(card)
        card.press(forDuration: 1.1)
        try requireCRUDReady(app.buttons["Rename"])
        app.buttons["Rename"].tap()
        let title = app.alerts.textFields.firstMatch
        try requireCRUDReady(title)
        title.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        title.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 12) + "CRUD renamed")
        let save = app.buttons["library.promptConfirm"]
        try requireCRUDReady(save)
        save.tap()
        let renamed: SmokeNotebook = try await eventually {
            let current: SmokeNotebook = try await self.api.request("notebooks/\(notebook.id)")
            return current.title == "CRUD renamed" ? current : nil
        }
        XCTAssertEqual(renamed.id, notebook.id)
        try requireCRUDReady(card)
        card.press(forDuration: 1.1)
        try requireCRUDReady(app.buttons["Delete"].firstMatch)
        app.buttons["Delete"].firstMatch.tap()
        let confirm = app.buttons["library.confirmDelete"]
        try requireCRUDReady(confirm)
        confirm.tap()
        let deleted: Bool = try await eventually {
            let list: SmokeList = try await self.api.request("notebooks")
            return list.notebooks.contains { $0.id == notebook.id } ? nil : true
        }
        XCTAssertTrue(deleted)
    }

    @MainActor
    func testPageActionsDuplicateReorderDeleteAndMoveStablePageIds() async throws {
        executionTimeAllowance = 120
        let notebook: SmokeNotebook = try await api.request("notebooks", method: "POST", body: ["title": "Page operations", "pages": 2])
        let target: SmokeNotebook = try await api.request("notebooks", method: "POST", body: ["title": "Page destination", "pages": 1])
        let first = notebook.pages[0].id
        try await api.setView(notebook: notebook.id, page: first)
        let app = launch()
        defer { app.terminate() }
        try requireCRUDReady(app.buttons["editor.pages"])
        app.buttons["editor.pages"].tap()
        try openMenu(app.buttons["pages.actions.\(first)"])
        try requireCRUDReady(app.buttons["pages.duplicate.\(first)"])
        app.buttons["pages.duplicate.\(first)"].tap()
        let duplicated: SmokeNotebook = try await eventually {
            let current: SmokeNotebook = try await self.api.request("notebooks/\(notebook.id)")
            return current.pages.count == 3 ? current : nil
        }
        let copy = duplicated.pages[1].id
        XCTAssertNotEqual(copy, first)
        XCTAssertEqual(duplicated.pages[2].id, notebook.pages[1].id)
        try openMenu(app.buttons["pages.actions.\(copy)"])
        try requireCRUDReady(app.buttons["pages.down.\(copy)"])
        app.buttons["pages.down.\(copy)"].tap()
        let reordered: SmokeNotebook = try await eventually {
            let current: SmokeNotebook = try await self.api.request("notebooks/\(notebook.id)")
            return current.pages.last?.id == copy ? current : nil
        }
        XCTAssertEqual(reordered.pages.map(\.id), [first, notebook.pages[1].id, copy])
        try openMenu(app.buttons["pages.actions.\(copy)"])
        try requireCRUDReady(app.buttons["pages.delete.\(copy)"])
        app.buttons["pages.delete.\(copy)"].tap()
        try requireCRUDReady(app.buttons["pages.confirmDelete"])
        app.buttons["pages.confirmDelete"].tap()
        let deleted: SmokeNotebook = try await eventually {
            let current: SmokeNotebook = try await self.api.request("notebooks/\(notebook.id)")
            return current.pages.count == 2 ? current : nil
        }
        XCTAssertEqual(deleted.pages.map(\.id), notebook.pages.map(\.id))
        try openMenu(app.buttons["pages.actions.\(first)"])
        try requireCRUDReady(app.buttons["Move to notebook…"])
        app.buttons["Move to notebook…"].tap()
        try requireCRUDReady(app.buttons["pages.target.\(target.id)"])
        app.buttons["pages.target.\(target.id)"].tap()
        let moved: SmokeNotebook = try await eventually {
            let current: SmokeNotebook = try await self.api.request("notebooks/\(target.id)")
            return current.pages.last?.id == first ? current : nil
        }
        XCTAssertEqual(moved.pages.map(\.id), target.pages.map(\.id) + [first])
        let source: SmokeNotebook = try await api.request("notebooks/\(notebook.id)")
        XCTAssertEqual(source.pages.map(\.id), [notebook.pages[1].id])
    }

    @MainActor
    func testDeletingOnlyPageShowsAnAddPageAction() async throws {
        let notebook: SmokeNotebook = try await api.request("notebooks", method: "POST", body: ["title": "Empty pages", "pages": 1])
        let pageId = notebook.pages[0].id
        try await api.setView(notebook: notebook.id, page: pageId)
        let app = launch()
        defer { app.terminate() }
        try requireCRUDReady(app.buttons["editor.pages"])
        app.buttons["editor.pages"].tap()
        try openMenu(app.buttons["pages.actions.\(pageId)"])
        try requireCRUDReady(app.buttons["pages.delete.\(pageId)"])
        app.buttons["pages.delete.\(pageId)"].tap()
        try requireCRUDReady(app.buttons["pages.confirmDelete"])
        app.buttons["pages.confirmDelete"].tap()
        let empty: SmokeNotebook = try await eventually {
            let current: SmokeNotebook = try await self.api.request("notebooks/\(notebook.id)")
            return current.pages.isEmpty ? current : nil
        }
        XCTAssertTrue(empty.pages.isEmpty)
        try requireCRUDReady(app.buttons["Done"])
        app.buttons["Done"].tap()
        try requireCRUDReady(app.buttons["editor.emptyAdd"])
        app.buttons["editor.emptyAdd"].tap()
        let added: SmokeNotebook = try await eventually {
            let current: SmokeNotebook = try await self.api.request("notebooks/\(notebook.id)")
            return current.pages.count == 1 ? current : nil
        }
        XCTAssertNotEqual(added.pages[0].id, pageId)
    }

    /// Runs last against the throwaway server; other study tests need their seeded fixtures.
    @MainActor
    func testZZDeletingTheFinalNotebookLeavesAnEmptyLibrary() async throws {
        let list: SmokeList = try await api.request("notebooks")
        for notebook in list.notebooks {
            let _: SmokeOK = try await api.request("notebooks/\(notebook.id)", method: "DELETE")
        }
        let final: SmokeNotebook = try await api.request("notebooks", method: "POST", body: ["title": "Last notebook", "pages": 1])
        let app = launch(autoopen: false)
        defer { app.terminate() }
        let card = app.buttons["notebook.\(final.id)"]
        try requireCRUDReady(card)
        card.press(forDuration: 1.1)
        try requireCRUDReady(app.buttons["Delete"].firstMatch)
        app.buttons["Delete"].firstMatch.tap()
        try requireCRUDReady(app.buttons["library.confirmDelete"])
        app.buttons["library.confirmDelete"].tap()
        let empty: Bool = try await eventually {
            let current: SmokeList = try await self.api.request("notebooks")
            return current.notebooks.isEmpty ? true : nil
        }
        XCTAssertTrue(empty)
        try requireCRUDReady(app.buttons["library.emptyCreate"])
    }

    /// SwiftUI menus inside list rows can report not hittable even while they take taps,
    /// so wait for the loaded, enabled control and tap its centre.
    @MainActor
    private func openMenu(_ element: XCUIElement, timeout: TimeInterval = 12) throws {
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND enabled == true"), object: element)
        guard XCTWaiter.wait(for: [ready], timeout: timeout) == .completed else {
            print("UI hierarchy when \(element) was not ready:\n\(XCUIApplication().debugDescription)")
            XCTFail("Menu did not become ready: \(element)")
            throw SmokeError.timeout
        }
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }

    @MainActor
    private func requireCRUDReady(_ element: XCUIElement, timeout: TimeInterval = 12) throws {
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND enabled == true AND hittable == true"), object: element)
        guard XCTWaiter.wait(for: [ready], timeout: timeout) == .completed else {
            // The smoke log is all CI evidence we can read, so record what was on screen instead.
            print("UI hierarchy when \(element) was not ready:\n\(XCUIApplication().debugDescription)")
            XCTFail("Control did not become ready: \(element)")
            throw SmokeError.timeout
        }
    }

    @MainActor
    func testSnapshotOnlyInkSurvivesPaperChange() async throws {
        let notebook: SmokeNotebook = try await api.request("notebooks", method: "POST", body: ["title": "Legacy snapshot preservation", "pages": 1])
        let page = try XCTUnwrap(notebook.pages.first)
        let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/l9sAAAAASUVORK5CYII="
        let _: SmokeOK = try await api.request("pages/\(page.id)/snapshot", method: "PUT", body: ["png": png, "textBoxes": [], "strokeCount": 2])
        let _: SmokePaperUpdate = try await api.request("pages/background", method: "POST", body: ["pageIds": [page.id], "background": "cornell", "paper": "black"])
        try await api.setView(notebook: notebook.id, page: page.id)
        let app = launch()
        defer { app.terminate() }
        try openFirstPage(app, pageId: page.id)
        // Allow the raw-backup 404 and scheduled snapshot refresh to finish. No raw ink exists.
        try await Task.sleep(for: .seconds(3))
        let current: SmokeNotebook = try await api.request("notebooks/\(notebook.id)")
        XCTAssertEqual(current.pages.first?.snapshotVersion, 1, "An empty local placeholder must not overwrite snapshot-only ink")
        XCTAssertEqual(current.pages.first?.paperSnapshotStale, true)
    }

    @MainActor
    func testPageTypesCornellBlackAndHex() async throws {
        let notebook: SmokeNotebook = try await api.request("notebooks", method: "POST", body: ["title": "Paper picker test", "pages": 1])
        let page = try XCTUnwrap(notebook.pages.first)
        try await api.setView(notebook: notebook.id, page: page.id)
        let app = launch()
        defer { app.terminate() }
        try openFirstPage(app, pageId: page.id)
        func openPicker() throws {
            try openMenu(app.buttons["Notebook options"])
            try requireReady(app.buttons["editor.pageType"])
            app.buttons["editor.pageType"].tap()
            try requireReady(app.buttons["paper.color"])
        }
        func selectPattern(_ id: String) throws {
            let row = app.buttons["paper.pattern.\(id)"]
            for _ in 0..<8 { if row.isHittable { break }; app.swipeUp() }
            try requireReady(row); row.tap()
            app.buttons["paper.apply"].tap()
            try requireReady(app.buttons["editor.askClaude"])
        }
        try openPicker()
        app.buttons["paper.color"].tap()
        app.buttons["Black"].tap()
        try selectPattern("cornell")
        let cornell: SmokeNotebook = try await eventually {
            let current: SmokeNotebook = try await self.api.request("notebooks/\(notebook.id)")
            return current.pages.first?.background == "cornell" && current.pages.first?.paper == "black" ? current : nil
        }
        XCTAssertEqual(cornell.pages.first?.paper, "black")
        let blackShot = XCTAttachment(screenshot: app.screenshot()); blackShot.name = "cornell-black"; blackShot.lifetime = .keepAlways; add(blackShot)
        try openPicker()
        try selectPattern("hex")
        let hex: SmokeNotebook = try await eventually {
            let current: SmokeNotebook = try await self.api.request("notebooks/\(notebook.id)")
            return current.pages.first?.background == "hex" ? current : nil
        }
        XCTAssertEqual(hex.pages.first?.paper, "black")
        let hexShot = XCTAttachment(screenshot: app.screenshot()); hexShot.name = "hex-paper"; hexShot.lifetime = .keepAlways; add(hexShot)
    }

    @MainActor
    func testWebAnimationTapFullscreenAndOffscreenPoster() async throws {
        let list: SmokeList = try await api.request("notebooks")
        let notebook = try XCTUnwrap(list.notebooks.first { $0.title == "Interactive blocks" })
        let page = try XCTUnwrap(notebook.pages.first)
        let block = try XCTUnwrap(page.claudeLayer.first { $0.type == "web" })
        try await api.setView(notebook: notebook.id, page: page.id)
        let app = launch()
        defer { app.terminate() }
        try openFirstPage(app, pageId: page.id)
        let button = app.webViews.buttons["Tap animation"]
        try requireReady(button, timeout: 15)
        button.tap()
        try requireReady(app.webViews.buttons["Clicked"])
        let _: SmokeItem = try await eventually {
            let current: SmokeNotebook = try await self.api.request("notebooks/\(notebook.id)")
            return current.pages[0].claudeLayer.first { $0.id == block.id && $0.logs?.contains(where: { $0.contains("button changed") }) == true && $0.poster != nil && $0.logs?.contains(where: { $0.contains("initial viewport 800x400") }) == true }
        }
        let rendered = XCTAttachment(screenshot: app.screenshot()); rendered.name = "web-live-button"; rendered.lifetime = .keepAlways; add(rendered)
        let controls = app.buttons["web.menu.\(block.id)"]
        try requireReady(controls)
        let originalCorner = controls.frame
        controls.tap(); app.buttons["Fullscreen"].tap()
        let close = app.buttons["web.fullscreen.close"]
        try requireReady(close)
        let full = XCTAttachment(screenshot: app.screenshot()); full.name = "web-fullscreen"; full.lifetime = .keepAlways; add(full)
        close.tap()
        let play = app.buttons["web.play.\(block.id)"]
        try requireReady(play)
        XCTAssertEqual(controls.frame.minX, originalCorner.minX, accuracy: 2)
        XCTAssertEqual(controls.frame.minY, originalCorner.minY, accuracy: 2)
        XCTAssertEqual(controls.frame.width, originalCorner.width, accuracy: 2)
        play.tap()
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: 0.85))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: 0.15))
        start.press(forDuration: 0.1, thenDragTo: end)
        start.press(forDuration: 0.1, thenDragTo: end)
        let offscreen = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.webViews["web.live.\(block.id)"])
        await fulfillment(of: [offscreen], timeout: 8)
        let _: SmokeItem = try await eventually {
            let current: SmokeNotebook = try await self.api.request("notebooks/\(notebook.id)")
            return current.pages[0].claudeLayer.first { $0.logs?.contains(where: { $0.contains("smoke load error") }) == true }
        }
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
private struct SmokePage: Decodable { var id: String; var background: String?; var paper: String?; var snapshotVersion: Int?; var paperSnapshotStale: Bool?; var claudeLayer: [SmokeItem]; var doubts: [SmokeDoubt]? }
private struct SmokeItem: Decodable { var id: String; var type: String; var text: String?; var revealed: Bool?; var poster: String?; var logs: [String]? }
private struct SmokeDoubt: Decodable { var id: String; var pageId: String; var region: SmokeRegion }
private struct SmokeRegion: Decodable { var x: Double; var y: Double; var w: Double; var h: Double }
private struct SmokeOK: Decodable { var ok: Bool }
private struct SmokePaperUpdate: Decodable { var pages: [SmokePage] }

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
