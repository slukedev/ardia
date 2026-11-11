import Foundation
import Testing

@testable import ArdiaVaultsCore

struct GoogleListRowsTests {
  func item(_ url: String, _ username: String) -> VaultItem {
    VaultItem(
      provider: "google", id: GoogleExportCSV.itemId(url: url, username: username), title: VaultOriginMatch.host(of: url) ?? url, username: username,
      urls: [url], hasTotp: false, vault: GoogleExportCSV.vaultName)
  }

  func site(_ name: String, count: Int? = nil) -> GoogleListSite { GoogleListSite(name: name, count: count) }

  @Test func `logins of sites Google still lists keep their ids, so their passwords stay`() throws {
    let previous = [item("https://www.alpha.example/login", "ann"), item("https://beta.example/", "bob")]
    let result = try #require(GoogleListRows.reconcile(previous: previous, sites: [site("alpha.example"), site("beta.example")], provider: "google"))
    #expect(Set(result.items.map(\.id)) == Set(previous.map(\.id)))
    #expect(result.added == 0 && result.dropped == 0)
  }

  @Test func `a site Google no longer lists drops its logins`() throws {
    let previous = [item("https://alpha.example/", "ann"), item("https://beta.example/", "bob"), item("https://gamma.example/", "cy")]
    let result = try #require(GoogleListRows.reconcile(previous: previous, sites: [site("alpha.example"), site("gamma.example")], provider: "google"))
    #expect(result.items.map(\.username) == ["ann", "cy"])
    #expect(result.dropped == 1)
  }

  @Test func `a new site appears as a login with no username or password yet`() throws {
    let previous = [item("https://alpha.example/", "ann")]
    let result = try #require(GoogleListRows.reconcile(previous: previous, sites: [site("alpha.example"), site("new.example")], provider: "google"))
    let added = try #require(result.items.first { $0.title == "new.example" })
    #expect(added.username.isEmpty)
    #expect(VaultOriginMatch.matches(added.urls, origin: "https://new.example"))
    #expect(GoogleListRows.isPlaceholder(added))
    #expect(result.added == 1)
  }

  @Test func `a site with more accounts than Ardia knows gets a placeholder beside the known login`() throws {
    let previous = [item("https://alpha.example/", "ann")]
    let result = try #require(GoogleListRows.reconcile(previous: previous, sites: [site("alpha.example", count: 2)], provider: "google"))
    #expect(result.items.count == 2)
    #expect(result.items.contains { GoogleListRows.isPlaceholder($0) })
  }

  @Test func `a placeholder goes once the export has the site's login`() throws {
    let placeholder = GoogleListRows.placeholder(site("new.example"), provider: "google")
    let previous = [placeholder, item("https://new.example/", "nia")]
    let result = try #require(GoogleListRows.reconcile(previous: previous, sites: [site("new.example")], provider: "google"))
    #expect(result.items.map(\.username) == ["nia"])
  }

  @Test func `a placeholder stays a placeholder across reads, so it isn't counted as new again`() throws {
    let placeholder = GoogleListRows.placeholder(site("new.example"), provider: "google")
    let result = try #require(GoogleListRows.reconcile(previous: [placeholder], sites: [site("new.example")], provider: "google"))
    #expect(result.items == [placeholder])
    #expect(result.added == 0)
  }

  @Test func `a listed name that isn't a host adds nothing`() throws {
    let result = try #require(GoogleListRows.reconcile(previous: [], sites: [site("example app")], provider: "google"))
    #expect(result.items.isEmpty)
  }

  @Test func `an empty read never empties a known list`() {
    #expect(GoogleListRows.reconcile(previous: [item("https://alpha.example/", "ann")], sites: [], provider: "google") == nil)
  }

  @Test func `a read that would drop most logins is distrusted`() {
    let previous = ["a", "b", "c", "d", "e"].map { item("https://\($0).example/", $0) }
    #expect(GoogleListRows.reconcile(previous: previous, sites: [site("a.example")], provider: "google") == nil)
  }

  @Test func `a placeholder fills from the export's only login for that site`() {
    let id = GoogleListRows.placeholderId(site: "new.example")
    let rows = [GoogleExportRow(name: "", url: "https://login.new.example/x", username: "nia", password: "pw")]
    #expect(GoogleListRows.row(for: id, in: rows)?.username == "nia")
    let two = rows + [GoogleExportRow(name: "", url: "https://new.example/", username: "max", password: "pw2")]
    #expect(GoogleListRows.row(for: id, in: two) == nil)
  }
}

struct GoogleListSiteTests {
  @Test func `a row reads its site name and an account count when Google shows one`() {
    #expect(GoogleListSite.parse(lines: ["  Alpha.example ", "3 accounts"]) == GoogleListSite(name: "alpha.example", count: 3))
    #expect(GoogleListSite.parse(lines: ["beta.example"]) == GoogleListSite(name: "beta.example", count: nil))
    #expect(GoogleListSite.parse(lines: ["", " "]) == nil)
  }

  @Test func `the same site listed twice counts once`() {
    let snapshot = GoogleListSnapshot(url: "https://passwords.google.com/", rows: [.init(lines: ["a.example"]), .init(lines: ["A.example"])])
    #expect(snapshot.sites.map(\.name) == ["a.example"])
  }
}

struct GoogleListFlowTests {
  let site = GoogleImportSite.google
  let start = Date(timeIntervalSince1970: 1_000_000)

  func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

  func list(_ names: [String], search: Bool = true) -> GoogleListSnapshot {
    GoogleListSnapshot(url: "https://passwords.google.com/", rows: names.map { .init(lines: [$0]) }, searchField: search)
  }

