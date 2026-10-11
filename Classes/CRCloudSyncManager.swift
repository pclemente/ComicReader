//
//  CRCloudSyncManager.swift
//  ComicFlow
//
//  iCloud Drive synchronization for ComicReader.
//
//  The manager deliberately has no dependency on Library or Comic. Objective-C
//  supplies immutable dictionary snapshots and applies the notifications below.
//

@preconcurrency import CryptoKit
@preconcurrency import Foundation

@objc(CRCloudSyncStatus)
public enum CRCloudSyncStatus: Int {
  case disabled = 0
  // Retained for source compatibility with older UI code. The manager no
  // longer emits this status because iCloud sync has no purchase gate.
  case notEntitled = 1
  case optInRequired = 2
  case iCloudUnavailable = 3
  case accountChanged = 4
  case ready = 5
  case syncing = 6
  case downloading = 7
  case waitingForNetwork = 8
  case quotaExceeded = 9
  case failed = 10
}

@objc(CRCloudSyncErrorCode)
public enum CRCloudSyncErrorCode: Int {
  case notConfigured = 1
  case optInRequired = 3
  case iCloudUnavailable = 4
  case accountChanged = 5
  case invalidSnapshot = 6
  case unsafePath = 7
  case unsupportedFile = 8
  case fileMissing = 9
  case integrityMismatch = 10
  case metadataUnavailable = 11
  case cancelled = 12
  case quotaExceeded = 13
}

@objcMembers
public final class CRCloudSyncManager: NSObject {
  // MARK: Objective-C contract

  public static let sharedManager = CRCloudSyncManager()
  public static let ubiquityContainerIdentifier = "iCloud.com.pabloclementeperez.ComicFlow"

  public static let statusDidChangeNotification = "CRCloudSyncStatusDidChangeNotification"
  public static let importedComicsNotification = "CRCloudSyncImportedComicsNotification"
  public static let readingStateDidChangeNotification = "CRCloudSyncReadingStateDidChangeNotification"
  public static let remoteDeletionsNotification = "CRCloudSyncRemoteDeletionsNotification"

  public static let localPathKey = "localPath"
  public static let relativePathKey = "relativePath"
  public static let contentIdentifierKey = "contentIdentifier"
  public static let legacyStatusKey = "legacyStatus"
  public static let currentPageKey = "currentPage"
  public static let pageCountKey = "pageCount"
  public static let readingUpdatedAtKey = "readingUpdatedAt"
  public static let readingMutationIdentifierKey = "readingMutationIdentifier"
  public static let sourceDeviceIdentifierKey = "sourceDeviceIdentifier"

  public static let resultUploadedCountKey = "uploadedCount"
  public static let resultIdentifiedComicsKey = "identifiedComics"
  public static let resultImportedComicsKey = "importedComics"
  public static let resultReadingStatesKey = "readingStates"
  public static let resultPendingDownloadCountKey = "pendingDownloadCount"
  public static let resultRemoteDeletionIdentifiersKey = "remoteDeletionIdentifiers"
  public static let resultPartialErrorsKey = "partialErrors"

  public static let errorDomain = "com.pabloclementeperez.ComicFlow.CloudSync"

  public var configured: Bool { viewValue { $0.configured } }
  public var optedIn: Bool { viewValue { $0.optedIn } }
  public var enabled: Bool { viewValue { $0.enabled } }
  public var isSyncing: Bool { viewValue { $0.isSyncing } }
  public var status: CRCloudSyncStatus { viewValue { $0.status } }
  public var statusMessage: String { viewValue { $0.statusMessage } }
  public var lastError: NSError? { viewValue { $0.lastError } }
  public var lastSyncDate: Date? { viewValue { $0.lastSyncDate } }

  /// Call at launch with the Documents library root. `optedIn` is the user's
  /// persisted preference, not permission to upload into a newly selected
  /// iCloud account. A new account still requires setOptedIn(true).
  @objc(configureWithLibraryRootPath:optedIn:)
  public func configure(libraryRootPath: NSString, optedIn: Bool) {
    let rootPath = libraryRootPath as String
    bumpGeneration()
    finishPendingRequests(error: makeError(.cancelled, "Cloud sync configuration changed."))
    clearTransientIdentityState()
    workQueue.async { [weak self] in
      guard let self else { return }
      self.libraryRootURL = URL(fileURLWithPath: rootPath, isDirectory: true).standardizedFileURL
      self.accessOptedIn = optedIn
      self.loadedAccountFingerprint = nil
      self.deviceState = nil
      self.automaticDownloadRetryCount = 0
      self.clearTransientIdentityState()
      self.refreshAccessStatus()
    }
  }

  /// This is the explicit opt-in/opt-out entry point. Opting in records the
  /// current ubiquity identity so a later account switch cannot upload silently.
  @objc(setOptedIn:completion:)
  public func setOptedIn(_ optedIn: Bool, completion: ((NSError?) -> Void)? = nil) {
    bumpGeneration()
    finishPendingRequests(error: makeError(.cancelled, "The iCloud sync setting changed."))
    clearTransientIdentityState()
    workQueue.async { [weak self] in
      guard let self else { return }
      if !optedIn {
        self.accessOptedIn = false
        self.defaults.removeObject(forKey: Self.consentedAccountDefaultsKey)
        self.loadedAccountFingerprint = nil
        self.deviceState = nil
        self.automaticDownloadRetryCount = 0
        self.clearTransientIdentityState()
        self.finishPendingRequests(error: self.makeError(.cancelled, "iCloud sync was turned off."))
        self.publish(status: .disabled,
                     message: "iCloud sync is off.",
                     error: nil,
                     enabled: false,
                     syncing: false)
        self.callOnMain { completion?(nil) }
        return
      }

      guard self.libraryRootURL != nil else {
        let error = self.makeError(.notConfigured, "The comic library has not been configured.")
        self.publish(status: .failed, message: error.localizedDescription, error: error, enabled: false)
        self.callOnMain { completion?(error) }
        return
      }
      do {
        let fingerprint = try self.currentAccountFingerprint()
        guard FileManager.default.url(forUbiquityContainerIdentifier: Self.ubiquityContainerIdentifier) != nil else {
          throw self.makeError(.iCloudUnavailable, "The ComicReader iCloud Drive container is unavailable.")
        }
        self.defaults.set(fingerprint, forKey: Self.consentedAccountDefaultsKey)
        self.accessOptedIn = true
        self.loadedAccountFingerprint = nil
        self.deviceState = nil
        self.automaticDownloadRetryCount = 0
        self.clearTransientIdentityState()
        self.publish(status: .ready, message: "Ready to sync with iCloud.", error: nil, enabled: true)
        self.callOnMain { completion?(nil) }
      } catch let error as NSError {
        self.accessOptedIn = false
        self.publishForAccessError(error)
        self.callOnMain { completion?(error) }
      }
    }
  }

  /// Coalesces snapshots submitted before a run starts. A snapshot contains
  /// dictionaries using the exported keys above. Completion always runs on main.
  @objc(synchronizeLibrarySnapshot:completion:)
  public func synchronizeLibrarySnapshot(_ snapshot: NSArray,
                                         completion: ((NSDictionary?, NSError?) -> Void)? = nil) {
    var shouldSchedule = false
    requestLock.lock()
    pendingSnapshot = snapshot.copy() as? NSArray ?? snapshot
    latestSnapshotForRetry = pendingSnapshot
    if let completion { pendingSyncCompletions.append(completion) }
    if !workerScheduled {
      workerScheduled = true
      shouldSchedule = true
    }
    requestLock.unlock()
    if shouldSchedule {
      workQueue.async { [weak self] in self?.drainSyncRequests() }
    }
  }

  /// Call for reader page changes, completion, rewind, mark-read, and mark-new.
  /// Supplying readingUpdatedAt and a fresh mutation ID is preferred; absent
  /// values are generated here on the serial queue.
  @objc(recordReadingStateForComic:completion:)
  public func recordReadingState(forComic comic: NSDictionary,
                                 completion: ((NSError?) -> Void)? = nil) {
    let comicBox = CRCloudUncheckedSendableBox(comic.copy() as? NSDictionary ?? comic)
    let requestedGeneration = generationValue()
    var provisionalIdentifier = stringValue(comic[Self.contentIdentifierKey])
    if provisionalIdentifier == nil, let path = stringValue(comic[Self.localPathKey]) {
      identityLock.lock()
      provisionalIdentifier = identityByLocalPath[URL(fileURLWithPath: path).standardizedFileURL.path]
      identityLock.unlock()
    }
    if let identifier = stringValue(comic[Self.contentIdentifierKey]),
       let normalized = CRCloudSyncPathPolicy.normalizedContentIdentifier(identifier),
       let provisional = readingRecord(from: comic,
                                       contentIdentifier: normalized,
                                       deviceIdentifier: deviceIdentifier,
                                       forceNewMutation: true) {
      pendingReadingLock.lock()
      if let existing = pendingReadingOverrides[normalized] {
        pendingReadingOverrides[normalized] = CRCloudReadingStateRecord.preferred(existing, provisional)
      } else {
        pendingReadingOverrides[normalized] = provisional
      }
      pendingReadingLock.unlock()
    }

    workQueue.async { [weak self] in
      guard let self else { return }
      do {
        let generation = requestedGeneration
        try self.checkGeneration(generation)
        let access = try self.prepareAccess(generation: generation)
        var state = try self.loadDeviceState(for: access.accountFingerprint)
        let comic = comicBox.value
        let prepared = try self.prepareSingleComicDictionary(comic,
                                                             state: &state,
                                                             generation: generation)
        if let provisionalIdentifier, provisionalIdentifier != prepared.contentIdentifier {
          self.pendingReadingLock.lock()
          self.pendingReadingOverrides.removeValue(forKey: provisionalIdentifier)
          self.pendingReadingLock.unlock()
        }
        guard var record = self.readingRecord(from: comic,
                                              contentIdentifier: prepared.contentIdentifier,
                                              deviceIdentifier: state.deviceIdentifier,
                                              forceNewMutation: true) else {
          throw self.makeError(.invalidSnapshot, "The reading-state dictionary is incomplete.")
        }
        self.identityLock.lock()
        self.identityByLocalPath[prepared.localURL.path] = prepared.contentIdentifier
        self.identityLock.unlock()
        self.pendingReadingLock.lock()
        if let newestPending = self.pendingReadingOverrides[prepared.contentIdentifier] {
          record = CRCloudReadingStateRecord.preferred(record, newestPending)
        }
        self.pendingReadingLock.unlock()
        if let existing = state.readingStatesByContentIdentifier[prepared.contentIdentifier] {
          let winner = CRCloudReadingStateRecord.preferred(existing.record, record)
          if winner != record {
            self.callOnMain { completion?(nil) }
            return
          }
          if winner == existing.record,
             existing.uploadedMutationIdentifier == existing.record.mutationIdentifier {
            self.callOnMain { completion?(nil) }
            return
          }
        }
        state.readingStatesByContentIdentifier[prepared.contentIdentifier] =
          CRCloudStoredReadingState(record: record,
                                    uploadedMutationIdentifier: nil,
                                    awaitingAdapterApply: false)
        self.deviceState = state
        try self.persistDeviceState(state)
        self.pendingReadingLock.lock()
        self.pendingReadingOverrides[prepared.contentIdentifier] = record
        self.pendingReadingLock.unlock()
        try self.uploadReadingRecord(record, access: access, generation: generation)
        state.readingStatesByContentIdentifier[prepared.contentIdentifier]?.uploadedMutationIdentifier = record.mutationIdentifier
        self.deviceState = state
        try self.persistDeviceState(state)
        self.pendingReadingLock.lock()
        if self.pendingReadingOverrides[prepared.contentIdentifier]?.mutationIdentifier == record.mutationIdentifier {
          self.pendingReadingOverrides.removeValue(forKey: prepared.contentIdentifier)
        }
        self.pendingReadingLock.unlock()
        self.publish(status: .ready, message: "Reading position synced.", error: nil, enabled: true)
        self.callOnMain { completion?(nil) }
      } catch let error as NSError {
        self.publishForOperationalError(error)
        self.callOnMain { completion?(error) }
      }
    }
  }

