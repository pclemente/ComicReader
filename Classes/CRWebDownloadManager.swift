import Foundation
import WebKit

enum CRWebDownloadState: Equatable {
  case downloading
  case validating
  case importing
  case completed
  case duplicate
  case failed
  case cancelled
}

struct CRWebDownloadEntry: Identifiable, Equatable {
  let id: UUID
  var displayName: String
  let destinationCollection: String?
  var state: CRWebDownloadState
  var progress: Double
  var pageCount: Int?
  var importedURL: URL?
  var errorDescription: String?
  var canRetry: Bool

  var isTerminal: Bool {
    switch state {
    case .completed, .duplicate, .failed, .cancelled: return true
    case .downloading, .validating, .importing: return false
    }
  }
}

private final class CRWebImportCancellationToken: @unchecked Sendable {
  private let lock = NSLock()
  private var cancelled = false

  var isCancelled: Bool {
    lock.lock()
    defer { lock.unlock() }
    return cancelled
  }

  func cancel() {
    lock.lock()
    cancelled = true
    lock.unlock()
  }
}

/// Owns WKDownload destinations and the complete validation/import lifecycle.
/// Source requests and resume data remain in memory only and are never logged.
@MainActor
final class CRWebDownloadManager: NSObject, WKDownloadDelegate {
  typealias EntitlementCheck = @MainActor () -> Bool

  private final class Record {
    let id: UUID
    var entry: CRWebDownloadEntry
    var download: WKDownload?
    var progressObservation: NSKeyValueObservation?
    var stagingDirectory: URL
    var payloadURL: URL
    var suggestedFilename = "Download"
    var mimeType: String?
    var resumeData: Data?
    var cancellationToken = CRWebImportCancellationToken()
    var generation = 0

    init(id: UUID,
         destinationCollection: String?,
         stagingDirectory: URL,
         payloadURL: URL) {
      self.id = id
      self.stagingDirectory = stagingDirectory
      self.payloadURL = payloadURL
      entry = CRWebDownloadEntry(id: id,
                                 displayName: "Download",
                                 destinationCollection: destinationCollection,
                                 state: .downloading,
                                 progress: 0,
                                 pageCount: nil,
                                 importedURL: nil,
                                 errorDescription: nil,
                                 canRetry: false)
    }
  }

  private let model: CRWebImportModel
  private let entitlementCheck: EntitlementCheck
  private let processingQueue = DispatchQueue(label: "com.comicreader.web-import", qos: .userInitiated)
  private var stagingSessionURL: URL?
  private var records: [UUID: Record] = [:]
  private var orderedIdentifiers: [UUID] = []
  private var identifiersByDownload: [ObjectIdentifier: UUID] = [:]
  private var pendingValidationIdentifiers: [UUID] = []
  private var processingImportIdentifier: UUID?
  private var entitlementObserver: NSObjectProtocol?

  var onChange: (([CRWebDownloadEntry]) -> Void)? {
    didSet { onChange?(entries) }
  }
  var onImport: ((URL) -> Void)?

  var entries: [CRWebDownloadEntry] {
    orderedIdentifiers.compactMap { records[$0]?.entry }
  }

  convenience init(libraryRootURL: URL) throws {
    try self.init(libraryRootURL: libraryRootURL, plusStore: CRPlusStore.sharedStore)
  }

