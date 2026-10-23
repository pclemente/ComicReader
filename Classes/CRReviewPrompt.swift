import Foundation
import StoreKit
import UIKit

struct CRReviewPromptPolicy: Equatable {
    var minimumQualifyingSessionDuration: TimeInterval = 60
    var minimumQualifyingSessions = 3
    var minimumDistinctReadingDays = 3
    var minimumTotalReadingDuration: TimeInterval = 10 * 60
    var requestCooldown: TimeInterval = 90 * 24 * 60 * 60
    var rollingRequestWindow: TimeInterval = 365 * 24 * 60 * 60
    var maximumRequestsInRollingWindow = 3
}

struct CRReviewPromptSnapshot: Equatable {
    let totalReadingDuration: TimeInterval
    let qualifyingSessionCount: Int
    let distinctReadingDayCount: Int
    let requestAttemptCount: Int
    let hasActiveReadingSession: Bool
    let isReadingSessionPaused: Bool
}

/// Tracks meaningful reader use and asks StoreKit for a review only after the
/// reader has closed. StoreKit decides whether an attempted request displays
/// UI, so the attempt is persisted before calling StoreKit.
@objc(CRReviewPrompt)
@MainActor
public final class CRReviewPrompt: NSObject {
    @objc public static let sharedPrompt = CRReviewPrompt()

    private struct RequestAttempt: Codable, Equatable {
        let version: String
        let date: Date
    }

    private struct PendingReadingSession: Codable, Equatable {
        let beganAt: Date
        var accumulatedDuration: TimeInterval
    }

    private struct PersistedState: Codable, Equatable {
        var totalReadingDuration: TimeInterval = 0
        var qualifyingSessionCount = 0
        var qualifyingReadingDays: [Date] = []
        var requestAttempts: [RequestAttempt] = []
        var pendingReadingSession: PendingReadingSession?
    }

    private struct ActiveReadingSession {
        let beganAt: Date
        var accumulatedDuration: TimeInterval
        var activeSegmentBeganAt: TimeInterval?
    }

    private nonisolated static let defaultStorageKey = "CRReviewPrompt.state.v1"
    private static let legacyLaunchCountKey = "launchCount"

    private let userDefaults: UserDefaults
    private let storageKey: String
    private let policy: CRReviewPromptPolicy
    private let calendar: Calendar
    private let now: () -> Date
    private let monotonicNow: () -> TimeInterval
    private let currentVersion: () -> String
    private let honorLegacyOptOut: Bool
    private let reviewRequester: (UIWindowScene?) -> Void

    private var persistedState: PersistedState
    private var activeReadingSession: ActiveReadingSession?

    private override init() {
        let defaults = UserDefaults.standard
        let storageKey = Self.defaultStorageKey
        self.userDefaults = defaults
        self.storageKey = storageKey
        self.policy = CRReviewPromptPolicy()
        self.calendar = Calendar.autoupdatingCurrent
        self.now = Date.init
        self.monotonicNow = { ProcessInfo.processInfo.systemUptime }
        self.currentVersion = {
            (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? ""
        }
        self.honorLegacyOptOut = true
        self.reviewRequester = { scene in
            guard let scene else { return }
            if #available(iOS 16.0, macCatalyst 16.0, *) {
                AppStore.requestReview(in: scene)
            } else {
                SKStoreReviewController.requestReview(in: scene)
            }
        }
        self.persistedState = Self.loadState(from: defaults, key: storageKey)
        super.init()
        sanitizePersistedState()
        recoverInterruptedSession()
    }

    init(userDefaults: UserDefaults,
         storageKey: String = CRReviewPrompt.defaultStorageKey,
         policy: CRReviewPromptPolicy = CRReviewPromptPolicy(),
         calendar: Calendar = Calendar(identifier: .gregorian),
         now: @escaping () -> Date,
         monotonicNow: @escaping () -> TimeInterval,
         currentVersion: @escaping () -> String,
         honorLegacyOptOut: Bool = true,
         reviewRequester: @escaping (UIWindowScene?) -> Void) {
        self.userDefaults = userDefaults
        self.storageKey = storageKey
        self.policy = policy
        self.calendar = calendar
        self.now = now
        self.monotonicNow = monotonicNow
        self.currentVersion = currentVersion
        self.honorLegacyOptOut = honorLegacyOptOut
        self.reviewRequester = reviewRequester
        self.persistedState = Self.loadState(from: userDefaults, key: storageKey)
        super.init()
        sanitizePersistedState()
        recoverInterruptedSession()
    }

    /// Starts one logical reader session. Repeated appearance callbacks, such
    /// as those caused by a tools sheet, do not create additional sessions.
    @objc public func beginReading() {
        guard activeReadingSession == nil else { return }
        activeReadingSession = ActiveReadingSession(
            beganAt: now(),
            accumulatedDuration: 0,
            activeSegmentBeganAt: monotonicNow()
        )
        persistedState.pendingReadingSession = PendingReadingSession(
            beganAt: activeReadingSession!.beganAt,
            accumulatedDuration: 0
        )
        saveState()
    }

    /// Completes the logical reader session and records only monotonic time
    /// accumulated while it was active.
    @objc public func endReading() {
        guard activeReadingSession != nil else { return }
        accrueActiveSegment()
        guard let session = activeReadingSession else { return }
        activeReadingSession = nil
        persistedState.pendingReadingSession = nil
        recordCompletedSession(beganAt: session.beganAt,
                               duration: session.accumulatedDuration)
        saveState()
    }