  /// Returns the identity learned during the most recent snapshot. The adapter
  /// can persist this beside its exact-page metadata and avoid re-hashing.
  @objc(contentIdentifierForLocalPath:)
  public func contentIdentifier(forLocalPath localPath: NSString) -> NSString? {
    identityLock.lock()
    let identifier = identityByLocalPath[URL(fileURLWithPath: localPath as String).standardizedFileURL.path]
    identityLock.unlock()
    return identifier as NSString?
  }

  /// Call immediately before or after a successful local file deletion. The
  /// cached path-to-hash mapping survives after the file itself is gone.
  @objc(removeLocalComicFromSyncWithLocalPath:)
  public func removeLocalComicFromSync(withLocalPath localPath: NSString) {
    bumpGeneration()
    finishPendingRequests(error: makeError(.cancelled, "The local comic was removed."))
    let standardizedPath = URL(fileURLWithPath: localPath as String).standardizedFileURL.path
    identityLock.lock()
    let cachedIdentifier = identityByLocalPath[standardizedPath]
    identityLock.unlock()
    workQueue.async { [weak self] in
      guard let self, let root = self.libraryRootURL else { return }
      let rootPath = root.standardizedFileURL.path
      guard standardizedPath.hasPrefix(rootPath + "/") else { return }
      let relative = String(standardizedPath.dropFirst(rootPath.count + 1))
      if self.deviceState == nil,
         let fingerprint = try? self.currentAccountFingerprint() {
        self.deviceState = try? self.loadDeviceState(for: fingerprint)
      }
      let identifier = cachedIdentifier ?? self.deviceState?.fingerprintsByRelativePath[relative]?.contentIdentifier
      guard let identifier else { return }
      guard var state = self.deviceState else { return }
      state.locallySuppressedContentIdentifiers[identifier] = Date().timeIntervalSince1970
      self.deviceState = state
      try? self.persistDeviceState(state)
    }
  }

  /// A local deletion only suppresses this identity on this installation. It
  /// never deletes cloud data and therefore cannot surprise another device.
  @objc(suppressRemoteComicWithContentIdentifier:)
  public func suppressRemoteComic(withContentIdentifier identifier: NSString) {
    guard let normalized = CRCloudSyncPathPolicy.normalizedContentIdentifier(identifier as String) else { return }
    bumpGeneration()
    finishPendingRequests(error: makeError(.cancelled, "The local comic was removed."))
    workQueue.async { [weak self] in
      guard let self else { return }
      if self.deviceState == nil,
         let fingerprint = try? self.currentAccountFingerprint() {
        self.deviceState = try? self.loadDeviceState(for: fingerprint)
      }
      guard var state = self.deviceState else { return }
      state.locallySuppressedContentIdentifiers[normalized] = Date().timeIntervalSince1970
      self.deviceState = state
      try? self.persistDeviceState(state)
    }
  }

  @objc(clearLocalSuppressionForContentIdentifier:)
  public func clearLocalSuppression(forContentIdentifier identifier: NSString) {
    guard let normalized = CRCloudSyncPathPolicy.normalizedContentIdentifier(identifier as String) else { return }
    workQueue.async { [weak self] in
      guard let self else { return }
      if self.deviceState == nil,
         let fingerprint = try? self.currentAccountFingerprint() {
        self.deviceState = try? self.loadDeviceState(for: fingerprint)
      }
      guard var state = self.deviceState else { return }
      state.locallySuppressedContentIdentifiers.removeValue(forKey: normalized)
      self.deviceState = state
      try? self.persistDeviceState(state)
    }
  }

  /// The app should expose this only behind a distinct "Delete from iCloud"
  /// user action. A durable cloud tombstone prevents another device re-uploading.
  @objc(deleteComicEverywhereWithContentIdentifier:completion:)
  public func deleteComicEverywhere(withContentIdentifier identifier: NSString,
                                    completion: ((NSError?) -> Void)? = nil) {
    guard let normalized = CRCloudSyncPathPolicy.normalizedContentIdentifier(identifier as String) else {
      callOnMain { completion?(self.makeError(.invalidSnapshot, "The comic identifier is invalid.")) }
      return
    }
    let requestedGeneration = generationValue()
    workQueue.async { [weak self] in
      guard let self else { return }
      do {
        let generation = requestedGeneration
        try self.checkGeneration(generation)
        let access = try self.prepareAccess(generation: generation)
        let deletion = CRCloudDeletionRecord(contentIdentifier: normalized,
                                             deletedAt: Date().timeIntervalSince1970,
                                             deviceIdentifier: self.deviceIdentifier)
        try self.writeJSON(deletion, to: self.deletionURL(for: normalized, access: access))
        // Manifest removal hides the item. Blob/state cleanup is best effort;
        // the durable tombstone remains the source of truth if cleanup is partial.
        try? self.coordinatedRemove(self.manifestURL(for: normalized, access: access))
        try? self.coordinatedRemove(self.comicDirectoryURL(for: normalized, access: access))
        try? self.coordinatedRemove(self.readingDirectoryURL(for: normalized, access: access))
        self.callOnMain { completion?(nil) }
      } catch let error as NSError {
        self.publishForOperationalError(error)
        self.callOnMain { completion?(error) }
      }
    }
  }

  public func cancel() {
    bumpGeneration()
    finishPendingRequests(error: makeError(.cancelled, "iCloud sync was cancelled."))
    workQueue.async { [weak self] in
      guard let self else { return }
      self.finishPendingRequests(error: self.makeError(.cancelled, "iCloud sync was cancelled."))
      self.refreshAccessStatus()
    }
  }

  // MARK: Private state

  private struct ViewState {
    var configured = false
    var optedIn = false
    var enabled = false
    var isSyncing = false
    var status: CRCloudSyncStatus = .disabled
    var statusMessage = "iCloud sync is off."
    var lastError: NSError?
    var lastSyncDate: Date?
  }

  struct AccessContext {
    let accountFingerprint: String
    let containerURL: URL
    let syncRootURL: URL
  }

  struct SnapshotComic {
    let localURL: URL
    let relativePath: String
    let suppliedContentIdentifier: String?
    let dictionary: NSDictionary
  }

  struct PreparedComic {
    let localURL: URL
    let relativePath: String
    let contentIdentifier: String
    let contentSHA256: String
    let fileSize: Int64
    let modificationTime: TimeInterval
    let dictionary: NSDictionary
  }

  struct SyncOutcome {
    var uploadedCount = 0
    var identifiedComics: [NSDictionary] = []
    var importedComics: [NSDictionary] = []
    var readingStates: [NSDictionary] = []
    var pendingDownloadCount = 0
    var waitingForMetadata = false
    var remoteDeletionIdentifiers: [String] = []
    var partialErrors: [NSError] = []

    var resultDictionary: NSDictionary {
      [CRCloudSyncManager.resultUploadedCountKey: uploadedCount,
       CRCloudSyncManager.resultIdentifiedComicsKey: identifiedComics,
       CRCloudSyncManager.resultImportedComicsKey: importedComics,
       CRCloudSyncManager.resultReadingStatesKey: readingStates,
       CRCloudSyncManager.resultPendingDownloadCountKey: pendingDownloadCount,
       CRCloudSyncManager.resultRemoteDeletionIdentifiersKey: remoteDeletionIdentifiers,
       CRCloudSyncManager.resultPartialErrorsKey: partialErrors]
    }
  }

  private static let consentedAccountDefaultsKey = "CRCloudSync.consentedAccountFingerprint.v1"
  private static let deviceIdentifierDefaultsKey = "CRCloudSync.deviceIdentifier.v1"

  private let workQueue = DispatchQueue(label: "com.pabloclementeperez.ComicFlow.cloud-sync", qos: .utility)
  private let viewLock = NSLock()
  private var viewState = ViewState()
  private let generationLock = NSLock()
  private var cancellationGeneration = 0
  private let requestLock = NSLock()
  private var pendingSnapshot: NSArray?
  private var latestSnapshotForRetry: NSArray?
  private var pendingSyncCompletions: [(NSDictionary?, NSError?) -> Void] = []
  private var workerScheduled = false
  private let pendingReadingLock = NSLock()
  private var pendingReadingOverrides: [String: CRCloudReadingStateRecord] = [:]
  private let identityLock = NSLock()
  private var identityByLocalPath: [String: String] = [:]

  private let defaults = UserDefaults.standard
  private let deviceIdentifier: String
  private var libraryRootURL: URL?
  private var accessOptedIn = false
  private var loadedAccountFingerprint: String?
  private var deviceState: CRCloudDeviceState?
  private var automaticDownloadRetryCount = 0
  private var downloadRetrySerial = 0
#if CR_CLOUD_SYNC_TESTING
  private var testingStateRootURL: URL?
  private var testingFingerprintState: CRCloudDeviceState?
#endif

  private override init() {
    if let stored = UserDefaults.standard.string(forKey: Self.deviceIdentifierDefaultsKey), !stored.isEmpty {
      deviceIdentifier = stored
    } else {
      let created = UUID().uuidString.lowercased()
      UserDefaults.standard.set(created, forKey: Self.deviceIdentifierDefaultsKey)
      deviceIdentifier = created
    }
    super.init()
    NotificationCenter.default.addObserver(self,
                                           selector: #selector(ubiquityIdentityDidChange(_:)),
                                           name: Notification.Name("NSUbiquityIdentityDidChangeNotification"),
                                           object: nil)
  }

  deinit { NotificationCenter.default.removeObserver(self) }

  @objc private func ubiquityIdentityDidChange(_ notification: Notification) {
    bumpGeneration()
    finishPendingRequests(error: makeError(.accountChanged,
                                           "The iCloud account changed. Confirm sync again for this account."))
    clearTransientIdentityState()
    workQueue.async { [weak self] in
      guard let self else { return }
      self.loadedAccountFingerprint = nil
      self.deviceState = nil
      self.automaticDownloadRetryCount = 0
      self.clearTransientIdentityState()
      self.finishPendingRequests(error: self.makeError(.accountChanged,
                                                       "The iCloud account changed. Confirm sync again for this account."))
      self.refreshAccessStatus()
    }
  }

  private func viewValue<T>(_ body: (ViewState) -> T) -> T {
    viewLock.lock()
    defer { viewLock.unlock() }
    return body(viewState)
  }

