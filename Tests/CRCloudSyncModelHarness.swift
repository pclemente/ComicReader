// Host-runnable pure tests. This file is intentionally not part of the app target.
// Run with:
//   xcrun swiftc -swift-version 5 Classes/CRCloudSyncModel.swift \
//     Tests/CRCloudSyncModelHarness.swift -o /tmp/CRCloudSyncModelHarness && \
//     /tmp/CRCloudSyncModelHarness

import Foundation

@main
enum CRCloudSyncModelHarness {
  static func main() throws {
    try testLaterRewindWins()
    try testLaterMarkNewWins()
    try testTieBreakIsDeterministic()
    try testExactPageIsIndependentFromLegacyStatus()
    try testPathContainmentAndTraversal()
    try testDuplicateNamesDoNotOverwrite()
    print("CRCloudSyncModelHarness: all tests passed")
  }

  private static func check(_ condition: @autoclosure () -> Bool,
                            _ message: String) throws {
    if !condition() {
      throw NSError(domain: "CRCloudSyncModelHarness",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: message])
    }
  }

  private static func record(status: Int,
                             page: Int,
                             modified: TimeInterval,
                             mutation: String,
                             device: String = "device-a") -> CRCloudReadingStateRecord {
    CRCloudReadingStateRecord(contentIdentifier: String(repeating: "a", count: 64),
                              legacyStatus: status,
                              currentPage: page,
                              pageCount: 100,
                              modifiedAt: modified,
                              mutationIdentifier: mutation,
                              deviceIdentifier: device)
  }

  private static func testLaterRewindWins() throws {
    let advanced = record(status: 80, page: 80, modified: 100, mutation: "m1")
    let rewind = record(status: 3, page: 3, modified: 101, mutation: "m2")
    try check(CRCloudReadingStateRecord.preferred(advanced, rewind) == rewind,
              "A later intentional rewind must beat a larger page number")
  }

  private static func testLaterMarkNewWins() throws {
    let reading = record(status: 50, page: 50, modified: 100, mutation: "m1")
    let markedNew = record(status: -1, page: 0, modified: 200, mutation: "m2")
    try check(CRCloudReadingStateRecord.preferred(reading, markedNew) == markedNew,
              "A later mark-new event must beat older progress")
  }

  private static func testTieBreakIsDeterministic() throws {
    let first = record(status: 2, page: 2, modified: 100, mutation: "aaa", device: "device-z")
    let second = record(status: 7, page: 7, modified: 100, mutation: "bbb", device: "device-a")
    try check(CRCloudReadingStateRecord.preferred(first, second) == second,
              "Mutation ID must deterministically break equal timestamps")
    try check(CRCloudReadingStateRecord.preferred(second, first) == second,
              "Tie-break result must not depend on argument order")
  }

  private static func testExactPageIsIndependentFromLegacyStatus() throws {
    let finishedOnPage = record(status: 0, page: 99, modified: 100, mutation: "m1")
    try check(finishedOnPage.legacyStatus == 0 && finishedOnPage.currentPage == 99,
              "Exact currentPage must survive legacy status 0")
  }

  private static func testPathContainmentAndTraversal() throws {
    let root = URL(fileURLWithPath: "/tmp/ComicReaderLibrary", isDirectory: true)
    try check(CRCloudSyncPathPolicy.normalizedRelativePath("Series/Issue.cbz") == "Series/Issue.cbz",
              "A normal collection path should be accepted")
    try check(CRCloudSyncPathPolicy.normalizedRelativePath("../escape.cbz") == nil,
              "Parent traversal must be rejected")
    try check(CRCloudSyncPathPolicy.normalizedRelativePath(".library/database.db") == nil,
              "Hidden application data must be rejected")
    try check(!CRCloudSyncPathPolicy.contains(URL(fileURLWithPath: "/tmp/ComicReaderLibrary2/a.cbz"),
                                              within: root),
              "Containment must use a path boundary")
  }

  private static func testDuplicateNamesDoNotOverwrite() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("CRCloudSyncModelHarness-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let first = root.appendingPathComponent("Same.cbz")
    try Data([1]).write(to: first)
    let second = CRCloudSyncPathPolicy.uniqueImportURL(relativePath: "Same.cbz",
                                                       libraryRootURL: root)
    try check(second.lastPathComponent == "Same (2).cbz",
              "A same-named remote comic must receive a collision-free name")
  }
}
