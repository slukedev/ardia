import Foundation
import Testing

@testable import ArdiaVaultsCore

struct ChromeLoginReaderTests {
  @Test func `a missing file reads as missing`() {
    #expect(throws: ChromeReadError.missing) {
      try ChromeLoginReader.read(Fixture.profile.appendingPathComponent("No Such File"), store: .account)
    }
  }

  @Test func `a file that isn't a database doesn't read`() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ardia-chrome-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appendingPathComponent("Login Data")
    try Data(repeating: 7, count: 4096).write(to: file)
    #expect(throws: ChromeReadError.self) { try ChromeLoginReader.read(file, store: .device) }
  }

  @Test func `rows that only exist in the write-ahead log are read`() throws {
    let rows = try ChromeLoginReader.read(Fixture.profile.appendingPathComponent("Login Data"), store: .device)
    #expect(rows.map(\.username) == ["mac-only", "router", "octo@example.com"])
    #expect(rows.allSatisfy { $0.store == .device })
  }

  @Test func `reading leaves Chrome's folder untouched`() throws {
    let before = try FileManager.default.contentsOfDirectory(atPath: Fixture.profile.path).sorted()
    _ = try Fixture.logins()
    let after = try FileManager.default.contentsOfDirectory(atPath: Fixture.profile.path).sorted()
    #expect(after == before)
  }

  @Test func `a database Chrome has open is read through a backup without touching its folder`() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ardia-live-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appendingPathComponent("Login Data")
    let writer = try LiveDatabase(file)
    defer { writer.close() }
    try writer.insert(origin: "https://live.example/", username: "live-user")
    #expect(ChromeLoginReader.isLive(file))
    let before = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
    let rows = try ChromeLoginReader.read(file, store: .device)
    #expect(rows.map(\.username) == ["live-user"])
    #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted() == before)
  }

  @Test func `stale private copies are swept and fresh ones kept`() throws {
    let base = FileManager.default.temporaryDirectory
    let old = base.appendingPathComponent("ardia-chrome-sweep-old-\(UUID().uuidString)")
    let fresh = base.appendingPathComponent("ardia-chrome-sweep-fresh-\(UUID().uuidString)")
    for folder in [old, fresh] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
    defer { for folder in [old, fresh] { try? FileManager.default.removeItem(at: folder) } }
    try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-3_600)], ofItemAtPath: old.path)
    ChromeLoginReader.sweepStaleCopies()
    #expect(FileManager.default.fileExists(atPath: old.path) == false)
    #expect(FileManager.default.fileExists(atPath: fresh.path))
  }

  @Test func `the account store's columns come through`() throws {
    let rows = try ChromeLoginReader.read(Fixture.profile.appendingPathComponent("Login Data For Account"), store: .account)
    let github = try #require(rows.first { $0.originURL == "https://github.com/login" })
    #expect(github.signonRealm == "https://github.com/")
    #expect(github.passwordModified > github.created)
    #expect(rows.contains { $0.blacklisted })
    #expect(rows.contains { $0.federationURL == "https://accounts.google.com" })
  }
}

struct ChromeLoginMappingTests {
  @Test(arguments: ["", "account", "account.", "cloud.0123456789abcdef0123456789abcdef", "account.0123456789ABCDEF0123456789ABCDEF",
                    "account.0123456789abcdef0123456789abcde", "account.0123456789abcdef0123456789abcdef0", "--account.x",
                    "device.0123456789abcdef0123456789abcdeg", "account.0123456789abcdef.0123456789abcde"])
  func `malformed ids are refused`(id: String) {
    #expect(ChromeLoginMapping.isValidId(id) == false)
  }

  @Test func `ids are valid, stable and differ by store`() {
    let account = Fixture.login(.account)
    let device = Fixture.login(.device)
    #expect(ChromeLoginMapping.isValidId(account.id))
    #expect(account.id == Fixture.login(.account).id)
    #expect(account.id.hasPrefix("account."))
    #expect(device.id.hasPrefix("device."))
    #expect(account.id.dropFirst(8) != device.id.dropFirst(7))
  }