  private func publish(status: CRCloudSyncStatus,
                       message: String,
                       error: NSError?,
                       enabled: Bool,
                       syncing: Bool = false,
                       lastSyncDate: Date? = nil) {
    viewLock.lock()
    let old = viewState
    viewState.configured = libraryRootURL != nil
    viewState.optedIn = accessOptedIn
    viewState.enabled = enabled
    viewState.isSyncing = syncing
    viewState.status = status
    viewState.statusMessage = message
    viewState.lastError = error
    if let lastSyncDate { viewState.lastSyncDate = lastSyncDate }
    let changed = old.status != viewState.status || old.isSyncing != viewState.isSyncing ||
      old.enabled != viewState.enabled || old.statusMessage != viewState.statusMessage ||
      old.lastError?.domain != viewState.lastError?.domain || old.lastError?.code != viewState.lastError?.code
    viewLock.unlock()
    if changed {
      callOnMain {
        NotificationCenter.default.post(name: Notification.Name(Self.statusDidChangeNotification), object: self)
      }
    }
  }

  private func callOnMain(_ block: @escaping () -> Void) {
    if Thread.isMainThread { block() } else { DispatchQueue.main.async(execute: block) }
  }

  private func generationValue() -> Int {
    generationLock.lock()
    defer { generationLock.unlock() }
    return cancellationGeneration
  }

  @discardableResult
  private func bumpGeneration() -> Int {
    generationLock.lock()
    cancellationGeneration += 1
    let result = cancellationGeneration
    generationLock.unlock()
    return result
  }

  private func checkGeneration(_ expected: Int) throws {
    guard generationValue() == expected else {
      throw makeError(.cancelled, "iCloud sync was cancelled.")
    }
  }

  private func clearTransientIdentityState() {
    pendingReadingLock.lock()
    pendingReadingOverrides.removeAll()
    pendingReadingLock.unlock()
    identityLock.lock()
    identityByLocalPath.removeAll()
    identityLock.unlock()
  }
}

// MARK: - Access, persistence, and request scheduling

private extension CRCloudSyncManager {
  func makeError(_ code: CRCloudSyncErrorCode,
                 _ description: String,
                 underlying: Error? = nil,
                 path: String? = nil) -> NSError {
    var userInfo: [String: Any] = [NSLocalizedDescriptionKey: description]
    if let underlying { userInfo[NSUnderlyingErrorKey] = underlying }
    if let path { userInfo[NSFilePathErrorKey] = path }
    return NSError(domain: Self.errorDomain, code: code.rawValue, userInfo: userInfo)
  }

  func currentAccountFingerprint() throws -> String {
    guard let token = FileManager.default.ubiquityIdentityToken else {
      throw makeError(.iCloudUnavailable,
                      "Sign in to iCloud and enable iCloud Drive to sync comics.")
    }
    do {
      let data = try NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: false)
      return Self.sha256Hex(data)
    } catch {
      throw makeError(.iCloudUnavailable,
                      "ComicReader could not identify the current iCloud account.",
                      underlying: error)
    }
  }

  func prepareAccess(generation: Int) throws -> AccessContext {
    try checkGeneration(generation)
    guard libraryRootURL != nil else {
      throw makeError(.notConfigured, "The comic library has not been configured.")
    }
    guard accessOptedIn else {
      throw makeError(.optInRequired, "Turn on iCloud sync before synchronizing comics.")
    }
    let fingerprint = try currentAccountFingerprint()
    guard defaults.string(forKey: Self.consentedAccountDefaultsKey) == fingerprint else {
      throw makeError(.accountChanged,
                      "The iCloud account changed. Confirm sync again for this account.")
    }
    guard let containerURL = FileManager.default.url(forUbiquityContainerIdentifier: Self.ubiquityContainerIdentifier) else {
      throw makeError(.iCloudUnavailable, "The ComicReader iCloud Drive container is unavailable.")
    }
    try checkGeneration(generation)
    guard try currentAccountFingerprint() == fingerprint else {
      throw makeError(.accountChanged, "The iCloud account changed while syncing.")
    }

    let syncRootURL = containerURL
      .appendingPathComponent("Documents", isDirectory: true)
      .appendingPathComponent("ComicReaderSync", isDirectory: true)
      .appendingPathComponent("v1", isDirectory: true)
    do {
      for url in [syncRootURL,
                  syncRootURL.appendingPathComponent("comics", isDirectory: true),
                  syncRootURL.appendingPathComponent("manifests", isDirectory: true),
                  syncRootURL.appendingPathComponent("reading", isDirectory: true),
                  syncRootURL.appendingPathComponent("deletions", isDirectory: true)] {
        try FileManager.default.createDirectory(at: url,
                                                withIntermediateDirectories: true,
                                                attributes: nil)
      }
    } catch {
      throw mappedFileError(error, action: "prepare the iCloud sync folder", path: syncRootURL.path)
    }
    return AccessContext(accountFingerprint: fingerprint,
                         containerURL: containerURL,
                         syncRootURL: syncRootURL)
  }

  func refreshAccessStatus() {
    guard libraryRootURL != nil else {
      publish(status: .disabled,
              message: "The comic library has not been configured.",
              error: nil,
              enabled: false)
      return
    }
    guard accessOptedIn else {
      publish(status: .disabled, message: "iCloud sync is off.", error: nil, enabled: false)
      return
    }
    do {
      let fingerprint = try currentAccountFingerprint()
      guard defaults.string(forKey: Self.consentedAccountDefaultsKey) == fingerprint else {
        publish(status: .accountChanged,
                message: "The iCloud account changed. Confirm sync again for this account.",
                error: nil,
                enabled: false)
        return
      }
      guard FileManager.default.url(forUbiquityContainerIdentifier: Self.ubiquityContainerIdentifier) != nil else {
        throw makeError(.iCloudUnavailable, "The ComicReader iCloud Drive container is unavailable.")
      }
      publish(status: .ready, message: "Ready to sync with iCloud.", error: nil, enabled: true)
    } catch let error as NSError {
      publishForAccessError(error)
    }
  }

  func publishForAccessError(_ error: NSError) {
    let code = CRCloudSyncErrorCode(rawValue: error.code)
    let status: CRCloudSyncStatus
    switch code {
    case .optInRequired: status = .optInRequired
    case .iCloudUnavailable: status = .iCloudUnavailable
    case .accountChanged: status = .accountChanged
    default: status = .failed
    }
    publish(status: status,
            message: error.localizedDescription,
            error: error,
            enabled: false,
            syncing: false)
  }

  func publishForOperationalError(_ error: NSError) {
    if error.domain == Self.errorDomain {
      switch CRCloudSyncErrorCode(rawValue: error.code) {
      case .notConfigured, .optInRequired, .iCloudUnavailable, .accountChanged:
        publishForAccessError(error)
        return
      case .quotaExceeded:
        publish(status: .quotaExceeded,
                message: error.localizedDescription,
                error: error,
                enabled: true,
                syncing: false)
        return
      case .cancelled:
        refreshAccessStatus()
        return
      default: break
      }
    }
    if isNetworkError(error) {
      publish(status: .waitingForNetwork,
              message: "Sync will continue when iCloud is reachable.",
              error: error,
              enabled: true,
              syncing: false)
    } else if isQuotaError(error) {
      publish(status: .quotaExceeded,
              message: "iCloud storage is full. Free some space to continue syncing.",
              error: error,
              enabled: true,
              syncing: false)
    } else {
      publish(status: .failed,
              message: error.localizedDescription,
              error: error,
              enabled: true,
              syncing: false)
    }
  }

  func mappedFileError(_ error: Error, action: String, path: String) -> NSError {
    let nsError = error as NSError
    if isQuotaError(nsError) {
      return makeError(.quotaExceeded,
                       "iCloud storage is full. ComicReader could not \(action).",
                       underlying: error,
                       path: path)
    }
    return NSError(domain: nsError.domain,
                   code: nsError.code,
                   userInfo: [NSLocalizedDescriptionKey: "ComicReader could not \(action).",
                              NSUnderlyingErrorKey: nsError,
                              NSFilePathErrorKey: path])
  }

  func isQuotaError(_ error: NSError) -> Bool {
    if error.domain == NSCocoaErrorDomain &&
        (error.code == CocoaError.fileWriteOutOfSpace.rawValue || error.code == 4_354) {
      return true
    }
    if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
      return isQuotaError(underlying)
    }
    return false
  }

  func isNetworkError(_ error: NSError) -> Bool {
    if error.domain == NSURLErrorDomain {
      return [NSURLErrorNotConnectedToInternet,
              NSURLErrorNetworkConnectionLost,
              NSURLErrorTimedOut,
              NSURLErrorCannotFindHost,
              NSURLErrorCannotConnectToHost].contains(error.code)
    }
    if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
      return isNetworkError(underlying)
    }
    return false
  }

  func stateFileURL(for accountFingerprint: String) throws -> URL {
#if CR_CLOUD_SYNC_TESTING
    if let testingStateRootURL {
      let directory = testingStateRootURL.appendingPathComponent(accountFingerprint, isDirectory: true)
      try FileManager.default.createDirectory(at: directory,
                                              withIntermediateDirectories: true,
                                              attributes: nil)
      return directory.appendingPathComponent("device-state.json", isDirectory: false)
    }
#endif
    guard let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory,
                                                            in: .userDomainMask).first else {
      throw makeError(.metadataUnavailable, "Application Support is unavailable.")
    }
    let directory = applicationSupport
      .appendingPathComponent("ComicReader", isDirectory: true)
      .appendingPathComponent("CloudSync", isDirectory: true)
      .appendingPathComponent("v1", isDirectory: true)
      .appendingPathComponent(accountFingerprint, isDirectory: true)
    try FileManager.default.createDirectory(at: directory,
                                            withIntermediateDirectories: true,
                                            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
    return directory.appendingPathComponent("device-state.json", isDirectory: false)
  }

  func loadDeviceState(for accountFingerprint: String) throws -> CRCloudDeviceState {
    if loadedAccountFingerprint == accountFingerprint, let deviceState { return deviceState }
    let url = try stateFileURL(for: accountFingerprint)
    let state: CRCloudDeviceState
    if FileManager.default.fileExists(atPath: url.path) {
      do {
        let decoded = try JSONDecoder().decode(CRCloudDeviceState.self, from: Data(contentsOf: url))
        if decoded.schemaVersion == 1 && decoded.accountFingerprint == accountFingerprint {
          state = decoded
        } else {
          state = CRCloudDeviceState(deviceIdentifier: deviceIdentifier,
                                     accountFingerprint: accountFingerprint)
        }
      } catch {
        let recoveryURL = url.deletingPathExtension()
          .appendingPathExtension("unreadable-\(Int(Date().timeIntervalSince1970)).json")
        try? FileManager.default.moveItem(at: url, to: recoveryURL)
        state = CRCloudDeviceState(deviceIdentifier: deviceIdentifier,
                                   accountFingerprint: accountFingerprint)
      }
    } else {
      state = CRCloudDeviceState(deviceIdentifier: deviceIdentifier,
                                 accountFingerprint: accountFingerprint)
    }
    var normalized = state
    normalized.deviceIdentifier = deviceIdentifier
    loadedAccountFingerprint = accountFingerprint
    deviceState = normalized
    return normalized
  }

  func persistDeviceState(_ state: CRCloudDeviceState) throws {
    let url = try stateFileURL(for: state.accountFingerprint)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    do {
      let data = try encoder.encode(state)
      try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    } catch {
      throw mappedFileError(error, action: "save local sync state", path: url.path)
    }
  }

  func drainSyncRequests() {
    while true {
      requestLock.lock()
      guard let snapshot = pendingSnapshot else {
        workerScheduled = false
        requestLock.unlock()
        return
      }
      pendingSnapshot = nil
      let completions = pendingSyncCompletions
      pendingSyncCompletions.removeAll()
      requestLock.unlock()

      let generation = generationValue()
      publish(status: .syncing,
              message: "Syncing comics with iCloud…",
              error: nil,
              enabled: true,
              syncing: true)
      do {
        let outcome = try performSync(snapshot: snapshot, generation: generation)
        let now = Date()
        if outcome.pendingDownloadCount > 0 {
          publish(status: .downloading,
                  message: outcome.waitingForMetadata
                    ? "Waiting for iCloud metadata…"
                    : outcome.pendingDownloadCount == 1
                    ? "Downloading 1 comic from iCloud…"
                    : "Downloading \(outcome.pendingDownloadCount) comics from iCloud…",
                  error: outcome.partialErrors.first,
                  enabled: true,
                  syncing: false,
                  lastSyncDate: now)
        } else if let networkError = outcome.partialErrors.first(where: { isNetworkError($0) }) {
          publish(status: .waitingForNetwork,
                  message: "Sync will continue when iCloud is reachable.",
                  error: networkError,
                  enabled: true,
                  syncing: false,
                  lastSyncDate: now)
        } else if let quotaError = outcome.partialErrors.first(where: { isQuotaError($0) }) {
          publish(status: .quotaExceeded,
                  message: "iCloud storage is full. Free some space to continue syncing.",
                  error: quotaError,
                  enabled: true,
                  syncing: false,
                  lastSyncDate: now)
        } else if let partialError = outcome.partialErrors.first {
          publish(status: .failed,
                  message: "Some iCloud items could not be synchronized.",
                  error: partialError,
                  enabled: true,
                  syncing: false,
                  lastSyncDate: now)
        } else {
          publish(status: .ready,
                  message: "Synced with iCloud.",
                  error: nil,
                  enabled: true,
                  syncing: false,
                  lastSyncDate: now)
        }
        emitOutcomeNotifications(outcome)
        callOnMain { completions.forEach { $0(outcome.resultDictionary, nil) } }
        if outcome.pendingDownloadCount > 0 {
          scheduleDownloadRetry(generation: generation)
        } else {
          automaticDownloadRetryCount = 0
          downloadRetrySerial += 1
        }
      } catch let error as NSError {
        publishForOperationalError(error)
        callOnMain { completions.forEach { $0(nil, error) } }
        if shouldAbort(for: error) {
          stopDrainingRequests(error: error)
          return
        }
      }
    }
  }

  func finishPendingRequests(error: NSError) {
    requestLock.lock()
    pendingSnapshot = nil
    latestSnapshotForRetry = nil
    let completions = pendingSyncCompletions
    pendingSyncCompletions.removeAll()
    requestLock.unlock()
    callOnMain { completions.forEach { $0(nil, error) } }
  }

  func stopDrainingRequests(error: NSError) {
    requestLock.lock()
    pendingSnapshot = nil
    latestSnapshotForRetry = nil
    let completions = pendingSyncCompletions
    pendingSyncCompletions.removeAll()
    workerScheduled = false
    requestLock.unlock()
    callOnMain { completions.forEach { $0(nil, error) } }
  }

  func scheduleDownloadRetry(generation: Int) {
    guard automaticDownloadRetryCount < 5 else { return }
    automaticDownloadRetryCount += 1
    downloadRetrySerial += 1
    let retrySerial = downloadRetrySerial
    workQueue.asyncAfter(deadline: .now() + 12) { [weak self] in
      guard let self,
            self.generationValue() == generation,
            self.downloadRetrySerial == retrySerial else { return }
      self.requestLock.lock()
      let newestSnapshot = self.latestSnapshotForRetry
      self.requestLock.unlock()
      if let newestSnapshot {
        self.synchronizeLibrarySnapshot(newestSnapshot, completion: nil)
      }
    }
  }

  func emitOutcomeNotifications(_ outcome: SyncOutcome) {
    if !outcome.importedComics.isEmpty {
      callOnMain {
        NotificationCenter.default.post(name: Notification.Name(Self.importedComicsNotification),
                                        object: self,
                                        userInfo: [Self.resultImportedComicsKey: outcome.importedComics])
      }
    }
    if !outcome.readingStates.isEmpty {
      callOnMain {
        NotificationCenter.default.post(name: Notification.Name(Self.readingStateDidChangeNotification),
                                        object: self,
                                        userInfo: [Self.resultReadingStatesKey: outcome.readingStates])
      }
    }
    if !outcome.remoteDeletionIdentifiers.isEmpty {
      callOnMain {
        NotificationCenter.default.post(name: Notification.Name(Self.remoteDeletionsNotification),
                                        object: self,
                                        userInfo: [Self.resultRemoteDeletionIdentifiersKey:
                                                    outcome.remoteDeletionIdentifiers])
      }
    }
  }
}

