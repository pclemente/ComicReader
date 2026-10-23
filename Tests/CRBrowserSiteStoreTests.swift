import Foundation
import XCTest

@testable import ComicFlow

final class CRBrowserSiteStoreTests: XCTestCase {
  private var fixtureRoot: URL!
  private var storageURL: URL!
  private var store: CRBrowserSiteStore!

  override func setUpWithError() throws {
    fixtureRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("CRBrowserSiteStoreTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
    storageURL = fixtureRoot.appendingPathComponent("state/BrowserSites-v1.json")
    store = CRBrowserSiteStore(storageURL: storageURL)
  }

  override func tearDownWithError() throws {
    if let fixtureRoot {
      try? FileManager.default.removeItem(at: fixtureRoot)
    }
    store = nil
    storageURL = nil
    fixtureRoot = nil
  }

  func testUserInputDefaultsToHTTPSAndNavigationKeepsQuery() throws {
    let normalized = try CRBrowserSiteStore.normalizedWebsiteURL(
      from: "  Example.COM/catalog?q=issue#page-2  "
    )
    XCTAssertEqual(normalized.absoluteString,
                   "https://example.com/catalog?q=issue#page-2")
  }

  func testSavedAndLastURLsNeverPersistQueryFragmentOrUserInfo() throws {
    let secretURL = try XCTUnwrap(URL(string: "https://example.com/catalog?token=secret#account"))
    let saved = try store.saveSite(name: "  Example   Comics  ", url: secretURL)
    try store.recordLastVisitedURL(secretURL)

    XCTAssertEqual(saved.name, "Example Comics")
    XCTAssertEqual(saved.url.absoluteString, "https://example.com/catalog")
    XCTAssertEqual(try CRBrowserSiteStore(storageURL: storageURL).lastVisitedURL()?.absoluteString,
                   "https://example.com/")

    let bytes = try Data(contentsOf: storageURL)
    let archiveText = try XCTUnwrap(String(data: bytes, encoding: .utf8))
    XCTAssertFalse(archiveText.contains("secret"))
    XCTAssertFalse(archiveText.contains("account"))

    XCTAssertThrowsError(
      try store.saveSite(name: "Unsafe",
                         url: XCTUnwrap(URL(string: "https://person:password@example.com/")))
    ) { error in
      XCTAssertEqual((error as NSError).code, CRBrowserSiteErrorCode.invalidURL.rawValue)
    }
  }

  func testSavingSameCanonicalURLUpdatesRatherThanTracksVisits() throws {
    let first = try store.saveSite(
      name: "Old Name",
      url: XCTUnwrap(URL(string: "https://example.com/reader?comic=one"))
    )
    let updated = try store.saveSite(
      name: "New Name",
      url: XCTUnwrap(URL(string: "https://EXAMPLE.com:443/reader?comic=two#last"))
    )

    XCTAssertEqual(updated.identifier, first.identifier)
    XCTAssertEqual(try store.sites().count, 1)
    XCTAssertEqual(try store.sites().first?.name, "New Name")
    XCTAssertEqual(try store.sites().first?.url.absoluteString, "https://example.com/reader")
  }

  func testPrivateStoreIsMemoryOnlyAndDoesNotTouchPersistentArchive() throws {
    _ = try store.saveSite(name: "Normal", url: XCTUnwrap(URL(string: "https://normal.example/")))
    let persistentBytes = try Data(contentsOf: storageURL)

    let privateStore = CRBrowserSiteStore(storageURL: nil)
    XCTAssertFalse(privateStore.isPersistent)
    _ = try privateStore.saveSite(name: "Private",
                                  url: XCTUnwrap(URL(string: "https://private.example/path?session=secret")))
    try privateStore.recordLastVisitedURL(
      XCTUnwrap(URL(string: "https://private.example/another?token=secret"))
    )

    XCTAssertEqual(try privateStore.sites().map(\.name), ["Private"])
    XCTAssertEqual(try Data(contentsOf: storageURL), persistentBytes)
    XCTAssertTrue(try CRBrowserSiteStore(storageURL: nil).sites().isEmpty)
    XCTAssertNil(try CRBrowserSiteStore(storageURL: nil).lastVisitedURL())
    XCTAssertEqual(try CRBrowserSiteStore(storageURL: storageURL).sites().map(\.name), ["Normal"])
  }

  func testClearSavedSitesDoesNotEraseTheSingleLastPage() throws {
    let page = try XCTUnwrap(URL(string: "https://example.com/reading?issue=12"))
    _ = try store.saveSite(name: "Example", url: page)
    try store.recordLastVisitedURL(page)

    try store.deleteAllSites()

    XCTAssertTrue(try store.sites().isEmpty)
    XCTAssertEqual(try store.lastVisitedURL()?.absoluteString, "https://example.com/")
  }

  func testURLValidationAllowsLocalHTTPButRejectsNonWebSchemes() throws {
    XCTAssertEqual(
      try CRBrowserSiteStore.normalizedWebsiteURL(from: "http://127.0.0.1:8080/comics")
        .absoluteString,
      "http://127.0.0.1:8080/comics"
    )

    for value in ["file:///private/comic.cbz", "javascript:alert(1)", "https://user@example.com/"] {
      XCTAssertThrowsError(try CRBrowserSiteStore.normalizedWebsiteURL(from: value)) { error in
        XCTAssertEqual((error as NSError).code, CRBrowserSiteErrorCode.invalidURL.rawValue)
      }
    }
  }

  func testDamagedArchiveIsPreservedInsteadOfOverwritten() throws {
    let damaged = Data("{ not valid JSON".utf8)
    try FileManager.default.createDirectory(at: storageURL.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    try damaged.write(to: storageURL)

    XCTAssertThrowsError(try store.sites()) { error in
      XCTAssertEqual((error as NSError).code, CRBrowserSiteErrorCode.invalidArchive.rawValue)
    }
    XCTAssertThrowsError(
      try store.saveSite(name: "Must not overwrite",
                         url: XCTUnwrap(URL(string: "https://example.com/")))
    )
    XCTAssertEqual(try Data(contentsOf: storageURL), damaged)
  }
}
