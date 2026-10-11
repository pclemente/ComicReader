import Foundation
import UIKit
import XCTest

@testable import ComicFlow

final class CRComicTextEngineTests: XCTestCase {
  private var fixtureRoot: URL!
  private var cacheDirectory: URL!

  override func setUpWithError() throws {
    fixtureRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("CRComicTextEngineTests-\(UUID().uuidString)", isDirectory: true)
    cacheDirectory = fixtureRoot.appendingPathComponent("cache", isDirectory: true)
    try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    if let fixtureRoot { try? FileManager.default.removeItem(at: fixtureRoot) }
    cacheDirectory = nil
    fixtureRoot = nil
  }

  func testIndexStartsAtRequestedPageThenProcessesRemainingPagesInOrder() throws {
    let source = FakePageSource(pageCount: 4)
    var recognizedPages: [Int] = []
    let engine = makeEngine(source: source) { _, pageIndex in
      recognizedPages.append(pageIndex)
      return "Text \(pageIndex)"
    }
    _ = try prepare(engine)

    let result = try buildIndex(engine, startingAt: 2)

    XCTAssertNil(result.error)
    XCTAssertEqual(recognizedPages, [2, 0, 1, 3])
    XCTAssertEqual(result.document?.pageTexts, [0: "Text 0", 1: "Text 1", 2: "Text 2", 3: "Text 3"])
  }

  func testIndexReportsPerPageProgressAndCompletedSnapshot() throws {
    let source = FakePageSource(pageCount: 3)
    let engine = makeEngine(source: source) { _, pageIndex in "Page \(pageIndex)" }
    _ = try prepare(engine)

    let result = try buildIndex(engine, startingAt: 1)

    XCTAssertEqual(result.progress.map(\.indexedPageCount), [1, 2, 3])
    XCTAssertEqual(result.progress.map(\.complete), [false, false, true])
    XCTAssertEqual(result.document?.indexedPageCount, 3)
    XCTAssertEqual(result.document?.pageCount, 3)
    XCTAssertEqual(result.document?.complete, true)
  }

  func testCacheResumesAcrossEnginesWithoutRerecognitionIncludingEmptyText() throws {
    let firstSource = FakePageSource(pageCount: 3)
    var firstCalls = 0
    let firstEngine = makeEngine(source: firstSource) { _, pageIndex in
      firstCalls += 1
      return pageIndex == 1 ? "" : "Page \(pageIndex)"
    }
    _ = try prepare(firstEngine)
    let firstResult = try buildIndex(firstEngine, startingAt: 0)
    XCTAssertNil(firstResult.error)
    XCTAssertEqual(firstCalls, 3)
    XCTAssertEqual(firstResult.document?.pageTexts[1], "")

    let secondSource = FakePageSource(pageCount: 3)
    var secondCalls = 0
    let secondEngine = makeEngine(source: secondSource) { _, pageIndex in
      secondCalls += 1
      return "Unexpected \(pageIndex)"
    }
    let reopened = try prepare(secondEngine)
    let resumed = try buildIndex(secondEngine, startingAt: 2)

    XCTAssertEqual(reopened.indexedPageCount, 3)
    XCTAssertTrue(reopened.complete)
    XCTAssertNil(resumed.error)
    XCTAssertEqual(secondCalls, 0)
    XCTAssertEqual(resumed.document?.pageTexts, firstResult.document?.pageTexts)
  }

  func testCurrentPageRecognitionDoesNotPersistIntoIndex() throws {
    let source = FakePageSource(pageCount: 1)
    var callCount = 0
    let engine = makeEngine(source: source) { _, _ in
      callCount += 1
      return callCount == 1 ? "Ephemeral" : "Indexed"
    }
    let initial = try prepare(engine)
    XCTAssertEqual(initial.indexedPageCount, 0)

    let pageText = try recognizePage(engine, pageIndex: 0)
    XCTAssertEqual(pageText.text, "Ephemeral")
    XCTAssertNil(pageText.error)
    XCTAssertEqual(try prepare(engine).indexedPageCount, 0)

    let indexed = try buildIndex(engine, startingAt: 0)
    XCTAssertNil(indexed.error)
    XCTAssertEqual(callCount, 2)
    XCTAssertEqual(indexed.document?.pageTexts[0], "Indexed")
  }

