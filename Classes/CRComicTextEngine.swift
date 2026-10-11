import CryptoKit
import Foundation
import ImageIO
import UIKit
import Vision

@objc(CRComicTextErrorCode)
public enum CRComicTextErrorCode: Int {
  case notPrepared = 1
  case invalidPage
  case comicChanged
  case cancelled
  case recognitionFailed
  case cacheUnavailable
}

@objc(CRComicTextDocument)
public final class CRComicTextDocument: NSObject {
  @objc public let fingerprint: String
  @objc public let pageCount: Int
  @objc public let indexedPageCount: Int
  @objc public let complete: Bool
  public let pageTexts: [Int: String]

  // Swift dictionaries with Int keys cannot be exported directly to Objective-C.
  // Keep the natural Swift API while exposing the same data with NSNumber keys.
  @objc(pageTexts) public let objectiveCPageTexts: [NSNumber: String]

  fileprivate init(fingerprint: String, pageCount: Int, pageTexts: [Int: String]) {
    self.fingerprint = fingerprint
    self.pageCount = pageCount
    self.pageTexts = pageTexts
    indexedPageCount = pageTexts.count
    complete = pageCount > 0 && pageTexts.count == pageCount
    objectiveCPageTexts = Dictionary(uniqueKeysWithValues: pageTexts.map {
      (NSNumber(value: $0.key), $0.value)
    })
    super.init()
  }
}

@objc(CRComicTextSearchResult)
public final class CRComicTextSearchResult: NSObject {
  @objc public let pageIndex: Int
  @objc public let snippet: String
  @objc public let pageText: String

  fileprivate init(pageIndex: Int, snippet: String, pageText: String) {
    self.pageIndex = pageIndex
    self.snippet = snippet
    self.pageText = pageText
    super.init()
  }
}

protocol CRComicTextPageProviding: AnyObject {
  var pageCount: Int { get }
  func image(atPageIndex pageIndex: Int, maxDimension: CGFloat) throws -> UIImage
  func embeddedText(atPageIndex pageIndex: Int) throws -> String?
  func isStillCurrent() -> Bool
}

typealias CRComicTextPageSourceFactory = (String) throws -> CRComicTextPageProviding
typealias CRComicTextIdentityResolver = (String) throws -> String
typealias CRComicTextRecognizer = (UIImage, Int) throws -> String

private final class CRComicPageSourceAdapter: CRComicTextPageProviding {
  private let source: CRComicPageSource

  init(path: String) throws {
    let value: CRComicPageSource? = try CRComicPageSource(path: path)
    guard let value else {
      throw CRComicTextEngine.makeError(.recognitionFailed,
                                        "This comic could not be opened for text recognition.")
    }
    source = value
  }

  var pageCount: Int { source.pageCount }

  func image(atPageIndex pageIndex: Int, maxDimension: CGFloat) throws -> UIImage {
    let value: UIImage? = try source.image(atPageIndex: pageIndex, maxDimension: maxDimension)
    guard let value else {
      throw CRComicTextEngine.makeError(.recognitionFailed,
                                        "A comic page could not be decoded for text recognition.")
    }
    return value
  }

  func embeddedText(atPageIndex pageIndex: Int) throws -> String? {
    try source.embeddedText(atPageIndex: pageIndex)
  }

  func isStillCurrent() -> Bool { source.isStillCurrent() }
}

private struct CRComicTextRecognitionConfiguration {
  let revision: Int
  let recognitionLanguages: [String]
  let automaticallyDetectsLanguage: Bool
  let cacheKey: String
}

private struct CRComicTextCachedPage: Codable {
  let pageIndex: Int
  let text: String
}

private struct CRComicTextCacheArchive: Codable {
  let schemaVersion: Int
  let fingerprint: String
  let configurationKey: String
  let pageCount: Int
  let pages: [CRComicTextCachedPage]
}

private struct CRComicTextPreparedState {
  let source: CRComicTextPageProviding
  let fingerprint: String
  let configuration: CRComicTextRecognitionConfiguration
  let cacheURL: URL
  var pageTexts: [Int: String]
}

