// Host-only runtime checks for CRCloudSyncManager's production file primitives.
// CR_CLOUD_SYNC_TESTING enables internal adapters; it is absent from app builds.
//
//   xcrun swiftc -swift-version 5 -D CR_CLOUD_SYNC_TESTING \
//     Classes/CRCloudSyncModel.swift Classes/CRCloudSyncManager.swift \
//     Tests/CRCloudSyncManagerHostHarness.swift \
//     -o /tmp/CRCloudSyncManagerHostHarness
//   /tmp/CRCloudSyncManagerHostHarness

import Foundation

@main
enum CRCloudSyncManagerHostHarness {
  static func main() throws {
    let fixtureRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("CRCloudSyncManagerHostHarness-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: fixtureRoot) }

    let sourceRoot = fixtureRoot.appendingPathComponent("source", isDirectory: true)
    let cloudRoot = fixtureRoot.appendingPathComponent("ubiquity/Documents/ComicReaderSync/v1",
                                                        isDirectory: true)
    let importRoot = fixtureRoot.appendingPathComponent("import", isDirectory: true)
    let stateRoot = fixtureRoot.appendingPathComponent("state", isDirectory: true)
    for directory in [sourceRoot, cloudRoot, importRoot, stateRoot] {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    let manager = CRCloudSyncManager.makeTestingManager(stateRootURL: stateRoot)
    try testConsentGate(manager: manager, libraryRoot: sourceRoot)
    try testDuplicateNamesAndRoundTrip(manager: manager,
                                       sourceRoot: sourceRoot,
                                       cloudRoot: cloudRoot,
                                       importRoot: importRoot)
    try testReplacementInvalidatesCachedIdentity(manager: manager, sourceRoot: sourceRoot)
    try testCancellation(manager: manager, sourceRoot: sourceRoot)
    try testAccountScopedSuppression(manager: manager, stateRoot: stateRoot)
    try testUnversionedReadingBaseline(manager: manager)
    print("CRCloudSyncManagerHostHarness: all tests passed")
  }

  private static func check(_ condition: @autoclosure () -> Bool,
                            _ message: String) throws {
    if !condition() {
      throw NSError(domain: "CRCloudSyncManagerHostHarness",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: message])
    }
  }

  private static func wait(until condition: @escaping () -> Bool,
                           timeout: TimeInterval = 5) throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition(), Date() < deadline {
      RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
    try check(condition(), "Timed out waiting for an asynchronous manager callback")
  }

  private static func testConsentGate(manager: CRCloudSyncManager,
                                      libraryRoot: URL) throws {
    manager.configure(libraryRootPath: libraryRoot.path as NSString,
                      optedIn: false)
    try wait { manager.configured }
    try check(!manager.enabled && manager.status == .disabled,
              "Explicit opt-in must default to off")

    var callbackFinished = false
    var callbackWasMainThread = false
    var returnedError: NSError?
    manager.synchronizeLibrarySnapshot([]) { _, error in
      callbackWasMainThread = Thread.isMainThread
      returnedError = error
      callbackFinished = true
    }
    try wait { callbackFinished }
    try check(callbackWasMainThread, "Objective-C completion must run on the main thread")
    try check(returnedError?.domain == CRCloudSyncManager.errorDomain &&
              returnedError?.code == CRCloudSyncErrorCode.optInRequired.rawValue,
              "A non-opted-in manager must reject sync before touching a container")
  }

  private static func testDuplicateNamesAndRoundTrip(manager: CRCloudSyncManager,
                                                     sourceRoot: URL,
                                                     cloudRoot: URL,
                                                     importRoot: URL) throws {
    let sourceA = sourceRoot.appendingPathComponent("source-a.cbz")
    let sourceB = sourceRoot.appendingPathComponent("source-b.cbz")
    let bytesA = Data((0..<262_144).map { UInt8($0 % 251) })
    let bytesB = Data((0..<262_144).map { UInt8(($0 + 73) % 251) })
    try bytesA.write(to: sourceA)
    try bytesB.write(to: sourceB)

    let artifactA = try manager.testingUpload(localURL: sourceA,
                                              preferredRelativePath: "Same.cbz",
                                              cloudRootURL: cloudRoot)
    let artifactB = try manager.testingUpload(localURL: sourceB,
                                              preferredRelativePath: "Same.cbz",
                                              cloudRootURL: cloudRoot)
    try check(artifactA.contentIdentifier != artifactB.contentIdentifier,
              "Different bytes must produce different comic identities")
    try check(artifactA.blobURL != artifactB.blobURL,
              "Same-named comics must occupy separate identity directories")
    let uploadedBytesA = try Data(contentsOf: artifactA.blobURL)
    let uploadedBytesB = try Data(contentsOf: artifactB.blobURL)
    try check(uploadedBytesA == bytesA && uploadedBytesB == bytesB,
              "Uploaded blobs must match their sources")

    let importedA = try manager.testingImport(artifactA,
                                              preferredRelativePath: "Same.cbz",
                                              importRootURL: importRoot,
                                              cloudRootURL: cloudRoot)
    let importedB = try manager.testingImport(artifactB,
                                              preferredRelativePath: "Same.cbz",
                                              importRootURL: importRoot,
                                              cloudRootURL: cloudRoot)
    try check(importedA.lastPathComponent == "Same.cbz" &&
              importedB.lastPathComponent == "Same (2).cbz",
              "Duplicate display names must import without overwriting")
    let importedBytesA = try Data(contentsOf: importedA)
    let importedBytesB = try Data(contentsOf: importedB)
    try check(importedBytesA == bytesA && importedBytesB == bytesB,
              "Round-tripped comic bytes must remain exact")

    try FileManager.default.removeItem(at: artifactA.blobURL)
    let repairedMissing = try manager.testingUpload(localURL: sourceA,
                                                    preferredRelativePath: "Same.cbz",
                                                    cloudRootURL: cloudRoot)
    let repairedMissingBytes = try Data(contentsOf: repairedMissing.blobURL)
    try check(repairedMissing.uploaded && repairedMissingBytes == bytesA,
              "A missing blob with a valid manifest must self-heal")

    try bytesB.write(to: repairedMissing.blobURL, options: .atomic)
    let repairedCorrupt = try manager.testingUpload(localURL: sourceA,
                                                    preferredRelativePath: "Same.cbz",
                                                    cloudRootURL: cloudRoot)
    let repairedCorruptBytes = try Data(contentsOf: repairedCorrupt.blobURL)
    try check(repairedCorrupt.uploaded && repairedCorruptBytes == bytesA,
              "A corrupt blob must be replaced before its manifest is trusted")
    let idempotent = try manager.testingUpload(localURL: sourceA,
                                               preferredRelativePath: "Same.cbz",
                                               cloudRootURL: cloudRoot)
    try check(!idempotent.uploaded, "A verified existing blob should not upload again")

    try Data(repeating: 0x99, count: bytesB.count).write(to: artifactB.blobURL, options: .atomic)
    do {
      _ = try manager.testingImport(artifactB,
                                    preferredRelativePath: "Corrupt.cbz",
                                    importRootURL: importRoot,
                                    cloudRootURL: cloudRoot)
      try check(false, "A corrupt downloaded blob must not be imported")
    } catch let error as NSError {
      try check(error.domain == CRCloudSyncManager.errorDomain &&
                error.code == CRCloudSyncErrorCode.integrityMismatch.rawValue,
                "Corrupt import must fail with an integrity error")
      try check(!FileManager.default.fileExists(atPath: importRoot.appendingPathComponent("Corrupt.cbz").path),
                "A failed integrity check must remove its partial local import")
    }
  }

  private static func testReplacementInvalidatesCachedIdentity(manager: CRCloudSyncManager,
                                                               sourceRoot: URL) throws {
    let comicURL = sourceRoot.appendingPathComponent("replacement.cbz")
    let replacementURL = sourceRoot.appendingPathComponent("replacement-new.cbz")
    let originalDate = Date(timeIntervalSince1970: 1_700_000_000)
    let oldBytes = Data(repeating: 0x11, count: 131_072)
    let newBytes = Data(repeating: 0x22, count: oldBytes.count)
    try oldBytes.write(to: comicURL)
    try FileManager.default.setAttributes([.modificationDate: originalDate], ofItemAtPath: comicURL.path)
    let oldIdentity = try manager.testingPreparedContentIdentifier(localURL: comicURL,
                                                                   relativePath: "replacement.cbz",
                                                                   libraryRootURL: sourceRoot)

    try newBytes.write(to: replacementURL)
    try FileManager.default.setAttributes([.modificationDate: originalDate], ofItemAtPath: replacementURL.path)
    try FileManager.default.removeItem(at: comicURL)
    try FileManager.default.moveItem(at: replacementURL, to: comicURL)
    try FileManager.default.setAttributes([.modificationDate: originalDate], ofItemAtPath: comicURL.path)
    let newIdentity = try manager.testingPreparedContentIdentifier(localURL: comicURL,
                                                                   relativePath: "replacement.cbz",
                                                                   libraryRootURL: sourceRoot)
    try check(oldIdentity != newIdentity,
              "A same-size replacement preserving mtime must invalidate the cached SHA")
  }

  private static func testCancellation(manager: CRCloudSyncManager,
                                       sourceRoot: URL) throws {
    let comicURL = sourceRoot.appendingPathComponent("cancel.cbz")
    try Data(repeating: 0x44, count: 2_097_152).write(to: comicURL)
    let error = manager.testingCancellationError(whileHashing: comicURL)
    try check(error?.domain == CRCloudSyncManager.errorDomain &&
              error?.code == CRCloudSyncErrorCode.cancelled.rawValue,
              "A stale generation must cancel hashing before producing an identity")
  }

  private static func testAccountScopedSuppression(manager: CRCloudSyncManager,
                                                   stateRoot: URL) throws {
    let identifier = String(repeating: "b", count: 64)
    try manager.testingSetLocalSuppression(identifier, accountFingerprint: "account-a")
    let accountAHasSuppression = try manager.testingHasLocalSuppression(identifier,
                                                                        accountFingerprint: "account-a")
    let accountBHasSuppression = try manager.testingHasLocalSuppression(identifier,
                                                                        accountFingerprint: "account-b")
    try check(accountAHasSuppression,
              "Local deletion suppression must persist for its account")
    try check(!accountBHasSuppression,
              "Local deletion suppression must not leak into another account")

    let reloaded = CRCloudSyncManager.makeTestingManager(stateRootURL: stateRoot)
    let reloadedHasSuppression = try reloaded.testingHasLocalSuppression(identifier,
                                                                         accountFingerprint: "account-a")
    try check(reloadedHasSuppression,
              "Per-account suppression must survive a manager restart")
  }

  private static func testUnversionedReadingBaseline(manager: CRCloudSyncManager) throws {
    let identifier = String(repeating: "c", count: 64)
    let baseline = manager.testingReadingRecord(["legacyStatus": 0,
                                                 "currentPage": 99,
                                                 "pageCount": 100],
                                                contentIdentifier: identifier)
    try check(baseline?.modifiedAt == 1,
              "A first-run state without a timestamp must be a low-priority baseline")
    try check(baseline?.legacyStatus == 0 && baseline?.currentPage == 99,
              "Exact currentPage must remain distinct from completed legacy status 0")
    let remote = CRCloudReadingStateRecord(contentIdentifier: identifier,
                                           legacyStatus: 12,
                                           currentPage: 12,
                                           pageCount: 100,
                                           modifiedAt: 2,
                                           mutationIdentifier: "remote-event",
                                           deviceIdentifier: "device-b")
    if let baseline {
      try check(CRCloudReadingStateRecord.preferred(baseline, remote) == remote,
                "Any real remote event must beat an unversioned local baseline")
    }
  }
}
