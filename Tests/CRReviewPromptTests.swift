import Foundation
import XCTest

@testable import ComicFlow

@MainActor
final class CRReviewPromptTests: XCTestCase {
    private final class Clock {
        var date = Date(timeIntervalSince1970: 1_700_000_000)
        var uptime: TimeInterval = 10_000
    }

    private final class Version {
        var value = "1.0"
    }

    private final class RequestCounter {
        var value = 0
    }

    @MainActor
    private struct Fixture {
        let defaults: UserDefaults
        let clock: Clock
        let version: Version
        let requests: RequestCounter
        let calendar: Calendar

        func makePrompt(honorLegacyOptOut: Bool = true) -> CRReviewPrompt {
            let clock = clock
            let version = version
            let requests = requests
            return CRReviewPrompt(
                userDefaults: defaults,
                calendar: calendar,
                now: { clock.date },
                monotonicNow: { clock.uptime },
                currentVersion: { version.value },
                honorLegacyOptOut: honorLegacyOptOut,
                reviewRequester: { _ in requests.value += 1 }
            )
        }

        func completeSession(_ duration: TimeInterval,
                             onDay dayOffset: Int,
                             using prompt: CRReviewPrompt) {
            clock.date = Date(timeIntervalSince1970: 1_700_000_000)
                .addingTimeInterval(TimeInterval(dayOffset) * 24 * 60 * 60)
            prompt.beginReading()
            clock.uptime += duration
            prompt.endReading()
        }
    }

    private var defaultsSuites: [String] = []

    override func tearDown() {
        for suite in defaultsSuites {
            UserDefaults.standard.removePersistentDomain(forName: suite)
        }
        defaultsSuites = []
        super.tearDown()
    }

    func testPauseExcludesBackgroundTimeAndRepeatedLifecycleCallsAreIdempotent() {
        let fixture = makeFixture()
        let prompt = fixture.makePrompt()

        prompt.beginReading()
        prompt.beginReading()
        fixture.clock.uptime += 40
        prompt.pauseReading()
        prompt.pauseReading()
        fixture.clock.uptime += 10_000
        prompt.resumeReading()
        prompt.resumeReading()
        fixture.clock.uptime += 20
        prompt.endReading()
        prompt.endReading()

        let snapshot = prompt.snapshotForTesting
        XCTAssertEqual(snapshot.totalReadingDuration, 60, accuracy: 0.001)
        XCTAssertEqual(snapshot.qualifyingSessionCount, 1)
        XCTAssertEqual(snapshot.distinctReadingDayCount, 1)
        XCTAssertFalse(snapshot.hasActiveReadingSession)
        XCTAssertFalse(snapshot.isReadingSessionPaused)
    }

    func testEligibilityRequiresClosedReaderThreeQualifyingDaysAndTenMinutes() {
        let fixture = makeFixture()
        let prompt = fixture.makePrompt()

        fixture.completeSession(200, onDay: 0, using: prompt)
        fixture.completeSession(200, onDay: 1, using: prompt)
        fixture.clock.date = Date(timeIntervalSince1970: 1_700_000_000)
            .addingTimeInterval(2 * 24 * 60 * 60)
        prompt.beginReading()
        fixture.clock.uptime += 200

        XCTAssertFalse(prompt.requestReviewIfEligibleForTesting(),
                       "A review must not be requested while the reader is open")
        prompt.endReading()

        XCTAssertTrue(prompt.requestReviewIfEligibleForTesting())
        XCTAssertEqual(fixture.requests.value, 1)
        XCTAssertFalse(prompt.requestReviewIfEligibleForTesting(),
                       "The same marketing version can be attempted only once")
        XCTAssertEqual(prompt.snapshotForTesting.requestAttemptCount, 1)

        let reloaded = fixture.makePrompt()
        XCTAssertFalse(reloaded.requestReviewIfEligibleForTesting(),
                       "The request attempt must persist even if StoreKit showed no UI")
    }

    func testSessionsMustQualifyOnThreeDistinctDays() {
        let fixture = makeFixture()
        let prompt = fixture.makePrompt()

        fixture.completeSession(200, onDay: 0, using: prompt)
        fixture.completeSession(200, onDay: 0, using: prompt)
        fixture.completeSession(200, onDay: 0, using: prompt)
        XCTAssertFalse(prompt.requestReviewIfEligibleForTesting())
        XCTAssertEqual(prompt.snapshotForTesting.qualifyingSessionCount, 3)
        XCTAssertEqual(prompt.snapshotForTesting.distinctReadingDayCount, 1)

        fixture.completeSession(60, onDay: 1, using: prompt)
        XCTAssertFalse(prompt.requestReviewIfEligibleForTesting())
        fixture.completeSession(60, onDay: 2, using: prompt)
        XCTAssertTrue(prompt.requestReviewIfEligibleForTesting())
    }