private final class CRComicTextIndexJob {
  let id = UUID()
  let generation: UInt64
  let pageOrder: [Int]
  let progress: (CRComicTextDocument) -> Void
  let completion: (CRComicTextDocument?, NSError?) -> Void
  var position = 0

  init(generation: UInt64,
       pageOrder: [Int],
       progress: @escaping (CRComicTextDocument) -> Void,
       completion: @escaping (CRComicTextDocument?, NSError?) -> Void) {
    self.generation = generation
    self.pageOrder = pageOrder
    self.progress = progress
    self.completion = completion
  }
}

@objc(CRComicTextEngine)
public final class CRComicTextEngine: NSObject {
  @objc public static let errorDomain = "com.pabloclementeperez.ComicReader.ComicText"

  private static let cacheSchemaVersion = 1
  private static let maximumRecognitionDimension: CGFloat = 2_400

  private let comicPath: String
  private let queue = DispatchQueue(label: "com.pabloclementeperez.ComicReader.ComicText",
                                    qos: .utility)
  private let pageSourceFactory: CRComicTextPageSourceFactory
  private let identityResolver: CRComicTextIdentityResolver
  private let cacheDirectory: URL
  private let injectedConfigurationKey: String?
  private let injectedRecognizer: CRComicTextRecognizer?

  private let cancellationLock = NSLock()
  private var cancellationGeneration: UInt64 = 0
  private var activeRequest: VNRecognizeTextRequest?

  // Accessed only on queue.
  private var preparedState: CRComicTextPreparedState?
  private var activeIndexJobID: UUID?

  @objc(initWithComicPath:)
  public init(comicPath: String) {
    let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
    self.comicPath = comicPath
    pageSourceFactory = { try CRComicPageSourceAdapter(path: $0) }
    identityResolver = { try CRPageBookmarkStore.sharedStore.resolveComic(atPath: $0).fingerprint }
    cacheDirectory = caches
      .appendingPathComponent("ComicReader", isDirectory: true)
      .appendingPathComponent("ComicText", isDirectory: true)
    injectedConfigurationKey = nil
    injectedRecognizer = nil
    super.init()
  }

  init(comicPath: String,
       pageSourceFactory: @escaping CRComicTextPageSourceFactory,
       identityResolver: @escaping CRComicTextIdentityResolver,
       cacheDirectory: URL,
       ocrConfigurationKey: String,
       recognizer: @escaping CRComicTextRecognizer) {
    self.comicPath = comicPath
    self.pageSourceFactory = pageSourceFactory
    self.identityResolver = identityResolver
    self.cacheDirectory = cacheDirectory
    injectedConfigurationKey = ocrConfigurationKey
    injectedRecognizer = recognizer
    super.init()
  }

  @objc(prepareWithCompletion:)
  public func prepare(completion: @escaping (CRComicTextDocument?, NSError?) -> Void) {
    let generation = currentGeneration()
    queue.async { [self] in
      do {
        try checkCancellation(generation)

        if let state = preparedState {
          try checkCurrent(state.source)
          try checkCancellation(generation)
          deliver { completion(self.document(from: state), nil) }
          return
        }

        let source = try pageSourceFactory(comicPath)
        guard source.pageCount > 0 else {
          throw Self.makeError(.recognitionFailed,
                               "The comic has no readable pages.")
        }
        try checkCurrent(source)
        try checkCancellation(generation)

        // The bookmark identity resolver hashes every byte and verifies the file
        // snapshot around that read. It intentionally runs off the main thread.
        let fingerprint = try identityResolver(comicPath)
        guard !fingerprint.isEmpty else {
          throw Self.makeError(.recognitionFailed,
                               "This comic could not be identified for text recognition.")
        }
        try checkCurrent(source)
        try checkCancellation(generation)

        let configuration = try recognitionConfiguration()
        let cacheURL = makeCacheURL(fingerprint: fingerprint,
                                    configurationKey: configuration.cacheKey)
        let pageTexts = loadCache(at: cacheURL,
                                  fingerprint: fingerprint,
                                  configurationKey: configuration.cacheKey,
                                  pageCount: source.pageCount)
        let state = CRComicTextPreparedState(source: source,
                                              fingerprint: fingerprint,
                                              configuration: configuration,
                                              cacheURL: cacheURL,
                                              pageTexts: pageTexts)
        try checkCurrent(source)
        try checkCancellation(generation)
        preparedState = state
        deliver { completion(self.document(from: state), nil) }
      } catch {
        deliver { completion(nil, error as NSError) }
      }
    }
  }

