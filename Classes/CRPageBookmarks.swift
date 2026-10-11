import CryptoKit
import Foundation

@objc(CRPageBookmarkErrorCode)
public enum CRPageBookmarkErrorCode: Int {
  case comicUnavailable = 1
  case comicChangedWhileReading
  case invalidBookmarkName
  case invalidPage
  case bookmarkNotFound
  case invalidArchive
  case unsupportedArchiveVersion
  case storageUnavailable
}

@objc(CRPageBookmarkComic)
public final class CRPageBookmarkComic: NSObject {
  fileprivate let storageKey: String

  @objc public let fingerprint: String

  fileprivate init(fingerprint: String) {
    self.fingerprint = fingerprint
    storageKey = fingerprint
    super.init()
  }
}

extension CRPageBookmarkComic: @unchecked Sendable {}

@objc(CRPageBookmark)
public final class CRPageBookmark: NSObject {
  @objc public let identifier: String
  @objc public let name: String
  @objc public let pageIndex: Int
  @objc public let createdAt: Date
  @objc public let modifiedAt: Date

  fileprivate init(record: CRPageBookmarkRecord) {
    identifier = record.identifier
    name = record.name
    pageIndex = record.pageIndex
    createdAt = record.createdAt
    modifiedAt = record.modifiedAt
    super.init()
  }
}

extension CRPageBookmark: @unchecked Sendable {}

private struct CRPageBookmarkRecord: Codable, Equatable {
  let identifier: String
  var name: String
  let pageIndex: Int
  let createdAt: Date
  var modifiedAt: Date
}

private struct CRPageBookmarkArchive: Codable {
  var version: Int
  var comics: [String: [CRPageBookmarkRecord]]

  static let currentVersion = 1
  static var empty: CRPageBookmarkArchive {
    CRPageBookmarkArchive(version: currentVersion, comics: [:])
  }
}

private struct CRPageBookmarkFileSnapshot: Equatable {
  let byteCount: UInt64
  let modificationDate: Date?
  let creationDate: Date?
  let deviceNumber: UInt64?
  let fileNumber: UInt64?
}

@objc(CRPageBookmarkStore)
public final class CRPageBookmarkStore: NSObject {
  @objc public static let sharedStore = CRPageBookmarkStore()
  @objc public static let errorDomain = "com.pabloclementeperez.ComicReader.PageBookmarks"

  private static let maximumNameLength = 80
  private static let hashReadSize = 1024 * 1024

  private let storageURL: URL
  private let fileManager: FileManager
  private let lock = NSLock()