// MARK: - Snapshot preparation and identities

private extension CRCloudSyncManager {
  static func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  func cloudKey(for contentIdentifier: String) -> String {
    Self.sha256Hex(Data(contentIdentifier.utf8))
  }

  func prepareSnapshot(_ snapshot: NSArray,
                       state: inout CRCloudDeviceState,
                       generation: Int) throws -> [PreparedComic] {
    guard let rootURL = libraryRootURL else {
      throw makeError(.notConfigured, "The comic library has not been configured.")
    }
    var result: [PreparedComic] = []
    var seenPaths = Set<String>()
    for case let dictionary as NSDictionary in snapshot {
      try checkGeneration(generation)
      guard let localPath = stringValue(dictionary[Self.localPathKey]),
            let validated = CRCloudSyncPathPolicy.validatedLocalURL(
              localPath: localPath,
              relativePath: stringValue(dictionary[Self.relativePathKey]),
              libraryRootURL: rootURL) else {
        throw makeError(.unsafePath,
                        "A comic snapshot contains a path outside the library.",
                        path: stringValue(dictionary[Self.localPathKey]))
      }
      guard seenPaths.insert(validated.url.path).inserted else { continue }
      let suppliedIdentifier: String?
      if let raw = stringValue(dictionary[Self.contentIdentifierKey]) {
        guard let normalized = CRCloudSyncPathPolicy.normalizedContentIdentifier(raw) else {
          throw makeError(.invalidSnapshot, "A comic snapshot contains an invalid content identifier.")
        }
        suppliedIdentifier = normalized
      } else {
        suppliedIdentifier = nil
      }
      let item = SnapshotComic(localURL: validated.url,
                               relativePath: validated.relativePath,
                               suppliedContentIdentifier: suppliedIdentifier,
                               dictionary: dictionary)
      result.append(try prepareComic(item, state: &state, generation: generation))
    }
    if result.count != snapshot.count {
      // Non-dictionary values are rejected instead of being silently ignored.
      let dictionaryCount = snapshot.compactMap { $0 as? NSDictionary }.count
      if dictionaryCount != snapshot.count {
        throw makeError(.invalidSnapshot, "The library snapshot must contain dictionaries only.")
      }
    }
    return result
  }

  func prepareSingleComicDictionary(_ dictionary: NSDictionary,
                                    state: inout CRCloudDeviceState,
                                    generation: Int) throws -> PreparedComic {
    guard let rootURL = libraryRootURL,
          let localPath = stringValue(dictionary[Self.localPathKey]),
          let validated = CRCloudSyncPathPolicy.validatedLocalURL(
            localPath: localPath,
            relativePath: stringValue(dictionary[Self.relativePathKey]),
            libraryRootURL: rootURL) else {
      throw makeError(.unsafePath,
                      "The comic path is outside the library.",
                      path: stringValue(dictionary[Self.localPathKey]))
    }
    let supplied: String?
    if let raw = stringValue(dictionary[Self.contentIdentifierKey]) {
      guard let normalized = CRCloudSyncPathPolicy.normalizedContentIdentifier(raw) else {
        throw makeError(.invalidSnapshot, "The comic identifier is invalid.")
      }
      supplied = normalized
    } else {
      supplied = nil
    }
    return try prepareComic(SnapshotComic(localURL: validated.url,
                                          relativePath: validated.relativePath,
                                          suppliedContentIdentifier: supplied,
                                          dictionary: dictionary),
                            state: &state,
                            generation: generation)
  }

  func prepareComic(_ comic: SnapshotComic,
                    state: inout CRCloudDeviceState,
                    generation: Int) throws -> PreparedComic {
    try checkGeneration(generation)
    let values: URLResourceValues
    do {
      values = try comic.localURL.resourceValues(forKeys: [.isRegularFileKey,
                                                           .isSymbolicLinkKey,
                                                           .fileSizeKey,
                                                           .contentModificationDateKey,
                                                           .creationDateKey,
                                                           .fileResourceIdentifierKey])
    } catch {
      throw makeError(.fileMissing,
                      "A comic is no longer available in the local library.",
                      underlying: error,
                      path: comic.localURL.path)
    }
    guard values.isRegularFile == true, values.isSymbolicLink != true else {
      throw makeError(.unsupportedFile,
                      "Only regular comic files can be synchronized.",
                      path: comic.localURL.path)
    }
    let fileSize = Int64(values.fileSize ?? 0)
    let modificationTime = values.contentModificationDate?.timeIntervalSince1970 ?? 0
    let creationTime = values.creationDate?.timeIntervalSince1970
    let resourceIdentifier = fileSystemIdentity(for: comic.localURL,
                                                resourceIdentifier: values.fileResourceIdentifier)

    let cached = state.fingerprintsByRelativePath[comic.relativePath]
    let cacheMatches = cached?.fileSize == fileSize &&
      cached?.modificationTime == modificationTime &&
      cached?.creationTime == creationTime &&
      cached?.fileResourceIdentifier != nil &&
      cached?.fileResourceIdentifier == resourceIdentifier &&
      (comic.suppliedContentIdentifier == nil ||
       cached?.contentIdentifier == comic.suppliedContentIdentifier)
    let contentSHA256: String
    if cacheMatches, let cached {
      contentSHA256 = cached.contentSHA256
    } else {
      contentSHA256 = try coordinatedSHA256(of: comic.localURL, generation: generation)
    }
    // Cloud identity is always the bytes' SHA-256. A supplied identifier is a
    // cache hint only; it must never alias replacement bytes to stale progress.
    let contentIdentifier = contentSHA256
    let fingerprint = CRCloudCachedFingerprint(relativePath: comic.relativePath,
                                               fileSize: fileSize,
                                               modificationTime: modificationTime,
                                               creationTime: creationTime,
                                               fileResourceIdentifier: resourceIdentifier,
                                               contentIdentifier: contentIdentifier,
                                               contentSHA256: contentSHA256)
    state.fingerprintsByRelativePath[comic.relativePath] = fingerprint
    // An explicit local re-import is the user's choice to make this identity
    // available again on this installation.
    state.locallySuppressedContentIdentifiers.removeValue(forKey: contentIdentifier)
    return PreparedComic(localURL: comic.localURL,
                         relativePath: comic.relativePath,
                         contentIdentifier: contentIdentifier,
                         contentSHA256: contentSHA256,
                         fileSize: fileSize,
                         modificationTime: modificationTime,
                         dictionary: comic.dictionary)
  }