    /// Stops foreground accrual without ending the reader session.
    @objc public func pauseReading() {
        accrueActiveSegment()
    }

    /// Continues a paused reader session. Calling this without a session, or
    /// when it is already accruing, is harmless.
    @objc public func resumeReading() {
        guard var session = activeReadingSession,
              session.activeSegmentBeganAt == nil else { return }
        session.activeSegmentBeganAt = monotonicNow()
        activeReadingSession = session
    }

    /// Returns true when this call recorded and submitted a StoreKit request.
    /// StoreKit may suppress its UI; that does not undo the persisted attempt.
    @objc(requestReviewIfEligibleInScene:)
    @discardableResult
    public func requestReviewIfEligible(in scene: UIWindowScene) -> Bool {
        attemptReviewRequest(sceneIsForeground: scene.activationState == .foregroundActive,
                             scene: scene)
    }

    @discardableResult
    func requestReviewIfEligibleForTesting(sceneIsForeground: Bool = true) -> Bool {
        attemptReviewRequest(sceneIsForeground: sceneIsForeground, scene: nil)
    }

    var snapshotForTesting: CRReviewPromptSnapshot {
        CRReviewPromptSnapshot(
            totalReadingDuration: persistedState.totalReadingDuration,
            qualifyingSessionCount: persistedState.qualifyingSessionCount,
            distinctReadingDayCount: persistedState.qualifyingReadingDays.count,
            requestAttemptCount: persistedState.requestAttempts.count,
            hasActiveReadingSession: activeReadingSession != nil,
            isReadingSessionPaused: activeReadingSession != nil &&
                activeReadingSession?.activeSegmentBeganAt == nil
        )
    }

    private func accrueActiveSegment() {
        guard var session = activeReadingSession,
              let segmentStart = session.activeSegmentBeganAt else { return }
        let elapsed = monotonicNow() - segmentStart
        if elapsed.isFinite, elapsed > 0 {
            session.accumulatedDuration += elapsed
        }
        session.activeSegmentBeganAt = nil
        activeReadingSession = session
        persistedState.pendingReadingSession = PendingReadingSession(
            beganAt: session.beganAt,
            accumulatedDuration: session.accumulatedDuration
        )
        saveState()
    }

    private func attemptReviewRequest(sceneIsForeground: Bool,
                                      scene: UIWindowScene?) -> Bool {
        guard sceneIsForeground,
              activeReadingSession == nil,
              persistedState.qualifyingSessionCount >= policy.minimumQualifyingSessions,
              persistedState.qualifyingReadingDays.count >= policy.minimumDistinctReadingDays,
              persistedState.totalReadingDuration >= policy.minimumTotalReadingDuration else {
            return false
        }

        if honorLegacyOptOut,
           userDefaults.integer(forKey: Self.legacyLaunchCountKey) < 0 {
            return false
        }

        let version = currentVersion().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !version.isEmpty,
              !persistedState.requestAttempts.contains(where: { $0.version == version }) else {
            return false
        }

        let requestDate = now()
        if let mostRecentAttempt = persistedState.requestAttempts.map(\.date).max(),
           requestDate.timeIntervalSince(mostRecentAttempt) < policy.requestCooldown {
            return false
        }

        let rollingCutoff = requestDate.addingTimeInterval(-policy.rollingRequestWindow)
        let requestsInWindow = persistedState.requestAttempts.filter {
            $0.date >= rollingCutoff
        }.count
        guard requestsInWindow < policy.maximumRequestsInRollingWindow else {
            return false
        }

        persistedState.requestAttempts.append(RequestAttempt(version: version, date: requestDate))
        saveState()
        reviewRequester(scene)
        return true
    }

    private static func loadState(from defaults: UserDefaults, key: String) -> PersistedState {
        guard let data = defaults.data(forKey: key),
              let state = try? JSONDecoder().decode(PersistedState.self, from: data) else {
            return PersistedState()
        }
        return state
    }

    private func sanitizePersistedState() {
        if !persistedState.totalReadingDuration.isFinite || persistedState.totalReadingDuration < 0 {
            persistedState.totalReadingDuration = 0
        }
        persistedState.qualifyingSessionCount = max(0, persistedState.qualifyingSessionCount)
        persistedState.qualifyingReadingDays = Array(Set(persistedState.qualifyingReadingDays))
            .sorted()
        if let pending = persistedState.pendingReadingSession,
           (!pending.accumulatedDuration.isFinite || pending.accumulatedDuration < 0) {
            persistedState.pendingReadingSession = nil
        }
    }

    private func recoverInterruptedSession() {
        guard let pending = persistedState.pendingReadingSession else { return }
        persistedState.pendingReadingSession = nil
        recordCompletedSession(beganAt: pending.beganAt,
                               duration: pending.accumulatedDuration)
        saveState()
    }

    private func recordCompletedSession(beganAt: Date, duration: TimeInterval) {
        let safeDuration = duration.isFinite ? max(0, duration) : 0
        persistedState.totalReadingDuration += safeDuration
        if safeDuration >= policy.minimumQualifyingSessionDuration {
            persistedState.qualifyingSessionCount += 1
            let day = calendar.startOfDay(for: beganAt)
            if !persistedState.qualifyingReadingDays.contains(day) {
                persistedState.qualifyingReadingDays.append(day)
                persistedState.qualifyingReadingDays.sort()
            }
        }
    }

    private func saveState() {
        guard let data = try? JSONEncoder().encode(persistedState) else { return }
        userDefaults.set(data, forKey: storageKey)
    }
}
