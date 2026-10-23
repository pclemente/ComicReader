import Foundation

@objc(CRBrowserSiteErrorCode)
public enum CRBrowserSiteErrorCode: Int {
  case invalidURL = 1
  case invalidName
  case siteNotFound
  case invalidArchive
  case unsupportedArchiveVersion
  case storageUnavailable
}

@objc(CRBrowserSite)
public final class CRBrowserSite: NSObject {
  @objc public let identifier: String
  @objc public let name: String
  @objc public let url: URL
  @objc public let createdAt: Date
  @objc public let modifiedAt: Date

  fileprivate init(record: CRBrowserSiteRecord) {
    identifier = record.identifier
    name = record.name
    url = record.url
    createdAt = record.createdAt
    modifiedAt = record.modifiedAt
    super.init()
  }
}

extension CRBrowserSite: @unchecked Sendable {}

private struct CRBrowserSiteRecord: Codable, Equatable {
  let identifier: String
  var name: String
  var url: URL
  let createdAt: Date
  var modifiedAt: Date
}

private struct CRBrowserSiteArchive: Codable {
  var version: Int
  var sites: [CRBrowserSiteRecord]
  var lastVisitedURL: URL?

  static let currentVersion = 1
  static var empty: CRBrowserSiteArchive {
    CRBrowserSiteArchive(version: currentVersion, sites: [], lastVisitedURL: nil)
  }
}

/// Stores the browser's deliberately small amount of user-approved state.
///
/// The store never records browsing history, cookies, credentials, download
/// requests, or URL query/fragment values. WebKit owns website data in its
/// default data store. A store initialized for private browsing is memory-only.
@objc(CRBrowserSiteStore)
public final class CRBrowserSiteStore: NSObject {
  @objc public static let sharedStore = CRBrowserSiteStore()
  @objc public static let errorDomain = "com.pabloclementeperez.ComicReader.BrowserSites"

  private static let maximumNameLength = 80
  private static let maximumURLLength = 4_096

  private let storageURL: URL?
  private let fileManager: FileManager
  private let lock = NSLock()
  private var transientArchive = CRBrowserSiteArchive.empty

  @objc public let isPersistent: Bool

