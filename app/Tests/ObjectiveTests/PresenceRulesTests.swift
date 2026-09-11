import Testing
@testable import Objective

struct PresenceRulesTests {
    private let now = 1_000_000.0

    private func state(_ change: (inout PresenceSignals) -> Void) -> PresenceState {
        var signals = PresenceSignals(now: now, lastInput: now - 5)
        change(&signals)
        return PresenceRules.evaluate(signals).state
    }

    @Test func recentInputMeansPresent() {
        #expect(state { _ in } == .present)
    }

    @Test func aFewQuietMinutesAreUnsure() {
        #expect(state { $0.lastInput = now - 5 * 60 } == .unsure)
    }

    @Test func fifteenQuietMinutesMeanAway() {
        #expect(state { $0.lastInput = now - 15 * 60 } == .away)
        #expect(state { $0.lastInput = nil } == .away)
    }

    @Test func aLockIgnoresTheInputBeforeIt() {
        #expect(state { $0.locked = true } == .unsure)
        #expect(state { $0.locked = true; $0.lastInput = now - 20 * 60 } == .away)
    }

    @Test func aCallKeepsYouPresentWithoutInput() {
        #expect(state { $0.lastInput = now - 10 * 60; $0.callActive = true } == .present)
        #expect(state { $0.lastInput = now - 10 * 60; $0.callActive = true; $0.locked = true } == .unsure)
    }

    @Test func aClosedLidWithNoDisplayMeansAway() {
        #expect(state { $0.lidClosedWithoutDisplay = true } == .away)
    }

    @Test func aPhoneGoneForThreeMinutesMeansAwayUnlessYouType() {
        #expect(state { $0.lastInput = now - 2 * 60; $0.phoneMissingSince = now - 60 } == .unsure)
        #expect(state { $0.lastInput = now - 2 * 60; $0.phoneMissingSince = now - 3 * 60 } == .away)
        #expect(state { $0.phoneMissingSince = now - 10 * 60 } == .present)
    }

    @Test func aMenuChoiceWinsUntilItEnds() {
        let away = PresenceOverride(kind: .away, since: now - 10, until: nil)
        #expect(state { $0.override = away } == .away)

        let here = PresenceOverride(kind: .here, since: now - 10, until: now + 60)
        #expect(state { $0.lastInput = now - 20 * 60; $0.override = here } == .present)

        let ended = PresenceOverride(kind: .here, since: now - 7200, until: now - 1)
        #expect(state { $0.lastInput = now - 20 * 60; $0.override = ended } == .away)
    }
}