  func coordinatedSHA256(of url: URL, generation: Int) throws -> String {
    let coordinator = NSFileCoordinator(filePresenter: nil)
    var coordinationError: NSError?
    var bodyError: Error?
    var digest = SHA256()
    coordinator.coordinate(readingItemAt: url, options: [.withoutChanges], error: &coordinationError) { coordinatedURL in
      do {
        let handle = try FileHandle(forReadingFrom: coordinatedURL)
        defer { try? handle.close() }
        while true {
          try self.checkGeneration(generation)
          let data = try handle.read(upToCount: 1_048_576) ?? Data()
          if data.isEmpty { break }
          digest.update(data: data)
        }
      } catch {
        bodyError = error
      }
    }
    if let bodyError { throw bodyError }
    if let coordinationError {
      throw mappedFileError(coordinationError, action: "read a local comic", path: url.path)
    }
    return digest.finalize().map { String(format: "%02x", $0) }.joined()
  }

  func fileSystemIdentity(for url: URL, resourceIdentifier value: Any?) -> String? {
    if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
       let system = attributes[.systemNumber] as? NSNumber,
       let file = attributes[.systemFileNumber] as? NSNumber {
      return "stat:\(system.uint64Value):\(file.uint64Value)"
    }
    if let data = value as? Data { return "resource:" + data.base64EncodedString() }
    if let data = value as? NSData { return "resource:" + (data as Data).base64EncodedString() }
    if let value,
       let archived = try? NSKeyedArchiver.archivedData(withRootObject: value,
                                                        requiringSecureCoding: false) {
      return "resource:" + Self.sha256Hex(archived)
    }
    return nil
  }

  func reconcileSnapshotReadingStates(_ comics: [PreparedComic],
                                      state: inout CRCloudDeviceState) {
    for comic in comics {
      guard let incoming = readingRecord(from: comic.dictionary,
                                         contentIdentifier: comic.contentIdentifier,
                                         deviceIdentifier: state.deviceIdentifier,
                                         forceNewMutation: false) else { continue }
      if var stored = state.readingStatesByContentIdentifier[comic.contentIdentifier] {
        if stored.record.hasSameReaderValue(as: incoming) {
          stored.awaitingAdapterApply = false
          state.readingStatesByContentIdentifier[comic.contentIdentifier] = stored
        } else if !stored.awaitingAdapterApply {
          let winner = CRCloudReadingStateRecord.preferred(stored.record, incoming)
          if winner == incoming {
            state.readingStatesByContentIdentifier[comic.contentIdentifier] =
              CRCloudStoredReadingState(record: incoming,
                                        uploadedMutationIdentifier: nil,
                                        awaitingAdapterApply: false)
          }
        }
      } else {
        state.readingStatesByContentIdentifier[comic.contentIdentifier] =
          CRCloudStoredReadingState(record: incoming,
                                    uploadedMutationIdentifier: nil,
                                    awaitingAdapterApply: false)
      }
    }
  }

  func readingRecord(from dictionary: NSDictionary,
                     contentIdentifier: String,
                     deviceIdentifier: String,
                     forceNewMutation: Bool) -> CRCloudReadingStateRecord? {
    let statusNumber = numberValue(dictionary[Self.legacyStatusKey]) ?? numberValue(dictionary["status"])
    let pageNumber = numberValue(dictionary[Self.currentPageKey]) ?? numberValue(dictionary["pageIndex"])
    guard statusNumber != nil || pageNumber != nil else { return nil }
    let legacyStatus = statusNumber?.intValue ?? 0
    let currentPage = pageNumber?.intValue ?? (legacyStatus > 0 ? legacyStatus : 0)
    let pageCount = (numberValue(dictionary[Self.pageCountKey]) ?? numberValue(dictionary["numberOfPages"]))?.intValue ?? 0
    let suppliedTimestamp = timestampValue(dictionary[Self.readingUpdatedAtKey]) ??
      timestampValue(dictionary["updatedAt"])
    let suppliedMutation = stringValue(dictionary[Self.readingMutationIdentifierKey]) ??
      stringValue(dictionary["mutationIdentifier"])
    // An unversioned first-run database snapshot is an epoch baseline. It seeds
    // an empty account but every real device event outranks it, so stale local
    // progress cannot overwrite an established cloud position.
    let isUnversionedBaseline = !forceNewMutation && suppliedTimestamp == nil && suppliedMutation == nil
    let modifiedAt = isUnversionedBaseline ? 1 : (suppliedTimestamp ?? Date().timeIntervalSince1970)
    let mutationIdentifier: String
    if let supplied = suppliedMutation.flatMap(CRCloudSyncPathPolicy.normalizedContentIdentifier) {
      mutationIdentifier = supplied
    } else if forceNewMutation {
      mutationIdentifier = UUID().uuidString.lowercased()
    } else {
      let stableInput = "\(contentIdentifier)|\(legacyStatus)|\(currentPage)|\(pageCount)|\(modifiedAt)"
      mutationIdentifier = Self.sha256Hex(Data(stableInput.utf8))
    }
    return CRCloudReadingStateRecord(contentIdentifier: contentIdentifier,
                                     legacyStatus: legacyStatus,
                                     currentPage: currentPage,
                                     pageCount: pageCount,
                                     modifiedAt: modifiedAt,
                                     mutationIdentifier: mutationIdentifier,
                                     deviceIdentifier: deviceIdentifier)
  }

  func readingDictionary(_ record: CRCloudReadingStateRecord) -> NSDictionary {
    [Self.contentIdentifierKey: record.contentIdentifier,
     Self.legacyStatusKey: record.legacyStatus,
     Self.currentPageKey: record.currentPage,
     Self.pageCountKey: record.pageCount,
     Self.readingUpdatedAtKey: Date(timeIntervalSince1970: record.modifiedAt),
     Self.readingMutationIdentifierKey: record.mutationIdentifier,
     Self.sourceDeviceIdentifierKey: record.deviceIdentifier]
  }

  func readingDictionaries(_ record: CRCloudReadingStateRecord,
                           state: CRCloudDeviceState) -> [NSDictionary] {
    let matchingPaths = state.fingerprintsByRelativePath.values
      .filter { $0.contentIdentifier == record.contentIdentifier }
      .map(\.relativePath)
      .sorted()
    guard let libraryRootURL, !matchingPaths.isEmpty else { return [readingDictionary(record)] }
    return matchingPaths.map { relativePath in
      let dictionary = NSMutableDictionary(dictionary: readingDictionary(record))
      dictionary[Self.relativePathKey] = relativePath
      dictionary[Self.localPathKey] = relativePath.split(separator: "/").reduce(libraryRootURL) {
        $0.appendingPathComponent(String($1), isDirectory: false)
      }.path
      return dictionary
    }
  }
}

// MARK: - Coordinated iCloud file operations

private extension CRCloudSyncManager {
  func manifestURL(for contentIdentifier: String, access: AccessContext) -> URL {
    keyedJSONURL(in: "manifests", contentIdentifier: contentIdentifier, access: access)
  }

  func deletionURL(for contentIdentifier: String, access: AccessContext) -> URL {
    keyedJSONURL(in: "deletions", contentIdentifier: contentIdentifier, access: access)
  }

  func readingRecordURL(for record: CRCloudReadingStateRecord, access: AccessContext) -> URL {
    readingDirectoryURL(for: record.contentIdentifier, access: access)
      .appendingPathComponent(cloudKey(for: record.deviceIdentifier) + ".json", isDirectory: false)
  }

  func comicDirectoryURL(for contentIdentifier: String, access: AccessContext) -> URL {
    let key = cloudKey(for: contentIdentifier)
    return access.syncRootURL
      .appendingPathComponent("comics", isDirectory: true)
      .appendingPathComponent(String(key.prefix(2)), isDirectory: true)
      .appendingPathComponent(key, isDirectory: true)
  }

  func readingDirectoryURL(for contentIdentifier: String, access: AccessContext) -> URL {
    let key = cloudKey(for: contentIdentifier)
    return access.syncRootURL
      .appendingPathComponent("reading", isDirectory: true)
      .appendingPathComponent(String(key.prefix(2)), isDirectory: true)
      .appendingPathComponent(key, isDirectory: true)
  }

  func keyedJSONURL(in directoryName: String,
                    contentIdentifier: String,
                    access: AccessContext) -> URL {
    let key = cloudKey(for: contentIdentifier)
    return access.syncRootURL
      .appendingPathComponent(directoryName, isDirectory: true)
      .appendingPathComponent(String(key.prefix(2)), isDirectory: true)
      .appendingPathComponent(key + ".json", isDirectory: false)
  }

  func blobURL(for manifest: CRCloudComicManifest, access: AccessContext) throws -> URL {
    guard CRCloudSyncPathPolicy.normalizedContentIdentifier(manifest.contentIdentifier) != nil,
          CRCloudSyncPathPolicy.safeCloudFileName(manifest.cloudFileName) == manifest.cloudFileName else {
      throw makeError(.integrityMismatch, "An iCloud comic manifest contains an unsafe path.")
    }
    let url = comicDirectoryURL(for: manifest.contentIdentifier, access: access)
      .appendingPathComponent(manifest.cloudFileName, isDirectory: false)
    guard CRCloudSyncPathPolicy.contains(url, within: access.syncRootURL) else {
      throw makeError(.unsafePath, "An iCloud comic path escaped the sync folder.", path: url.path)
    }
    return url
  }