  @objc(recognizePageAtPageIndex:completion:)
  public func recognizePage(atPageIndex pageIndex: Int,
                            completion: @escaping (String?, NSError?) -> Void) {
    let generation = currentGeneration()
    queue.async { [self] in
      do {
        guard let state = preparedState else { throw notPreparedError() }
        try validate(pageIndex: pageIndex, pageCount: state.source.pageCount)
        try checkCancellation(generation)
        try checkCurrent(state.source)
        let text = try recognize(pageIndex: pageIndex, state: state, generation: generation)
        try checkCancellation(generation)
        try checkCurrent(state.source)
        deliver { completion(text, nil) }
      } catch {
        deliver { completion(nil, error as NSError) }
      }
    }
  }

  @objc(buildIndexStartingAtPageIndex:progress:completion:)
  public func buildIndex(startingAtPageIndex pageIndex: Int,
                         progress: @escaping (CRComicTextDocument) -> Void,
                         completion: @escaping (CRComicTextDocument?, NSError?) -> Void) {
    let generation = currentGeneration()
    queue.async { [self] in
      do {
        guard let state = preparedState else { throw notPreparedError() }
        try validate(pageIndex: pageIndex, pageCount: state.source.pageCount)
        try checkCancellation(generation)
        try checkCurrent(state.source)

        let order = [pageIndex] + (0..<state.source.pageCount).filter { $0 != pageIndex }
        let job = CRComicTextIndexJob(generation: generation,
                                      pageOrder: order,
                                      progress: progress,
                                      completion: completion)
        activeIndexJobID = job.id
        processNextPage(in: job)
      } catch {
        let snapshot = preparedState.map(document(from:))
        deliver { completion(snapshot, error as NSError) }
      }
    }
  }

  @objc(searchForQuery:completion:)
  public func search(forQuery query: String,
                     completion: @escaping ([CRComicTextSearchResult]?, NSError?) -> Void) {
    let generation = currentGeneration()
    queue.async { [self] in
      do {
        guard let state = preparedState else { throw notPreparedError() }
        try checkCancellation(generation)
        try checkCurrent(state.source)

        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty else {
          deliver { completion([], nil) }
          return
        }

        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        let results = state.pageTexts.keys.sorted().compactMap { pageIndex -> CRComicTextSearchResult? in
          let text = state.pageTexts[pageIndex] ?? ""
          guard let range = text.range(of: normalizedQuery, options: options) else { return nil }
          return CRComicTextSearchResult(pageIndex: pageIndex,
                                         snippet: makeSnippet(text: text, match: range),
                                         pageText: text)
        }
        try checkCancellation(generation)
        deliver { completion(results, nil) }
      } catch {
        deliver { completion(nil, error as NSError) }
      }
    }
  }

  /// Performs only the cheap device/inode/size/date snapshot validation held by
  /// the page source. It deliberately does not hash the comic again.
  @objc(validateCurrentWithCompletion:)
  public func validateCurrent(completion: @escaping (NSError?) -> Void) {
    let generation = currentGeneration()
    queue.async { [self] in
      do {
        guard let state = preparedState else { throw notPreparedError() }
        try checkCancellation(generation)
        try checkCurrent(state.source)
        deliver { completion(nil) }
      } catch {
        deliver { completion(error as NSError) }
      }
    }
  }

  @objc public func cancel() {
    cancellationLock.lock()
    cancellationGeneration &+= 1
    let request = activeRequest
    cancellationLock.unlock()
    request?.cancel()
  }

