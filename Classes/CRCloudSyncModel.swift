//
//  CRCloudSyncModel.swift
//  ComicFlow
//
//  Pure data and path rules shared by CRCloudSyncManager and its host tests.
//

import Foundation

struct CRCloudReadingStateRecord: Codable, Equatable {
  let schemaVersion: Int
  let contentIdentifier: String
  let legacyStatus: Int
  let currentPage: Int
  let pageCount: Int
  let modifiedAt: TimeInterval
  let mutationIdentifier: String
  let deviceIdentifier: String

  init(contentIdentifier: String,
       legacyStatus: Int,
       currentPage: Int,
       pageCount: Int,
       modifiedAt: TimeInterval,
       mutationIdentifier: String,
       deviceIdentifier: String) {
    self.schemaVersion = 1
    self.contentIdentifier = contentIdentifier
    self.legacyStatus = legacyStatus
    self.pageCount = max(0, pageCount)
    if pageCount > 0 {
      self.currentPage = min(max(0, currentPage), pageCount - 1)
    } else {
      self.currentPage = max(0, currentPage)
    }
    self.modifiedAt = modifiedAt
    self.mutationIdentifier = mutationIdentifier
    self.deviceIdentifier = deviceIdentifier
  }

  /// A total order is required because two devices can write at the same time.
  /// Page number is intentionally absent: a later rewind or mark-new action wins.
  static func preferred(_ lhs: CRCloudReadingStateRecord,
                        _ rhs: CRCloudReadingStateRecord) -> CRCloudReadingStateRecord {
    if lhs.modifiedAt != rhs.modifiedAt {
      return lhs.modifiedAt > rhs.modifiedAt ? lhs : rhs
    }
    if lhs.mutationIdentifier != rhs.mutationIdentifier {
      return lhs.mutationIdentifier > rhs.mutationIdentifier ? lhs : rhs
    }
    if lhs.deviceIdentifier != rhs.deviceIdentifier {
      return lhs.deviceIdentifier > rhs.deviceIdentifier ? lhs : rhs
    }
    // This final comparison only resolves malformed duplicate mutation IDs.
    let lhsTuple = "\(lhs.legacyStatus):\(lhs.currentPage):\(lhs.pageCount)"
    let rhsTuple = "\(rhs.legacyStatus):\(rhs.currentPage):\(rhs.pageCount)"
    return lhsTuple >= rhsTuple ? lhs : rhs
  }

  func hasSameReaderValue(as other: CRCloudReadingStateRecord) -> Bool {
    legacyStatus == other.legacyStatus &&
      currentPage == other.currentPage &&
      pageCount == other.pageCount
  }
}

struct CRCloudComicManifest: Codable, Equatable {
  let schemaVersion: Int
  let contentIdentifier: String
  let contentSHA256: String
  let cloudFileName: String
  let preferredRelativePath: String
  let fileSize: Int64
  let uploadedAt: TimeInterval
  let uploaderDeviceIdentifier: String

  init(contentIdentifier: String,
       contentSHA256: String,
       cloudFileName: String,
       preferredRelativePath: String,
       fileSize: Int64,
       uploadedAt: TimeInterval,
       uploaderDeviceIdentifier: String) {
    self.schemaVersion = 1
    self.contentIdentifier = contentIdentifier
    self.contentSHA256 = contentSHA256
    self.cloudFileName = cloudFileName
    self.preferredRelativePath = preferredRelativePath
    self.fileSize = fileSize
    self.uploadedAt = uploadedAt
    self.uploaderDeviceIdentifier = uploaderDeviceIdentifier
  }
}

struct CRCloudDeletionRecord: Codable, Equatable {
  let schemaVersion: Int
  let contentIdentifier: String
  let deletedAt: TimeInterval
  let deviceIdentifier: String

  init(contentIdentifier: String, deletedAt: TimeInterval, deviceIdentifier: String) {
    self.schemaVersion = 1
    self.contentIdentifier = contentIdentifier
    self.deletedAt = deletedAt
    self.deviceIdentifier = deviceIdentifier
  }
}

struct CRCloudCachedFingerprint: Codable, Equatable {
  let relativePath: String
  let fileSize: Int64
  let modificationTime: TimeInterval
  let creationTime: TimeInterval?
  let fileResourceIdentifier: String?
  let contentIdentifier: String
  let contentSHA256: String
}

struct CRCloudStoredReadingState: Codable, Equatable {
  var record: CRCloudReadingStateRecord
  var uploadedMutationIdentifier: String?
  var awaitingAdapterApply: Bool
}

struct CRCloudDeviceState: Codable, Equatable {
  var schemaVersion = 1
  var deviceIdentifier: String
  var accountFingerprint: String
  var fingerprintsByRelativePath: [String: CRCloudCachedFingerprint] = [:]
  var readingStatesByContentIdentifier: [String: CRCloudStoredReadingState] = [:]
  var locallySuppressedContentIdentifiers: [String: TimeInterval] = [:]
  var lastSyncAt: TimeInterval?
}

enum CRCloudSyncPathPolicy {
  private static let supportedExtensions = Set(["pdf", "zip", "cbz", "rar", "cbr"])

  static func normalizedContentIdentifier(_ value: String) -> String? {
    guard !value.isEmpty, value.utf8.count <= 128 else { return nil }
    let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
    guard value.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
    return value
  }