  func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(value)
    try coordinatedWrite(data, to: url)
  }

  func coordinatedWrite(_ data: Data, to url: URL) throws {
    do {
      try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                              withIntermediateDirectories: true,
                                              attributes: nil)
    } catch {
      throw mappedFileError(error, action: "create an iCloud sync folder", path: url.path)
    }
    let coordinator = NSFileCoordinator(filePresenter: nil)
    var coordinationError: NSError?
    var bodyError: Error?
    coordinator.coordinate(writingItemAt: url, options: [.forReplacing], error: &coordinationError) { coordinatedURL in
      do { try data.write(to: coordinatedURL, options: .atomic) } catch { bodyError = error }
    }
    if let bodyError { throw mappedFileError(bodyError, action: "write iCloud metadata", path: url.path) }
    if let coordinationError {
      throw mappedFileError(coordinationError, action: "coordinate iCloud metadata", path: url.path)
    }
  }

  func coordinatedRead<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
    let coordinator = NSFileCoordinator(filePresenter: nil)
    var coordinationError: NSError?
    var bodyError: Error?
    var value: T?
    coordinator.coordinate(readingItemAt: url, options: [.withoutChanges], error: &coordinationError) { coordinatedURL in
      do { value = try JSONDecoder().decode(type, from: Data(contentsOf: coordinatedURL)) }
      catch { bodyError = error }
    }
    if let bodyError { throw bodyError }
    if let coordinationError {
      throw mappedFileError(coordinationError, action: "read iCloud metadata", path: url.path)
    }
    guard let value else { throw makeError(.metadataUnavailable, "iCloud metadata was empty.", path: url.path) }
    return value
  }

  func coordinatedRemove(_ url: URL) throws {
    guard FileManager.default.fileExists(atPath: url.path) else { return }
    let coordinator = NSFileCoordinator(filePresenter: nil)
    var coordinationError: NSError?
    var bodyError: Error?
    coordinator.coordinate(writingItemAt: url, options: [.forDeleting], error: &coordinationError) { coordinatedURL in
      do { try FileManager.default.removeItem(at: coordinatedURL) } catch { bodyError = error }
    }
    if let bodyError { throw mappedFileError(bodyError, action: "remove an iCloud item", path: url.path) }
    if let coordinationError {
      throw mappedFileError(coordinationError, action: "coordinate an iCloud deletion", path: url.path)
    }
  }

  func isAvailableLocally(_ url: URL) throws -> Bool {
    let keys: Set<URLResourceKey> = [.isUbiquitousItemKey,
                                     .ubiquitousItemDownloadingStatusKey,
                                     .ubiquitousItemDownloadingErrorKey]
    let values: URLResourceValues
    do { values = try url.resourceValues(forKeys: keys) }
    catch {
      if FileManager.default.fileExists(atPath: url.path) { return true }
      let nsError = error as NSError
      if nsError.domain == NSCocoaErrorDomain && nsError.code == CocoaError.fileNoSuchFile.rawValue {
        // A newly discovered iCloud document can briefly lack a local
        // placeholder. Asking FileManager to materialize it is safe and the
        // bounded retry loop will distinguish a transient delay from a bad item.
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        return false
      }
      throw mappedFileError(error, action: "inspect an iCloud item", path: url.path)
    }
    if let downloadError = values.ubiquitousItemDownloadingError { throw downloadError }
    guard values.isUbiquitousItem == true else {
      return FileManager.default.fileExists(atPath: url.path)
    }
    if values.ubiquitousItemDownloadingStatus == .current ||
        values.ubiquitousItemDownloadingStatus == .downloaded {
      return true
    }
    do {
      try FileManager.default.startDownloadingUbiquitousItem(at: url)
      return false
    } catch {
      throw mappedFileError(error, action: "start an iCloud download", path: url.path)
    }
  }

  func uploadComic(_ comic: PreparedComic,
                   existingManifest: CRCloudComicManifest?,
                   access: AccessContext,
                   generation: Int) throws -> Bool {
    try checkGeneration(generation)
    if let existingManifest, existingManifest.contentSHA256 != comic.contentSHA256 {
      throw makeError(.integrityMismatch,
                      "The iCloud manifest does not match this comic's content identity.",
                      path: comic.localURL.path)
    }
    let fileName = existingManifest?.cloudFileName ??
      CRCloudSyncPathPolicy.safeCloudFileName(comic.localURL.lastPathComponent)
    let manifest = CRCloudComicManifest(contentIdentifier: comic.contentIdentifier,
                                        contentSHA256: comic.contentSHA256,
                                        cloudFileName: fileName,
                                        preferredRelativePath: comic.relativePath,
                                        fileSize: comic.fileSize,
                                        uploadedAt: Date().timeIntervalSince1970,
                                        uploaderDeviceIdentifier: deviceIdentifier)
    let destinationURL = try blobURL(for: manifest, access: access)
    try FileManager.default.createDirectory(at: destinationURL.deletingLastPathComponent(),
                                            withIntermediateDirectories: true,
                                            attributes: nil)
    var needsUpload = true
    if FileManager.default.fileExists(atPath: destinationURL.path) {
      guard try isAvailableLocally(destinationURL) else {
        throw CRCloudDownloadPendingError(url: destinationURL)
      }
      needsUpload = try coordinatedSHA256(of: destinationURL, generation: generation) != comic.contentSHA256
    }
    if !needsUpload, existingManifest != nil { return false }
    if needsUpload {
      try coordinatedAtomicUpload(localURL: comic.localURL,
                                  cloudURL: destinationURL,
                                  expectedSHA256: comic.contentSHA256,
                                  generation: generation)
    }
    try writeJSON(manifest, to: manifestURL(for: comic.contentIdentifier, access: access))
    return true
  }

  func coordinatedAtomicUpload(localURL: URL,
                               cloudURL: URL,
                               expectedSHA256: String,
                               generation: Int) throws {
    let temporaryURL = cloudURL.deletingLastPathComponent()
      .appendingPathComponent(".\(UUID().uuidString).uploading", isDirectory: false)
    let coordinator = NSFileCoordinator(filePresenter: nil)
    var coordinationError: NSError?
    var bodyError: Error?
    coordinator.coordinate(readingItemAt: localURL,
                           options: [.withoutChanges],
                           writingItemAt: temporaryURL,
                           options: [],
                           error: &coordinationError) { source, destination in
      do {
        try self.checkGeneration(generation)
        try FileManager.default.copyItem(at: source, to: destination)
      } catch { bodyError = error }
    }
    if let bodyError {
      try? FileManager.default.removeItem(at: temporaryURL)
      throw mappedFileError(bodyError, action: "upload a comic", path: cloudURL.path)
    }
    if let coordinationError {
      try? FileManager.default.removeItem(at: temporaryURL)
      throw mappedFileError(coordinationError, action: "coordinate a comic upload", path: cloudURL.path)
    }
    do {
      let copiedHash = try coordinatedSHA256(of: temporaryURL, generation: generation)
      guard copiedHash == expectedSHA256 else {
        throw makeError(.integrityMismatch,
                        "The local comic changed while it was being uploaded.",
                        path: localURL.path)
      }
      var replaceCoordinationError: NSError?
      var replaceBodyError: Error?
      NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: cloudURL,
                                                       options: [.forReplacing],
                                                       error: &replaceCoordinationError) { destination in
        do {
          if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
          }
          try FileManager.default.moveItem(at: temporaryURL, to: destination)
        } catch { replaceBodyError = error }
      }
      if let replaceBodyError { throw replaceBodyError }
      if let replaceCoordinationError { throw replaceCoordinationError }
    } catch {
      try? FileManager.default.removeItem(at: temporaryURL)
      throw mappedFileError(error, action: "finish a verified comic upload", path: cloudURL.path)
    }
  }

  func importComic(manifest: CRCloudComicManifest,
                   destinationURL: URL,
                   access: AccessContext,
                   generation: Int) throws {
    let cloudURL = try blobURL(for: manifest, access: access)
    guard try isAvailableLocally(cloudURL) else {
      throw CRCloudDownloadPendingError(url: cloudURL)
    }
    try FileManager.default.createDirectory(at: destinationURL.deletingLastPathComponent(),
                                            withIntermediateDirectories: true,
                                            attributes: nil)
    let temporaryURL = destinationURL.deletingLastPathComponent()
      .appendingPathComponent(".\(UUID().uuidString).importing", isDirectory: false)
    let coordinator = NSFileCoordinator(filePresenter: nil)
    var coordinationError: NSError?
    var bodyError: Error?
    coordinator.coordinate(readingItemAt: cloudURL,
                           options: [.withoutChanges],
                           writingItemAt: temporaryURL,
                           options: [],
                           error: &coordinationError) { source, temporary in
      do {
        try self.checkGeneration(generation)
        try FileManager.default.copyItem(at: source, to: temporary)
      } catch { bodyError = error }
    }
    if let bodyError {
      try? FileManager.default.removeItem(at: temporaryURL)
      throw mappedFileError(bodyError, action: "import an iCloud comic", path: destinationURL.path)
    }
    if let coordinationError {
      try? FileManager.default.removeItem(at: temporaryURL)
      throw mappedFileError(coordinationError, action: "coordinate an iCloud comic import", path: destinationURL.path)
    }
    do {
      let importedHash = try coordinatedSHA256(of: temporaryURL, generation: generation)
      guard importedHash == manifest.contentSHA256 else {
        throw makeError(.integrityMismatch,
                        "An iCloud comic failed its integrity check.",
                        path: cloudURL.path)
      }
      try FileManager.default.moveItem(at: temporaryURL, to: destinationURL)
    } catch {
      try? FileManager.default.removeItem(at: temporaryURL)
      throw error
    }
  }

  func uploadReadingRecord(_ record: CRCloudReadingStateRecord,
                           access: AccessContext,
                           generation: Int) throws {
    try checkGeneration(generation)
    try writeJSON(record, to: readingRecordURL(for: record, access: access))
  }
}

// MARK: - Synchronization pass