  private func processNextPage(in job: CRComicTextIndexJob) {
    dispatchPrecondition(condition: .onQueue(queue))

    do {
      guard activeIndexJobID == job.id else { throw cancellationError() }
      try checkCancellation(job.generation)
      guard var state = preparedState else { throw notPreparedError() }
      try checkCurrent(state.source)

      guard job.position < job.pageOrder.count else {
        activeIndexJobID = nil
        let snapshot = document(from: state)
        deliver { job.completion(snapshot, nil) }
        return
      }

      let pageIndex = job.pageOrder[job.position]
      job.position += 1

      if state.pageTexts[pageIndex] == nil {
        let text = try recognize(pageIndex: pageIndex, state: state, generation: job.generation)
        try checkCancellation(job.generation)
        try checkCurrent(state.source)

        var candidateTexts = state.pageTexts
        candidateTexts[pageIndex] = text
        try commit(pageTexts: candidateTexts, state: &state, generation: job.generation)
        try checkCurrent(state.source)
      }

      let snapshot = document(from: state)
      deliver { [weak self] in
        job.progress(snapshot)
        guard let self else {
          job.completion(snapshot, Self.makeError(.cancelled,
                                                   "Text recognition was cancelled."))
          return
        }
        self.queue.async { self.processNextPage(in: job) }
      }
    } catch {
      if activeIndexJobID == job.id { activeIndexJobID = nil }
      let snapshot = preparedState.map(document(from:))
      deliver { job.completion(snapshot, error as NSError) }
    }
  }

  private func recognize(pageIndex: Int,
                         state: CRComicTextPreparedState,
                         generation: UInt64) throws -> String {
    try autoreleasepool {
      try checkCancellation(generation)
      try checkCurrent(state.source)

      if let embedded = try state.source.embeddedText(atPageIndex: pageIndex) {
        let trimmed = embedded.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
      }

      try checkCancellation(generation)
      try checkCurrent(state.source)
      let image = try state.source.image(atPageIndex: pageIndex,
                                         maxDimension: Self.maximumRecognitionDimension)
      try checkCancellation(generation)
      try checkCurrent(state.source)

      let text: String
      if let injectedRecognizer {
        text = try injectedRecognizer(image, pageIndex)
      } else {
        text = try recognizeWithVision(image: image,
                                       configuration: state.configuration,
                                       generation: generation)
      }
      try checkCancellation(generation)
      try checkCurrent(state.source)
      return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
  }

  private func recognizeWithVision(image: UIImage,
                                   configuration: CRComicTextRecognitionConfiguration,
                                   generation: UInt64) throws -> String {
    guard let cgImage = image.cgImage else {
      throw Self.makeError(.recognitionFailed,
                           "A comic page could not be prepared for text recognition.")
    }

    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true
    request.revision = configuration.revision
    request.recognitionLanguages = configuration.recognitionLanguages
    if #available(iOS 16.0, *) {
      request.automaticallyDetectsLanguage = configuration.automaticallyDetectsLanguage
    }

    try register(request: request, generation: generation)
    defer { unregister(request: request) }

    do {
      let handler = VNImageRequestHandler(cgImage: cgImage,
                                          orientation: image.imageOrientation.cgImageOrientation,
                                          options: [:])
      try handler.perform([request])
    } catch {
      try checkCancellation(generation)
      throw Self.makeError(.recognitionFailed,
                           "Text recognition could not read this comic page.",
                           underlying: error)
    }

    try checkCancellation(generation)
    return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
  }

  private func recognitionConfiguration() throws -> CRComicTextRecognitionConfiguration {
    if let injectedConfigurationKey {
      return CRComicTextRecognitionConfiguration(revision: 0,
                                                   recognitionLanguages: [],
                                                   automaticallyDetectsLanguage: false,
                                                   cacheKey: "injected:\(injectedConfigurationKey)")
    }

    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true
    let preferred = Self.uniqueLanguageIdentifiers(Locale.preferredLanguages)

    if #available(iOS 16.0, *) {
      request.revision = VNRecognizeTextRequestRevision3
      request.automaticallyDetectsLanguage = true
      let key = "vision;revision=3;level=accurate;correction=1;automatic=1;preferred=\(preferred.joined(separator: ","))"
      return CRComicTextRecognitionConfiguration(revision: request.revision,
                                                   recognitionLanguages: [],
                                                   automaticallyDetectsLanguage: true,
                                                   cacheKey: key)
    }