  static func normalizedRelativePath(_ value: String) -> String? {
    guard !value.isEmpty, !value.hasPrefix("/"), value.utf8.count <= 1_024 else { return nil }
    let components = NSString(string: value).pathComponents
    guard !components.isEmpty,
          components.count <= 2,
          components.allSatisfy({ component in
            !component.isEmpty && component != "." && component != ".." &&
              !component.hasPrefix(".") && component.rangeOfCharacter(from: .controlCharacters) == nil
          }),
          let fileName = components.last,
          supportedExtensions.contains((fileName as NSString).pathExtension.lowercased()) else {
      return nil
    }
    if components.count == 2 && components[0].caseInsensitiveCompare("Inbox") == .orderedSame {
      return nil
    }
    return NSString.path(withComponents: components).precomposedStringWithCanonicalMapping
  }

  static func contains(_ childURL: URL, within rootURL: URL) -> Bool {
    let root = rootURL.standardizedFileURL.resolvingSymlinksInPath().path
    let child = childURL.standardizedFileURL.resolvingSymlinksInPath().path
    return child == root || child.hasPrefix(root.hasSuffix("/") ? root : root + "/")
  }

  static func validatedLocalURL(localPath: String,
                                relativePath: String?,
                                libraryRootURL: URL) -> (url: URL, relativePath: String)? {
    let localURL = URL(fileURLWithPath: localPath).standardizedFileURL
    guard localURL.path.hasPrefix("/"), contains(localURL, within: libraryRootURL) else { return nil }

    let relative: String
    if let supplied = relativePath, !supplied.isEmpty {
      guard let normalized = normalizedRelativePath(supplied) else { return nil }
      relative = normalized
    } else {
      let rootPath = libraryRootURL.standardizedFileURL.path
      guard localURL.path.hasPrefix(rootPath + "/") else { return nil }
      let derived = String(localURL.path.dropFirst(rootPath.count + 1))
      guard let normalized = normalizedRelativePath(derived) else { return nil }
      relative = normalized
    }

    let expectedURL = relative.split(separator: "/").reduce(libraryRootURL.standardizedFileURL) {
      $0.appendingPathComponent(String($1), isDirectory: false)
    }
    guard expectedURL.standardizedFileURL.path == localURL.standardizedFileURL.path,
          contains(expectedURL, within: libraryRootURL) else { return nil }
    return (localURL, relative)
  }

  static func safeImportRelativePath(_ preferredPath: String, fallbackFileName: String) -> String {
    let rawComponents = NSString(string: preferredPath).pathComponents.filter {
      !$0.isEmpty && $0 != "." && $0 != ".." && $0 != "/"
    }
    let rawFileName = rawComponents.last ?? fallbackFileName
    let fileName = safeComponent(rawFileName, fallback: fallbackFileName, preserveExtension: true)
    if rawComponents.count > 1 {
      let collectionSource = rawComponents.dropLast().joined(separator: " - ")
      let collection = safeComponent(collectionSource, fallback: "Synced Comics", preserveExtension: false)
      if collection.caseInsensitiveCompare("Inbox") != .orderedSame {
        return collection + "/" + fileName
      }
    }
    return fileName
  }

  static func safeCloudFileName(_ value: String) -> String {
    safeComponent(value, fallback: "Comic.pdf", preserveExtension: true)
  }

  static func uniqueImportURL(relativePath: String,
                              libraryRootURL: URL,
                              reservedPaths: Set<String> = []) -> URL {
    let relative = safeImportRelativePath(relativePath,
                                          fallbackFileName: (relativePath as NSString).lastPathComponent)
    let components = NSString(string: relative).pathComponents
    let directoryURL: URL
    if components.count > 1 {
      directoryURL = libraryRootURL.appendingPathComponent(components[0], isDirectory: true)
    } else {
      directoryURL = libraryRootURL
    }
    let fileName = components.last ?? "Comic.pdf"
    let stem = (fileName as NSString).deletingPathExtension
    let ext = (fileName as NSString).pathExtension
    var candidate = directoryURL.appendingPathComponent(fileName, isDirectory: false)
    var suffix = 2
    while FileManager.default.fileExists(atPath: candidate.path) || reservedPaths.contains(candidate.path) {
      let nextName = ext.isEmpty ? "\(stem) (\(suffix))" : "\(stem) (\(suffix)).\(ext)"
      candidate = directoryURL.appendingPathComponent(nextName, isDirectory: false)
      suffix += 1
    }
    return candidate
  }

  private static func safeComponent(_ value: String,
                                    fallback: String,
                                    preserveExtension: Bool) -> String {
    var candidate = value.precomposedStringWithCanonicalMapping
    let forbidden = CharacterSet(charactersIn: "/:\0").union(.controlCharacters)
    candidate = String(candidate.unicodeScalars.map { forbidden.contains($0) ? "_" : Character(String($0)) })
    candidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
    while candidate.hasPrefix(".") { candidate.removeFirst() }
    if candidate.isEmpty || candidate == "." || candidate == ".." { candidate = fallback }

    let originalExtension = preserveExtension ? (candidate as NSString).pathExtension : ""
    let maximumStemBytes = 180
    var stem = preserveExtension ? (candidate as NSString).deletingPathExtension : candidate
    while stem.utf8.count > maximumStemBytes && !stem.isEmpty { stem.removeLast() }
    if stem.isEmpty { stem = "Comic" }
    if preserveExtension && !originalExtension.isEmpty {
      let cleanedExtension = String(originalExtension.prefix(12)).filter { $0.isLetter || $0.isNumber }
      if !cleanedExtension.isEmpty { return stem + "." + cleanedExtension }
    }
    return stem
  }
}
