import Foundation
import Testing

@testable import ArdiaVaultsCore

struct GoogleWebLimitsTests {
  let now = Date(timeIntervalSince1970: 2_000_000)

  func ago(_ seconds: TimeInterval) -> Date { now.addingTimeInterval(-seconds) }

  @Test(arguments: [GoogleWebTrigger.unlock, .schedule])
  func `an automatic refresh waits an hour after the last one`(trigger: GoogleWebTrigger) {
    let limits = GoogleWebLimits(lastSuccess: ago(3599), lastAttempt: ago(3599))
    #expect(limits.verdict(trigger, now: now, busy: false) == .notDue(until: ago(-1)))
    let hourLater = GoogleWebLimits(lastSuccess: ago(3600), lastAttempt: ago(3600))
    #expect(hourLater.verdict(trigger, now: now, busy: false) == .go)
    #expect(GoogleWebLimits().verdict(trigger, now: now, busy: false) == .go)
  }

  @Test func `using a password never reaches Google`() {
    #expect(GoogleWebLimits().verdict(.use, now: now, busy: false) == .notDue(until: nil))
  }

  @Test(arguments: [GoogleWebTrigger.unlock, .schedule, .person])
  func `only one hidden-page operation runs at a time`(trigger: GoogleWebTrigger) {
    #expect(GoogleWebLimits().verdict(trigger, now: now, busy: true) == .busy)
  }

  @Test func `Sync Now skips the hour and the backoff but not a minute's spacing`() {
    var limits = GoogleWebLimits(lastSuccess: ago(120), lastAttempt: ago(120))
    limits.failed(.network, now: ago(120))
    #expect(limits.verdict(.person, now: now, busy: false) == .go)
    let justTried = GoogleWebLimits(lastAttempt: ago(30))
    #expect(justTried.verdict(.person, now: now, busy: false) == .notDue(until: ago(-30)))
  }

  @Test func `failures back off 15 minutes, then 30, doubling up to 6 hours`() {
    let expected: [TimeInterval] = [900, 1800, 3600, 7200, 14_400, 21_600, 21_600]
    #expect((1...7).map(GoogleWebLimits.backoff(afterFailures:)) == expected)
    #expect(GoogleWebLimits.backoff(afterFailures: 200) == 21_600)
  }

  @Test func `a failed automatic refresh waits out its backoff, and success clears it`() {
    var limits = GoogleWebLimits()
    limits.started(ago(1900))
    limits.failed(.network, now: ago(1900))
    limits.started(ago(1000))
    limits.failed(.timeout, now: ago(1000))
    #expect(limits.failures == 2)
    #expect(limits.verdict(.schedule, now: now, busy: false) == .notDue(until: ago(1000 - 1800)))
    #expect(limits.verdict(.schedule, now: ago(-800), busy: false) == .go)
    limits.succeeded(now)
    #expect(limits.failures == 0 && limits.lastFailure == nil)
  }

  @Test func `a refused or cancelled run, or a check asked too soon, is not a failure`() {
    var limits = GoogleWebLimits()
    for error in [GoogleImportError.cancelled, .notAllowed, .checkTooSoon] { limits.failed(error, now: now) }
    #expect(limits.failures == 0 && limits.held == nil)
  }

  @Test(arguments: [GoogleImportError.signIn, .twoStep, .captcha, .unusualActivity, .insecureBrowser, .onDeviceEncryption])
  func `a challenge other than the password stops automatic refreshes until the person confirms`(error: GoogleImportError) {
    var limits = GoogleWebLimits()
    limits.started(ago(86_400))
    limits.failed(error, now: ago(86_400))
    #expect(limits.verdict(.schedule, now: now, busy: false) == .held(error))
    #expect(limits.verdict(.unlock, now: now, busy: false) == .held(error))
    #expect(limits.verdict(.person, now: now, busy: false) == .go)
    limits.personConfirmed()
    #expect(limits.verdict(.schedule, now: now, busy: false) == .go)
  }

  @Test func `an automatic run answers at most one password check per 10 minutes`() {
    var limits = GoogleWebLimits()
    #expect(limits.mayAnswerCheck(byPerson: false, now: now))
    limits.answeredCheck(ago(599))
    #expect(!limits.mayAnswerCheck(byPerson: false, now: now))
    #expect(limits.mayAnswerCheck(byPerson: true, now: now))
    limits.answeredCheck(ago(600))
    #expect(limits.mayAnswerCheck(byPerson: false, now: now))
  }

