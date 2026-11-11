import CommonCrypto
import CryptoKit
import Foundation
import SQLite3

enum ChromeStore: String, CaseIterable, Sendable {
  case account
  case device

  var fileName: String { self == .account ? "Login Data For Account" : "Login Data" }
  var vaultName: String { self == .account ? "Google Account" : "On This Mac" }
}

struct ChromeLogin: Equatable, Sendable {
  var store: ChromeStore
  var originURL: String
  var username: String
  var signonRealm: String
  var encryptedPassword: Data
  var blacklisted = false
  var federationURL = ""
  var created: Int64 = 0
  var lastUsed: Int64 = 0
  var passwordModified: Int64 = 0

  var id: String { ChromeLoginMapping.id(self) }
}

enum ChromeReadError: Error, Equatable, Sendable {
  case missing
  case busy
  case unreadable(String)
}

enum ChromeTime {
  static let unixEpochOffset: Int64 = 11_644_473_600_000_000

  static func milliseconds(_ chrome: Int64) -> Double? {
    guard chrome > unixEpochOffset else { return nil }
    return Double((chrome - unixEpochOffset) / 1000)
  }

  static func chrome(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1_000_000).rounded()) + unixEpochOffset }
}

enum ChromeCrypto {
  static let prefix = Data("v10".utf8)
  static let keyLength = kCCKeySizeAES128

  private static let salt = Data("saltysalt".utf8)
  private static let rounds: UInt32 = 1003
  private static let iv = Data(repeating: 0x20, count: kCCBlockSizeAES128)

  static func deriveKey(secret: Data) -> Data? {
    guard !secret.isEmpty else { return nil }
    var key = Data(count: keyLength)
    let status = key.withUnsafeMutableBytes { out in
      secret.withUnsafeBytes { secret in
        salt.withUnsafeBytes { salt in
          CCKeyDerivationPBKDF(
            CCPBKDFAlgorithm(kCCPBKDF2), secret.bindMemory(to: Int8.self).baseAddress, secret.count,
            salt.bindMemory(to: UInt8.self).baseAddress, salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), rounds,
            out.bindMemory(to: UInt8.self).baseAddress, keyLength)
        }
      }
    }
    return status == kCCSuccess ? key : nil
  }

  static func isEncrypted(_ value: Data) -> Bool { value.count > prefix.count && value.prefix(prefix.count) == prefix }

  static func decrypt(_ value: Data, key: Data) -> String? {
    guard let plain = crypt(CCOperation(kCCDecrypt), value, key: key) else { return nil }
    return String(data: plain, encoding: .utf8)
  }

  static func encrypt(_ plain: String, key: Data) -> Data? {
    guard key.count == keyLength else { return nil }
    return crypt(CCOperation(kCCEncrypt), Data(plain.utf8), key: key).map { prefix + $0 }
  }

  static func hex(_ key: Data) -> String { key.map { String(format: "%02x", $0) }.joined() }

  static func key(hex: String) -> Data? {
    guard hex.count == keyLength * 2, hex.allSatisfy(\.isHexDigit) else { return nil }
    var bytes = Data(capacity: keyLength)
    var index = hex.startIndex
    while index < hex.endIndex {
      let next = hex.index(index, offsetBy: 2)
      guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
      bytes.append(byte)
      index = next
    }
    return bytes
  }

  private static func crypt(_ operation: CCOperation, _ value: Data, key: Data) -> Data? {
    guard key.count == keyLength else { return nil }
    let input: Data
    if operation == CCOperation(kCCDecrypt) {
      guard isEncrypted(value) else { return nil }
      input = Data(value.dropFirst(prefix.count))
      guard input.count % kCCBlockSizeAES128 == 0 else { return nil }
    } else {
      input = value
    }
    var output = Data(count: input.count + kCCBlockSizeAES128)
    let capacity = output.count
    var written = 0
    let status = output.withUnsafeMutableBytes { out in
      input.withUnsafeBytes { input in
        iv.withUnsafeBytes { iv in
          key.withUnsafeBytes { key in
            CCCrypt(
              operation, CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding), key.baseAddress, key.count, iv.baseAddress,
              input.baseAddress, input.count, out.baseAddress, capacity, &written)
          }
        }
      }
    }
    guard status == kCCSuccess else { return nil }
    return output.prefix(written)
  }
}

struct ChromeLoginList: Sendable {
  var items: [VaultItem] = []
  var passwords: [String: String] = [:]
  var candidates = 0
  var undecryptable = 0

  var keyFits: Bool { candidates == 0 || undecryptable < candidates }
}

