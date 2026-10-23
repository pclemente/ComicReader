import Foundation
import UIKit
import XCTest

@testable import ComicFlow

final class CRWebImportTests: XCTestCase {
  private var fixtureRoot: URL!
  private var libraryRoot: URL!
  private var model: CRWebImportModel!

  override func setUpWithError() throws {
    fixtureRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("CRWebImportTests-\(UUID().uuidString)", isDirectory: true)
    libraryRoot = fixtureRoot.appendingPathComponent("Library", isDirectory: true)
    try FileManager.default.createDirectory(at: libraryRoot, withIntermediateDirectories: true)
    model = try CRWebImportModel(libraryRootURL: libraryRoot)
  }

  override func tearDownWithError() throws {
    model = nil
    if let fixtureRoot { try? FileManager.default.removeItem(at: fixtureRoot) }
    libraryRoot = nil
    fixtureRoot = nil
  }

  func testUntrustedFilenamesAreNormalizedAndFormatClaimsMustMatch() throws {
    XCTAssertEqual(try CRWebImportModel.normalizedFilename("../../.secret\u{202E}fdp.PDF",
                                                          detectedFormat: .pdf),
                   "secret fdp.pdf")
    XCTAssertEqual(try CRWebImportModel.normalizedFilename("C:\\private\\Issue.CBZ",
                                                          detectedFormat: .zip),
                   "Issue.cbz")
    XCTAssertEqual(try CRWebImportModel.normalizedFilename("no-extension",
                                                          detectedFormat: .rar),
                   "no-extension.cbr")
    XCTAssertEqual(try CRWebImportModel.normalizedFilename("..\\..\\\u{0}: .pdf",
                                                          detectedFormat: .pdf),
                   "Download.pdf")

    XCTAssertThrowsError(try CRWebImportModel.normalizedFilename("pretend.pdf",
                                                                 detectedFormat: .zip)) { error in
      XCTAssertEqual(error as? CRWebImportError, .contentTypeMismatch)
    }

    let veryLong = String(repeating: "é", count: 400) + ".pdf"
    let normalized = try CRWebImportModel.normalizedFilename(veryLong, detectedFormat: .pdf)
    XCTAssertLessThanOrEqual((normalized as NSString).deletingPathExtension.count, 180)
    XCTAssertEqual((normalized as NSString).pathExtension, "pdf")
  }

  func testCollectionsAreDirectVisibleFoldersAndNeverSymlinks() throws {
    XCTAssertEqual(try model.createCollection(named: "  Manga  "), "Manga")
    XCTAssertEqual(try model.availableCollections(), ["Manga"])

    for invalid in ["../Escape", "Nested/Folder", "Nested\\Folder", ".Hidden", "Inbox", "A:B", "\n"] {
      XCTAssertThrowsError(try model.createCollection(named: invalid), "Accepted unsafe name: \(invalid)") { error in
        XCTAssertTrue(error is CRWebImportError)
      }
    }

    let outside = fixtureRoot.appendingPathComponent("Outside", isDirectory: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
    let linked = libraryRoot.appendingPathComponent("Linked", isDirectory: true)
    try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: outside)
    XCTAssertEqual(try model.availableCollections(), ["Manga"])

    let rootLink = fixtureRoot.appendingPathComponent("LibraryLink", isDirectory: true)
    try FileManager.default.createSymbolicLink(at: rootLink, withDestinationURL: libraryRoot)
    XCTAssertThrowsError(try CRWebImportModel(libraryRootURL: rootLink)) { error in
      XCTAssertEqual(error as? CRWebImportError, .invalidLibraryRoot)
    }
  }

  func testHTMLMasqueradingAsPDFIsRejectedBeforePageValidation() throws {
    let staged = try stage(Data("  <!DOCTYPE html><html><body>Sign in</body></html>".utf8))
    XCTAssertThrowsError(try model.prepareImport(stagedURL: staged.payload,
                                                 suggestedFilename: "Private.pdf",
                                                 mimeType: "application/pdf",
                                                 destinationCollection: nil)) { error in
      XCTAssertEqual(error as? CRWebImportError, .contentTypeMismatch)
    }

    let stagedWithHTMLType = try stage(makePDF(text: "Real PDF bytes"))
    XCTAssertThrowsError(try model.prepareImport(stagedURL: stagedWithHTMLType.payload,
                                                 suggestedFilename: "Private.pdf",
                                                 mimeType: "text/html; charset=utf-8",
                                                 destinationCollection: nil)) { error in
      XCTAssertEqual(error as? CRWebImportError, .contentTypeMismatch)
    }
  }