  @Test func `an automatic attempt that never finished still spaces the next by 15 minutes`() {
    var limits = GoogleWebLimits()
    limits.started(ago(60))
    #expect(limits.verdict(.unlock, now: now, busy: false) == .notDue(until: ago(60 - 900)))
  }

  @Test func `the limits survive a round trip to disk`() throws {
    var limits = GoogleWebLimits()
    limits.started(now)
    limits.failed(.captcha, now: now)
    limits.answeredCheck(now)
    let decoded = try JSONDecoder().decode(GoogleWebLimits.self, from: JSONEncoder().encode(limits))
    #expect(decoded == limits)
  }
}

struct GoogleExportFlowTests {
  let start = Date(timeIntervalSince1970: 1_000)
  func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

  @Test func `export clicks the row, confirms the dialog, answers the check, then finishes on the captured list`() {
    var flow = GoogleExportFlow(started: start, mayAnswerCheck: true)
    #expect(flow.step(.options(importButton: true), exportButton: false, captured: false, now: at(0.3)) == .wait)
    #expect(flow.step(.options(importButton: true), exportButton: true, captured: false, now: at(1)) == .clickExport)
    #expect(flow.step(.confirmExport, exportButton: false, captured: false, now: at(2)) == .wait)
    #expect(flow.step(.confirmExport, exportButton: false, captured: false, now: at(5)) == .clickConfirmExport)
    #expect(flow.step(.passwordChallenge(rejected: false), exportButton: false, captured: false, now: at(6)) == .fillPassword)
    #expect(flow.step(.passwordChallenge(rejected: false), exportButton: false, captured: false, now: at(7)) == .wait)
    #expect(flow.step(.loading, exportButton: false, captured: true, now: at(9)) == .finish)
  }

  @Test func `a check the limits don't allow ends the run without typing the password`() {
    var flow = GoogleExportFlow(started: start, mayAnswerCheck: false)
    #expect(flow.step(.passwordChallenge(rejected: false), exportButton: false, captured: false, now: at(1)) == .fail(.checkTooSoon))
  }

  @Test func `a rejected password fails after one try instead of retrying`() {
    var flow = GoogleExportFlow(started: start, mayAnswerCheck: true)
    #expect(flow.step(.passwordChallenge(rejected: false), exportButton: false, captured: false, now: at(1)) == .fillPassword)
    #expect(flow.step(.passwordChallenge(rejected: true), exportButton: false, captured: false, now: at(2)) == .fail(.wrongPassword))
  }

  @Test func `the Export button is clicked at most three times`() {
    var flow = GoogleExportFlow(started: start, mayAnswerCheck: true)
    let clicks = stride(from: 1.0, through: 19, by: 1).map { flow.step(.options(importButton: false), exportButton: true, captured: false, now: at($0)) }
    #expect(clicks.filter { $0 == .clickExport }.count == 3)
    #expect(flow.step(.options(importButton: false), exportButton: true, captured: false, now: at(21.5)) == .fail(.pageChanged))
  }

  @Test(arguments: [GoogleImportStage.twoStep, .captcha, .signIn, .unusualActivity])
  func `pages only a person can pass hand over, then get five minutes`(stage: GoogleImportStage) {
    var flow = GoogleExportFlow(started: start, mayAnswerCheck: true)
    let action = flow.step(stage, exportButton: false, captured: false, now: at(1))
    #expect(action == .needPerson(stage.needsPerson!))
    flow.personStarted(at(1))
    #expect(flow.step(stage, exportButton: false, captured: false, now: at(200)) == .needPerson(stage.needsPerson!))
    #expect(flow.step(stage, exportButton: false, captured: false, now: at(302)) == .fail(.timeout))
  }

  @Test func `a page that never loads fails as a network problem`() {
    var flow = GoogleExportFlow(started: start, mayAnswerCheck: true)
    #expect(flow.step(.loading, exportButton: false, captured: false, now: at(1)) == .wait)
    #expect(flow.step(.loading, exportButton: false, captured: false, now: at(21.5)) == .fail(.network))
  }
}

struct GoogleExportClassifierTests {
  @Test func `Google's confirmation dialog reads as confirm export, not the import dialog`() {
    let page = GoogleImportSnapshot(url: "https://passwords.google.com/options", dialog: "Export Passwords\nYour passwords will be visible to anyone who can see the exported file.", dialogButtons: ["Cancel", "Export"])
    #expect(GoogleImportClassifier.classify(page, site: .google) == .confirmExport)
  }