  func testRecognitionErrorDoesNotCreateEmptyCachedPage() throws {
    let failingSource = FakePageSource(pageCount: 1)
    let failingEngine = makeEngine(source: failingSource) { _, _ in throw TestFailure.recognition }
    _ = try prepare(failingEngine)
    let failure = try buildIndex(failingEngine, startingAt: 0)
    XCTAssertNotNil(failure.error)
    XCTAssertEqual(failure.document?.indexedPageCount, 0)

    let reopenedSource = FakePageSource(pageCount: 1)
    var retryCalls = 0
    let reopenedEngine = makeEngine(source: reopenedSource) { _, _ in
      retryCalls += 1
      return "Recovered"
    }
    XCTAssertEqual(try prepare(reopenedEngine).indexedPageCount, 0)
    let recovered = try buildIndex(reopenedEngine, startingAt: 0)

    XCTAssertNil(recovered.error)
    XCTAssertEqual(retryCalls, 1)
    XCTAssertEqual(recovered.document?.pageTexts[0], "Recovered")
  }

  func testCancellationAfterProgressPreventsLaterPageCommits() throws {
    let source = FakePageSource(pageCount: 3)
    var recognizedPages: [Int] = []
    let engine = makeEngine(source: source) { _, pageIndex in
      recognizedPages.append(pageIndex)
      return "Page \(pageIndex)"
    }
    _ = try prepare(engine)

    let completion = expectation(description: "cancelled index completes")
    var finalDocument: CRComicTextDocument?
    var finalError: NSError?
    engine.buildIndex(startingAtPageIndex: 0, progress: { document in
      XCTAssertTrue(Thread.isMainThread)
      if document.indexedPageCount == 1 { engine.cancel() }
    }, completion: { document, error in
      XCTAssertTrue(Thread.isMainThread)
      finalDocument = document
      finalError = error
      completion.fulfill()
    })
    wait(for: [completion], timeout: 5)

    XCTAssertEqual(finalError?.domain, CRComicTextEngine.errorDomain)
    XCTAssertEqual(finalError?.code, CRComicTextErrorCode.cancelled.rawValue)
    XCTAssertEqual(finalDocument?.pageTexts, [0: "Page 0"])
    XCTAssertEqual(recognizedPages, [0])

    let reopened = makeEngine(source: FakePageSource(pageCount: 3)) { _, pageIndex in
      "Resumed \(pageIndex)"
    }
    XCTAssertEqual(try prepare(reopened).pageTexts, [0: "Page 0"])
  }

  func testSearchIsCaseAndDiacriticInsensitiveAndReturnsContext() throws {
    let pageTexts = [
      0: "Nothing relevant here.",
      1: "A quiet Café appears beside the station.",
      2: "The second cafe closes at dusk."
    ]
    let engine = makeEngine(source: FakePageSource(pageCount: 3)) { _, pageIndex in
      pageTexts[pageIndex]!
    }
    _ = try prepare(engine)
    _ = try buildIndex(engine, startingAt: 0)

    let search = try search(engine, query: "CAFE")

    XCTAssertNil(search.error)
    XCTAssertEqual(search.results.map(\.pageIndex), [1, 2])
    XCTAssertEqual(search.results.first?.pageText, pageTexts[1])
    XCTAssertTrue(search.results.first?.snippet.contains("Café") == true)
  }