    func testShortSessionsContributeReadingTimeButDoNotQualify() {
        let fixture = makeFixture()
        let prompt = fixture.makePrompt()

        for day in 0..<11 {
            fixture.completeSession(59, onDay: day, using: prompt)
        }

        XCTAssertEqual(prompt.snapshotForTesting.totalReadingDuration, 649, accuracy: 0.001)
        XCTAssertEqual(prompt.snapshotForTesting.qualifyingSessionCount, 0)
        XCTAssertFalse(prompt.requestReviewIfEligibleForTesting())
        XCTAssertEqual(fixture.requests.value, 0)
    }

    func testCooldownAndRollingAnnualLimitApplyAcrossVersions() {
        let fixture = makeFixture()
        let prompt = fixture.makePrompt()
        fixture.completeSession(200, onDay: 0, using: prompt)
        fixture.completeSession(200, onDay: 1, using: prompt)
        fixture.completeSession(200, onDay: 2, using: prompt)
        let firstAttemptDate = fixture.clock.date

        XCTAssertTrue(prompt.requestReviewIfEligibleForTesting())
        fixture.version.value = "2.0"
        fixture.clock.date = firstAttemptDate.addingTimeInterval(89 * 24 * 60 * 60)
        XCTAssertFalse(prompt.requestReviewIfEligibleForTesting())
        fixture.clock.date = firstAttemptDate.addingTimeInterval(90 * 24 * 60 * 60)
        XCTAssertTrue(prompt.requestReviewIfEligibleForTesting())

        fixture.version.value = "3.0"
        fixture.clock.date = firstAttemptDate.addingTimeInterval(180 * 24 * 60 * 60)
        XCTAssertTrue(prompt.requestReviewIfEligibleForTesting())
        fixture.version.value = "4.0"
        fixture.clock.date = firstAttemptDate.addingTimeInterval(270 * 24 * 60 * 60)
        XCTAssertFalse(prompt.requestReviewIfEligibleForTesting(),
                       "Only three attempts are allowed in a rolling year")

        fixture.clock.date = firstAttemptDate.addingTimeInterval(367 * 24 * 60 * 60)
        XCTAssertTrue(prompt.requestReviewIfEligibleForTesting())
        XCTAssertEqual(fixture.requests.value, 4)
    }

    func testLegacyRatedChoiceAndInactiveSceneSuppressAutomaticRequest() {
        let fixture = makeFixture()
        let prompt = fixture.makePrompt()
        fixture.completeSession(200, onDay: 0, using: prompt)
        fixture.completeSession(200, onDay: 1, using: prompt)
        fixture.completeSession(200, onDay: 2, using: prompt)

        fixture.defaults.set(-1, forKey: "launchCount")
        XCTAssertFalse(prompt.requestReviewIfEligibleForTesting())
        XCTAssertEqual(fixture.requests.value, 0)

        let policyOnlyPrompt = fixture.makePrompt(honorLegacyOptOut: false)
        XCTAssertFalse(policyOnlyPrompt.requestReviewIfEligibleForTesting(sceneIsForeground: false))
        XCTAssertTrue(policyOnlyPrompt.requestReviewIfEligibleForTesting(sceneIsForeground: true))
        XCTAssertEqual(fixture.requests.value, 1)
    }

    func testPausedSessionSurvivesTerminationWithoutBackgroundAccrual() {
        let fixture = makeFixture()
        var prompt: CRReviewPrompt? = fixture.makePrompt()
        prompt?.beginReading()
        fixture.clock.uptime += 75
        prompt?.pauseReading()
        fixture.clock.uptime += 50_000
        prompt = nil

        let recovered = fixture.makePrompt()
        XCTAssertEqual(recovered.snapshotForTesting.totalReadingDuration, 75, accuracy: 0.001)
        XCTAssertEqual(recovered.snapshotForTesting.qualifyingSessionCount, 1)
        XCTAssertFalse(recovered.snapshotForTesting.hasActiveReadingSession)
    }

    private func makeFixture() -> Fixture {
        let suite = "CRReviewPromptTests.\(UUID().uuidString)"
        defaultsSuites.append(suite)
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return Fixture(defaults: defaults,
                       clock: Clock(),
                       version: Version(),
                       requests: RequestCounter(),
                       calendar: calendar)
    }
}
