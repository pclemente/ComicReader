import CryptoKit
import Foundation

enum CRWebImportError: Error, LocalizedError, Equatable {
  case plusRequired
  case invalidLibraryRoot
  case invalidCollection
  case collectionAlreadyExists
  case unsupportedFormat
  case contentTypeMismatch
  case invalidDownload
  case unreadableComic
  case retryUnavailable
  case cancelled
  case fileOperationFailed

  var errorDescription: String? {
    switch self {
    case .plusRequired:
      return "ComicReader Plus is required to download comics from the web."
    case .invalidLibraryRoot:
      return "The comic library is unavailable."
    case .invalidCollection:
      return "Choose a valid library collection."
    case .collectionAlreadyExists:
      return "A collection with that name already exists."
    case .unsupportedFormat:
      return "This download is not a supported PDF, CBZ, or CBR comic."
    case .contentTypeMismatch:
      return "The downloaded content does not match its comic format."
    case .invalidDownload:
      return "The downloaded file is incomplete or invalid."
    case .unreadableComic:
      return "The downloaded comic has no readable pages."
    case .retryUnavailable:
      return "This download cannot be resumed. Start it again from the web page."
    case .cancelled:
      return "The download was cancelled."
    case .fileOperationFailed:
      return "ComicReader could not save the downloaded comic."
    }
  }
}

enum CRWebComicFormat: String, CaseIterable {
  case pdf
  case zip
  case rar

  var canonicalExtension: String {
    switch self {
    case .pdf: return "pdf"
    case .zip: return "cbz"
    case .rar: return "cbr"
    }
  }

  var acceptedExtensions: Set<String> {
    switch self {
    case .pdf: return ["pdf"]
    case .zip: return ["cbz", "zip"]
    case .rar: return ["cbr", "rar"]
    }
  }

  static func format(forExtension pathExtension: String) -> CRWebComicFormat? {
    let value = pathExtension.lowercased()
    return allCases.first { $0.acceptedExtensions.contains(value) }
  }
}

struct CRWebPreparedImport {
  let stagedURL: URL
  let suggestedFilename: String
  let destinationCollection: String?
  let fingerprint: String
  let fileSize: UInt64
  let pageCount: Int
  let fileSnapshot: CRWebFileSnapshot
  let duplicateURL: URL?
  let duplicateSnapshot: CRWebFileSnapshot?
}

enum CRWebImportCommitResult: Equatable {
  case imported(URL)
  case duplicate(URL)

  var url: URL {
    switch self {
    case .imported(let url), .duplicate(let url): return url
    }
  }
}

struct CRWebFileSnapshot: Equatable {
  let size: UInt64
  let modificationDate: Date?
  let systemNumber: UInt64?
  let fileNumber: UInt64?
}

/// Synchronous filesystem policy used by the web download manager. Expensive
/// methods are deliberately not actor-isolated; callers run preparation on a
/// private serial queue and reserve the short, atomic commit for the main actor.
final class CRWebImportModel: @unchecked Sendable {
  static let supportedExtensions: Set<String> = ["pdf", "cbz", "zip", "cbr", "rar"]

  private static let hashReadSize = 1_048_576
  private static let defaultMaximumValidationPageBytes: UInt64 = 96 * 1_024 * 1_024
  private static let maximumFilenameLength = 180
  private static let maximumCollectionNameLength = 120
  private static let stagingDirectoryName = ".ComicReader-Web-Staging"
  private static let processStagingPrefix = UUID().uuidString + "-"

  let libraryRootURL: URL
  private let fileManager: FileManager
  private let maximumValidationPageBytes: UInt64

  init(libraryRootURL: URL,
       fileManager: FileManager = .default,
       maximumValidationPageBytes: UInt64 = CRWebImportModel.defaultMaximumValidationPageBytes) throws {
    precondition(maximumValidationPageBytes > 0)
    // Initialize the per-process prefix before this model can inspect staging.
    _ = Self.processStagingPrefix
    guard libraryRootURL.isFileURL else { throw CRWebImportError.invalidLibraryRoot }
    let sourceURL = libraryRootURL.standardizedFileURL
    let sourceValues = try? sourceURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    guard sourceValues?.isDirectory == true, sourceValues?.isSymbolicLink != true else {
      throw CRWebImportError.invalidLibraryRoot
    }
    let resolved = sourceURL.resolvingSymlinksInPath().standardizedFileURL
    guard resolved.path != "/" else { throw CRWebImportError.invalidLibraryRoot }
    self.libraryRootURL = resolved
    self.fileManager = fileManager
    self.maximumValidationPageBytes = maximumValidationPageBytes
  }

