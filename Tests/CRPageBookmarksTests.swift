import Foundation
import XCTest

@testable import ComicFlow

final class CRPageBookmarksTests: XCTestCase {
  private var fixtureRoot: URL!
  private var storageURL: URL!
  private var store: CRPageBookmarkStore!

  override func setUpWithError() throws {
    fixtureRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("CRPageBookmarksTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
    storageURL = fixtureRoot.appendingPathComponent("state/PageBookmarks-v1.json")
    store = CRPageBookmarkStore(storageURL: storageURL)
  }

  override func tearDownWithError() throws {
    if let fixtureRoot {
      try? FileManager.default.removeItem(at: fixtureRoot)
    }
    store = nil
    storageURL = nil
    fixtureRoot = nil
  }

  func testAddRenameDeleteAndPersistence() throws {
    let comicURL = try makeComic(name: "Issue.cbz", bytes: Data("comic-one".utf8))
    let comic = try store.resolveComic(atPath: comicURL.path)

    let later = try store.addBookmark(for: comic, name: "  Final battle  ", pageIndex: 8, pageCount: 12)
    let earlier = try store.addBookmark(for: comic, name: "Opening", pageIndex: 1, pageCount: 12)

    let reopenedStore = CRPageBookmarkStore(storageURL: storageURL)
    XCTAssertEqual(try reopenedStore.bookmarks(for: comic).map(\.identifier),
                   [earlier.identifier, later.identifier],
                   "Bookmarks should persist and list in page order")
    XCTAssertEqual(try reopenedStore.bookmarks(for: comic).map(\.name),
                   ["Opening", "Final battle"])

    let renamed = try reopenedStore.renameBookmark(for: comic,
                                                   identifier: earlier.identifier,
                                                   name: " First page ")
    XCTAssertEqual(renamed.name, "First page")
    XCTAssertGreaterThanOrEqual(renamed.modifiedAt, renamed.createdAt)

    try reopenedStore.deleteBookmark(for: comic, identifier: later.identifier)
    let remaining = try CRPageBookmarkStore(storageURL: storageURL).bookmarks(for: comic)
    XCTAssertEqual(remaining.count, 1)
    XCTAssertEqual(remaining.first?.identifier, earlier.identifier)
    XCTAssertEqual(remaining.first?.name, "First page")
  }

  func testReplacementAtSamePathDoesNotInheritBookmarks() throws {
    let comicURL = try makeComic(name: "Replace.cbz", bytes: Data(repeating: 0x11, count: 4_096))
    let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
    try FileManager.default.setAttributes([.modificationDate: fixedDate], ofItemAtPath: comicURL.path)

    let original = try store.resolveComic(atPath: comicURL.path)
    _ = try store.addBookmark(for: original, name: "Original", pageIndex: 3, pageCount: 10)

    try Data(repeating: 0x22, count: 4_096).write(to: comicURL, options: .atomic)
    try FileManager.default.setAttributes([.modificationDate: fixedDate], ofItemAtPath: comicURL.path)
    let replacement = try store.resolveComic(atPath: comicURL.path)

    XCTAssertNotEqual(original.fingerprint, replacement.fingerprint,
                      "Equal paths, sizes, and modification dates must not alias different bytes")
    XCTAssertTrue(try store.bookmarks(for: replacement).isEmpty)
    XCTAssertEqual(try store.bookmarks(for: original).map(\.name), ["Original"],
                   "Replacing a file must not destroy its old bookmark data")
  }

  func testDifferentComicsWithSameFilenameRemainIsolated() throws {
    let firstURL = try makeComic(name: "A/Same.cbz", bytes: Data("first comic".utf8))
    let secondURL = try makeComic(name: "B/Same.cbz", bytes: Data("second comic".utf8))
    let first = try store.resolveComic(atPath: firstURL.path)
    let second = try store.resolveComic(atPath: secondURL.path)

    _ = try store.addBookmark(for: first, name: "Only first", pageIndex: 0, pageCount: 2)

    XCTAssertEqual(try store.bookmarks(for: first).count, 1)
    XCTAssertTrue(try store.bookmarks(for: second).isEmpty)
  }

  func testMovingTheSameComicKeepsItsBookmarks() throws {
    let originalURL = try makeComic(name: "Before.cbz", bytes: Data("same bytes after move".utf8))
    let original = try store.resolveComic(atPath: originalURL.path)
    _ = try store.addBookmark(for: original, name: "Keep me", pageIndex: 2, pageCount: 4)

    let movedURL = fixtureRoot.appendingPathComponent("After.cbz")
    try FileManager.default.moveItem(at: originalURL, to: movedURL)
    let moved = try store.resolveComic(atPath: movedURL.path)

    XCTAssertEqual(original.fingerprint, moved.fingerprint)
    XCTAssertEqual(try store.bookmarks(for: moved).map(\.name), ["Keep me"])
  }

  func testInvalidArchiveIsPreservedAndReported() throws {
    let comicURL = try makeComic(name: "Issue.cbz", bytes: Data("comic".utf8))
    let comic = try store.resolveComic(atPath: comicURL.path)
    let corruptData = Data("{ definitely not valid json".utf8)
    try FileManager.default.createDirectory(at: storageURL.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    try corruptData.write(to: storageURL)

    XCTAssertThrowsError(try store.bookmarks(for: comic)) { error in
      XCTAssertEqual((error as NSError).domain, CRPageBookmarkStore.errorDomain)
      XCTAssertEqual((error as NSError).code, CRPageBookmarkErrorCode.invalidArchive.rawValue)
    }
    XCTAssertThrowsError(try store.addBookmark(for: comic,
                                               name: "Must not overwrite",
                                               pageIndex: 0,
                                               pageCount: 1))
    XCTAssertEqual(try Data(contentsOf: storageURL), corruptData)
  }

  func testBookmarkValidationRejectsEmptyNamesAndInvalidPages() throws {
    let comicURL = try makeComic(name: "Issue.cbz", bytes: Data("comic".utf8))
    let comic = try store.resolveComic(atPath: comicURL.path)

    XCTAssertThrowsError(try store.addBookmark(for: comic,
                                               name: "  \n ",
                                               pageIndex: 0,
                                               pageCount: 1)) { error in
      XCTAssertEqual((error as NSError).code, CRPageBookmarkErrorCode.invalidBookmarkName.rawValue)
    }
    XCTAssertThrowsError(try store.addBookmark(for: comic,
                                               name: "Missing page",
                                               pageIndex: 1,
                                               pageCount: 1)) { error in
      XCTAssertEqual((error as NSError).code, CRPageBookmarkErrorCode.invalidPage.rawValue)
    }
    XCTAssertTrue(try store.bookmarks(for: comic).isEmpty)
  }

  private func makeComic(name: String, bytes: Data) throws -> URL {
    let url = fixtureRoot.appendingPathComponent(name)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    try bytes.write(to: url)
    return url
  }
}