private extension CRCloudSyncManager {
  func performSync(snapshot: NSArray, generation: Int) throws -> SyncOutcome {
    let access = try prepareAccess(generation: generation)
    var state = try loadDeviceState(for: access.accountFingerprint)
    var outcome = SyncOutcome()
    let comics = try prepareSnapshot(snapshot, state: &state, generation: generation)
    identityLock.lock()
    for comic in comics { identityByLocalPath[comic.localURL.path] = comic.contentIdentifier }
    identityLock.unlock()
    outcome.identifiedComics = comics.map {
      [Self.localPathKey: $0.localURL.path,
       Self.relativePathKey: $0.relativePath,
       Self.contentIdentifierKey: $0.contentIdentifier]
    }
    reconcileSnapshotReadingStates(comics, state: &state)
    applyPendingReadingOverrides(to: &state)
    try persistDeviceState(state)

    let metadataDiscovery = discoverMetadataURLs(access: access)
    guard metadataDiscovery.completed else {
      try checkGeneration(generation)
      outcome.pendingDownloadCount = 1
      outcome.waitingForMetadata = true
      outcome.partialErrors.append(makeError(.metadataUnavailable,
                                             "Waiting for iCloud to finish loading sync metadata."))
      return outcome
    }
    let metadataURLs = metadataDiscovery.urls
    var deletionRecords: [String: CRCloudDeletionRecord] = [:]
    var manifests: [String: CRCloudComicManifest] = [:]
    var remoteReadingRecords: [String: [CRCloudReadingStateRecord]] = [:]

    for url in metadataURLs where metadataCategory(of: url, access: access) == "deletions" {
      try checkGeneration(generation)
      do {
        guard try isAvailableLocally(url) else {
          outcome.pendingDownloadCount += 1
          continue
        }
        let deletion = try coordinatedRead(CRCloudDeletionRecord.self, from: url)
        guard validDeletion(deletion, at: url, access: access) else {
          throw makeError(.integrityMismatch, "An iCloud deletion record is invalid.", path: url.path)
        }
        if let existing = deletionRecords[deletion.contentIdentifier] {
          if deletion.deletedAt > existing.deletedAt ||
              (deletion.deletedAt == existing.deletedAt && deletion.deviceIdentifier > existing.deviceIdentifier) {
            deletionRecords[deletion.contentIdentifier] = deletion
          }
        } else {
          deletionRecords[deletion.contentIdentifier] = deletion
        }
      } catch let error as CRCloudDownloadPendingError {
        _ = error
        outcome.pendingDownloadCount += 1
      } catch let error as NSError {
        if shouldAbort(for: error) { throw error }
        outcome.partialErrors.append(error)
      }
    }

    for url in metadataURLs where metadataCategory(of: url, access: access) == "manifests" {
      try checkGeneration(generation)
      do {
        guard try isAvailableLocally(url) else {
          outcome.pendingDownloadCount += 1
          continue
        }
        let manifest = try coordinatedRead(CRCloudComicManifest.self, from: url)
        guard validManifest(manifest, at: url, access: access) else {
          throw makeError(.integrityMismatch, "An iCloud comic manifest is invalid.", path: url.path)
        }
        if deletionRecords[manifest.contentIdentifier] != nil { continue }
        if let existing = manifests[manifest.contentIdentifier] {
          if manifest.uploadedAt > existing.uploadedAt ||
              (manifest.uploadedAt == existing.uploadedAt &&
               manifest.uploaderDeviceIdentifier > existing.uploaderDeviceIdentifier) {
            manifests[manifest.contentIdentifier] = manifest
          }
        } else {
          manifests[manifest.contentIdentifier] = manifest
        }
      } catch let error as CRCloudDownloadPendingError {
        _ = error
        outcome.pendingDownloadCount += 1
      } catch let error as NSError {
        if shouldAbort(for: error) { throw error }
        outcome.partialErrors.append(error)
      }
    }

    let localIdentifiers = Set(comics.map(\.contentIdentifier))
    outcome.remoteDeletionIdentifiers = deletionRecords.keys
      .filter { localIdentifiers.contains($0) }
      .sorted()

    // Content identities make upload idempotent. Same-named comics live under
    // separate identity directories; identical copies share one cloud blob.
    var uploadedIdentifiers = Set<String>()
    for comic in comics {
      try checkGeneration(generation)
      if deletionRecords[comic.contentIdentifier] != nil { continue }
      if uploadedIdentifiers.contains(comic.contentIdentifier) { continue }
      do {
        if try uploadComic(comic,
                           existingManifest: manifests[comic.contentIdentifier],
                           access: access,
                           generation: generation) {
          outcome.uploadedCount += 1
          let fileName = CRCloudSyncPathPolicy.safeCloudFileName(comic.localURL.lastPathComponent)
          manifests[comic.contentIdentifier] = CRCloudComicManifest(
            contentIdentifier: comic.contentIdentifier,
            contentSHA256: comic.contentSHA256,
            cloudFileName: fileName,
            preferredRelativePath: comic.relativePath,
            fileSize: comic.fileSize,
            uploadedAt: Date().timeIntervalSince1970,
            uploaderDeviceIdentifier: deviceIdentifier)
        }
        uploadedIdentifiers.insert(comic.contentIdentifier)
      } catch is CRCloudDownloadPendingError {
        outcome.pendingDownloadCount += 1
      } catch let error as NSError {
        if shouldAbort(for: error) { throw error }
        outcome.partialErrors.append(error)
      }
    }

    guard let libraryRootURL else {
      throw makeError(.notConfigured, "The comic library has not been configured.")
    }
    var knownIdentifiers = localIdentifiers
    for fingerprint in state.fingerprintsByRelativePath.values {
      let cachedURL = fingerprint.relativePath.split(separator: "/").reduce(libraryRootURL) {
        $0.appendingPathComponent(String($1), isDirectory: false)
      }
      if FileManager.default.fileExists(atPath: cachedURL.path) {
        knownIdentifiers.insert(fingerprint.contentIdentifier)
      }
    }
    var reservedImportPaths = Set<String>()
    for identifier in manifests.keys.sorted() {
      try checkGeneration(generation)
      guard !knownIdentifiers.contains(identifier),
            deletionRecords[identifier] == nil,
            state.locallySuppressedContentIdentifiers[identifier] == nil,
            let manifest = manifests[identifier] else { continue }
      let safeRelativePath = CRCloudSyncPathPolicy.safeImportRelativePath(
        manifest.preferredRelativePath,
        fallbackFileName: manifest.cloudFileName)
      let destinationURL = CRCloudSyncPathPolicy.uniqueImportURL(relativePath: safeRelativePath,
                                                                libraryRootURL: libraryRootURL,
                                                                reservedPaths: reservedImportPaths)
      do {
        let cloudURL = try blobURL(for: manifest, access: access)
        guard try isAvailableLocally(cloudURL) else {
          outcome.pendingDownloadCount += 1
          continue
        }
        try importComic(manifest: manifest,
                        destinationURL: destinationURL,
                        access: access,
                        generation: generation)
        do {
          try checkGeneration(generation)
          guard try currentAccountFingerprint() == access.accountFingerprint else {
            throw makeError(.accountChanged, "The iCloud account changed while importing a comic.")
          }
        } catch {
          try? FileManager.default.removeItem(at: destinationURL)
          throw error
        }
        reservedImportPaths.insert(destinationURL.path)
        knownIdentifiers.insert(identifier)
        let relativePath = relativeLibraryPath(for: destinationURL, rootURL: libraryRootURL)
        let attributes = try destinationURL.resourceValues(forKeys: [.fileSizeKey,
                                                                      .contentModificationDateKey,
                                                                      .creationDateKey,
                                                                      .fileResourceIdentifierKey])
        let importedFingerprint = CRCloudCachedFingerprint(
          relativePath: relativePath,
          fileSize: Int64(attributes.fileSize ?? Int(manifest.fileSize)),
          modificationTime: attributes.contentModificationDate?.timeIntervalSince1970 ?? 0,
          creationTime: attributes.creationDate?.timeIntervalSince1970,
          fileResourceIdentifier: fileSystemIdentity(for: destinationURL,
                                                      resourceIdentifier: attributes.fileResourceIdentifier),
          contentIdentifier: identifier,
          contentSHA256: manifest.contentSHA256)
        state.fingerprintsByRelativePath[relativePath] = importedFingerprint
        self.deviceState = state
        do {
          try persistDeviceState(state)
        } catch {
          state.fingerprintsByRelativePath.removeValue(forKey: relativePath)
          self.deviceState = state
          try? FileManager.default.removeItem(at: destinationURL)
          throw error
        }
        outcome.importedComics.append([
          Self.localPathKey: destinationURL.path,
          Self.relativePathKey: relativePath,
          Self.contentIdentifierKey: identifier
        ])
      } catch is CRCloudDownloadPendingError {
        outcome.pendingDownloadCount += 1
      } catch let error as NSError {
        if shouldAbort(for: error) { throw error }
        outcome.partialErrors.append(error)
      }
    }

    // Read all remote device events. Each device owns one file per comic, so
    // iCloud never has to merge simultaneous writes to the same state file.
    for url in metadataURLs where metadataCategory(of: url, access: access) == "reading" {
      try checkGeneration(generation)
      do {
        guard try isAvailableLocally(url) else {
          outcome.pendingDownloadCount += 1
          continue
        }
        let record = try coordinatedRead(CRCloudReadingStateRecord.self, from: url)
        guard validReadingRecord(record, at: url, access: access),
              deletionRecords[record.contentIdentifier] == nil else {
          throw makeError(.integrityMismatch, "An iCloud reading-state record is invalid.", path: url.path)
        }
        remoteReadingRecords[record.contentIdentifier, default: []].append(record)
      } catch let error as NSError {
        if shouldAbort(for: error) { throw error }
        outcome.partialErrors.append(error)
      }
    }

    // Capture a page turn that arrived while large comic files were copying.
    applyPendingReadingOverrides(to: &state)
    for (identifier, var stored) in state.readingStatesByContentIdentifier.sorted(by: { $0.key < $1.key }) {
      try checkGeneration(generation)
      guard deletionRecords[identifier] == nil,
            stored.record.deviceIdentifier == state.deviceIdentifier,
            stored.uploadedMutationIdentifier != stored.record.mutationIdentifier else { continue }
      do {
        try uploadReadingRecord(stored.record, access: access, generation: generation)
        stored.uploadedMutationIdentifier = stored.record.mutationIdentifier
        state.readingStatesByContentIdentifier[identifier] = stored
        remoteReadingRecords[identifier, default: []].append(stored.record)
        pendingReadingLock.lock()
        if pendingReadingOverrides[identifier]?.mutationIdentifier == stored.record.mutationIdentifier {
          pendingReadingOverrides.removeValue(forKey: identifier)
        }
        pendingReadingLock.unlock()
      } catch let error as NSError {
        if shouldAbort(for: error) { throw error }
        outcome.partialErrors.append(error)
      }
    }

    // Merge by event time plus stable tie-breakers. Never merge using max(page).
    let allReadingIdentifiers = Set(remoteReadingRecords.keys)
      .union(state.readingStatesByContentIdentifier.keys)
      .subtracting(deletionRecords.keys)
    for identifier in allReadingIdentifiers.sorted() {
      var candidates = remoteReadingRecords[identifier] ?? []
      if let local = state.readingStatesByContentIdentifier[identifier]?.record {
        candidates.append(local)
      }
      pendingReadingLock.lock()
      if let pending = pendingReadingOverrides[identifier] { candidates.append(pending) }
      pendingReadingLock.unlock()
      guard var winner = candidates.first else { continue }
      for candidate in candidates.dropFirst() {
        winner = CRCloudReadingStateRecord.preferred(winner, candidate)
      }
      if let stored = state.readingStatesByContentIdentifier[identifier], stored.record == winner {
        if stored.awaitingAdapterApply {
          outcome.readingStates.append(contentsOf: readingDictionaries(winner, state: state))
        }
        continue
      }
      let isPendingLocal: Bool
      pendingReadingLock.lock()
      isPendingLocal = pendingReadingOverrides[identifier]?.mutationIdentifier == winner.mutationIdentifier
      pendingReadingLock.unlock()
      if isPendingLocal {
        state.readingStatesByContentIdentifier[identifier] =
          CRCloudStoredReadingState(record: winner,
                                    uploadedMutationIdentifier: nil,
                                    awaitingAdapterApply: false)
      } else {
        state.readingStatesByContentIdentifier[identifier] =
          CRCloudStoredReadingState(record: winner,
                                    uploadedMutationIdentifier: winner.deviceIdentifier == state.deviceIdentifier
                                      ? winner.mutationIdentifier : nil,
                                    awaitingAdapterApply: true)
        outcome.readingStates.append(contentsOf: readingDictionaries(winner, state: state))
      }
    }

    state.lastSyncAt = Date().timeIntervalSince1970
    self.deviceState = state
    try persistDeviceState(state)
    try checkGeneration(generation)
    // An account can switch without the generation notification reaching us yet.
    guard try currentAccountFingerprint() == access.accountFingerprint else {
      throw makeError(.accountChanged, "The iCloud account changed while syncing.")
    }
    return outcome
  }

  func applyPendingReadingOverrides(to state: inout CRCloudDeviceState) {
    pendingReadingLock.lock()
    let overrides = pendingReadingOverrides
    pendingReadingLock.unlock()
    for (identifier, pending) in overrides {
      if let stored = state.readingStatesByContentIdentifier[identifier] {
        let winner = CRCloudReadingStateRecord.preferred(stored.record, pending)
        if winner == pending {
          state.readingStatesByContentIdentifier[identifier] =
            CRCloudStoredReadingState(record: pending,
                                      uploadedMutationIdentifier: nil,
                                      awaitingAdapterApply: false)
        }
      } else {
        state.readingStatesByContentIdentifier[identifier] =
          CRCloudStoredReadingState(record: pending,
                                    uploadedMutationIdentifier: nil,
                                    awaitingAdapterApply: false)
      }
    }
  }

  func shouldAbort(for error: NSError) -> Bool {
    guard error.domain == Self.errorDomain,
          let code = CRCloudSyncErrorCode(rawValue: error.code) else { return false }
    return [.cancelled, .accountChanged, .notConfigured,
            .optInRequired, .iCloudUnavailable].contains(code)
  }

  func validManifest(_ manifest: CRCloudComicManifest, at url: URL, access: AccessContext) -> Bool {
    manifest.schemaVersion == 1 &&
      CRCloudSyncPathPolicy.normalizedContentIdentifier(manifest.contentIdentifier) != nil &&
      validSHA256(manifest.contentSHA256) &&
      manifest.contentIdentifier == manifest.contentSHA256 &&
      manifest.fileSize >= 0 &&
      manifest.uploadedAt.isFinite &&
      manifest.cloudFileName == CRCloudSyncPathPolicy.safeCloudFileName(manifest.cloudFileName) &&
      url.deletingPathExtension().lastPathComponent == cloudKey(for: manifest.contentIdentifier) &&
      CRCloudSyncPathPolicy.contains(url, within: access.syncRootURL)
  }

