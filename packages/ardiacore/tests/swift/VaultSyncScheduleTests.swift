import Foundation
import Testing

@testable import ArdiaVaultsCore

struct VaultSyncScheduleTests {
  private let now = Date(timeIntervalSince1970: 1_000_000)

  private func ago(_ seconds: TimeInterval) -> Date { now.addingTimeInterval(-seconds) }

  @Test func `no interval is today's automatic sync, zero is manual`() {
    #expect(VaultSyncSchedule(seconds: nil) == .automatic)
    #expect(VaultSyncSchedule(seconds: .nan) == .automatic)
    #expect(VaultSyncSchedule(seconds: 0) == .manual)
    #expect(VaultSyncSchedule(seconds: -5) == .manual)
    #expect(VaultSyncSchedule(seconds: 900) == .every(900))
  }

  @Test func `a timed interval stays between a minute and a day`() {
    #expect(VaultSyncSchedule(seconds: 1) == .every(60))
    #expect(VaultSyncSchedule(seconds: 1_000_000) == .every(86_400))
  }

  @Test func `automatic refreshes on use after 60 seconds and never on the timer`() {
    let schedule = VaultSyncSchedule.automatic
    #expect(!schedule.refreshes(.use, fetchedAt: ago(59), now: now, unlocked: true, inFlight: false))
    #expect(schedule.refreshes(.use, fetchedAt: ago(60), now: now, unlocked: true, inFlight: false))
    #expect(!schedule.refreshes(.timer, fetchedAt: ago(3600), now: now, unlocked: true, inFlight: false))
  }

  @Test(arguments: [VaultSyncSchedule.Trigger.use, .timer])
  func `a timed interval refreshes once it has passed`(trigger: VaultSyncSchedule.Trigger) {
    let schedule = VaultSyncSchedule.every(300)
    #expect(!schedule.refreshes(trigger, fetchedAt: ago(299), now: now, unlocked: true, inFlight: false))
    #expect(schedule.refreshes(trigger, fetchedAt: ago(300), now: now, unlocked: true, inFlight: false))
    #expect(schedule.refreshes(trigger, fetchedAt: nil, now: now, unlocked: true, inFlight: false))
  }

  @Test(arguments: [VaultSyncSchedule.Trigger.use, .timer])
  func `manual never refreshes by itself`(trigger: VaultSyncSchedule.Trigger) {
    #expect(!VaultSyncSchedule.manual.refreshes(trigger, fetchedAt: ago(86_400), now: now, unlocked: true, inFlight: false))
    #expect(!VaultSyncSchedule.manual.refreshes(trigger, fetchedAt: nil, now: now, unlocked: true, inFlight: false))
  }

  @Test(arguments: [VaultSyncSchedule.automatic, .every(300)])
  func `a locked manager or one already refreshing is left alone`(schedule: VaultSyncSchedule) {
    #expect(!schedule.refreshes(.use, fetchedAt: ago(3600), now: now, unlocked: false, inFlight: false))
    #expect(!schedule.refreshes(.use, fetchedAt: ago(3600), now: now, unlocked: true, inFlight: true))
    #expect(!schedule.refreshes(.timer, fetchedAt: ago(3600), now: now, unlocked: false, inFlight: false))
  }
}