  init(libraryRootURL: URL, plusStore: CRPlusStore) throws {
    let model = try CRWebImportModel(libraryRootURL: libraryRootURL)
    self.model = model
    entitlementCheck = { plusStore.isUnlocked }
    stagingSessionURL = try model.makeStagingSession()
    super.init()
    entitlementObserver = NotificationCenter.default.addObserver(
      forName: CRPlusStore.entitlementDidChangeNotification,
      object: plusStore,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor [weak self] in self?.entitlementDidChange() }
    }
  }

  /// Test-only dependency injection keeps StoreKit out of filesystem and local
  /// WebKit integration tests while preserving the same commit-time gate.
  init(libraryRootURL: URL, entitlementCheck: @escaping EntitlementCheck) throws {
    let model = try CRWebImportModel(libraryRootURL: libraryRootURL)
    self.model = model
    self.entitlementCheck = entitlementCheck
    stagingSessionURL = try model.makeStagingSession()
    super.init()
  }

  deinit {
    if let entitlementObserver { NotificationCenter.default.removeObserver(entitlementObserver) }
    for record in records.values {
      record.cancellationToken.cancel()
      record.progressObservation?.invalidate()
      model.removeStagingItem(record.stagingDirectory)
    }
    if let stagingSessionURL { model.removeStagingSession(stagingSessionURL) }
  }

  func availableCollections() throws -> [String] {
    guard entitlementCheck() else { throw CRWebImportError.plusRequired }
    return try model.availableCollections()
  }

  @discardableResult
  func createCollection(named name: String) throws -> String {
    guard entitlementCheck() else { throw CRWebImportError.plusRequired }
    return try model.createCollection(named: name)
  }

  @discardableResult
  func adopt(download: WKDownload, destinationCollection: String?) throws -> UUID {
    guard entitlementCheck() else {
      download.cancel(nil)
      throw CRWebImportError.plusRequired
    }
    if let destinationCollection {
      guard try model.availableCollections().contains(destinationCollection) else {
        download.cancel(nil)
        throw CRWebImportError.invalidCollection
      }
    }
    let id = UUID()
    let item = try model.makeStagingItem(in: try activeStagingSession(), identifier: id)
    let record = Record(id: id,
                        destinationCollection: destinationCollection,
                        stagingDirectory: item.directory,
                        payloadURL: item.payload)
    records[id] = record
    orderedIdentifiers.append(id)
    attach(download: download, to: record)
    publishChanges()
    return id
  }

  func cancel(id: UUID) {
    guard let record = records[id], !record.entry.isTerminal else { return }
    cancel(record: record, preserveResumeData: true, terminalState: .cancelled,
           message: CRWebImportError.cancelled.localizedDescription)
  }

  func retry(id: UUID, in webView: WKWebView) throws {
    guard entitlementCheck() else { throw CRWebImportError.plusRequired }
    guard let record = records[id],
          record.entry.state == .failed || record.entry.state == .cancelled,
          let resumeData = record.resumeData else {
      throw CRWebImportError.retryUnavailable
    }

    record.generation += 1
    let generation = record.generation
    let item = try model.makeStagingItem(in: try activeStagingSession(), identifier: id)
    record.stagingDirectory = item.directory
    record.payloadURL = item.payload
    record.resumeData = nil
    record.cancellationToken = CRWebImportCancellationToken()
    record.entry.state = .downloading
    record.entry.progress = 0
    record.entry.pageCount = nil
    record.entry.importedURL = nil
    record.entry.errorDescription = nil
    record.entry.canRetry = false
    publishChanges()

    webView.resumeDownload(fromResumeData: resumeData) { [weak self] download in
      guard let self else {
        download.cancel(nil)
        return
      }
      guard let current = self.records[id],
            current === record,
            current.generation == generation,
            current.entry.state == .downloading else {
        download.cancel(nil)
        return
      }
      self.attach(download: download, to: current)
    }
  }

  func remove(id: UUID) {
    guard let record = records[id] else { return }
    destroy(record: record)
    records.removeValue(forKey: id)
    orderedIdentifiers.removeAll { $0 == id }
    pendingValidationIdentifiers.removeAll { $0 == id }
    publishChanges()
  }

  func openableURL(for id: UUID) -> URL? {
    guard let record = records[id],
          record.entry.state == .completed || record.entry.state == .duplicate,
          let url = record.entry.importedURL,
          model.isSafeImportedURL(url) else { return nil }
    return url
  }

  /// Used on private-mode changes and browser closure. All resumable state and
  /// staging bytes are discarded before this method returns; late WebKit and
  /// validation callbacks are ignored by identity/generation checks.
  func cancelAndRemoveAll() {
    let oldRecords = Array(records.values)
    records.removeAll()
    orderedIdentifiers.removeAll()
    identifiersByDownload.removeAll()
    pendingValidationIdentifiers.removeAll()
    processingImportIdentifier = nil
    let oldSession = stagingSessionURL
    stagingSessionURL = nil
    for record in oldRecords { destroy(record: record) }
    if let oldSession { model.removeStagingSession(oldSession) }
    publishChanges()
  }

  private func activeStagingSession() throws -> URL {
    if let stagingSessionURL { return stagingSessionURL }
    let session = try model.makeStagingSession()
    stagingSessionURL = session
    return session
  }

  private func attach(download: WKDownload, to record: Record) {
    if let previous = record.download {
      identifiersByDownload.removeValue(forKey: ObjectIdentifier(previous))
      previous.delegate = nil
    }
    record.download = download
    identifiersByDownload[ObjectIdentifier(download)] = record.id
    download.delegate = self
    record.progressObservation = download.progress.observe(\.fractionCompleted,
                                                           options: [.initial, .new]) { [weak self, weak download] progress, _ in
      let fraction = progress.fractionCompleted
      Task { @MainActor [weak self, weak download] in
        guard let self, let download else { return }
        self.updateProgress(download: download, fraction: fraction)
      }
    }
  }

  private func updateProgress(download: WKDownload, fraction: Double) {
    guard fraction.isFinite,
          let record = record(for: download),
          record.entry.state == .downloading else { return }
    let clamped = min(max(fraction, 0), 1)
    guard abs(record.entry.progress - clamped) >= 0.002 || clamped == 1 else { return }
    record.entry.progress = clamped
    publishChanges()
  }

  private func record(for download: WKDownload) -> Record? {
    identifiersByDownload[ObjectIdentifier(download)].flatMap { records[$0] }
  }

  private func detachDownload(from record: Record) {
    record.progressObservation?.invalidate()
    record.progressObservation = nil
    if let download = record.download {
      identifiersByDownload.removeValue(forKey: ObjectIdentifier(download))
      download.delegate = nil
    }
    record.download = nil
  }

  private func cancel(record: Record,
                      preserveResumeData: Bool,
                      terminalState: CRWebDownloadState,
                      message: String?) {
    record.generation += 1
    let generation = record.generation
    record.cancellationToken.cancel()
    record.resumeData = nil
    record.entry.state = terminalState
    record.entry.errorDescription = message
    record.entry.canRetry = false
    record.progressObservation?.invalidate()
    record.progressObservation = nil
    let download = record.download
    if let download {
      identifiersByDownload.removeValue(forKey: ObjectIdentifier(download))
      download.delegate = nil
      record.download = nil
      download.cancel { [weak self, weak record] resumeData in
        guard let self, let record,
              preserveResumeData,
              self.records[record.id] === record,
              record.generation == generation,
              record.entry.state == terminalState,
              let resumeData, !resumeData.isEmpty else { return }
        record.resumeData = resumeData
        record.entry.canRetry = true
        self.publishChanges()
      }
    }
    model.removeStagingItem(record.stagingDirectory)
    publishChanges()
  }

  private func destroy(record: Record) {
    record.generation += 1
    record.cancellationToken.cancel()
    record.resumeData = nil
    record.progressObservation?.invalidate()
    record.progressObservation = nil
    if let download = record.download {
      identifiersByDownload.removeValue(forKey: ObjectIdentifier(download))
      download.delegate = nil
      download.cancel(nil)
      record.download = nil
    }
    model.removeStagingItem(record.stagingDirectory)
  }

  private func entitlementDidChange() {
    guard !entitlementCheck() else { return }
    let message = CRWebImportError.plusRequired.localizedDescription
    for record in records.values where !record.entry.isTerminal {
      cancel(record: record, preserveResumeData: false, terminalState: .failed, message: message)
    }
  }

  private func enqueueValidation(for record: Record) {
    pendingValidationIdentifiers.append(record.id)
    processNextValidationIfNeeded()
  }

  private func processNextValidationIfNeeded() {
    guard processingImportIdentifier == nil else { return }
    while !pendingValidationIdentifiers.isEmpty {
      let id = pendingValidationIdentifiers.removeFirst()
      guard let record = records[id], record.entry.state == .validating else { continue }
      processingImportIdentifier = id
      let generation = record.generation
      let token = record.cancellationToken
      let stagedURL = record.payloadURL
      let suggestedFilename = record.suggestedFilename
      let mimeType = record.mimeType
      let destinationCollection = record.entry.destinationCollection
      let importModel = model
      processingQueue.async { [weak self] in
        guard let self else { return }
        let result: Result<CRWebPreparedImport, Error> = autoreleasepool {
          Result {
            try importModel.prepareImport(stagedURL: stagedURL,
                                          suggestedFilename: suggestedFilename,
                                          mimeType: mimeType,
                                          destinationCollection: destinationCollection,
                                          shouldContinue: { !token.isCancelled })
          }
        }
        Task { @MainActor [weak self] in
          self?.completePreparation(result, id: id, generation: generation, token: token)
        }
      }
      return
    }
  }

  private func completePreparation(_ result: Result<CRWebPreparedImport, Error>,
                                   id: UUID,
                                   generation: Int,
                                   token: CRWebImportCancellationToken) {
    guard processingImportIdentifier == id else { return }
    processingImportIdentifier = nil
    defer { processNextValidationIfNeeded() }
    guard let record = records[id],
          record.generation == generation,
          record.cancellationToken === token,
          record.entry.state == .validating,
          !token.isCancelled else {
      return
    }

    switch result {
    case .failure(let error):
      fail(record: record, error: error)

    case .success(let prepared):
      record.entry.state = .importing
      record.entry.pageCount = prepared.pageCount
      publishChanges()
      do {
        let commit = try model.commit(prepared) { [weak self, weak record] in
          guard let self, let record else { return false }
          return self.entitlementCheck() &&
            self.records[id] === record &&
            record.generation == generation &&
            record.cancellationToken === token &&
            !token.isCancelled &&
            record.entry.state == .importing
        }
        record.entry.state = commit.isDuplicate ? .duplicate : .completed
        record.entry.progress = 1
        record.entry.importedURL = commit.url
        record.entry.errorDescription = nil
        record.entry.canRetry = false
        record.resumeData = nil
        model.removeStagingItem(record.stagingDirectory)
        publishChanges()
        onImport?(commit.url)
      } catch {
        if !entitlementCheck() {
          fail(record: record, error: CRWebImportError.plusRequired)
        } else if token.isCancelled {
          fail(record: record, error: CRWebImportError.cancelled)
        } else {
          fail(record: record, error: error)
        }
      }
    }
  }

  private func fail(record: Record, error: Error) {
    record.entry.state = error is CRWebImportError && (error as? CRWebImportError) == .cancelled
      ? .cancelled : .failed
    record.entry.errorDescription = userFacingMessage(for: error)
    record.entry.canRetry = record.resumeData?.isEmpty == false
    model.removeStagingItem(record.stagingDirectory)
    publishChanges()
  }

  private func userFacingMessage(for error: Error) -> String {
    if let error = error as? CRWebImportError {
      return error.localizedDescription
    }
    // WebKit and filesystem errors can embed sensitive paths or source URLs.
    return "The download could not be completed."
  }

  private func publishChanges() {
    onChange?(entries)
  }
}

