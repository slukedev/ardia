import Foundation
import Testing

@testable import ArdiaVaultsCore

struct GoogleWebAdmissionTests {
  let now = Date(timeIntervalSince1970: 3_000_000)

  func ago(_ seconds: TimeInterval) -> Date { now.addingTimeInterval(-seconds) }

  func admit(_ limits: GoogleWebLimits, _ trigger: GoogleWebTrigger, rapt: Date? = nil) -> GoogleWebAdmission {
    limits.admission(trigger, now: now, busy: false, raptSeen: rapt)
  }

  @Test func `the reconcile after a save runs on the fresh rapt and never answers a check`() {
    let limits = GoogleWebLimits(lastSuccess: ago(120), lastAttempt: ago(120), lastCheck: ago(20))
    #expect(admit(limits, .afterSave, rapt: ago(20)) == GoogleWebAdmission(verdict: .go, mayAnswerCheck: false))
  }

  @Test func `the reconcile after a save needs a rapt`() {
    #expect(admit(GoogleWebLimits(), .afterSave).verdict == .notDue(until: nil))
  }

  @Test func `the reconcile after a save keeps a minute from the last export`() {
    let limits = GoogleWebLimits(lastSuccess: ago(30), lastAttempt: ago(30))
    #expect(admit(limits, .afterSave, rapt: ago(10)).verdict == .notDue(until: ago(-30)))
  }

  @Test func `the reconcile after a save honours a hold and the backoff`() {
    var held = GoogleWebLimits()
    held.failed(.captcha, now: ago(3600))
    #expect(admit(held, .afterSave, rapt: ago(5)).verdict == .held(.captcha))
    var backingOff = GoogleWebLimits(lastAttempt: ago(300))
    backingOff.failed(.network, now: ago(300))
    #expect(admit(backingOff, .afterSave, rapt: ago(5)).verdict == .notDue(until: ago(300 - 900)))
  }

  @Test(arguments: [GoogleWebTrigger.schedule, .use])
  func `with a fresh rapt, refreshes come every 15 minutes without a check`(trigger: GoogleWebTrigger) {
    let due = GoogleWebLimits(lastSuccess: ago(900), lastAttempt: ago(900))
    #expect(admit(due, trigger, rapt: ago(60)) == GoogleWebAdmission(verdict: .go, mayAnswerCheck: false))
    let early = GoogleWebLimits(lastSuccess: ago(899), lastAttempt: ago(899))
    #expect(admit(early, trigger, rapt: ago(60)).verdict == .notDue(until: ago(-1)))
  }

  @Test func `without a rapt the schedule keeps the hour`() {
    let limits = GoogleWebLimits(lastSuccess: ago(1800), lastAttempt: ago(1800))
    #expect(admit(limits, .schedule).verdict == .notDue(until: ago(1800 - 3600)))
  }

  @Test func `an old rapt doesn't count as fresh`() {
    let limits = GoogleWebLimits(lastSuccess: ago(1800), lastAttempt: ago(1800))
    #expect(admit(limits, .schedule, rapt: ago(GoogleWebLimits.raptLifetime)).verdict == .notDue(until: ago(1800 - 3600)))
    #expect(admit(limits, .use, rapt: ago(GoogleWebLimits.raptLifetime)).verdict == .notDue(until: nil))
  }

  @Test func `using a list never reaches Google without a rapt`() {
    #expect(admit(GoogleWebLimits(), .use).verdict == .notDue(until: nil))
  }

  @Test func `an hourly run with no rapt waits out the 10 minutes since the last check`() {
    let limits = GoogleWebLimits(lastSuccess: ago(7200), lastAttempt: ago(7200), lastCheck: ago(300))
    #expect(admit(limits, .unlock).verdict == .notDue(until: ago(300 - 600)))
    let later = GoogleWebLimits(lastSuccess: ago(7200), lastAttempt: ago(7200), lastCheck: ago(600))
    #expect(admit(later, .unlock) == GoogleWebAdmission(verdict: .go, mayAnswerCheck: true))
  }

  @Test func `an hourly run with a rapt starts but answers no check inside the 10 minutes`() {
    let limits = GoogleWebLimits(lastSuccess: ago(7200), lastAttempt: ago(7200), lastCheck: ago(300))
    #expect(admit(limits, .schedule, rapt: ago(300)) == GoogleWebAdmission(verdict: .go, mayAnswerCheck: false))
  }

  @Test func `the fast refresh still keeps 15 minutes from the last attempt and the backoff`() {
    let recentAttempt = GoogleWebLimits(lastSuccess: ago(2000), lastAttempt: ago(600))
    #expect(admit(recentAttempt, .schedule, rapt: ago(60)).verdict == .notDue(until: ago(600 - 900)))
    var failing = GoogleWebLimits(lastSuccess: ago(4000), lastAttempt: ago(1000))
    failing.failed(.network, now: ago(1000))
    failing.failed(.network, now: ago(1000))
    #expect(admit(failing, .schedule, rapt: ago(60)).verdict == .notDue(until: ago(1000 - 1800)))
  }

  @Test(arguments: [GoogleWebTrigger.schedule, .use, .unlock])
  func `a hold stops the fast refresh too`(trigger: GoogleWebTrigger) {
    var limits = GoogleWebLimits(lastSuccess: ago(4000), lastAttempt: ago(4000))
    limits.failed(.twoStep, now: ago(4000))
    #expect(admit(limits, trigger, rapt: ago(60)).verdict == .held(.twoStep))
  }

  @Test func `Sync Now is unchanged and may answer a check`() {
    let limits = GoogleWebLimits(lastSuccess: ago(120), lastAttempt: ago(120), lastCheck: ago(60))
    #expect(admit(limits, .person) == GoogleWebAdmission(verdict: .go, mayAnswerCheck: true))
  }

  @Test(arguments: [GoogleWebTrigger.afterSave, .use, .schedule, .person])
  func `a busy page refuses every trigger`(trigger: GoogleWebTrigger) {
    #expect(GoogleWebLimits().admission(trigger, now: now, busy: true, raptSeen: ago(5)).verdict == .busy)
  }
}
