import Foundation

public enum CRSavedQuoteErrorCode: Int {
  case invalidFingerprint = 1
  case invalidComicName
  case invalidPage
  case invalidText
  case invalidIdentifier
  case quoteNotFound
  case invalidArchive
  case unsupportedArchiveVersion
  case storageUnavailable
}

public struct CRSavedQuote: Codable, Equatable, Identifiable, Sendable {
  public let id: String
  public let comicName: String
  public let pageIndex: Int
  public let text: String
  public let createdAt: Date
  public let modifiedAt: Date
}

private struct CRSavedQuoteArchive: Codable {
  var version: Int
  var recordsByFingerprint: [String: [CRSavedQuote]]

  static let currentVersion = 1
  static var empty: CRSavedQuoteArchive {
    CRSavedQuoteArchive(version: currentVersion, recordsByFingerprint: [:])
  }
}

public final class CRSavedQuoteStore {
  public static let sharedStore = CRSavedQuoteStore()
  public static let errorDomain = "com.pabloclementeperez.ComicReader.SavedQuotes"
  public static let maximumFingerprintLength = 256
  public static let maximumComicNameLength = 512
  public static let maximumTextLength = 10_000

  private static let maximumIdentifierLength = 64

  private let storageURL: URL
  private let fileManager: FileManager
  private let now: () -> Date
  private let lock = NSLock()