enum ChromeLoginMapping {
  static func id(_ login: ChromeLogin) -> String {
    let source = [login.store.rawValue, login.originURL, login.username, login.signonRealm].joined(separator: "\u{0}")
    let digest = SHA256.hash(data: Data(source.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    return "\(login.store.rawValue).\(digest)"
  }

  static func isValidId(_ id: String) -> Bool {
    let parts = id.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 2, ChromeStore(rawValue: String(parts[0])) != nil, parts[1].count == 32 else { return false }
    return parts[1].allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
  }

  static func isWebLogin(_ login: ChromeLogin) -> Bool {
    guard !login.blacklisted, login.federationURL.isEmpty, !login.encryptedPassword.isEmpty else { return false }
    let scheme = URLComponents(string: login.originURL)?.scheme?.lowercased()
    return (scheme == "https" || scheme == "http") && VaultOriginMatch.host(of: login.originURL) != nil
  }

  static func merged(_ logins: [ChromeLogin]) -> [ChromeLogin] {
    var seenLogins = Set<String>()
    var seenIds = Set<String>()
    var kept: [ChromeLogin] = []
    let ordered = logins.filter(isWebLogin).enumerated().sorted { first, second in
      let firstRank = first.element.store == .account ? 0 : 1
      let secondRank = second.element.store == .account ? 0 : 1
      if firstRank != secondRank { return firstRank < secondRank }
      let firstChanged = changed(first.element)
      let secondChanged = changed(second.element)
      return firstChanged != secondChanged ? firstChanged > secondChanged : first.offset < second.offset
    }.map(\.element)
    for login in ordered {
      let key = "\(login.signonRealm)\u{0}\(login.username)"
      guard seenIds.insert(login.id).inserted, seenLogins.insert(key).inserted else { continue }
      kept.append(login)
    }
    return kept
  }

  static func item(_ login: ChromeLogin, provider: String) -> VaultItem {
    VaultItem(
      provider: provider, id: login.id, title: title(login), username: login.username, urls: [login.originURL], hasTotp: false,
      vault: login.store.vaultName, favorite: nil, updatedAt: ChromeTime.milliseconds(changed(login)))
  }

  static func list(_ logins: [ChromeLogin], key: Data, provider: String) -> ChromeLoginList {
    var list = ChromeLoginList()
    for login in merged(logins) {
      list.candidates += 1
      guard let password = ChromeCrypto.decrypt(login.encryptedPassword, key: key) else {
        list.undecryptable += 1
        continue
      }
      guard !password.isEmpty else { continue }
      let item = item(login, provider: provider)
      list.items.append(item)
      list.passwords[item.id] = password
    }
    list.items.sort { ($0.title.lowercased(), $0.username.lowercased()) < ($1.title.lowercased(), $1.username.lowercased()) }
    return list
  }

  static func title(_ login: ChromeLogin) -> String {
    let host = VaultOriginMatch.host(of: login.originURL) ?? VaultOriginMatch.host(of: login.signonRealm) ?? login.originURL
    return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
  }

  static func changed(_ login: ChromeLogin) -> Int64 { login.passwordModified > 0 ? login.passwordModified : login.created }
}

enum ChromeLoginReader {
  static func read(_ file: URL, store: ChromeStore) throws(ChromeReadError) -> [ChromeLogin] {
    do {
      return try readOnce(file, store: store)
    } catch .busy {
      return try readOnce(file, store: store)
    }
  }

  static func modified(_ file: URL) -> Date? {
    [file.path, file.path + "-wal"].compactMap { path in
      (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }.max()
  }

  static func sweepStaleCopies(olderThan age: TimeInterval = 600, now: Date = Date()) {
    let manager = FileManager.default
    let base = manager.temporaryDirectory
    for name in (try? manager.contentsOfDirectory(atPath: base.path)) ?? [] where name.hasPrefix(copyPrefix) {
      let folder = base.appendingPathComponent(name, isDirectory: true)
      let modified = (try? manager.attributesOfItem(atPath: folder.path))?[.modificationDate] as? Date ?? .distantPast
      if now.timeIntervalSince(modified) >= age { try? manager.removeItem(at: folder) }
    }
  }

  private static let copyPrefix = "ardia-chrome-"

  private static func readOnce(_ file: URL, store: ChromeStore) throws(ChromeReadError) -> [ChromeLogin] {
    let manager = FileManager.default
    guard manager.fileExists(atPath: file.path) else { throw .missing }
    let folder = manager.temporaryDirectory.appendingPathComponent("\(copyPrefix)\(UUID().uuidString)", isDirectory: true)
    defer { try? manager.removeItem(at: folder) }
    let copy = folder.appendingPathComponent("logins.sqlite")
    do {
      try manager.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    } catch {
      throw .unreadable("Ardia couldn't make a private folder to read Chrome's passwords.")
    }
    if isLive(file), backUp(file, to: copy) { return try query(copy, store: store) }
    for suffix in ["", "-wal", "-journal", "-shm"] { try? manager.removeItem(atPath: copy.path + suffix) }
    let before = signature(file)
    do {
      try manager.copyItem(at: file, to: copy)
      for suffix in ["-wal", "-journal"] where manager.fileExists(atPath: file.path + suffix) {
        try manager.copyItem(atPath: file.path + suffix, toPath: copy.path + suffix)
      }
    } catch {
      throw manager.fileExists(atPath: file.path) ? .busy : .missing
    }
    guard signature(file) == before else { throw .busy }
    return try query(copy, store: store)
  }

  static func isLive(_ file: URL) -> Bool {
    ["-wal", "-shm"].allSatisfy { FileManager.default.fileExists(atPath: file.path + $0) }
  }

  private static func backUp(_ file: URL, to copy: URL) -> Bool {
    var source: OpaquePointer?
    var target: OpaquePointer?
    defer {
      sqlite3_close(target)
      sqlite3_close(source)
    }
    let uri = URL(fileURLWithPath: file.path).absoluteString + "?mode=ro"
    guard sqlite3_open_v2(uri, &source, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK, let source,
      sqlite3_open_v2(copy.path, &target, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK, let target,
      let backup = sqlite3_backup_init(target, "main", source, "main")
    else { return false }
    let step = sqlite3_backup_step(backup, -1)
    let finished = sqlite3_backup_finish(backup)
    return step == SQLITE_DONE && finished == SQLITE_OK
  }

  private static func signature(_ file: URL) -> [String] {
    [file.path, file.path + "-wal", file.path + "-journal"].map { path in
      guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else { return "-" }
      let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate ?? 0
      return "\(modified):\((attributes[.size] as? NSNumber)?.int64Value ?? -1)"
    }
  }

  private static func query(_ copy: URL, store: ChromeStore) throws(ChromeReadError) -> [ChromeLogin] {
    var db: OpaquePointer?
    defer { sqlite3_close(db) }
    guard sqlite3_open_v2(copy.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else {
      throw .unreadable("Chrome's password file didn't open.")
    }
    sqlite3_busy_timeout(db, 2000)
    var statement: OpaquePointer?
    defer { sqlite3_finalize(statement) }
    let prepared = sqlite3_prepare_v2(db, "SELECT * FROM logins", -1, &statement, nil)
    guard prepared == SQLITE_OK, let statement else { throw error(prepared, db) }
    var columns: [String: Int32] = [:]
    for index in 0..<sqlite3_column_count(statement) {
      if let name = sqlite3_column_name(statement, index) { columns[String(cString: name)] = index }
    }
    func text(_ name: String) -> String {
      guard let index = columns[name], let value = sqlite3_column_text(statement, index) else { return "" }
      return String(cString: value)
    }
    func integer(_ name: String) -> Int64 {
      guard let index = columns[name] else { return 0 }
      return sqlite3_column_int64(statement, index)
    }
    func blob(_ name: String) -> Data {
      guard let index = columns[name], let bytes = sqlite3_column_blob(statement, index) else { return Data() }
      return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, index)))
    }
    var logins: [ChromeLogin] = []
    while true {
      let step = sqlite3_step(statement)
      if step == SQLITE_DONE { return logins }
      guard step == SQLITE_ROW else { throw error(step, db) }
      logins.append(
        ChromeLogin(
          store: store, originURL: text("origin_url"), username: text("username_value"), signonRealm: text("signon_realm"),
          encryptedPassword: blob("password_value"), blacklisted: integer("blacklisted_by_user") != 0,
          federationURL: text("federation_url"), created: integer("date_created"), lastUsed: integer("date_last_used"),
          passwordModified: integer("date_password_modified")))
    }
  }

  private static func error(_ code: Int32, _ db: OpaquePointer) -> ChromeReadError {
    switch code & 0xff {
    case SQLITE_BUSY, SQLITE_LOCKED, SQLITE_CORRUPT, SQLITE_NOTADB: return .busy
    default: return .unreadable("Chrome's password file didn't read (\(String(cString: sqlite3_errmsg(db)))).")
    }
  }
}