  func validateLibraryRoot() throws {
    let values = try? libraryRootURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    guard values?.isDirectory == true,
          values?.isSymbolicLink != true,
          libraryRootURL.resolvingSymlinksInPath().standardizedFileURL == libraryRootURL else {
      throw CRWebImportError.invalidLibraryRoot
    }
  }

  func availableCollections() throws -> [String] {
    try validateLibraryRoot()
    let urls: [URL]
    do {
      urls = try fileManager.contentsOfDirectory(at: libraryRootURL,
                                                includingPropertiesForKeys: [.isDirectoryKey,
                                                                             .isSymbolicLinkKey,
                                                                             .isHiddenKey],
                                                options: [.skipsSubdirectoryDescendants])
    } catch {
      throw CRWebImportError.invalidLibraryRoot
    }
    return urls.compactMap { url in
      let name = url.lastPathComponent
      guard (try? validatedCollectionName(name)) == name,
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey,
                                                            .isSymbolicLinkKey,
                                                            .isHiddenKey]),
            values.isDirectory == true,
            values.isSymbolicLink != true,
            values.isHidden != true,
            isDirectChild(url, of: libraryRootURL),
            url.resolvingSymlinksInPath().standardizedFileURL == url.standardizedFileURL else {
        return nil
      }
      return name
    }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
  }

  @discardableResult
  func createCollection(named proposedName: String) throws -> String {
    try validateLibraryRoot()
    let name = try validatedCollectionName(proposedName)
    let existingNames = (try? fileManager.contentsOfDirectory(atPath: libraryRootURL.path)) ?? []
    if existingNames.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
      throw CRWebImportError.collectionAlreadyExists
    }
    let destination = libraryRootURL.appendingPathComponent(name, isDirectory: true)
    guard isDirectChild(destination, of: libraryRootURL) else {
      throw CRWebImportError.invalidCollection
    }
    if fileManager.fileExists(atPath: destination.path) {
      throw CRWebImportError.collectionAlreadyExists
    }
    do {
      try fileManager.createDirectory(at: destination,
                                      withIntermediateDirectories: false,
                                      attributes: nil)
    } catch {
      throw CRWebImportError.fileOperationFailed
    }
    do {
      _ = try collectionURL(named: name)
      return name
    } catch let error as CRWebImportError {
      try? fileManager.removeItem(at: destination)
      throw error
    } catch {
      try? fileManager.removeItem(at: destination)
      throw CRWebImportError.fileOperationFailed
    }
  }

  func validatedCollectionName(_ proposedName: String) throws -> String {
    let normalized = proposedName.precomposedStringWithCanonicalMapping
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let forbiddenScalars = normalized.unicodeScalars.contains {
      CharacterSet.controlCharacters.contains($0) ||
        CharacterSet.illegalCharacters.contains($0) ||
        Self.isDirectionalFormattingScalar($0)
    }
    guard !normalized.isEmpty,
          normalized.count <= Self.maximumCollectionNameLength,
          normalized.utf8.count <= 240,
          !normalized.hasPrefix("."),
          normalized != ".",
          normalized != "..",
          normalized.caseInsensitiveCompare("Inbox") != .orderedSame,
          !normalized.contains("/"),
          !normalized.contains("\\"),
          !normalized.contains(":"),
          !forbiddenScalars else {
      throw CRWebImportError.invalidCollection
    }
    return normalized
  }

  func makeStagingSession() throws -> URL {
    try validateLibraryRoot()
    let baseURL = libraryRootURL.appendingPathComponent(Self.stagingDirectoryName, isDirectory: true)
    do {
      if !fileManager.fileExists(atPath: baseURL.path) {
        try fileManager.createDirectory(at: baseURL,
                                        withIntermediateDirectories: false,
                                        attributes: nil)
      }
      let values = try baseURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
      guard values.isDirectory == true,
            values.isSymbolicLink != true,
            isDirectChild(baseURL, of: libraryRootURL),
            baseURL.resolvingSymlinksInPath().standardizedFileURL == baseURL.standardizedFileURL else {
        throw CRWebImportError.invalidLibraryRoot
      }
      var mutableBaseURL = baseURL
      var baseResourceValues = URLResourceValues()
      baseResourceValues.isExcludedFromBackup = true
      try mutableBaseURL.setResourceValues(baseResourceValues)

      // A new process never resumes WKDownload work. Remove sessions owned by
      // earlier process instances, leaving concurrent browser controllers with
      // this process prefix untouched.
      if let children = try? fileManager.contentsOfDirectory(at: baseURL,
                                                              includingPropertiesForKeys: nil,
                                                              options: [.skipsSubdirectoryDescendants]) {
        for child in children where !child.lastPathComponent.hasPrefix(Self.processStagingPrefix) {
          try? fileManager.removeItem(at: child)
        }
      }

      let sessionURL = baseURL.appendingPathComponent(Self.processStagingPrefix + UUID().uuidString,
                                                       isDirectory: true)
      try fileManager.createDirectory(at: sessionURL,
                                      withIntermediateDirectories: false,
                                      attributes: nil)
      var mutableURL = sessionURL
      var resourceValues = URLResourceValues()
      resourceValues.isExcludedFromBackup = true
      do {
        try mutableURL.setResourceValues(resourceValues)
      } catch {
        try? fileManager.removeItem(at: sessionURL)
        throw error
      }
      return sessionURL
    } catch let error as CRWebImportError {
      throw error
    } catch {
      throw CRWebImportError.fileOperationFailed
    }
  }

  func makeStagingItem(in sessionURL: URL, identifier: UUID) throws -> (directory: URL, payload: URL) {
    guard isDirectChild(sessionURL, of: libraryRootURL.appendingPathComponent(Self.stagingDirectoryName,
                                                                               isDirectory: true)),
          sessionURL.resolvingSymlinksInPath().standardizedFileURL == sessionURL.standardizedFileURL else {
      throw CRWebImportError.fileOperationFailed
    }
    let directory = sessionURL.appendingPathComponent(identifier.uuidString, isDirectory: true)
    do {
      if fileManager.fileExists(atPath: directory.path) {
        try fileManager.removeItem(at: directory)
      }
      try fileManager.createDirectory(at: directory,
                                      withIntermediateDirectories: false,
                                      attributes: nil)
      return (directory, directory.appendingPathComponent("payload", isDirectory: false))
    } catch {
      throw CRWebImportError.fileOperationFailed
    }
  }

  func removeStagingItem(_ directory: URL) {
    let baseURL = libraryRootURL.appendingPathComponent(Self.stagingDirectoryName, isDirectory: true)
    guard baseURL.resolvingSymlinksInPath().standardizedFileURL == baseURL.standardizedFileURL,
          isContained(directory, by: baseURL),
          directory.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL ==
            directory.deletingLastPathComponent().standardizedFileURL else { return }
    try? fileManager.removeItem(at: directory)
  }

  func removeStagingSession(_ sessionURL: URL) {
    let baseURL = libraryRootURL.appendingPathComponent(Self.stagingDirectoryName, isDirectory: true)
    guard baseURL.resolvingSymlinksInPath().standardizedFileURL == baseURL.standardizedFileURL,
          isDirectChild(sessionURL, of: baseURL),
          sessionURL.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL ==
            baseURL.standardizedFileURL else { return }
    try? fileManager.removeItem(at: sessionURL)
    if let contents = try? fileManager.contentsOfDirectory(atPath: baseURL.path), contents.isEmpty {
      try? fileManager.removeItem(at: baseURL)
    }
  }

  func previewFilename(_ suggestedFilename: String) -> String {
    let component = Self.untrustedLastPathComponent(suggestedFilename)
    let pathExtension = (component as NSString).pathExtension.lowercased()
    let preferredExtension = Self.supportedExtensions.contains(pathExtension) ? pathExtension : nil
    return Self.safeFilenameBase(component, strippingExtension: !pathExtension.isEmpty) +
      (preferredExtension.map { ".\($0)" } ?? "")
  }

  func prepareImport(stagedURL: URL,
                     suggestedFilename: String,
                     mimeType: String?,
                     destinationCollection: String?,
                     shouldContinue: () -> Bool = { true }) throws -> CRWebPreparedImport {
    guard shouldContinue() else { throw CRWebImportError.cancelled }
    try validateLibraryRoot()
    if let destinationCollection { _ = try collectionURL(named: destinationCollection) }

    let values = try? stagedURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
    guard values?.isRegularFile == true,
          values?.isSymbolicLink != true,
          (values?.fileSize ?? 0) > 0 else {
      throw CRWebImportError.invalidDownload
    }
    guard shouldContinue() else { throw CRWebImportError.cancelled }

    let header: Data
    do {
      let handle = try FileHandle(forReadingFrom: stagedURL)
      defer { try? handle.close() }
      header = try handle.read(upToCount: 4_096) ?? Data()
    } catch {
      throw CRWebImportError.invalidDownload
    }
    let normalizedMIMEType = mimeType?.split(separator: ";", maxSplits: 1).first?
      .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if Self.looksLikeHTML(header) || normalizedMIMEType == "text/html" ||
        normalizedMIMEType == "application/xhtml+xml" {
      throw CRWebImportError.contentTypeMismatch
    }
    guard let format = Self.detectedFormat(header) else {
      throw CRWebImportError.unsupportedFormat
    }
    let filename = try Self.normalizedFilename(suggestedFilename, detectedFormat: format)
    let validatedURL = stagedURL.deletingLastPathComponent()
      .appendingPathComponent("validated.\((filename as NSString).pathExtension)", isDirectory: false)
    do {
      if validatedURL != stagedURL {
        if fileManager.fileExists(atPath: validatedURL.path) { try fileManager.removeItem(at: validatedURL) }
        try fileManager.moveItem(at: stagedURL, to: validatedURL)
      }
    } catch {
      throw CRWebImportError.fileOperationFailed
    }

    guard shouldContinue() else { throw CRWebImportError.cancelled }
    let pageCount: Int
    do {
      let source: CRComicPageSource? = try CRComicPageSource(path: validatedURL.path)
      guard let source, source.pageCount > 0 else { throw CRWebImportError.unreadableComic }
      guard shouldContinue() else { throw CRWebImportError.cancelled }
      // Archive page counts are based on filename extensions. Decode one small
      // thumbnail so an entry named like an image cannot make a corrupt archive
      // look like a readable comic without scanning every page.
      _ = try source.image(atPageIndex: 0,
                           maxDimension: 128,
                           maximumUncompressedBytes: maximumValidationPageBytes)
      guard shouldContinue() else { throw CRWebImportError.cancelled }
      pageCount = source.pageCount
    } catch let error as CRWebImportError {
      throw error
    } catch {
      throw CRWebImportError.unreadableComic
    }

    let fingerprint = try sha256(of: validatedURL, shouldContinue: shouldContinue)
    let snapshot = try fileSnapshot(at: validatedURL)
    let duplicate = try findDuplicate(fileSize: snapshot.size,
                                      fingerprint: fingerprint,
                                      excluding: validatedURL,
                                      shouldContinue: shouldContinue)
    return CRWebPreparedImport(stagedURL: validatedURL,
                               suggestedFilename: filename,
                               destinationCollection: destinationCollection,
                               fingerprint: fingerprint,
                               fileSize: snapshot.size,
                               pageCount: pageCount,
                               fileSnapshot: snapshot,
                               duplicateURL: duplicate?.url,
                               duplicateSnapshot: duplicate?.snapshot)
  }

  func commit(_ prepared: CRWebPreparedImport,
              shouldContinue: () -> Bool = { true }) throws -> CRWebImportCommitResult {
    guard shouldContinue() else { throw CRWebImportError.cancelled }
    try validateLibraryRoot()
    let destinationDirectory = try prepared.destinationCollection.map { try collectionURL(named: $0) } ?? libraryRootURL
    guard try fileSnapshot(at: prepared.stagedURL) == prepared.fileSnapshot else {
      throw CRWebImportError.invalidDownload
    }

    if let duplicateURL = prepared.duplicateURL,
       let duplicateSnapshot = prepared.duplicateSnapshot,
       (try? fileSnapshot(at: duplicateURL)) == duplicateSnapshot,
       isIndexedComicURL(duplicateURL),
       let duplicateValues = try? duplicateURL.resourceValues(forKeys: [.isRegularFileKey,
                                                                         .isSymbolicLinkKey]),
       duplicateValues.isRegularFile == true,
       duplicateValues.isSymbolicLink != true,
       duplicateURL.resolvingSymlinksInPath().standardizedFileURL == duplicateURL.standardizedFileURL {
      guard shouldContinue() else { throw CRWebImportError.cancelled }
      return .duplicate(duplicateURL)
    }

    var occupiedNames = Set(((try? fileManager.contentsOfDirectory(atPath: destinationDirectory.path)) ?? [])
      .map(Self.collisionKey))
    var suffix = 1
    while suffix < 100_000 {
      guard shouldContinue() else { throw CRWebImportError.cancelled }
      let candidate = uniqueCandidate(filename: prepared.suggestedFilename,
                                      in: destinationDirectory,
                                      suffix: suffix)
      guard isDirectChild(candidate, of: destinationDirectory),
            isContained(candidate, by: libraryRootURL),
            destinationDirectory.resolvingSymlinksInPath().standardizedFileURL ==
              destinationDirectory.standardizedFileURL,
            isPhysicallyContained(candidate, by: libraryRootURL) else {
        throw CRWebImportError.invalidCollection
      }
      if occupiedNames.contains(Self.collisionKey(candidate.lastPathComponent)) {
        suffix += 1
        continue
      }
      do {
        // The staging tree and library share a volume, so this is an atomic
        // reveal to the library indexer. moveItem fails rather than replacing.
        try fileManager.moveItem(at: prepared.stagedURL, to: candidate)
        let values = try candidate.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              isDirectChild(candidate, of: destinationDirectory),
              isContained(candidate, by: libraryRootURL),
              isPhysicallyContained(candidate, by: libraryRootURL) else {
          try? fileManager.removeItem(at: candidate)
          throw CRWebImportError.fileOperationFailed
        }
        return .imported(candidate)
      } catch let error as CRWebImportError {
        throw error
      } catch let error as NSError where error.domain == NSCocoaErrorDomain &&
        error.code == NSFileWriteFileExistsError {
        occupiedNames.insert(Self.collisionKey(candidate.lastPathComponent))
        suffix += 1
      } catch {
        throw CRWebImportError.fileOperationFailed
      }
    }
    throw CRWebImportError.fileOperationFailed
  }

  static func normalizedFilename(_ suggestedFilename: String,
                                 detectedFormat: CRWebComicFormat) throws -> String {
    let component = untrustedLastPathComponent(suggestedFilename)
    let suppliedExtension = (component as NSString).pathExtension.lowercased()
    if let claimedFormat = CRWebComicFormat.format(forExtension: suppliedExtension),
       claimedFormat != detectedFormat {
      throw CRWebImportError.contentTypeMismatch
    }
    let outputExtension = detectedFormat.acceptedExtensions.contains(suppliedExtension)
      ? suppliedExtension : detectedFormat.canonicalExtension
    return safeFilenameBase(component, strippingExtension: !suppliedExtension.isEmpty) + "." + outputExtension
  }

  static func detectedFormat(_ header: Data) -> CRWebComicFormat? {
    let bytes = [UInt8](header.prefix(1_024))
    var pdfBytes = bytes
    if pdfBytes.starts(with: [0xEF, 0xBB, 0xBF]) { pdfBytes.removeFirst(3) }
    let trimmed = pdfBytes.drop { byte in
      byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
    }
    if trimmed.starts(with: Array("%PDF-".utf8)) { return .pdf }
    if bytes.starts(with: [0x50, 0x4B, 0x03, 0x04]) ||
        bytes.starts(with: [0x50, 0x4B, 0x05, 0x06]) ||
        bytes.starts(with: [0x50, 0x4B, 0x07, 0x08]) { return .zip }
    if bytes.starts(with: [0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x00]) ||
        bytes.starts(with: [0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x01, 0x00]) { return .rar }
    return nil
  }

  static func looksLikeHTML(_ data: Data) -> Bool {
    var bytes = [UInt8](data.prefix(1_024))
    if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes.removeFirst(3) }
    while let first = bytes.first, first == 0x20 || first == 0x09 || first == 0x0A || first == 0x0D {
      bytes.removeFirst()
    }
    let prefix = String(decoding: bytes.prefix(128), as: UTF8.self).lowercased()
    return prefix.hasPrefix("<!doctype html") ||
      prefix.hasPrefix("<html") ||
      prefix.hasPrefix("<head") ||
      prefix.hasPrefix("<body")
  }

  private func collectionURL(named proposedName: String) throws -> URL {
    let name = try validatedCollectionName(proposedName)
    let url = libraryRootURL.appendingPathComponent(name, isDirectory: true)
    guard isDirectChild(url, of: libraryRootURL),
          let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isHiddenKey]),
          values.isDirectory == true,
          values.isSymbolicLink != true,
          values.isHidden != true,
          url.resolvingSymlinksInPath().standardizedFileURL == url.standardizedFileURL else {
      throw CRWebImportError.invalidCollection
    }
    return url
  }

  private func findDuplicate(fileSize: UInt64,
                             fingerprint: String,
                             excluding stagedURL: URL,
                             shouldContinue: () -> Bool) throws -> (url: URL, snapshot: CRWebFileSnapshot)? {
    for candidate in try indexedComicURLs() {
      guard shouldContinue() else { throw CRWebImportError.cancelled }
      guard candidate != stagedURL,
            let candidateSnapshot = try? fileSnapshot(at: candidate),
            candidateSnapshot.size == fileSize else { continue }
      if try sha256(of: candidate, shouldContinue: shouldContinue) == fingerprint {
        guard let stableSnapshot = try? fileSnapshot(at: candidate),
              stableSnapshot == candidateSnapshot else { continue }
        return (candidate, stableSnapshot)
      }
    }
    return nil
  }

  private func indexedComicURLs() throws -> [URL] {
    let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .isHiddenKey]
    let rootItems: [URL]
    do {
      rootItems = try fileManager.contentsOfDirectory(at: libraryRootURL,
                                                      includingPropertiesForKeys: Array(keys),
                                                      options: [.skipsSubdirectoryDescendants])
    } catch {
      throw CRWebImportError.invalidLibraryRoot
    }
    var result: [URL] = []
    for item in rootItems {
      let values = try? item.resourceValues(forKeys: keys)
      guard values?.isSymbolicLink != true, values?.isHidden != true else { continue }
      if values?.isRegularFile == true, isIndexedComicURL(item) {
        result.append(item)
      } else if values?.isDirectory == true,
                (try? validatedCollectionName(item.lastPathComponent)) == item.lastPathComponent,
                item.resolvingSymlinksInPath().standardizedFileURL == item.standardizedFileURL {
        let children = (try? fileManager.contentsOfDirectory(at: item,
                                                             includingPropertiesForKeys: Array(keys),
                                                             options: [.skipsSubdirectoryDescendants])) ?? []
        for child in children {
          let childValues = try? child.resourceValues(forKeys: keys)
          if childValues?.isRegularFile == true,
             childValues?.isSymbolicLink != true,
             childValues?.isHidden != true,
             isIndexedComicURL(child) {
            result.append(child)
          }
        }
      }
    }
    return result.sorted { $0.path < $1.path }
  }

  private func isIndexedComicURL(_ url: URL) -> Bool {
    guard Self.supportedExtensions.contains(url.pathExtension.lowercased()),
          !url.lastPathComponent.hasPrefix("."),
          isContained(url, by: libraryRootURL) else { return false }
    let relative = String(url.standardizedFileURL.path.dropFirst(libraryRootURL.path.count))
      .split(separator: "/", omittingEmptySubsequences: true)
    return relative.count == 1 || relative.count == 2
  }

  func isSafeImportedURL(_ url: URL) -> Bool {
    guard isIndexedComicURL(url),
          let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
          values.isRegularFile == true,
          values.isSymbolicLink != true,
          isPhysicallyContained(url, by: libraryRootURL) else { return false }
    return true
  }

  private func sha256(of url: URL, shouldContinue: () -> Bool) throws -> String {
    let before = try fileSnapshot(at: url)
    let handle: FileHandle
    do { handle = try FileHandle(forReadingFrom: url) }
    catch { throw CRWebImportError.invalidDownload }
    defer { try? handle.close() }
    var hasher = SHA256()
    do {
      while true {
        guard shouldContinue() else { throw CRWebImportError.cancelled }
        let data = try autoreleasepool { try handle.read(upToCount: Self.hashReadSize) ?? Data() }
        if data.isEmpty { break }
        hasher.update(data: data)
      }
    } catch let error as CRWebImportError {
      throw error
    } catch {
      throw CRWebImportError.invalidDownload
    }
    guard try fileSnapshot(at: url) == before else { throw CRWebImportError.invalidDownload }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }

  private func fileSnapshot(at url: URL) throws -> CRWebFileSnapshot {
    let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
                                                    .contentModificationDateKey])
    guard values?.isRegularFile == true, values?.isSymbolicLink != true else {
      throw CRWebImportError.invalidDownload
    }
    let attributes: [FileAttributeKey: Any]
    do { attributes = try fileManager.attributesOfItem(atPath: url.path) }
    catch { throw CRWebImportError.invalidDownload }
    return CRWebFileSnapshot(size: (attributes[.size] as? NSNumber)?.uint64Value ?? UInt64(values?.fileSize ?? 0),
                             modificationDate: values?.contentModificationDate,
                             systemNumber: (attributes[.systemNumber] as? NSNumber)?.uint64Value,
                             fileNumber: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value)
  }

  private func uniqueCandidate(filename: String, in directory: URL, suffix: Int) -> URL {
    if suffix == 1 { return directory.appendingPathComponent(filename, isDirectory: false) }
    let value = filename as NSString
    let name = value.deletingPathExtension
    let pathExtension = value.pathExtension
    return directory.appendingPathComponent("\(name) (\(suffix)).\(pathExtension)", isDirectory: false)
  }

  private static func collisionKey(_ filename: String) -> String {
    filename.precomposedStringWithCanonicalMapping
      .folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
  }

  private func isDirectChild(_ child: URL, of parent: URL) -> Bool {
    child.standardizedFileURL.deletingLastPathComponent() == parent.standardizedFileURL
  }

  private func isContained(_ child: URL, by parent: URL) -> Bool {
    let childPath = child.standardizedFileURL.path
    let parentPath = parent.standardizedFileURL.path
    return childPath.hasPrefix(parentPath + "/")
  }

  private func isPhysicallyContained(_ child: URL, by parent: URL) -> Bool {
    let resolvedParent = parent.resolvingSymlinksInPath().standardizedFileURL
    guard resolvedParent == parent.standardizedFileURL else { return false }
    return isContained(child.resolvingSymlinksInPath().standardizedFileURL, by: resolvedParent)
  }

  private static func untrustedLastPathComponent(_ value: String) -> String {
    let slashesNormalized = value.replacingOccurrences(of: "\\", with: "/")
    return slashesNormalized.split(separator: "/", omittingEmptySubsequences: true).last.map(String.init) ?? "Download"
  }

  private static func safeFilenameBase(_ component: String, strippingExtension: Bool) -> String {
    let initial: String
    if strippingExtension {
      initial = (component as NSString).deletingPathExtension
    } else {
      initial = component
    }
    let filteredScalars = initial.precomposedStringWithCanonicalMapping.unicodeScalars.map { scalar -> Character in
      if CharacterSet.controlCharacters.contains(scalar) ||
          CharacterSet.illegalCharacters.contains(scalar) ||
          isDirectionalFormattingScalar(scalar) ||
          scalar == "/" || scalar == "\\" || scalar == ":" {
        return " "
      }
      return Character(String(scalar))
    }
    var result = String(filteredScalars)
      .split(whereSeparator: { $0.isWhitespace })
      .joined(separator: " ")
      .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
    while result.hasPrefix(".") { result.removeFirst() }
    if result.isEmpty { result = "Download" }
    if result.count > maximumFilenameLength {
      result = String(result.prefix(maximumFilenameLength))
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    while result.utf8.count > 220, !result.isEmpty { result.removeLast() }
    result = result.trimmingCharacters(in: .whitespacesAndNewlines)
    return result.isEmpty ? "Download" : result
  }

  private static func isDirectionalFormattingScalar(_ scalar: UnicodeScalar) -> Bool {
    switch scalar.value {
    case 0x061C, 0x200E, 0x200F, 0x202A...0x202E, 0x2066...0x2069:
      return true
    default:
      return false
    }
  }
}