  @Test func `the read finishes once the list stops growing`() {
    var flow = GoogleListFlow(started: start)
    #expect(flow.step(list(["a.example"]), site: site, now: at(0.3)) == .wait)
    #expect(flow.step(list(["a.example", "b.example"]), site: site, now: at(0.6)) == .wait)
    #expect(flow.step(list(["a.example", "b.example"]), site: site, now: at(1.5)) == .wait)
    #expect(flow.step(list(["a.example", "b.example"]), site: site, now: at(2.2)) == .finish([.init(name: "a.example"), .init(name: "b.example")]))
  }

  @Test func `an account with no passwords reads as empty only after a wait`() {
    var flow = GoogleListFlow(started: start)
    #expect(flow.step(list([]), site: site, now: at(0.3)) == .wait)
    #expect(flow.step(list([]), site: site, now: at(3)) == .wait)
    #expect(flow.step(list([]), site: site, now: at(6.4)) == .finish([]))
  }

  @Test func `a page without the list or its search field is a changed page`() {
    var flow = GoogleListFlow(started: start)
    _ = flow.step(list([], search: false), site: site, now: at(0.3))
    #expect(flow.step(list([], search: false), site: site, now: at(10)) == .wait)
    #expect(flow.step(list([], search: false), site: site, now: at(15.4)) == .fail(.pageChanged))
  }

  @Test func `a password check ends the read without typing anything`() {
    var flow = GoogleListFlow(started: start)
    let check = GoogleListSnapshot(url: "https://accounts.google.com/v3/signin/challenge/pwd", passwordField: true)
    #expect(flow.step(check, site: site, now: at(1)) == .fail(.checkTooSoon))
  }

  @Test func `Google's sign-in page ends the read as needing the person`() {
    var flow = GoogleListFlow(started: start)
    let signIn = GoogleListSnapshot(url: "https://accounts.google.com/v3/signin/identifier", text: "Sign in")
    #expect(flow.step(signIn, site: site, now: at(1)) == .fail(.signIn))
  }

  @Test func `a page that never answers times out`() {
    var flow = GoogleListFlow(started: start)
    #expect(flow.step(nil, site: site, now: at(14)) == .wait)
    #expect(flow.step(nil, site: site, now: at(15)) == .fail(.network))
    var slow = GoogleListFlow(started: start)
    #expect(slow.step(list(["a.example"]), site: site, now: at(30)) == .fail(.timeout))
  }
}

struct GoogleListLimitsTests {
  let now = Date(timeIntervalSince1970: 2_000_000)

  func ago(_ seconds: TimeInterval) -> Date { now.addingTimeInterval(-seconds) }

  @Test func `Sync Now reads at most once a minute and never waits for the hour`() {
    let limits = GoogleListLimits(lastAttempt: ago(59), lastSuccess: ago(59))
    #expect(limits.verdict(byPerson: true, now: now, busy: false, lastExport: ago(10), held: false) == .notDue(until: ago(-1)))
    let later = GoogleListLimits(lastAttempt: ago(60), lastSuccess: ago(60))
    #expect(later.verdict(byPerson: true, now: now, busy: false, lastExport: ago(10), held: false) == .go)
  }

  @Test func `automatic reads keep 15 minutes from the last read or export`() {
    #expect(GoogleListLimits().verdict(byPerson: false, now: now, busy: false, lastExport: ago(899), held: false) == .notDue(until: ago(-1)))
    #expect(GoogleListLimits(lastAttempt: ago(100)).verdict(byPerson: false, now: now, busy: false, lastExport: nil, held: false) == .notDue(until: ago(-800)))
    #expect(GoogleListLimits(lastAttempt: ago(900)).verdict(byPerson: false, now: now, busy: false, lastExport: ago(3600), held: false) == .go)
  }

  @Test func `a hold stops automatic reads but not the person's`() {
    #expect(GoogleListLimits().verdict(byPerson: false, now: now, busy: false, lastExport: nil, held: true) == .notDue(until: nil))
    #expect(GoogleListLimits().verdict(byPerson: true, now: now, busy: false, lastExport: nil, held: true) == .go)
  }

  @Test(arguments: [true, false])
  func `a read waits for any other hidden-page operation`(byPerson: Bool) {
    #expect(GoogleListLimits().verdict(byPerson: byPerson, now: now, busy: true, lastExport: nil, held: false) == .busy)
  }
}

struct GoogleSyncPlanTests {
  @Test(arguments: [GoogleWebTrigger.person, .personAnyway, .unlock, .schedule, .use, .afterSave])
  func `Sync Now only reads, whatever started it`(trigger: GoogleWebTrigger) {
    #expect(GoogleSyncPlan(trigger: trigger, readOnly: true) == GoogleSyncPlan(mayExport: false, mayRead: true, readByPerson: true))
  }

  @Test(arguments: [GoogleWebTrigger.person, .personAnyway, .afterSave])
  func `downloading the passwords and the reconcile after a save only export`(trigger: GoogleWebTrigger) {
    #expect(GoogleSyncPlan(trigger: trigger, readOnly: false) == GoogleSyncPlan(mayExport: true, mayRead: false, readByPerson: false))
  }

  @Test(arguments: [GoogleWebTrigger.unlock, .schedule, .use])
  func `automatic syncs export when the hour allows and read otherwise`(trigger: GoogleWebTrigger) {
    #expect(GoogleSyncPlan(trigger: trigger, readOnly: false) == GoogleSyncPlan(mayExport: true, mayRead: true, readByPerson: false))
  }
}
