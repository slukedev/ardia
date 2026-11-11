import CryptoKit
import Foundation

struct ChromeHandoff: Equatable, Sendable {
  var id: String
  var host: String
  var url: String
  var username: String
  var passwordDigest: Data
  var started: Date
  var lastModified: Date? = nil
}

enum ChromeHandoffStep: Equatable, Sendable {
  case waiting(ChromeHandoff)
  case saved
  case expired
}

enum ChromeKeyVerdict: Equatable, Sendable {
  case fits
  case wrongKey
  case unknown(String)
}

enum ChromeHandoffRules {
  static let lifetime: TimeInterval = 600
  static let clockSlack: Int64 = 5_000_000

  static func digest(_ password: String) -> Data { Data(SHA256.hash(data: Data(password.utf8))) }

  static func sameOrigin(_ first: String, _ second: String) -> Bool {
    guard let one = VaultOriginMatch.parts(of: first, assumingHTTPS: false), let two = VaultOriginMatch.parts(of: second, assumingHTTPS: false)
    else { return false }
    return one.scheme == two.scheme && one.host == two.host && (one.port ?? defaultPort(one.scheme)) == (two.port ?? defaultPort(two.scheme))
  }

  static func isSaved(_ handoff: ChromeHandoff, rows: [ChromeLogin], key: Data?) -> Bool {
    let since = ChromeTime.chrome(handoff.started) - clockSlack
    return rows.contains { row in
      guard !row.blacklisted, row.username == handoff.username,
        sameOrigin(row.originURL, handoff.url) || sameOrigin(row.signonRealm, handoff.url)
      else { return false }
      if max(row.created, row.passwordModified) >= since { return true }
      guard let key, let password = ChromeCrypto.decrypt(row.encryptedPassword, key: key) else { return false }
      return digest(password) == handoff.passwordDigest
    }
  }

  static func step(_ handoff: ChromeHandoff, now: Date, modified: Date?, key: Data?, read: () -> [ChromeLogin]?) -> ChromeHandoffStep {
    if now.timeIntervalSince(handoff.started) >= lifetime { return .expired }
    if handoff.lastModified != nil, modified == handoff.lastModified { return .waiting(handoff) }
    guard let rows = read() else { return .waiting(handoff) }
    if isSaved(handoff, rows: rows, key: key) { return .saved }
    var next = handoff
    next.lastModified = modified ?? .distantPast
    return .waiting(next)
  }

  static func verdict(_ logins: Result<[ChromeLogin], Error>, key: Data) -> ChromeKeyVerdict {
    switch logins {
    case .success(let rows): return ChromeLoginMapping.list(rows, key: key, provider: "").keyFits ? .fits : .wrongKey
    case .failure(VaultError.failed(let message)): return .unknown(message)
    case .failure: return .unknown("Ardia couldn't read Chrome's passwords.")
    }
  }

  private static func defaultPort(_ scheme: String) -> Int { scheme == "http" ? 80 : 443 }
}