  func testChangedSourceMakesValidationAndIndexingFailWithoutRecognition() throws {
    let source = FakePageSource(pageCount: 2)
    var resolverCalls = 0
    var recognitionCalls = 0
    let engine = CRComicTextEngine(comicPath: "/fixture/comic.cbz",
                                   pageSourceFactory: { _ in source },
                                   identityResolver: { _ in
                                     resolverCalls += 1
                                     return resolverCalls == 1 ? "sha256:original" : "sha256:replacement"
                                   },
                                   cacheDirectory: cacheDirectory,
                                   ocrConfigurationKey: "tests-v1",
                                   recognizer: { _, _ in
                                     recognitionCalls += 1
                                     return "Text"
                                   })
    _ = try prepare(engine)
    source.setCurrent(false)

    let validation = expectation(description: "validation completes")
    var validationError: NSError?
    engine.validateCurrent { error in
      XCTAssertTrue(Thread.isMainThread)
      validationError = error
      validation.fulfill()
    }
    wait(for: [validation], timeout: 5)

    let index = try buildIndex(engine, startingAt: 0)
    let secondPrepare = try prepareResult(engine)
    XCTAssertEqual(validationError?.code, CRComicTextErrorCode.comicChanged.rawValue)
    XCTAssertEqual(index.error?.code, CRComicTextErrorCode.comicChanged.rawValue)
    XCTAssertEqual(secondPrepare.error?.code, CRComicTextErrorCode.comicChanged.rawValue)
    XCTAssertEqual(resolverCalls, 1, "An already-prepared engine must not switch fingerprints")
    XCTAssertEqual(recognitionCalls, 0)
  }

  private func makeEngine(source: FakePageSource,
                          recognizer: @escaping CRComicTextRecognizer) -> CRComicTextEngine {
    CRComicTextEngine(comicPath: "/fixture/comic.cbz",
                      pageSourceFactory: { _ in source },
                      identityResolver: { _ in "sha256:test-comic" },
                      cacheDirectory: cacheDirectory,
                      ocrConfigurationKey: "tests-v1",
                      recognizer: recognizer)
  }

  private func prepare(_ engine: CRComicTextEngine,
                       file: StaticString = #filePath,
                       line: UInt = #line) throws -> CRComicTextDocument {
    let result = try prepareResult(engine)
    if let error = result.error { throw error }
    return try XCTUnwrap(result.document, file: file, line: line)
  }

  private func prepareResult(_ engine: CRComicTextEngine) throws
    -> (document: CRComicTextDocument?, error: NSError?) {
    let completion = expectation(description: "prepare completes")
    var result: (CRComicTextDocument?, NSError?) = (nil, nil)
    engine.prepare { document, error in
      XCTAssertTrue(Thread.isMainThread)
      result = (document, error)
      completion.fulfill()
    }
    wait(for: [completion], timeout: 5)
    return result
  }

  private func recognizePage(_ engine: CRComicTextEngine, pageIndex: Int) throws
    -> (text: String?, error: NSError?) {
    let completion = expectation(description: "page recognition completes")
    var result: (String?, NSError?) = (nil, nil)
    engine.recognizePage(atPageIndex: pageIndex) { text, error in
      XCTAssertTrue(Thread.isMainThread)
      result = (text, error)
      completion.fulfill()
    }
    wait(for: [completion], timeout: 5)
    return result
  }

  private func buildIndex(_ engine: CRComicTextEngine, startingAt pageIndex: Int) throws
    -> (document: CRComicTextDocument?, error: NSError?, progress: [CRComicTextDocument]) {
    let completion = expectation(description: "index completes")
    var snapshots: [CRComicTextDocument] = []
    var result: (CRComicTextDocument?, NSError?) = (nil, nil)
    engine.buildIndex(startingAtPageIndex: pageIndex, progress: { document in
      XCTAssertTrue(Thread.isMainThread)
      snapshots.append(document)
    }, completion: { document, error in
      XCTAssertTrue(Thread.isMainThread)
      result = (document, error)
      completion.fulfill()
    })
    wait(for: [completion], timeout: 5)
    return (result.0, result.1, snapshots)
  }

