import Foundation
import Testing

@testable import ArdiaVaultsCore

struct ChromeHandoffRulesTests {
  let started = Date(timeIntervalSince1970: 1_800_000_000)

  func handoff(url: String = "https://github.com/login", username: String = "octo", password: String = "new-pass") -> ChromeHandoff {
    ChromeHandoff(
      id: "h1", host: "github.com", url: url, username: username,
      passwordDigest: ChromeHandoffRules.digest(password), started: started)
  }

  func row(_ store: ChromeStore = .account, origin: String = "https://github.com/", realm: String? = nil, username: String = "octo",
           password: String = "new-pass", at date: Date, key: Data) -> ChromeLogin {
    var login = ChromeLogin(
      store: store, originURL: origin, username: username, signonRealm: realm ?? origin,
      encryptedPassword: ChromeCrypto.encrypt(password, key: key) ?? Data())
    login.created = ChromeTime.chrome(date)
    return login
  }

  @Test func `an unrelated row doesn't count as saved`() throws {
    let key = try Fixture.key
    let later = started.addingTimeInterval(30)
    let rows = [
      row(origin: "https://gitlab.com/", at: later, key: key), row(username: "someone-else", at: later, key: key),
      row(origin: "http://github.com/", at: later, key: key),
    ]
    #expect(ChromeHandoffRules.isSaved(handoff(), rows: rows, key: key) == false)
  }

  @Test func `an older row with a different password isn't saved`() throws {
    let key = try Fixture.key
    let rows = [row(password: "old-pass", at: started.addingTimeInterval(-86_400), key: key)]
    #expect(ChromeHandoffRules.isSaved(handoff(), rows: rows, key: key) == false)
  }

  @Test func `a never-save row isn't saved`() throws {
    let key = try Fixture.key
    var blocked = row(at: started.addingTimeInterval(30), key: key)
    blocked.blacklisted = true
    #expect(ChromeHandoffRules.isSaved(handoff(), rows: [blocked], key: key) == false)
  }

  @Test(arguments: [ChromeStore.account, .device])
  func `a new row in either store is saved`(store: ChromeStore) throws {
    let key = try Fixture.key
    #expect(ChromeHandoffRules.isSaved(handoff(), rows: [row(store, password: "whatever", at: started.addingTimeInterval(30), key: key)], key: nil))
  }

  @Test(arguments: [ChromeStore.account, .device])
  func `an existing row with the same password is saved`(store: ChromeStore) throws {
    let key = try Fixture.key
    let rows = [row(store, at: started.addingTimeInterval(-86_400), key: key)]
    #expect(ChromeHandoffRules.isSaved(handoff(), rows: rows, key: key))
  }

  @Test func `an existing row can't be compared while locked`() throws {
    let key = try Fixture.key
    let rows = [row(at: started.addingTimeInterval(-86_400), key: key)]
    #expect(ChromeHandoffRules.isSaved(handoff(), rows: rows, key: nil) == false)
  }

  @Test func `the realm matches when the origin has a path`() throws {
    let key = try Fixture.key
    let rows = [row(origin: "https://github.com/session", realm: "https://github.com/", at: started.addingTimeInterval(30), key: key)]
    #expect(ChromeHandoffRules.isSaved(handoff(url: "https://github.com"), rows: rows, key: nil))
  }

  @Test func `a handoff expires after ten minutes without reading`() {
    var reads = 0
    let step = ChromeHandoffRules.step(handoff(), now: started.addingTimeInterval(600), modified: Date(), key: nil) {
      reads += 1
      return []
    }
    #expect(step == .expired)
    #expect(reads == 0)
  }

  @Test func `a failed read keeps the old change time so the next poll reads again`() {
    var watched = handoff()
    watched.lastModified = Date(timeIntervalSince1970: 1)
    let changed = Date(timeIntervalSince1970: 2)
    let step = ChromeHandoffRules.step(watched, now: started.addingTimeInterval(10), modified: changed, key: nil) { nil }
    #expect(step == .waiting(watched))
  }

  @Test func `an unchanged store isn't read again`() {
    var watched = handoff()
    watched.lastModified = Date(timeIntervalSince1970: 1)
    var reads = 0
    let step = ChromeHandoffRules.step(watched, now: started.addingTimeInterval(10), modified: watched.lastModified, key: nil) {
      reads += 1
      return []
    }
    #expect(step == .waiting(watched))
    #expect(reads == 0)
  }

  @Test func `a successful read without the login records the change time`() {
    let changed = Date(timeIntervalSince1970: 2)
    let step = ChromeHandoffRules.step(handoff(), now: started.addingTimeInterval(10), modified: changed, key: nil) { [] }
    var expected = handoff()
    expected.lastModified = changed
    #expect(step == .waiting(expected))
  }

  @Test func `the first poll reads even before anything changes`() throws {
    let key = try Fixture.key
    let existing = [row(at: started.addingTimeInterval(-86_400), key: key)]
    #expect(ChromeHandoffRules.step(handoff(), now: started.addingTimeInterval(2), modified: nil, key: key) { existing } == .saved)
  }

}

struct ChromeKeyVerdictTests {
  @Test func `a read that failed says nothing about the key`() throws {
    let verdict = ChromeHandoffRules.verdict(.failure(VaultError.failed("Chrome is busy with its passwords.")), key: try Fixture.key)
    #expect(verdict == .unknown("Chrome is busy with its passwords."))
  }

  @Test func `a signed-out read says nothing about the key`() throws {
    #expect(ChromeHandoffRules.verdict(.failure(VaultError.signedOut), key: try Fixture.key) == .unknown("Ardia couldn't read Chrome's passwords."))
  }

  @Test func `a key that opens no row is wrong`() throws {
    let wrong = try #require(ChromeCrypto.deriveKey(secret: Data("some-other-secret".utf8)))
    let rows = try Fixture.logins().filter { $0.originURL != "https://wrongkey.example/" }
    #expect(ChromeHandoffRules.verdict(.success(rows), key: wrong) == .wrongKey)
  }

  @Test func `the right key fits, and so does any key for no rows`() throws {
    #expect(ChromeHandoffRules.verdict(.success(try Fixture.logins()), key: try Fixture.key) == .fits)
    #expect(ChromeHandoffRules.verdict(.success([]), key: Data()) == .fits)
  }
}