  @objc public override convenience init() {
    let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory,
                                                       in: .userDomainMask).first!
    let directory = applicationSupport.appendingPathComponent("ComicReader", isDirectory: true)
    self.init(storageURL: directory.appendingPathComponent("BrowserSites-v1.json"),
              fileManager: .default)
  }

  @objc(initWithPrivateBrowsing:)
  public convenience init(privateBrowsing: Bool) {
    if privateBrowsing {
      self.init(storageURL: nil, fileManager: .default)
    } else {
      self.init()
    }
  }

  init(storageURL: URL?, fileManager: FileManager = .default) {
    self.storageURL = storageURL
    self.fileManager = fileManager
    isPersistent = storageURL != nil
    super.init()
  }

  /// Converts user-entered text into an HTTP(S) page URL. A missing scheme is
  /// interpreted as HTTPS. This method deliberately preserves query and
  /// fragment values for navigation; persistence methods strip them.
  @objc(normalizedWebsiteURLFromString:error:)
  public class func normalizedWebsiteURL(from input: String) throws -> URL {
    let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty,
          trimmed.count <= maximumURLLength,
          trimmed.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
      throw failure(.invalidURL, "Enter a valid website address.")
    }

    let candidate: String
    if let schemeRange = trimmed.range(of: "://"), !schemeRange.isEmpty {
      candidate = trimmed
    } else {
      candidate = "https://\(trimmed)"
    }

    guard var components = URLComponents(string: candidate),
          let scheme = components.scheme?.lowercased(),
          scheme == "https" || scheme == "http",
          let host = components.host, !host.isEmpty,
          components.user == nil, components.password == nil else {
      throw failure(.invalidURL,
                    "Website addresses must use HTTP or HTTPS and cannot contain sign-in details.")
    }

    components.scheme = scheme
    components.host = host.lowercased()
    if (scheme == "https" && components.port == 443) ||
       (scheme == "http" && components.port == 80) {
      components.port = nil
    }
    guard let url = components.url, url.host != nil else {
      throw failure(.invalidURL, "Enter a valid website address.")
    }
    return url
  }

  /// Returns a canonical URL suitable for local persistence. Query and
  /// fragment values are always removed, including from the single last-page
  /// value, so transient tokens never land in the archive.
  @objc(persistableWebsiteURL:error:)
  public class func persistableWebsiteURL(_ url: URL) throws -> URL {
    let normalized = try normalizedWebsiteURL(from: url.absoluteString)
    guard var components = URLComponents(url: normalized, resolvingAgainstBaseURL: false) else {
      throw failure(.invalidURL, "Enter a valid website address.")
    }
    components.query = nil
    components.fragment = nil
    guard let result = components.url else {
      throw failure(.invalidURL, "Enter a valid website address.")
    }
    return result
  }

  /// Returns only a URL origin for automatic session restoration. Unlike an
  /// explicitly saved shortcut, an automatically remembered page must not
  /// retain a path because sites sometimes place transient sign-in material in
  /// path components.
  @objc(persistableWebsiteOriginURL:error:)
  public class func persistableWebsiteOriginURL(_ url: URL) throws -> URL {
    let normalized = try normalizedWebsiteURL(from: url.absoluteString)
    guard var components = URLComponents(url: normalized, resolvingAgainstBaseURL: false) else {
      throw failure(.invalidURL, "Enter a valid website address.")
    }
    components.path = "/"
    components.query = nil
    components.fragment = nil
    guard let result = components.url else {
      throw failure(.invalidURL, "Enter a valid website address.")
    }
    return result
  }

  @objc(loadSitesWithError:)
  public func sites() throws -> [CRBrowserSite] {
    try withLock {
      try loadArchive().sites
        .sorted {
          let comparison = $0.name.localizedCaseInsensitiveCompare($1.name)
          return comparison == .orderedSame ? $0.identifier < $1.identifier : comparison == .orderedAscending
        }
        .map(CRBrowserSite.init(record:))
    }
  }

  @discardableResult
  @objc(saveSiteWithName:url:error:)
  public func saveSite(name: String, url: URL) throws -> CRBrowserSite {
    let validatedName = try Self.validatedName(name)
    let persistedURL = try Self.persistableWebsiteURL(url)

    return try withLock {
      var archive = try loadArchive()
      let now = Date()
      if let index = archive.sites.firstIndex(where: { $0.url == persistedURL }) {
        archive.sites[index].name = validatedName
        archive.sites[index].modifiedAt = now
        try saveArchive(archive)
        return CRBrowserSite(record: archive.sites[index])
      }

      let record = CRBrowserSiteRecord(identifier: UUID().uuidString.lowercased(),
                                       name: validatedName,
                                       url: persistedURL,
                                       createdAt: now,
                                       modifiedAt: now)
      archive.sites.append(record)
      try saveArchive(archive)
      return CRBrowserSite(record: record)
    }
  }

  @discardableResult
  @objc(renameSiteWithIdentifier:name:error:)
  public func renameSite(identifier: String, name: String) throws -> CRBrowserSite {
    let validatedName = try Self.validatedName(name)
    return try withLock {
      var archive = try loadArchive()
      guard let index = archive.sites.firstIndex(where: { $0.identifier == identifier }) else {
        throw Self.failure(.siteNotFound, "That saved website no longer exists.")
      }
      archive.sites[index].name = validatedName
      archive.sites[index].modifiedAt = Date()
      try saveArchive(archive)
      return CRBrowserSite(record: archive.sites[index])
    }
  }

  @objc(deleteSiteWithIdentifier:error:)
  public func deleteSite(identifier: String) throws {
    try withLock {
      var archive = try loadArchive()
      guard let index = archive.sites.firstIndex(where: { $0.identifier == identifier }) else {
        throw Self.failure(.siteNotFound, "That saved website no longer exists.")
      }
      archive.sites.remove(at: index)
      try saveArchive(archive)
    }
  }

  /// Removes named shortcuts without altering the normal session's last page.
  @objc(deleteAllSitesWithError:)
  public func deleteAllSites() throws {
    try withLock {
      var archive = try loadArchive()
      archive.sites.removeAll()
      try saveArchive(archive)
    }
  }

  public func lastVisitedURL() throws -> URL? {
    try withLock { try loadArchive().lastVisitedURL }
  }

  @objc(recordLastVisitedURL:error:)
  public func recordLastVisitedURL(_ url: URL?) throws {
    let persistedURL = try url.map(Self.persistableWebsiteOriginURL)
    try withLock {
      var archive = try loadArchive()
      archive.lastVisitedURL = persistedURL
      try saveArchive(archive)
    }
  }

  private class func validatedName(_ name: String) throws -> String {
    let words = name
      .split(whereSeparator: { $0.isWhitespace })
      .map(String.init)
    let normalized = words.joined(separator: " ")
    guard !normalized.isEmpty, normalized.count <= maximumNameLength else {
      throw failure(.invalidName,
                    "Website names must contain 1 to \(maximumNameLength) characters.")
    }
    return normalized
  }

  private func loadArchive() throws -> CRBrowserSiteArchive {
    guard let storageURL else {
      return transientArchive
    }
    guard fileManager.fileExists(atPath: storageURL.path) else {
      return .empty
    }

    let data: Data
    do {
      data = try Data(contentsOf: storageURL, options: .mappedIfSafe)
    } catch {
      throw Self.failure(.storageUnavailable,
                         "Saved websites could not be read.",
                         underlying: error)
    }

    let archive: CRBrowserSiteArchive
    do {
      archive = try JSONDecoder().decode(CRBrowserSiteArchive.self, from: data)
    } catch {
      throw Self.failure(.invalidArchive,
                         "Saved website data is damaged and was left unchanged.",
                         underlying: error)
    }
    guard archive.version == CRBrowserSiteArchive.currentVersion else {
      throw Self.failure(.unsupportedArchiveVersion,
                         "This saved website data was created by a newer version of ComicReader.")
    }
    return archive
  }

  private func saveArchive(_ archive: CRBrowserSiteArchive) throws {
    guard let storageURL else {
      transientArchive = archive
      return
    }

    do {
      let parent = storageURL.deletingLastPathComponent()
      try fileManager.createDirectory(at: parent,
                                      withIntermediateDirectories: true,
                                      attributes: nil)
      let data = try JSONEncoder().encode(archive)
      try data.write(to: storageURL, options: .atomic)
    } catch {
      throw Self.failure(.storageUnavailable,
                         "Saved websites could not be updated.",
                         underlying: error)
    }
  }

  private func withLock<T>(_ operation: () throws -> T) rethrows -> T {
    lock.lock()
    defer { lock.unlock() }
    return try operation()
  }

  private class func failure(_ code: CRBrowserSiteErrorCode,
                             _ description: String,
                             underlying: Error? = nil) -> NSError {
    var userInfo: [String: Any] = [NSLocalizedDescriptionKey: description]
    if let underlying {
      userInfo[NSUnderlyingErrorKey] = underlying
    }
    return NSError(domain: errorDomain, code: code.rawValue, userInfo: userInfo)
  }
}
