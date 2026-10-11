import Foundation
import XCTest

@testable import ComicFlow

final class CRSavedQuotesTests: XCTestCase {
  private var fixtureRoot: URL!
  private var storageURL: URL!

  override func setUpWithError() throws {
    fixtureRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("CRSavedQuotesTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
    storageURL = fixtureRoot.appendingPathComponent("state/SavedQuotes-v1.json")
  }

  override func tearDownWithError() throws {
    if let fixtureRoot {
      try? FileManager.default.removeItem(at: fixtureRoot)
    }
    storageURL = nil
    fixtureRoot = nil
  }

  func testAddEditDeleteAndPersistence() throws {
    let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
    let modifiedAt = Date(timeIntervalSince1970: 1_700_000_100)
    var dates = [createdAt, modifiedAt]
    let store = makeStore { dates.removeFirst() }

    let quote = try store.add(fingerprint: "sha256:comic-a",
                              comicName: "  Little Nemo  ",
                              pageIndex: 8,
                              text: "  Wake up!  \n")
    XCTAssertNotNil(UUID(uuidString: quote.id))
    XCTAssertEqual(quote.comicName, "Little Nemo")
    XCTAssertEqual(quote.pageIndex, 8)
    XCTAssertEqual(quote.text, "Wake up!")
    XCTAssertEqual(quote.createdAt, createdAt)
    XCTAssertEqual(quote.modifiedAt, createdAt)

    let reopened = makeStore { modifiedAt }
    XCTAssertEqual(try reopened.records(for: "sha256:comic-a"), [quote])

    try reopened.update(fingerprint: "sha256:comic-a", id: quote.id, text: "  A new line.  ")
    let edited = try makeStore().records(for: "sha256:comic-a").first
    XCTAssertEqual(edited?.id, quote.id)
    XCTAssertEqual(edited?.comicName, quote.comicName)
    XCTAssertEqual(edited?.pageIndex, quote.pageIndex)
    XCTAssertEqual(edited?.text, "A new line.")
    XCTAssertEqual(edited?.createdAt, createdAt)
    XCTAssertEqual(edited?.modifiedAt, modifiedAt)

    try reopened.remove(fingerprint: "sha256:comic-a", id: quote.id)
    XCTAssertTrue(try makeStore().records(for: "sha256:comic-a").isEmpty)
  }

  func testRecordsSortByPageAndRemainReadableWithoutEntitlementState() throws {
    let store = makeStore()
    let last = try store.add(fingerprint: "sha256:comic-a",
                             comicName: "Issue One",
                             pageIndex: 10,
                             text: "Last")
    let first = try store.add(fingerprint: "sha256:comic-a",
                              comicName: "Issue One",
                              pageIndex: 1,
                              text: "First")

    let reopenedWithoutAnyPurchaseInput = makeStore()
    XCTAssertEqual(try reopenedWithoutAnyPurchaseInput.records(for: "sha256:comic-a").map(\.id),
                   [first.id, last.id])
    XCTAssertEqual(try reopenedWithoutAnyPurchaseInput.records(for: "sha256:comic-a").map(\.text),
                   ["First", "Last"])
  }

  func testFullFingerprintDefinesQuoteIdentity() throws {
    let store = makeStore()
    let quote = try store.add(fingerprint: "sha256:bytes-one",
                              comicName: "Same Name.cbz",
                              pageIndex: 2,
                              text: "Only the first comic")

    XCTAssertEqual(try store.records(for: "sha256:bytes-one").map(\.id), [quote.id])
    XCTAssertTrue(try store.records(for: "sha256:bytes-two").isEmpty)

    let reopened = makeStore()
    XCTAssertEqual(try reopened.records(for: "  sha256:bytes-one\n").map(\.id), [quote.id],
                   "Incidental surrounding whitespace must not create a second identity")
  }

  func testInvalidInputsAreRejectedWithoutCreatingStorage() throws {
    let store = makeStore()

    assertError(.invalidFingerprint) {
      _ = try store.add(fingerprint: " \n ", comicName: "Comic", pageIndex: 0, text: "Quote")
    }
    assertError(.invalidFingerprint) {
      _ = try store.add(fingerprint: String(repeating: "f", count: 257),
                        comicName: "Comic", pageIndex: 0, text: "Quote")
    }
    assertError(.invalidComicName) {
      _ = try store.add(fingerprint: "sha256:a", comicName: "  ", pageIndex: 0, text: "Quote")
    }
    assertError(.invalidPage) {
      _ = try store.add(fingerprint: "sha256:a", comicName: "Comic", pageIndex: -1, text: "Quote")
    }
    assertError(.invalidText) {
      _ = try store.add(fingerprint: "sha256:a", comicName: "Comic", pageIndex: 0, text: " \n ")
    }
    assertError(.invalidText) {
      _ = try store.add(fingerprint: "sha256:a",
                        comicName: "Comic",
                        pageIndex: 0,
                        text: String(repeating: "x", count: CRSavedQuoteStore.maximumTextLength + 1))
    }
    assertError(.invalidIdentifier) {
      try store.update(fingerprint: "sha256:a", id: "  ", text: "Quote")
    }

    XCTAssertFalse(FileManager.default.fileExists(atPath: storageURL.path))
  }

  func testMissingQuoteDoesNotModifyExistingRecords() throws {
    let store = makeStore()
    let quote = try store.add(fingerprint: "sha256:a",
                              comicName: "Comic",
                              pageIndex: 0,
                              text: "Keep me")

    assertError(.quoteNotFound) {
      try store.update(fingerprint: "sha256:a",
                       id: UUID().uuidString.lowercased(),
                       text: "Replacement")
    }
    assertError(.quoteNotFound) {
      try store.remove(fingerprint: "sha256:different", id: quote.id)
    }
    XCTAssertEqual(try store.records(for: "sha256:a"), [quote])
  }

  func testCorruptArchiveIsPreservedAndEveryMutationFailsClosed() throws {
    let corruptData = Data("{ definitely not saved quote JSON".utf8)
    try FileManager.default.createDirectory(at: storageURL.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    try corruptData.write(to: storageURL)
    let store = makeStore()

    assertError(.invalidArchive) {
      _ = try store.records(for: "sha256:a")
    }
    assertError(.invalidArchive) {
      _ = try store.add(fingerprint: "sha256:a", comicName: "Comic", pageIndex: 0, text: "Quote")
    }
    assertError(.invalidArchive) {
      try store.update(fingerprint: "sha256:a", id: UUID().uuidString, text: "Quote")
    }
    assertError(.invalidArchive) {
      try store.remove(fingerprint: "sha256:a", id: UUID().uuidString)
    }

    XCTAssertEqual(try Data(contentsOf: storageURL), corruptData)
  }

  func testStorageFailurePreservesUnderlyingError() throws {
    let blockedDirectory = storageURL.deletingLastPathComponent()
    try Data("not a directory".utf8).write(to: blockedDirectory)
    let store = makeStore()

    assertError(.storageUnavailable, hasUnderlyingError: true) {
      _ = try store.add(fingerprint: "sha256:a",
                        comicName: "Comic",
                        pageIndex: 0,
                        text: "Quote")
    }
    XCTAssertEqual(try Data(contentsOf: blockedDirectory), Data("not a directory".utf8))
  }

  func testConcurrentAddsDoNotLoseRecords() throws {
    let store = makeStore()
    let queue = DispatchQueue(label: "CRSavedQuotesTests.concurrent", attributes: .concurrent)
    let group = DispatchGroup()
    let errorLock = NSLock()
    var errors: [Error] = []

    for index in 0..<24 {
      group.enter()
      queue.async {
        defer { group.leave() }
        do {
          _ = try store.add(fingerprint: "sha256:shared",
                            comicName: "Shared",
                            pageIndex: index,
                            text: "Quote \(index)")
        } catch {
          errorLock.lock()
          errors.append(error)
          errorLock.unlock()
        }
      }
    }

    XCTAssertEqual(group.wait(timeout: .now() + 10), .success)
    XCTAssertTrue(errors.isEmpty, "Concurrent writes failed: \(errors)")
    let records = try store.records(for: "sha256:shared")
    XCTAssertEqual(records.count, 24)
    XCTAssertEqual(records.map(\.pageIndex), Array(0..<24))
  }

  private func makeStore(now: @escaping () -> Date = Date.init) -> CRSavedQuoteStore {
    CRSavedQuoteStore(storageURL: storageURL, now: now)
  }

  private func assertError(_ expected: CRSavedQuoteErrorCode,
                           hasUnderlyingError: Bool = false,
                           operation: () throws -> Void,
                           file: StaticString = #filePath,
                           line: UInt = #line) {
    XCTAssertThrowsError(try operation(), file: file, line: line) { error in
      let error = error as NSError
      XCTAssertEqual(error.domain, CRSavedQuoteStore.errorDomain, file: file, line: line)
      XCTAssertEqual(error.code, expected.rawValue, file: file, line: line)
      if hasUnderlyingError {
        XCTAssertNotNil(error.userInfo[NSUnderlyingErrorKey], file: file, line: line)
      }
    }
  }
}