  @objc public override convenience init() {
    let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory,
                                                       in: .userDomainMask).first!
    let directory = applicationSupport.appendingPathComponent("ComicReader", isDirectory: true)
    self.init(storageURL: directory.appendingPathComponent("PageBookmarks-v1.json"),
              fileManager: .default)
  }

  init(storageURL: URL, fileManager: FileManager = .default) {
    self.storageURL = storageURL
    self.fileManager = fileManager
    super.init()
  }

  /// Resolves a comic by its bytes rather than its database row or display name.
  /// Hashing happens outside the persistence lock and callers should invoke this
  /// method away from the main thread for large comics.
  @objc(resolveComicAtPath:error:)
  public func resolveComic(atPath path: String) throws -> CRPageBookmarkComic {
    let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
    var lastChangeError: NSError?

    // Atomic replacement during a read is uncommon, but one retry avoids binding
    // bookmarks to a partial view of either file.
    for _ in 0..<2 {
      let before = try snapshot(of: url)
      let digest: SHA256.Digest
      do {
        digest = try digestFile(at: url)
      } catch {
        throw failure(.comicUnavailable,
                      "This comic could not be read to identify its bookmarks.",
                      underlying: error)
      }
      let after = try snapshot(of: url)
      guard before == after else {
        lastChangeError = failure(.comicChangedWhileReading,
                                  "The comic changed while its bookmarks were loading.")
        continue
      }

      let fingerprint = digest.map { String(format: "%02x", $0) }.joined()
      return CRPageBookmarkComic(fingerprint: "sha256:\(fingerprint)")
    }

    throw lastChangeError ?? failure(.comicChangedWhileReading,
                                     "The comic changed while its bookmarks were loading.")
  }

  @objc(bookmarksForComic:error:)
  public func bookmarks(for comic: CRPageBookmarkComic) throws -> [CRPageBookmark] {
    try withLock {
      let archive = try loadArchive()
      return sortedRecords(archive.comics[comic.storageKey] ?? []).map(CRPageBookmark.init(record:))
    }
  }

  @discardableResult
  @objc(addBookmarkForComic:name:pageIndex:pageCount:error:)
  public func addBookmark(for comic: CRPageBookmarkComic,
                          name: String,
                          pageIndex: Int,
                          pageCount: Int) throws -> CRPageBookmark {
    let normalizedName = try validatedName(name)
    guard pageCount > 0, pageIndex >= 0, pageIndex < pageCount else {
      throw failure(.invalidPage, "That page is no longer available in this comic.")
    }

    return try withLock {
      var archive = try loadArchive()
      let now = Date()
      let record = CRPageBookmarkRecord(identifier: UUID().uuidString.lowercased(),
                                        name: normalizedName,
                                        pageIndex: pageIndex,
                                        createdAt: now,
                                        modifiedAt: now)
      archive.comics[comic.storageKey, default: []].append(record)
      try saveArchive(archive)
      return CRPageBookmark(record: record)
    }
  }

  @discardableResult
  @objc(renameBookmarkForComic:identifier:name:error:)
  public func renameBookmark(for comic: CRPageBookmarkComic,
                             identifier: String,
                             name: String) throws -> CRPageBookmark {
    let normalizedName = try validatedName(name)

    return try withLock {
      var archive = try loadArchive()
      guard var records = archive.comics[comic.storageKey],
            let index = records.firstIndex(where: { $0.identifier == identifier }) else {
        throw failure(.bookmarkNotFound, "That bookmark no longer exists.")
      }
      records[index].name = normalizedName
      records[index].modifiedAt = Date()
      archive.comics[comic.storageKey] = records
      try saveArchive(archive)
      return CRPageBookmark(record: records[index])
    }
  }

  @objc(deleteBookmarkForComic:identifier:error:)
  public func deleteBookmark(for comic: CRPageBookmarkComic,
                             identifier: String) throws {
    try withLock {
      var archive = try loadArchive()
      guard var records = archive.comics[comic.storageKey],
            let index = records.firstIndex(where: { $0.identifier == identifier }) else {
        throw failure(.bookmarkNotFound, "That bookmark no longer exists.")
      }
      records.remove(at: index)
      if records.isEmpty {
        archive.comics.removeValue(forKey: comic.storageKey)
      } else {
        archive.comics[comic.storageKey] = records
      }
      try saveArchive(archive)
    }
  }

  private func snapshot(of url: URL) throws -> CRPageBookmarkFileSnapshot {
    do {
      let attributes = try fileManager.attributesOfItem(atPath: url.path)
      guard attributes[.type] as? FileAttributeType == .typeRegular else {
        throw failure(.comicUnavailable, "The selected comic is not a regular file.")
      }
      guard let size = (attributes[.size] as? NSNumber)?.uint64Value else {
        throw failure(.comicUnavailable, "The selected comic has no readable file size.")
      }
      return CRPageBookmarkFileSnapshot(
        byteCount: size,
        modificationDate: attributes[.modificationDate] as? Date,
        creationDate: attributes[.creationDate] as? Date,
        deviceNumber: (attributes[.systemNumber] as? NSNumber)?.uint64Value,
        fileNumber: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
      )
    } catch let error as NSError where error.domain == Self.errorDomain {
      throw error
    } catch {
      throw failure(.comicUnavailable,
                    "This comic is unavailable, so its bookmarks could not be loaded.",
                    underlying: error)
    }
  }

  private func digestFile(at url: URL) throws -> SHA256.Digest {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }

    var hasher = SHA256()
    while true {
      let data = try autoreleasepool {
        try handle.read(upToCount: Self.hashReadSize) ?? Data()
      }
      if data.isEmpty {
        break
      }
      hasher.update(data: data)
    }
    return hasher.finalize()
  }

  private func validatedName(_ name: String) throws -> String {
    let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty, normalized.count <= Self.maximumNameLength else {
      throw failure(.invalidBookmarkName,
                    "Enter a bookmark name between 1 and \(Self.maximumNameLength) characters.")
    }
    return normalized
  }

  private func loadArchive() throws -> CRPageBookmarkArchive {
    guard fileManager.fileExists(atPath: storageURL.path) else {
      return .empty
    }

    let archive: CRPageBookmarkArchive
    do {
      let data = try Data(contentsOf: storageURL, options: .mappedIfSafe)
      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = .iso8601
      archive = try decoder.decode(CRPageBookmarkArchive.self, from: data)
    } catch {
      throw failure(.invalidArchive,
                    "Your saved page bookmarks could not be read. The existing file was left unchanged.",
                    underlying: error)
    }

    guard archive.version == CRPageBookmarkArchive.currentVersion else {
      throw failure(.unsupportedArchiveVersion,
                    "These page bookmarks were created by an unsupported app version.")
    }
    guard archive.comics.values.joined().allSatisfy({ record in
      !record.identifier.isEmpty &&
        !record.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        record.name.count <= Self.maximumNameLength &&
        record.pageIndex >= 0
    }) else {
      throw failure(.invalidArchive,
                    "Your saved page bookmarks contain invalid data. The existing file was left unchanged.")
    }
    return archive
  }

  private func saveArchive(_ archive: CRPageBookmarkArchive) throws {
    do {
      try fileManager.createDirectory(at: storageURL.deletingLastPathComponent(),
                                      withIntermediateDirectories: true)
      let encoder = JSONEncoder()
      encoder.dateEncodingStrategy = .iso8601
      encoder.outputFormatting = [.sortedKeys]
      let data = try encoder.encode(archive)
      try data.write(to: storageURL, options: .atomic)
    } catch {
      throw failure(.storageUnavailable,
                    "Your page bookmark changes could not be saved.",
                    underlying: error)
    }
  }

  private func sortedRecords(_ records: [CRPageBookmarkRecord]) -> [CRPageBookmarkRecord] {
    records.sorted {
      if $0.pageIndex != $1.pageIndex {
        return $0.pageIndex < $1.pageIndex
      }
      if $0.createdAt != $1.createdAt {
        return $0.createdAt < $1.createdAt
      }
      return $0.identifier < $1.identifier
    }
  }

  private func withLock<T>(_ body: () throws -> T) rethrows -> T {
    lock.lock()
    defer { lock.unlock() }
    return try body()
  }

  private func failure(_ code: CRPageBookmarkErrorCode,
                       _ description: String,
                       underlying: Error? = nil) -> NSError {
    var userInfo: [String: Any] = [NSLocalizedDescriptionKey: description]
    if let underlying {
      userInfo[NSUnderlyingErrorKey] = underlying
    }
    return NSError(domain: Self.errorDomain, code: code.rawValue, userInfo: userInfo)
  }
}

extension CRPageBookmarkStore: @unchecked Sendable {}