  @Test func `an unusual-activity page needs the person`() {
    let page = GoogleImportSnapshot(url: "https://accounts.google.com/v3/signin/challenge/selection", text: "Google noticed unusual activity on your account")
    #expect(GoogleImportClassifier.classify(page, site: .google) == .unusualActivity)
  }
}

struct GoogleRaptTests {
  let site = GoogleImportSite.google

  @Test func `the check's token is read only from the passwords site`() {
    #expect(GoogleRapt.token(in: "https://passwords.google.com/options?rapt=AEjHL4N_x-1", site: site) == "AEjHL4N_x-1")
    #expect(GoogleRapt.token(in: "https://evil.example/options?rapt=AEjHL4N", site: site) == nil)
    #expect(GoogleRapt.token(in: "https://passwords.google.com/options?rapt=a%22b", site: site) == nil)
    #expect(GoogleRapt.token(in: "https://passwords.google.com/options", site: site) == nil)
  }

  @Test func `a kept token is added to export and import pages, replacing an older one`() {
    let rapt = GoogleRapt(token: "fresh", seen: Date())
    #expect(GoogleRapt.url(site.optionsURL, adding: rapt) == "https://passwords.google.com/options?rapt=fresh")
    #expect(GoogleRapt.url("https://passwords.google.com/options?import=1&rapt=old", adding: rapt) == "https://passwords.google.com/options?import=1&rapt=fresh")
    #expect(GoogleRapt.url(site.importURL, adding: nil) == site.importURL)
  }
}

struct GoogleExportCSVTests {
  @Test func `quoted fields keep commas, quotes and newlines`() throws {
    let text = "name,url,username,password,note\r\n\"a, b\",https://a.example/,\"x\"\"y\",\"p,w\n2\",\"line 1\nline \"\"2\"\"\"\nb.example,https://b.example/,bob,hunter2,\n"
    let rows = try #require(GoogleExportCSV.rows(text))
    #expect(rows == [
      GoogleExportRow(name: "a, b", url: "https://a.example/", username: "x\"y", password: "p,w\n2"),
      GoogleExportRow(name: "b.example", url: "https://b.example/", username: "bob", password: "hunter2"),
    ])
  }

  @Test func `a byte order mark, reordered columns and a missing trailing newline still parse`() throws {
    let rows = try #require(GoogleExportCSV.rows("\u{FEFF}url,password,username\nhttps://c.example/,pw,carol"))
    #expect(rows == [GoogleExportRow(name: "", url: "https://c.example/", username: "carol", password: "pw")])
  }

  @Test func `text without the password columns isn't a password list`() {
    #expect(GoogleExportCSV.rows("a,b,c\n1,2,3\n") == nil)
    #expect(GoogleExportCSV.rows("") == nil)
  }

  @Test func `rows become Google Account items with their passwords, skipping apps, blanks and duplicates`() {
    let rows = [
      GoogleExportRow(name: "", url: "https://www.zeta.example/login", username: "z", password: "1"),
      GoogleExportRow(name: "Alpha", url: "https://alpha.example/", username: "a", password: "2"),
      GoogleExportRow(name: "App", url: "android://hash@com.example/", username: "a", password: "3"),
      GoogleExportRow(name: "Empty", url: "https://empty.example/", username: "e", password: ""),
      GoogleExportRow(name: "Alpha again", url: "https://alpha.example/", username: "a", password: "4"),
    ]
    let list = GoogleExportCSV.list(rows, provider: "google")
    #expect(list.items.map(\.title) == ["Alpha", "zeta.example"])
    #expect(list.items.allSatisfy { $0.vault == "Google Account" && $0.provider == "google" && GoogleExportCSV.isValidId($0.id) })
    #expect(list.passwords[list.items[0].id] == "2")
    #expect(list.passwords.count == 2)
  }

  @Test func `ids are stable for the same site and username and differ otherwise`() {
    let one = GoogleExportCSV.itemId(url: "https://a.example/", username: "a")
    #expect(one == GoogleExportCSV.itemId(url: "https://a.example/", username: "a"))
    #expect(one != GoogleExportCSV.itemId(url: "https://a.example/", username: "b"))
    #expect(!GoogleExportCSV.isValidId("account." + one.dropFirst(4)))
  }
}