  func validDeletion(_ deletion: CRCloudDeletionRecord, at url: URL, access: AccessContext) -> Bool {
    deletion.schemaVersion == 1 &&
      CRCloudSyncPathPolicy.normalizedContentIdentifier(deletion.contentIdentifier) != nil &&
      deletion.deletedAt.isFinite && deletion.deletedAt > 0 &&
      CRCloudSyncPathPolicy.normalizedContentIdentifier(deletion.deviceIdentifier) != nil &&
      url.deletingPathExtension().lastPathComponent == cloudKey(for: deletion.contentIdentifier) &&
      CRCloudSyncPathPolicy.contains(url, within: access.syncRootURL)
  }

  func validReadingRecord(_ record: CRCloudReadingStateRecord, at url: URL, access: AccessContext) -> Bool {
    let futureLimit = Date().addingTimeInterval(30 * 24 * 60 * 60).timeIntervalSince1970
    return record.schemaVersion == 1 &&
      CRCloudSyncPathPolicy.normalizedContentIdentifier(record.contentIdentifier) != nil &&
      CRCloudSyncPathPolicy.normalizedContentIdentifier(record.deviceIdentifier) != nil &&
      CRCloudSyncPathPolicy.normalizedContentIdentifier(record.mutationIdentifier) != nil &&
      record.modifiedAt.isFinite && record.modifiedAt > 0 && record.modifiedAt <= futureLimit &&
      record.currentPage >= 0 && record.pageCount >= 0 &&
      (record.pageCount == 0 || record.currentPage < record.pageCount) &&
      url.deletingLastPathComponent().lastPathComponent == cloudKey(for: record.contentIdentifier) &&
      url.deletingPathExtension().lastPathComponent == cloudKey(for: record.deviceIdentifier) &&
      CRCloudSyncPathPolicy.contains(url, within: access.syncRootURL)
  }

  func validSHA256(_ value: String) -> Bool {
    value.count == 64 && value.allSatisfy { $0.isNumber || ("a"..."f").contains(String($0)) }
  }

  func relativeLibraryPath(for url: URL, rootURL: URL) -> String {
    let root = rootURL.standardizedFileURL.path
    let path = url.standardizedFileURL.path
    return path.hasPrefix(root + "/") ? String(path.dropFirst(root.count + 1)) : url.lastPathComponent
  }

  func metadataCategory(of url: URL, access: AccessContext) -> String? {
    let root = access.syncRootURL.standardizedFileURL.path
    let path = url.standardizedFileURL.path
    guard path.hasPrefix(root + "/") else { return nil }
    return String(path.dropFirst(root.count + 1)).split(separator: "/").first.map(String.init)
  }

  func discoverMetadataURLs(access: AccessContext) -> CRCloudMetadataCollection {
    var urls = Set<URL>()
    let keys: [URLResourceKey] = [.isRegularFileKey, .isHiddenKey]
    if let enumerator = FileManager.default.enumerator(at: access.syncRootURL,
                                                       includingPropertiesForKeys: keys,
                                                       options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
      for case let url as URL in enumerator where url.pathExtension.lowercased() == "json" {
        urls.insert(url.standardizedFileURL)
      }
    }
    let queryResult = CRCloudMetadataCollector.collect(rootURL: access.syncRootURL, timeout: 6)
    for url in queryResult.urls where url.pathExtension.lowercased() == "json" &&
      CRCloudSyncPathPolicy.contains(url, within: access.syncRootURL) {
      urls.insert(url.standardizedFileURL)
    }
    return CRCloudMetadataCollection(urls: urls.sorted { $0.path < $1.path },
                                     completed: queryResult.completed)
  }
}

private struct CRCloudDownloadPendingError: Error {
  let url: URL
}

private struct CRCloudMetadataCollection {
  let urls: [URL]
  let completed: Bool
}

private final class CRCloudUncheckedSendableBox<Value>: @unchecked Sendable {
  let value: Value
  init(_ value: Value) { self.value = value }
}

private final class CRCloudMetadataCollector: NSObject {
  private let rootURL: URL
  private let semaphore = DispatchSemaphore(value: 0)
  private let lock = NSLock()
  private var resultURLs: [URL] = []
  private var completed = false
  private var query: NSMetadataQuery?
  private var observer: NSObjectProtocol?

  private init(rootURL: URL) { self.rootURL = rootURL }

  static func collect(rootURL: URL, timeout: TimeInterval) -> CRCloudMetadataCollection {
    let collector = CRCloudMetadataCollector(rootURL: rootURL)
    DispatchQueue.main.async { collector.start() }
    _ = collector.semaphore.wait(timeout: .now() + timeout)
    collector.lock.lock()
    let result = collector.resultURLs
    let completed = collector.completed
    collector.lock.unlock()
    DispatchQueue.main.async { collector.stop() }
    return CRCloudMetadataCollection(urls: result, completed: completed)
  }

  private func start() {
    let query = NSMetadataQuery()
    self.query = query
    query.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
    query.predicate = NSPredicate(format: "%K BEGINSWITH %@", NSMetadataItemPathKey, rootURL.path)
    observer = NotificationCenter.default.addObserver(forName: .NSMetadataQueryDidFinishGathering,
                                                       object: query,
                                                       queue: .main) { [weak self] _ in
      self?.finishGathering()
    }
    if !query.start() { semaphore.signal() }
  }

  private func finishGathering() {
    guard let query else { semaphore.signal(); return }
    query.disableUpdates()
    let urls = query.results.compactMap { item -> URL? in
      guard let metadataItem = item as? NSMetadataItem else { return nil }
      return metadataItem.value(forAttribute: NSMetadataItemURLKey) as? URL
    }
    lock.lock()
    resultURLs = urls
    completed = true
    lock.unlock()
    semaphore.signal()
  }

  private func stop() {
    if let observer { NotificationCenter.default.removeObserver(observer) }
    observer = nil
    query?.stop()
    query = nil
  }
}

private func stringValue(_ value: Any?) -> String? {
  if let value = value as? String { return value }
  if let value = value as? NSString { return value as String }
  return nil
}

private func numberValue(_ value: Any?) -> NSNumber? {
  if let value = value as? NSNumber { return value }
  return nil
}

private func timestampValue(_ value: Any?) -> TimeInterval? {
  if let date = value as? Date { return date.timeIntervalSince1970 }
  if let number = value as? NSNumber { return number.doubleValue }
  if let text = stringValue(value) {
    let formatter = ISO8601DateFormatter()
    return formatter.date(from: text)?.timeIntervalSince1970
  }
  return nil
}

#if CR_CLOUD_SYNC_TESTING
struct CRCloudSyncTestingArtifact {
  let contentIdentifier: String
  let manifestURL: URL
  let blobURL: URL
  let uploaded: Bool
}

extension CRCloudSyncManager {
  @nonobjc static func makeTestingManager(stateRootURL: URL) -> CRCloudSyncManager {
    let manager = CRCloudSyncManager()
    manager.testingStateRootURL = stateRootURL
    return manager
  }

  @nonobjc func testingUpload(localURL: URL,
                              preferredRelativePath: String,
                              cloudRootURL: URL) throws -> CRCloudSyncTestingArtifact {
    let generation = generationValue()
    let attributes = try localURL.resourceValues(forKeys: [.fileSizeKey,
                                                            .contentModificationDateKey])
    let hash = try coordinatedSHA256(of: localURL, generation: generation)
    let comic = PreparedComic(localURL: localURL,
                              relativePath: preferredRelativePath,
                              contentIdentifier: hash,
                              contentSHA256: hash,
                              fileSize: Int64(attributes.fileSize ?? 0),
                              modificationTime: attributes.contentModificationDate?.timeIntervalSince1970 ?? 0,
                              dictionary: [:])
    let access = AccessContext(accountFingerprint: "test-account",
                               containerURL: cloudRootURL.deletingLastPathComponent(),
                               syncRootURL: cloudRootURL)
    for directory in ["comics", "manifests", "reading", "deletions"] {
      try FileManager.default.createDirectory(at: cloudRootURL.appendingPathComponent(directory,
                                                                                       isDirectory: true),
                                              withIntermediateDirectories: true)
    }
    let manifestURL = manifestURL(for: hash, access: access)
    let existingManifest: CRCloudComicManifest?
    if FileManager.default.fileExists(atPath: manifestURL.path) {
      existingManifest = try coordinatedRead(CRCloudComicManifest.self, from: manifestURL)
    } else {
      existingManifest = nil
    }
    let uploaded = try uploadComic(comic,
                                   existingManifest: existingManifest,
                                   access: access,
                                   generation: generation)
    let manifest = try coordinatedRead(CRCloudComicManifest.self, from: manifestURL)
    return CRCloudSyncTestingArtifact(contentIdentifier: hash,
                                      manifestURL: manifestURL,
                                      blobURL: try blobURL(for: manifest, access: access),
                                      uploaded: uploaded)
  }

  @nonobjc func testingImport(_ artifact: CRCloudSyncTestingArtifact,
                              preferredRelativePath: String,
                              importRootURL: URL,
                              cloudRootURL: URL,
                              reservedPaths: Set<String> = []) throws -> URL {
    let access = AccessContext(accountFingerprint: "test-account",
                               containerURL: cloudRootURL.deletingLastPathComponent(),
                               syncRootURL: cloudRootURL)
    let manifest = try coordinatedRead(CRCloudComicManifest.self, from: artifact.manifestURL)
    let destination = CRCloudSyncPathPolicy.uniqueImportURL(relativePath: preferredRelativePath,
                                                            libraryRootURL: importRootURL,
                                                            reservedPaths: reservedPaths)
    try importComic(manifest: manifest,
                    destinationURL: destination,
                    access: access,
                    generation: generationValue())
    return destination
  }

  @nonobjc func testingPreparedContentIdentifier(localURL: URL,
                                                 relativePath: String,
                                                 libraryRootURL: URL) throws -> String {
    self.libraryRootURL = libraryRootURL
    var state = testingFingerprintState ??
      CRCloudDeviceState(deviceIdentifier: deviceIdentifier, accountFingerprint: "test-account")
    let prepared = try prepareComic(SnapshotComic(localURL: localURL,
                                                  relativePath: relativePath,
                                                  suppliedContentIdentifier: nil,
                                                  dictionary: [:]),
                                    state: &state,
                                    generation: generationValue())
    testingFingerprintState = state
    return prepared.contentIdentifier
  }

  @nonobjc func testingCancellationError(whileHashing url: URL) -> NSError? {
    let staleGeneration = generationValue()
    bumpGeneration()
    do {
      _ = try coordinatedSHA256(of: url, generation: staleGeneration)
      return nil
    } catch {
      return error as NSError
    }
  }

  @nonobjc func testingReadingRecord(_ dictionary: NSDictionary,
                                     contentIdentifier: String) -> CRCloudReadingStateRecord? {
    readingRecord(from: dictionary,
                  contentIdentifier: contentIdentifier,
                  deviceIdentifier: deviceIdentifier,
                  forceNewMutation: false)
  }

  @nonobjc func testingSetLocalSuppression(_ identifier: String,
                                           accountFingerprint: String) throws {
    loadedAccountFingerprint = nil
    deviceState = nil
    var state = try loadDeviceState(for: accountFingerprint)
    state.locallySuppressedContentIdentifiers[identifier] = Date().timeIntervalSince1970
    deviceState = state
    try persistDeviceState(state)
  }

  @nonobjc func testingHasLocalSuppression(_ identifier: String,
                                           accountFingerprint: String) throws -> Bool {
    loadedAccountFingerprint = nil
    deviceState = nil
    return try loadDeviceState(for: accountFingerprint)
      .locallySuppressedContentIdentifiers[identifier] != nil
  }
}
#endif