    request.revision = VNRecognizeTextRequestRevision2
    let supported = try request.supportedRecognitionLanguages()
    let supportedByKey = Dictionary(uniqueKeysWithValues: supported.map { ($0.lowercased(), $0) })
    let languages = preferred.compactMap { supportedByKey[$0.lowercased()] }
    request.recognitionLanguages = languages
    let key = "vision;revision=2;level=accurate;correction=1;automatic=0;languages=\(languages.joined(separator: ","))"
    return CRComicTextRecognitionConfiguration(revision: request.revision,
                                                 recognitionLanguages: languages,
                                                 automaticallyDetectsLanguage: false,
                                                 cacheKey: key)
  }

  private static func uniqueLanguageIdentifiers(_ identifiers: [String]) -> [String] {
    var seen = Set<String>()
    return identifiers.compactMap { value in
      let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !normalized.isEmpty, seen.insert(normalized.lowercased()).inserted else { return nil }
      return normalized
    }
  }

  private func makeCacheURL(fingerprint: String, configurationKey: String) -> URL {
    let rawKey = "schema=\(Self.cacheSchemaVersion)|fingerprint=\(fingerprint)|configuration=\(configurationKey)"
    let digest = SHA256.hash(data: Data(rawKey.utf8)).map { String(format: "%02x", $0) }.joined()
    return cacheDirectory.appendingPathComponent("\(digest).json")
  }

  private func loadCache(at url: URL,
                         fingerprint: String,
                         configurationKey: String,
                         pageCount: Int) -> [Int: String] {
    guard let data = try? Data(contentsOf: url),
          let archive = try? JSONDecoder().decode(CRComicTextCacheArchive.self, from: data),
          archive.schemaVersion == Self.cacheSchemaVersion,
          archive.fingerprint == fingerprint,
          archive.configurationKey == configurationKey,
          archive.pageCount == pageCount else {
      return [:]
    }

    var texts: [Int: String] = [:]
    for page in archive.pages where page.pageIndex >= 0 && page.pageIndex < pageCount {
      // Reject duplicate indices instead of allowing archive order to decide.
      guard texts[page.pageIndex] == nil else { return [:] }
      texts[page.pageIndex] = page.text
    }
    return texts
  }

  private func persist(pageTexts: [Int: String], state: CRComicTextPreparedState) throws {
    let pages = pageTexts.keys.sorted().compactMap { pageIndex -> CRComicTextCachedPage? in
      guard let text = pageTexts[pageIndex] else { return nil }
      return CRComicTextCachedPage(pageIndex: pageIndex, text: text)
    }
    let archive = CRComicTextCacheArchive(schemaVersion: Self.cacheSchemaVersion,
                                           fingerprint: state.fingerprint,
                                           configurationKey: state.configuration.cacheKey,
                                           pageCount: state.source.pageCount,
                                           pages: pages)
    do {
      try FileManager.default.createDirectory(at: cacheDirectory,
                                              withIntermediateDirectories: true)
      var resourceValues = URLResourceValues()
      resourceValues.isExcludedFromBackup = true
      var directory = cacheDirectory
      try? directory.setResourceValues(resourceValues)

      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys]
      let data = try encoder.encode(archive)
      try data.write(to: state.cacheURL, options: [.atomic])
    } catch {
      throw Self.makeError(.cacheUnavailable,
                           "The recognized text could not be saved on this device.",
                           underlying: error)
    }
  }

  /// Serial queue ownership protects state, while this short lock makes the
  /// persistence boundary ordered with respect to cancel(). If cancel returns,
  /// no later page can pass this generation check and commit.
  private func commit(pageTexts: [Int: String],
                      state: inout CRComicTextPreparedState,
                      generation: UInt64) throws {
    cancellationLock.lock()
    guard generation == cancellationGeneration else {
      cancellationLock.unlock()
      throw cancellationError()
    }

    do {
      try persist(pageTexts: pageTexts, state: state)
      state.pageTexts = pageTexts
      preparedState = state
      cancellationLock.unlock()
    } catch {
      cancellationLock.unlock()
      throw error
    }
  }

  private func document(from state: CRComicTextPreparedState) -> CRComicTextDocument {
    CRComicTextDocument(fingerprint: state.fingerprint,
                        pageCount: state.source.pageCount,
                        pageTexts: state.pageTexts)
  }

  private func validate(pageIndex: Int, pageCount: Int) throws {
    guard pageIndex >= 0, pageIndex < pageCount else {
      throw Self.makeError(.invalidPage, "That comic page is unavailable.")
    }
  }

  private func checkCurrent(_ source: CRComicTextPageProviding) throws {
    guard source.isStillCurrent() else {
      throw Self.makeError(.comicChanged,
                           "The comic changed while its text was being read. Reopen it to continue.")
    }
  }

  private func currentGeneration() -> UInt64 {
    cancellationLock.lock()
    defer { cancellationLock.unlock() }
    return cancellationGeneration
  }

  private func checkCancellation(_ generation: UInt64) throws {
    cancellationLock.lock()
    let cancelled = generation != cancellationGeneration
    cancellationLock.unlock()
    if cancelled { throw cancellationError() }
  }

  private func register(request: VNRecognizeTextRequest, generation: UInt64) throws {
    cancellationLock.lock()
    guard generation == cancellationGeneration else {
      cancellationLock.unlock()
      request.cancel()
      throw cancellationError()
    }
    activeRequest = request
    cancellationLock.unlock()
  }

  private func unregister(request: VNRecognizeTextRequest) {
    cancellationLock.lock()
    if activeRequest === request { activeRequest = nil }
    cancellationLock.unlock()
  }

  private func notPreparedError() -> NSError {
    Self.makeError(.notPrepared,
                   "Prepare this comic before reading or searching its text.")
  }

  private func cancellationError() -> NSError {
    Self.makeError(.cancelled, "Text recognition was cancelled.")
  }

  fileprivate static func makeError(_ code: CRComicTextErrorCode,
                                    _ description: String,
                                    underlying: Error? = nil) -> NSError {
    var userInfo: [String: Any] = [NSLocalizedDescriptionKey: description]
    if let underlying { userInfo[NSUnderlyingErrorKey] = underlying }
    return NSError(domain: errorDomain, code: code.rawValue, userInfo: userInfo)
  }

  private func makeSnippet(text: String, match: Range<String.Index>) -> String {
    let utf16 = text as NSString
    let matchRange = NSRange(match, in: text)
    let contextLength = 72
    let start = max(0, matchRange.location - contextLength)
    let end = min(utf16.length, NSMaxRange(matchRange) + contextLength)
    let raw = utf16.substring(with: NSRange(location: start, length: end - start))
    let collapsed = raw.components(separatedBy: .whitespacesAndNewlines)
      .filter { !$0.isEmpty }
      .joined(separator: " ")
    return (start > 0 ? "…" : "") + collapsed + (end < utf16.length ? "…" : "")
  }

  private func deliver(_ block: @escaping () -> Void) {
    if Thread.isMainThread {
      block()
    } else {
      DispatchQueue.main.async(execute: block)
    }
  }
}

private extension UIImage.Orientation {
  var cgImageOrientation: CGImagePropertyOrientation {
    switch self {
    case .up: return .up
    case .upMirrored: return .upMirrored
    case .down: return .down
    case .downMirrored: return .downMirrored
    case .left: return .left
    case .leftMirrored: return .leftMirrored
    case .right: return .right
    case .rightMirrored: return .rightMirrored
    @unknown default: return .up
    }
  }
}