private extension CRWebImportCommitResult {
  var isDuplicate: Bool {
    if case .duplicate = self { return true }
    return false
  }
}

extension CRWebDownloadManager {
  func download(_ download: WKDownload,
                decideDestinationUsing response: URLResponse,
                suggestedFilename: String,
                completionHandler: @escaping (URL?) -> Void) {
    guard let record = record(for: download),
          record.entry.state == .downloading,
          entitlementCheck() else {
      completionHandler(nil)
      return
    }
    record.suggestedFilename = suggestedFilename
    record.mimeType = response.mimeType
    record.entry.displayName = model.previewFilename(suggestedFilename)
    do {
      if FileManager.default.fileExists(atPath: record.payloadURL.path) {
        try FileManager.default.removeItem(at: record.payloadURL)
      }
      publishChanges()
      completionHandler(record.payloadURL)
    } catch {
      fail(record: record, error: CRWebImportError.fileOperationFailed)
      completionHandler(nil)
    }
  }

  func download(_ download: WKDownload,
                willPerformHTTPRedirection response: HTTPURLResponse,
                newRequest request: URLRequest,
                decisionHandler: @escaping (WKDownload.RedirectPolicy) -> Void) {
    decisionHandler(.allow)
  }

  func download(_ download: WKDownload,
                didReceive challenge: URLAuthenticationChallenge,
                completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
    // WebKit retains its own authenticated session. Do not extract or copy raw
    // credentials into app-managed storage.
    completionHandler(.performDefaultHandling, nil)
  }

  func downloadDidFinish(_ download: WKDownload) {
    guard let record = record(for: download), record.entry.state == .downloading else { return }
    detachDownload(from: record)
    record.entry.state = .validating
    record.entry.progress = 1
    record.entry.errorDescription = nil
    record.entry.canRetry = false
    publishChanges()
    enqueueValidation(for: record)
  }

  func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
    guard let record = record(for: download), record.entry.state == .downloading else { return }
    detachDownload(from: record)
    record.resumeData = resumeData?.isEmpty == false ? resumeData : nil
    record.entry.state = .failed
    record.entry.errorDescription = userFacingMessage(for: error)
    record.entry.canRetry = record.resumeData != nil
    model.removeStagingItem(record.stagingDirectory)
    publishChanges()
  }
}