  public convenience init() {
    let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory,
                                                       in: .userDomainMask).first!
    let directory = applicationSupport.appendingPathComponent("ComicReader", isDirectory: true)
    self.init(storageURL: directory.appendingPathComponent("SavedQuotes-v1.json"),
              fileManager: .default,
              now: Date.init)
  }

  init(storageURL: URL,
       fileManager: FileManager = .default,
       now: @escaping () -> Date = Date.init) {
    self.storageURL = storageURL
    self.fileManager = fileManager
    self.now = now
  }

  public func records(for fingerprint: String) throws -> [CRSavedQuote] {
    let key = try validatedFingerprint(fingerprint)
    return try withLock {
      let archive = try loadArchive()
      return sortedRecords(archive.recordsByFingerprint[key] ?? [])
    }
  }

  @discardableResult
  public func add(fingerprint: String,
                  comicName: String,
                  pageIndex: Int,
                  text: String) throws -> CRSavedQuote {
    let key = try validatedFingerprint(fingerprint)
    let normalizedComicName = try validatedComicName(comicName)
    let normalizedText = try validatedText(text)
    guard pageIndex >= 0 else {
      throw failure(.invalidPage, "Choose a valid comic page for this quote.")
    }

    return try withLock {
      var archive = try loadArchive()
      let timestamp = currentTimestamp()
      let quote = CRSavedQuote(id: UUID().uuidString.lowercased(),
                               comicName: normalizedComicName,
                               pageIndex: pageIndex,
                               text: normalizedText,
                               createdAt: timestamp,
                               modifiedAt: timestamp)
      archive.recordsByFingerprint[key, default: []].append(quote)
      try saveArchive(archive)
      return quote
    }
  }

  public func update(fingerprint: String, id: String, text: String) throws {
    let key = try validatedFingerprint(fingerprint)
    let normalizedIdentifier = try validatedIdentifier(id)
    let normalizedText = try validatedText(text)

    try withLock {
      var archive = try loadArchive()
      guard var records = archive.recordsByFingerprint[key],
            let index = records.firstIndex(where: { $0.id == normalizedIdentifier }) else {
        throw failure(.quoteNotFound, "That saved quote no longer exists.")
      }

      let current = records[index]
      records[index] = CRSavedQuote(id: current.id,
                                    comicName: current.comicName,
                                    pageIndex: current.pageIndex,
                                    text: normalizedText,
                                    createdAt: current.createdAt,
                                    modifiedAt: max(current.createdAt, currentTimestamp()))
      archive.recordsByFingerprint[key] = records
      try saveArchive(archive)
    }
  }

  public func remove(fingerprint: String, id: String) throws {
    let key = try validatedFingerprint(fingerprint)
    let normalizedIdentifier = try validatedIdentifier(id)

    try withLock {
      var archive = try loadArchive()
      guard var records = archive.recordsByFingerprint[key],
            let index = records.firstIndex(where: { $0.id == normalizedIdentifier }) else {
        throw failure(.quoteNotFound, "That saved quote no longer exists.")
      }

      records.remove(at: index)
      if records.isEmpty {
        archive.recordsByFingerprint.removeValue(forKey: key)
      } else {
        archive.recordsByFingerprint[key] = records
      }
      try saveArchive(archive)
    }
  }

  private func validatedFingerprint(_ fingerprint: String) throws -> String {
    let normalized = fingerprint.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty,
          normalized.count <= Self.maximumFingerprintLength,
          normalized.rangeOfCharacter(from: .controlCharacters) == nil else {
      throw failure(.invalidFingerprint, "This comic does not have a valid fingerprint.")
    }
    return normalized
  }

  private func validatedComicName(_ comicName: String) throws -> String {
    let normalized = comicName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty, normalized.count <= Self.maximumComicNameLength else {
      throw failure(.invalidComicName,
                    "Enter a comic name between 1 and \(Self.maximumComicNameLength) characters.")
    }
    return normalized
  }

  private func validatedText(_ text: String) throws -> String {
    let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty, normalized.count <= Self.maximumTextLength else {
      throw failure(.invalidText,
                    "Enter quote text between 1 and \(Self.maximumTextLength) characters.")
    }
    return normalized
  }

  private func validatedIdentifier(_ identifier: String) throws -> String {
    let normalized = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty,
          normalized.count <= Self.maximumIdentifierLength,
          normalized.rangeOfCharacter(from: .controlCharacters) == nil else {
      throw failure(.invalidIdentifier, "That saved quote has an invalid identifier.")
    }
    return normalized
  }

  private func loadArchive() throws -> CRSavedQuoteArchive {
    guard fileManager.fileExists(atPath: storageURL.path) else {
      return .empty
    }

    let data: Data
    do {
      data = try Data(contentsOf: storageURL, options: .mappedIfSafe)
    } catch {
      throw failure(.storageUnavailable,
                    "Your saved quotes could not be read.",
                    underlying: error)
    }

    let archive: CRSavedQuoteArchive
    do {
      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = .iso8601
      archive = try decoder.decode(CRSavedQuoteArchive.self, from: data)
    } catch {
      throw failure(.invalidArchive,
                    "Your saved quotes could not be read. The existing file was left unchanged.",
                    underlying: error)
    }

    guard archive.version == CRSavedQuoteArchive.currentVersion else {
      throw failure(.unsupportedArchiveVersion,
                    "These saved quotes were created by an unsupported app version.")
    }
    guard isValidArchive(archive) else {
      throw failure(.invalidArchive,
                    "Your saved quotes contain invalid data. The existing file was left unchanged.")
    }
    return archive
  }

  private func saveArchive(_ archive: CRSavedQuoteArchive) throws {
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
                    "Your saved quote changes could not be saved.",
                    underlying: error)
    }
  }

  private func isValidArchive(_ archive: CRSavedQuoteArchive) -> Bool {
    var identifiers = Set<String>()
    for (fingerprint, records) in archive.recordsByFingerprint {
      guard isStoredFingerprintValid(fingerprint) else {
        return false
      }
      for record in records {
        guard isStoredIdentifierValid(record.id),
              identifiers.insert(record.id).inserted,
              isStoredComicNameValid(record.comicName),
              record.pageIndex >= 0,
              isStoredTextValid(record.text),
              record.modifiedAt >= record.createdAt else {
          return false
        }
      }
    }
    return true
  }

  private func isStoredFingerprintValid(_ fingerprint: String) -> Bool {
    !fingerprint.isEmpty &&
      fingerprint.count <= Self.maximumFingerprintLength &&
      fingerprint == fingerprint.trimmingCharacters(in: .whitespacesAndNewlines) &&
      fingerprint.rangeOfCharacter(from: .controlCharacters) == nil
  }

  private func isStoredIdentifierValid(_ identifier: String) -> Bool {
    !identifier.isEmpty &&
      identifier.count <= Self.maximumIdentifierLength &&
      identifier == identifier.trimmingCharacters(in: .whitespacesAndNewlines) &&
      identifier.rangeOfCharacter(from: .controlCharacters) == nil
  }

  private func isStoredComicNameValid(_ comicName: String) -> Bool {
    !comicName.isEmpty &&
      comicName.count <= Self.maximumComicNameLength &&
      comicName == comicName.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func isStoredTextValid(_ text: String) -> Bool {
    !text.isEmpty &&
      text.count <= Self.maximumTextLength &&
      text == text.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func sortedRecords(_ records: [CRSavedQuote]) -> [CRSavedQuote] {
    records.sorted {
      if $0.pageIndex != $1.pageIndex {
        return $0.pageIndex < $1.pageIndex
      }
      if $0.createdAt != $1.createdAt {
        return $0.createdAt < $1.createdAt
      }
      return $0.id < $1.id
    }
  }

  private func currentTimestamp() -> Date {
    // JSONEncoder's ISO-8601 strategy stores whole seconds. Normalize before
    // returning a record so the value remains identical after persistence.
    Date(timeIntervalSince1970: now().timeIntervalSince1970.rounded(.down))
  }

  private func withLock<T>(_ body: () throws -> T) rethrows -> T {
    lock.lock()
    defer { lock.unlock() }
    return try body()
  }

  private func failure(_ code: CRSavedQuoteErrorCode,
                       _ description: String,
                       underlying: Error? = nil) -> NSError {
    var userInfo: [String: Any] = [NSLocalizedDescriptionKey: description]
    if let underlying {
      userInfo[NSUnderlyingErrorKey] = underlying
    }
    return NSError(domain: Self.errorDomain, code: code.rawValue, userInfo: userInfo)
  }
}

extension CRSavedQuoteStore: @unchecked Sendable {}