  private func search(_ engine: CRComicTextEngine, query: String) throws
    -> (results: [CRComicTextSearchResult], error: NSError?) {
    let completion = expectation(description: "search completes")
    var returnedResults: [CRComicTextSearchResult] = []
    var returnedError: NSError?
    engine.search(forQuery: query) { results, error in
      XCTAssertTrue(Thread.isMainThread)
      returnedResults = results ?? []
      returnedError = error
      completion.fulfill()
    }
    wait(for: [completion], timeout: 5)
    return (returnedResults, returnedError)
  }
}

final class CRComicPageSourceTests: XCTestCase {
  private var fixtureRoot: URL!

  override func setUpWithError() throws {
    fixtureRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("CRComicPageSourceTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    if let fixtureRoot { try? FileManager.default.removeItem(at: fixtureRoot) }
    fixtureRoot = nil
  }

  func testPDFPageCountEmbeddedTextAndBoundedRendering() throws {
    let url = fixtureRoot.appendingPathComponent("two-pages.pdf")
    try makeTwoPagePDF().write(to: url)
    let source = try makeSource(path: url.path)

    XCTAssertEqual(source.pageCount, 2)
    XCTAssertTrue(try source.embeddedText(atPageIndex: 0)?.contains("First PDF page") == true)
    XCTAssertTrue(try source.embeddedText(atPageIndex: 1)?.contains("Second PDF page") == true)

    let image: UIImage? = try source.image(atPageIndex: 0, maxDimension: 128)
    let cgImage = try XCTUnwrap(image?.cgImage)
    XCTAssertLessThanOrEqual(cgImage.width, 128)
    XCTAssertLessThanOrEqual(cgImage.height, 128)
    XCTAssertTrue(source.isStillCurrent())
  }

  func testPDFMutationInvalidatesExistingSource() throws {
    let url = fixtureRoot.appendingPathComponent("mutable.pdf")
    try makeTwoPagePDF().write(to: url)
    let source = try makeSource(path: url.path)
    XCTAssertTrue(source.isStillCurrent())

    let handle = try FileHandle(forWritingTo: url)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data([0]))
    try handle.close()

    XCTAssertFalse(source.isStillCurrent())
  }

  private func makeSource(path: String) throws -> CRComicPageSource {
    let source: CRComicPageSource? = try CRComicPageSource(path: path)
    return try XCTUnwrap(source)
  }

  private func makeTwoPagePDF() -> Data {
    let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 600, height: 800))
    return renderer.pdfData { context in
      let attributes: [NSAttributedString.Key: Any] = [
        .font: UIFont.systemFont(ofSize: 28),
        .foregroundColor: UIColor.black
      ]
      context.beginPage()
      ("First PDF page" as NSString).draw(at: CGPoint(x: 60, y: 90), withAttributes: attributes)
      context.beginPage()
      ("Second PDF page" as NSString).draw(at: CGPoint(x: 60, y: 90), withAttributes: attributes)
    }
  }
}

private enum TestFailure: Error {
  case recognition
}

private final class FakePageSource: CRComicTextPageProviding {
  let pageCount: Int
  private let embeddedTexts: [Int: String]
  private let lock = NSLock()
  private var current = true

  init(pageCount: Int, embeddedTexts: [Int: String] = [:]) {
    self.pageCount = pageCount
    self.embeddedTexts = embeddedTexts
  }

  func image(atPageIndex pageIndex: Int, maxDimension: CGFloat) throws -> UIImage {
    guard pageIndex >= 0, pageIndex < pageCount, maxDimension > 0 else {
      throw TestFailure.recognition
    }
    return UIImage()
  }

  func embeddedText(atPageIndex pageIndex: Int) throws -> String? {
    guard pageIndex >= 0, pageIndex < pageCount else { throw TestFailure.recognition }
    return embeddedTexts[pageIndex]
  }

  func isStillCurrent() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return current
  }

  func setCurrent(_ value: Bool) {
    lock.lock()
    current = value
    lock.unlock()
  }
}