  @Test func `an id ignores the password and dates`() {
    var changed = Fixture.login()
    changed.encryptedPassword = Data("v10other".utf8)
    changed.passwordModified = 99
    #expect(changed.id == Fixture.login().id)
  }

  @Test(arguments: [
    { (login: inout ChromeLogin) in login.blacklisted = true },
    { (login: inout ChromeLogin) in login.federationURL = "https://accounts.google.com" },
    { (login: inout ChromeLogin) in login.encryptedPassword = Data() },
    { (login: inout ChromeLogin) in login.originURL = "android://hash@com.example.app/" },
    { (login: inout ChromeLogin) in login.originURL = "ftp://example.com/" },
    { (login: inout ChromeLogin) in login.originURL = "" },
  ])
  func `logins Ardia can't fill are left out`(change: (inout ChromeLogin) -> Void) {
    var login = Fixture.login()
    change(&login)
    #expect(ChromeLoginMapping.isWebLogin(login) == false)
    #expect(ChromeLoginMapping.merged([login]).isEmpty)
  }

  @Test func `the account copy wins over the same login on this Mac`() {
    let device = Fixture.login(.device)
    let account = Fixture.login(.account)
    #expect(ChromeLoginMapping.merged([device, account]).map(\.store) == [.account])
  }

  @Test func `a row maps to an item with its store, title and date`() {
    var login = Fixture.login(.device, origin: "https://www.shop.example/cart")
    login.created = ChromeTime.chrome(Date(timeIntervalSince1970: 1_000))
    let item = ChromeLoginMapping.item(login, provider: "google")
    #expect(item.provider == "google")
    #expect(item.title == "shop.example")
    #expect(item.urls == ["https://www.shop.example/cart"])
    #expect(item.vault == "On This Mac")
    #expect(item.hasTotp == false)
    #expect(item.updatedAt == 1_000_000)
  }

  @Test func `a later password change sets the date`() {
    var login = Fixture.login()
    login.created = ChromeTime.chrome(Date(timeIntervalSince1970: 1_000))
    login.passwordModified = ChromeTime.chrome(Date(timeIntervalSince1970: 2_000))
    #expect(ChromeLoginMapping.item(login, provider: "google").updatedAt == 2_000_000)
  }

  @Test func `the wrong key opens nothing and says so`() throws {
    let wrong = try #require(ChromeCrypto.deriveKey(secret: Data("some-other-secret".utf8)))
    let list = ChromeLoginMapping.list(try Fixture.logins(), key: wrong, provider: "google")
    #expect(list.items.count == 1)
    #expect(list.keyFits)
    let only = ChromeLoginMapping.list(try Fixture.logins().filter { $0.originURL != "https://wrongkey.example/" }, key: wrong, provider: "google")
    #expect(only.items.isEmpty)
    #expect(only.keyFits == false)
  }

  @Test func `no logins at all fit any key`() {
    #expect(ChromeLoginMapping.list([], key: Data(), provider: "google").keyFits)
  }

  @Test func `the fixture lists the fillable logins with their passwords`() throws {
    let list = ChromeLoginMapping.list(try Fixture.logins(), key: try Fixture.key, provider: "google")
    let byTitle = Dictionary(uniqueKeysWithValues: list.items.map { ($0.title, $0) })
    #expect(list.items.map(\.title) == ["127.0.0.1", "accounts.google.com", "github.com", "local.example", "localhost", "shop.example"])
    #expect(list.undecryptable == 1)
    #expect(byTitle["github.com"]?.vault == "Google Account")
    #expect(byTitle["local.example"]?.vault == "On This Mac")
    #expect(byTitle["localhost"]?.urls == ["http://localhost:3000/login"])
    let github = try #require(byTitle["github.com"])
    #expect(list.passwords[github.id] == "gh-fixture-pass")
    let shop = try #require(byTitle["shop.example"])
    #expect(list.passwords[shop.id] == "pässwörd 🔑")
    #expect(Set(list.passwords.keys) == Set(list.items.map(\.id)))
  }
}