  func testCorruptAndEmptyArchivesAreRejectedEvenWithValidSignatures() throws {
    let corruptBytes = Data([0x50, 0x4B, 0x03, 0x04] + Array(repeating: 0, count: 32))
    let corrupt = try stage(corruptBytes)
    XCTAssertThrowsError(try model.prepareImport(stagedURL: corrupt.payload,
                                                 suggestedFilename: "Corrupt.cbz",
                                                 mimeType: "application/zip",
                                                 destinationCollection: nil)) { error in
      XCTAssertEqual(error as? CRWebImportError, .unreadableComic)
    }

    // A valid ZIP end-of-central-directory record with zero entries is still
    // not a comic because CRComicPageSource reports no readable pages.
    let emptyZip = Data([0x50, 0x4B, 0x05, 0x06] + Array(repeating: 0, count: 18))
    let empty = try stage(emptyZip)
    XCTAssertThrowsError(try model.prepareImport(stagedURL: empty.payload,
                                                 suggestedFilename: "Empty.zip",
                                                 mimeType: "application/zip",
                                                 destinationCollection: nil)) { error in
      XCTAssertEqual(error as? CRWebImportError, .unreadableComic)
    }
  }

  func testArchiveWhoseFirstImageEntryCannotBeDecodedIsRejected() throws {
    // This is a structurally valid ZIP containing page.jpg, but that entry is
    // plain text rather than image data. Counting extensions alone reports one
    // page; preparation must prove that the first page can actually be read.
    let archive = try XCTUnwrap(Data(base64Encoded:
      "UEsDBBQAAAAAAIMYIlBR2j+NCgAAAAoAAAAIAAAAcGFnZS5qcGdjb21pYy1wYWdlUEsDBBQAAAAAAIMYIlAUNBRPCAAAAAgAAAATAAAAX19NQUNPU1gvLl9wYWdlLmpwZ21ldGFkYXRhUEsBAhQDFAAAAAAAgxgiUFHaP40KAAAACgAAAAgAAAAAAAAAAAAAAIABAAAAAHBhZ2UuanBnUEsBAhQDFAAAAAAAgxgiUBQ0FE8IAAAACAAAABMAAAAAAAAAAAAAAIABMAAAAF9fTUFDT1NYLy5fcGFnZS5qcGdQSwUGAAAAAAIAAgB3AAAAaQAAAAAA"))
    let staged = try stage(archive)

    XCTAssertThrowsError(try model.prepareImport(stagedURL: staged.payload,
                                                 suggestedFilename: "Unreadable.cbz",
                                                 mimeType: "application/zip",
                                                 destinationCollection: nil)) { error in
      XCTAssertEqual(error as? CRWebImportError, .unreadableComic)
    }
  }

  func testAutomaticArchiveValidationCapsUncompressedFirstPage() throws {
    // The ZIP is only 240 bytes, but its valid PNG entry expands to 8,281
    // bytes. Use a small injected limit to exercise the production 96 MiB cap
    // without creating a large test fixture.
    let archive = try XCTUnwrap(Data(base64Encoded:
      "UEsDBBQAAAAIALdJV123QcRIfgAAAFkgAAAIAAAAcGFnZS5wbmftyDEKwkAARNFZ04RgLqCNlfdYs0G3CaIWKQMhZUyzoLWdYOFJPIM3sLfwGlq6HkP4D2YG5ryulnk2ySTlfuU2cc0v6Sj29bB9SbM0lHUohr7v9kEWAAAAAAAAAAAAAAD8venFzSWNvbO747P9PO5SYozeiS3iL19W7rZoTl9QSwECFAMUAAAACAC3SVddt0HESH4AAABZIAAACAAAAAAAAAAAAAAAgAEAAAAAcGFnZS5wbmdQSwUGAAAAAAEAAQA2AAAApAAAAAAA"))
    let limitedModel = try CRWebImportModel(libraryRootURL: libraryRoot,
                                            maximumValidationPageBytes: 1_024)
    let oversizedStage = try stage(archive)
    XCTAssertThrowsError(try limitedModel.prepareImport(stagedURL: oversizedStage.payload,
                                                        suggestedFilename: "Oversized.cbz",
                                                        mimeType: "application/zip",
                                                        destinationCollection: nil)) { error in
      XCTAssertEqual(error as? CRWebImportError, .unreadableComic)
    }

    // The same archive must remain readable through the default production
    // limit, proving the rejection above came from the extraction bound.
    let acceptedStage = try stage(archive)
    let prepared = try model.prepareImport(stagedURL: acceptedStage.payload,
                                           suggestedFilename: "Allowed.cbz",
                                           mimeType: "application/zip",
                                           destinationCollection: nil)
    XCTAssertEqual(prepared.pageCount, 1)
  }

