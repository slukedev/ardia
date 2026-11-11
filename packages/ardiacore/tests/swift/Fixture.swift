import Foundation
import SQLite3

@testable import ArdiaVaultsCore

enum Fixture {
  static let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
  static let chrome = packageRoot.appendingPathComponent("tests/fixtures/google/Chrome", isDirectory: true)
  static let profile = chrome.appendingPathComponent("Default", isDirectory: true)

  static var secret: Data {
    get throws {
      let file = packageRoot.appendingPathComponent("../import/fixtures/secrets.json")
      let secrets = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: file))
      return Data((secrets["chromiumSafeStorageSecret"] ?? "").utf8)
    }
  }

  static var key: Data {
    get throws { try ChromeCrypto.deriveKey(secret: secret) ?? Data() }
  }

  static func logins() throws -> [ChromeLogin] {
    try ChromeStore.allCases.flatMap { store in try ChromeLoginReader.read(profile.appendingPathComponent(store.fileName), store: store) }
  }

  static func login(_ store: ChromeStore = .account, origin: String = "https://example.com/login", username: String = "sam",
                    password: Data = Data("v10-placeholder".utf8)) -> ChromeLogin {
    ChromeLogin(store: store, originURL: origin, username: username, signonRealm: "https://example.com/", encryptedPassword: password)
  }
}

final class LiveDatabase {
  private var db: OpaquePointer?

  init(_ file: URL) throws {
    guard sqlite3_open(file.path, &db) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
    try run("PRAGMA journal_mode=WAL")
    try run("PRAGMA wal_autocheckpoint=0")
    try run("""
      CREATE TABLE logins (origin_url VARCHAR NOT NULL, username_value VARCHAR, password_value BLOB, signon_realm VARCHAR NOT NULL,
        date_created INTEGER NOT NULL DEFAULT 0, blacklisted_by_user INTEGER NOT NULL DEFAULT 0)
      """)
  }

  func insert(origin: String, username: String) throws {
    try run("INSERT INTO logins(origin_url, username_value, password_value, signon_realm) VALUES ('\(origin)', '\(username)', x'00', '\(origin)')")
  }

  func close() {
    sqlite3_close(db)
    db = nil
  }

  private func run(_ sql: String) throws {
    guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
  }
}
