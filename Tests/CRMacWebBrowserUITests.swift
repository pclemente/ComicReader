import AppKit
import CoreGraphics
import CoreText
import Foundation
import Network
import StoreKitTest
import XCTest

/// Native macOS runner for the Catalyst app. A separate app identifier keeps
/// this test's purchases, preferences, website data and comics out of the
/// developer's regular ComicReader installation.
@MainActor
final class CRMacWebBrowserUITests: XCTestCase {
    private let hostIdentifier = "com.pabloclementeperez.ComicFlow.MacUITestHost"
    private var application: XCUIApplication?

    override func tearDown() {
        if let application {
            let screenshot = XCTAttachment(screenshot: application.screenshot())
            screenshot.name = "Mac browser final state"
            screenshot.lifetime = .keepAlways
            add(screenshot)
            application.terminate()
        }
        application = nil
        super.tearDown()
    }

    func testPurchaseRestoreAndAuthenticatedWebsiteImport() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CR_UI_MAC_FIXTURE_IMPORT"] == "1",
                          "Run with the dedicated MacUITestHost app and CR_UI_MAC_FIXTURE_IMPORT=1.")
        XCTAssertEqual(ProcessInfo.processInfo.environment["CR_UI_MAC_HOST_BUNDLE_IDENTIFIER"], hostIdentifier,
                       "The UI test must never launch ComicReader's production bundle.")
        continueAfterFailure = false
        let configuration = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "ComicReader",
                                                                     withExtension: "storekit"))
        let purchases = try SKTestSession(contentsOf: configuration)
        purchases.resetToDefaultState()
        purchases.clearTransactions()
        purchases.disableDialogs = true
        XCTAssertTrue(purchases.disableDialogs,
                      "StoreKitTest must accept and return configuration before UI launch.")
        defer {
            purchases.clearTransactions()
            purchases.resetToDefaultState()
        }

        let publisher = try CRMacPublisherFixture()
        try publisher.start()
        defer { publisher.stop() }

        let app = XCUIApplication(bundleIdentifier: hostIdentifier)
        application = app
        app.launchArguments = ["-serverType", "0", "-launchCount", "-1",
                               "-currentComic", "0", "-currentCollection", "0",
                               "-plusIntroductionShown", "YES", "-releaseNews1_6Shown", "YES",
                               "-CRCloudSyncOptedIn", "NO", "-AppleLanguages", "(en)"]
        app.launch()

        click(app.buttons["library.browser"])
        open(publisher.url(for: "login"), in: app)
        XCTAssertTrue(app.webViews.staticTexts["Signed in to test publisher"].waitForExistence(timeout: 30))
        click(app.buttons["library.browser.done"])
        click(app.buttons["library.browser"])
        open(publisher.url(for: ""), in: app)
        XCTAssertTrue(app.webViews.staticTexts["Signed in to test publisher"].waitForExistence(timeout: 15),
                      "Closing the browser should preserve the publisher's WebKit session.")
        screenshot("Mac authenticated publisher", app: app)

        let download = app.webViews.links["Download test comic"]
        click(download)
        let upgrade = app.alerts["ComicReader Plus"]
        XCTAssertTrue(upgrade.waitForExistence(timeout: 15))
        click(upgrade.buttons["View Plus"])
        let purchase = app.cells["plus.purchase"]
        click(purchase)
        XCTAssertTrue(wait(for: purchase, predicate: "exists == YES AND value == 'Unlocked'", timeout: 30),
                      "The purchase must unlock the real Catalyst application.")
        XCTAssertTrue(purchases.allTransactions().contains {
            $0.productIdentifier == "com.pabloclementeperez.ComicFlow.plus"
        })
        click(app.cells["plus.restore"])
        let restored = app.alerts["Purchase Restored"]
        XCTAssertTrue(restored.waitForExistence(timeout: 30),
                      "Restore must revalidate the entitlement in the Catalyst process.")
        click(restored.buttons["OK"])
        XCTAssertEqual(purchase.value as? String, "Unlocked")
        screenshot("Mac Plus purchase restored", app: app)
        click(app.buttons["Done"])

        click(download)
        let destination = app.buttons["Library Root  ✓"]
        click(destination)
        XCTAssertTrue(destination.waitForNonExistence(timeout: 10))
        let imported = app.cells.matching(NSPredicate(format:
            "identifier == %@ AND label == %@ AND value BEGINSWITH %@",
            "library.browser.download", publisher.fileName, "Imported")).firstMatch
        XCTAssertTrue(imported.waitForExistence(timeout: 30),
                      "An authenticated attachment must validate and import through WKDownload.")
        screenshot("Mac validated website import", app: app)

        click(app.buttons["library.browser.downloads.back"])
        click(download)
        click(destination)
        XCTAssertTrue(destination.waitForNonExistence(timeout: 10))
        let duplicate = app.cells.matching(NSPredicate(format:
            "identifier == %@ AND label == %@ AND value BEGINSWITH %@",
            "library.browser.download", publisher.fileName, "Already in library")).firstMatch
        XCTAssertTrue(duplicate.waitForExistence(timeout: 30),
                      "Downloading the same bytes twice must find the original library copy.")
        click(duplicate)
        click(app.buttons["Open Comic"])
        let canvas = app.otherElements["reader.canvas"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["Please Wait…"].waitForNonExistence(timeout: 20))
        XCTAssertTrue(wait(for: canvas, predicate: "exists == YES AND hittable == YES", timeout: 10))
        screenshot("Mac downloaded comic reader", app: app)
        // Only the isolated test host receives the uniquely named fixture.
        // No production library, preference domain or website data is removed.
    }

    private func open(_ url: URL, in app: XCUIApplication) {
        let homeAddress = app.textFields["library.browser.homeAddress"]
        let address = homeAddress.waitForExistence(timeout: 3)
            ? homeAddress : app.textFields["library.browser.address"]
        click(address)
        let pasteboard = NSPasteboard.general
        let previousItems = (pasteboard.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString(url.absoluteString, forType: .string))
        let fixtureChangeCount = pasteboard.changeCount
        defer {
            // Restore the user's clipboard without overwriting a newer copy.
            // Its contents are never logged or attached to test results.
            if pasteboard.changeCount == fixtureChangeCount {
                pasteboard.clearContents()
                if !previousItems.isEmpty { pasteboard.writeObjects(previousItems) }
            }
        }
        address.typeKey("a", modifierFlags: .command)
        address.typeKey("v", modifierFlags: .command)
        // Pasting the known fixture URL avoids keyboard-layout punctuation loss.
        // Verify before navigating so this test can never visit another host.
        XCTAssertEqual(address.value as? String, url.absoluteString)
        address.typeKey(XCUIKeyboardKey.return, modifierFlags: [])
    }

    private func click(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(wait(for: element, predicate: "exists == YES AND enabled == YES AND hittable == YES",
                           timeout: 20), "Control is not ready: \(element)", file: file, line: line)
        element.click()
    }

    private func wait(for element: XCUIElement, predicate: String, timeout: TimeInterval) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: predicate), object: element)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    private func screenshot(_ name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

/// A private publisher fixture bound only to loopback. A path-scoped HttpOnly
/// cookie is required through a redirect before the PDF attachment is served.
private final class CRMacPublisherFixture {
    private enum Failure: Error { case pdfCreation, listenerStart }

    let fileName = "Mac-Web-\(UUID().uuidString).pdf"
    private let path = UUID().uuidString.lowercased()
    private let queue = DispatchQueue(label: "ComicReader.MacPublisherFixture")
    private let listener: NWListener
    private let comic: Data
    private var connections: [UUID: NWConnection] = [:]
    private var port: NWEndpoint.Port?

    init() throws {
        let pdf = NSMutableData()
        var mediaBox = CGRect(x: 0, y: 0, width: 600, height: 800)
        guard let consumer = CGDataConsumer(data: pdf as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw Failure.pdfCreation
        }
        for page in 1...3 {
            context.beginPDFPage(nil)
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(mediaBox)
            let text = NSAttributedString(string: "MAC WEB JOURNEY — page \(page) — \(path.prefix(8))", attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 24, nil)
            ])
            context.textPosition = CGPoint(x: 40, y: 730)
            CTLineDraw(CTLineCreateWithAttributedString(text), context)
            context.endPDFPage()
        }
        context.closePDF()
        comic = pdf as Data
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    func start() throws {
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready, .failed, .cancelled: ready.signal()
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            let identifier = UUID()
            self.connections[identifier] = connection
            connection.start(queue: self.queue)
            self.receive(connection, identifier: identifier, bytes: Data())
            self.queue.asyncAfter(deadline: .now() + 20) { [weak self, weak connection] in
                connection?.cancel()
                self?.connections.removeValue(forKey: identifier)
            }
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 10) == .success,
              case .ready = listener.state, let port = listener.port else {
            listener.cancel()
            throw Failure.listenerStart
        }
        self.port = port
    }

    func url(for route: String) -> URL {
        URL(string: "http://localhost:\(port!.rawValue)/\(path)/\(route)")!
    }

    func stop() {
        queue.sync {
            listener.cancel()
            connections.values.forEach { $0.cancel() }
            connections.removeAll()
        }
    }

    private func receive(_ connection: NWConnection, identifier: UUID, bytes: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, complete, error in
            guard let self else { connection.cancel(); return }
            var requestBytes = bytes
            if let data { requestBytes.append(data) }
            if requestBytes.count > 32_768 {
                self.close(connection, identifier: identifier)
            } else if requestBytes.range(of: Data("\r\n\r\n".utf8)) != nil {
                self.respond(to: String(decoding: requestBytes, as: UTF8.self), connection: connection, identifier: identifier)
            } else if complete || error != nil {
                self.close(connection, identifier: identifier)
            } else {
                self.receive(connection, identifier: identifier, bytes: requestBytes)
            }
        }
    }

    private func respond(to request: String, connection: NWConnection, identifier: UUID) {
        let route = request.components(separatedBy: " ").dropFirst().first ?? "/"
        let root = "/\(path)/"
        let cookie = "CRMacFixture_\(path.replacingOccurrences(of: "-", with: ""))=yes"
        let signedIn = request.components(separatedBy: "\r\n").contains {
            $0.lowercased().hasPrefix("cookie:") && $0.contains(cookie)
        }
        var status = "200 OK"
        var mime = "text/html; charset=utf-8"
        var headers = ""
        let body: Data
        if route == root + "download", signedIn {
            status = "302 Found"
            headers = "Location: \(root)protected/comic.pdf\r\n"
            body = Data()
        } else if route == root + "protected/comic.pdf", signedIn {
            mime = "application/pdf"
            headers = "Content-Disposition: attachment; filename=\"\(fileName)\"\r\n"
            body = comic
        } else if route.hasPrefix(root) {
            let login = route == root + "login"
            if login { headers = "Set-Cookie: \(cookie); HttpOnly; SameSite=Lax; Path=\(root)\r\n" }
            let state = signedIn || login ? "Signed in to test publisher" : "No publisher session"
            body = Data("<!doctype html><meta name='viewport' content='width=device-width'><title>Test publisher</title><h1>\(state)</h1><p><a href='\(root)login'>Sign in to test publisher</a></p><p><a href='\(root)download'>Download test comic</a></p>".utf8)
        } else {
            status = "404 Not Found"
            body = Data()
        }
        var response = Data("HTTP/1.1 \(status)\r\nContent-Type: \(mime)\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\(headers)\r\n".utf8)
        response.append(body)
        connection.send(content: response, contentContext: .finalMessage, isComplete: true,
                        completion: .contentProcessed { [weak self] _ in
            self?.close(connection, identifier: identifier)
        })
    }

    private func close(_ connection: NWConnection, identifier: UUID) {
        connection.cancel()
        connections.removeValue(forKey: identifier)
    }
}