  func testDuplicateBytesReuseExistingComicAndNameCollisionsNeverOverwrite() throws {
    let originalData = makePDF(text: "Original")
    let firstStage = try stage(originalData)
    let firstPrepared = try model.prepareImport(stagedURL: firstStage.payload,
                                                suggestedFilename: "Issue.pdf",
                                                mimeType: "application/pdf",
                                                destinationCollection: nil)
    XCTAssertEqual(firstPrepared.pageCount, 1)
    let firstResult = try model.commit(firstPrepared)
    guard case .imported(let firstURL) = firstResult else {
      return XCTFail("The first comic should be imported")
    }
    XCTAssertEqual(firstURL.lastPathComponent, "Issue.pdf")
    XCTAssertEqual(try Data(contentsOf: firstURL), originalData)

    let duplicateStage = try stage(originalData)
    let duplicatePrepared = try model.prepareImport(stagedURL: duplicateStage.payload,
                                                    suggestedFilename: "Different name.pdf",
                                                    mimeType: "application/pdf",
                                                    destinationCollection: nil)
    XCTAssertEqual(duplicatePrepared.duplicateURL, firstURL)
    XCTAssertEqual(try model.commit(duplicatePrepared), .duplicate(firstURL))
    XCTAssertFalse(FileManager.default.fileExists(atPath: libraryRoot
      .appendingPathComponent("Different name.pdf").path))

    let collisionData = makePDF(text: "Different bytes")
    let collisionStage = try stage(collisionData)
    let collisionPrepared = try model.prepareImport(stagedURL: collisionStage.payload,
                                                    suggestedFilename: "Issue.pdf",
                                                    mimeType: "application/pdf",
                                                    destinationCollection: nil)
    let collisionResult = try model.commit(collisionPrepared)
    guard case .imported(let collisionURL) = collisionResult else {
      return XCTFail("Different bytes should be imported separately")
    }
    XCTAssertEqual(collisionURL.lastPathComponent, "Issue (2).pdf")
    XCTAssertEqual(try Data(contentsOf: firstURL), originalData, "A collision must never overwrite the first comic")
    XCTAssertEqual(try Data(contentsOf: collisionURL), collisionData)
  }

  func testCollectionSymlinkSwapCannotEscapeLibraryAtCommit() throws {
    let collection = try model.createCollection(named: "Comics")
    let staged = try stage(makePDF(text: "Confined"))
    let prepared = try model.prepareImport(stagedURL: staged.payload,
                                           suggestedFilename: "Issue.pdf",
                                           mimeType: "application/pdf",
                                           destinationCollection: collection)

    let collectionURL = libraryRoot.appendingPathComponent(collection, isDirectory: true)
    let outside = fixtureRoot.appendingPathComponent("Outside", isDirectory: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
    try FileManager.default.removeItem(at: collectionURL)
    try FileManager.default.createSymbolicLink(at: collectionURL, withDestinationURL: outside)

    XCTAssertThrowsError(try model.commit(prepared)) { error in
      XCTAssertEqual(error as? CRWebImportError, .invalidCollection)
    }
    XCTAssertTrue((try FileManager.default.contentsOfDirectory(atPath: outside.path)).isEmpty)
    XCTAssertTrue(FileManager.default.fileExists(atPath: prepared.stagedURL.path),
                  "A rejected commit should leave staging available for deterministic cleanup")
  }

  func testCancellationPreventsValidationAndFinalAtomicCommit() throws {
    let beforeValidation = try stage(makePDF(text: "Cancel validation"))
    XCTAssertThrowsError(try model.prepareImport(stagedURL: beforeValidation.payload,
                                                 suggestedFilename: "Cancelled.pdf",
                                                 mimeType: "application/pdf",
                                                 destinationCollection: nil,
                                                 shouldContinue: { false })) { error in
      XCTAssertEqual(error as? CRWebImportError, .cancelled)
    }

    let beforeCommit = try stage(makePDF(text: "Cancel commit"))
    let prepared = try model.prepareImport(stagedURL: beforeCommit.payload,
                                           suggestedFilename: "Cancelled.pdf",
                                           mimeType: "application/pdf",
                                           destinationCollection: nil)
    XCTAssertThrowsError(try model.commit(prepared, shouldContinue: { false })) { error in
      XCTAssertEqual(error as? CRWebImportError, .cancelled)
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: libraryRoot
      .appendingPathComponent("Cancelled.pdf").path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: prepared.stagedURL.path))
  }

  func testStagingIsHiddenExcludedFromBackupAndExplicitlyRemoved() throws {
    let session = try model.makeStagingSession()
    XCTAssertTrue(session.deletingLastPathComponent().lastPathComponent.hasPrefix("."))
    XCTAssertEqual(try session.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)

    let item = try model.makeStagingItem(in: session, identifier: UUID())
    try Data("temporary".utf8).write(to: item.payload)
    model.removeStagingItem(item.directory)
    XCTAssertFalse(FileManager.default.fileExists(atPath: item.directory.path))
    model.removeStagingSession(session)
    XCTAssertFalse(FileManager.default.fileExists(atPath: session.path))
  }

  private func stage(_ data: Data) throws -> (directory: URL, payload: URL) {
    let session = try model.makeStagingSession()
    let item = try model.makeStagingItem(in: session, identifier: UUID())
    try data.write(to: item.payload, options: .atomic)
    return item
  }

  private func makePDF(text: String) -> Data {
    let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 480, height: 640))
    return renderer.pdfData { context in
      context.beginPage()
      (text as NSString).draw(at: CGPoint(x: 40, y: 60),
                              withAttributes: [.font: UIFont.systemFont(ofSize: 24)])
    }
  }
}
