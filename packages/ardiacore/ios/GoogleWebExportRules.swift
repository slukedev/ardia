import CryptoKit
import Foundation

enum GoogleWebTrigger: String, Sendable {
  case unlock
  case schedule
  case person
  case use
  case afterSave
}

struct GoogleWebAdmission: Equatable, Sendable {
  var verdict: GoogleWebVerdict
  var mayAnswerCheck: Bool
}

enum GoogleWebVerdict: Equatable, Sendable {
  case go
  case busy
  case notDue(until: Date?)
  case held(GoogleImportError)
}

struct GoogleWebLimits: Codable, Equatable, Sendable {
  static let refreshSpacing: TimeInterval = 3600
  static let checkSpacing: TimeInterval = 600
  static let personSpacing: TimeInterval = 60
  static let firstBackoff: TimeInterval = 900
  static let longestBackoff: TimeInterval = 21_600
  static let freshRefreshSpacing: TimeInterval = 900
  static let afterSaveSpacing: TimeInterval = 60
  static let raptLifetime: TimeInterval = 3600

  var lastSuccess: Date?
  var lastAttempt: Date?
  var lastCheck: Date?
  var failures = 0
  var lastFailure: Date?
  var held: GoogleImportError?

  static func backoff(afterFailures failures: Int) -> TimeInterval {
    guard failures > 0 else { return 0 }
    let doublings = min(failures - 1, 16)
    return min(firstBackoff * pow(2, Double(doublings)), longestBackoff)
  }

  func verdict(_ trigger: GoogleWebTrigger, now: Date, busy: Bool) -> GoogleWebVerdict {
    admission(trigger, now: now, busy: busy, raptSeen: nil).verdict
  }

  func admission(_ trigger: GoogleWebTrigger, now: Date, busy: Bool, raptSeen: Date?) -> GoogleWebAdmission {
    if busy { return GoogleWebAdmission(verdict: .busy, mayAnswerCheck: false) }
    let raptFresh = raptSeen.map { now.timeIntervalSince($0) < Self.raptLifetime } ?? false
    switch trigger {
    case .person:
      if let lastAttempt, now.timeIntervalSince(lastAttempt) < Self.personSpacing {
        return GoogleWebAdmission(verdict: .notDue(until: lastAttempt.addingTimeInterval(Self.personSpacing)), mayAnswerCheck: false)
      }
      return GoogleWebAdmission(verdict: .go, mayAnswerCheck: true)
    case .afterSave:
      guard raptFresh else { return GoogleWebAdmission(verdict: .notDue(until: nil), mayAnswerCheck: false) }
      if let held { return GoogleWebAdmission(verdict: .held(held), mayAnswerCheck: false) }
      var until = backoffEnd
      if let lastAttempt { until = later(until, lastAttempt.addingTimeInterval(Self.afterSaveSpacing)) }
      return checkless(until, now: now)
    case .use:
      if let held, raptFresh { return GoogleWebAdmission(verdict: .held(held), mayAnswerCheck: false) }
      guard raptFresh else { return GoogleWebAdmission(verdict: .notDue(until: nil), mayAnswerCheck: false) }
      return checkless(fastDue, now: now)
    case .unlock, .schedule:
      if let held { return GoogleWebAdmission(verdict: .held(held), mayAnswerCheck: false) }
      var slow = automaticGates
      if let lastSuccess { slow = later(slow, lastSuccess.addingTimeInterval(Self.refreshSpacing)) }
      if slow.map({ now >= $0 }) ?? true {
        let checkAllowed = mayAnswerCheck(byPerson: false, now: now)
        if raptFresh || checkAllowed { return GoogleWebAdmission(verdict: .go, mayAnswerCheck: checkAllowed) }
        return GoogleWebAdmission(verdict: .notDue(until: lastCheck?.addingTimeInterval(Self.checkSpacing)), mayAnswerCheck: false)
      }
      guard raptFresh else { return GoogleWebAdmission(verdict: .notDue(until: slow), mayAnswerCheck: false) }
      return checkless(fastDue, now: now)
    }
  }

  private var backoffEnd: Date? {
    guard let lastFailure, failures > 0 else { return nil }
    return lastFailure.addingTimeInterval(Self.backoff(afterFailures: failures))
  }

  private var automaticGates: Date? {
    var until = backoffEnd
    if let lastAttempt { until = later(until, lastAttempt.addingTimeInterval(Self.firstBackoff)) }
    return until
  }

  private var fastDue: Date? {
    var until = automaticGates
    if let lastSuccess { until = later(until, lastSuccess.addingTimeInterval(Self.freshRefreshSpacing)) }
    return until
  }

  private func checkless(_ until: Date?, now: Date) -> GoogleWebAdmission {
    if let until, now < until { return GoogleWebAdmission(verdict: .notDue(until: until), mayAnswerCheck: false) }
    return GoogleWebAdmission(verdict: .go, mayAnswerCheck: false)
  }

  func mayAnswerCheck(byPerson: Bool, now: Date) -> Bool {
    guard !byPerson, let lastCheck else { return true }
    return now.timeIntervalSince(lastCheck) >= Self.checkSpacing
  }

  mutating func started(_ now: Date) { lastAttempt = now }

  mutating func answeredCheck(_ now: Date) { lastCheck = now }

  mutating func succeeded(_ now: Date) {
    lastSuccess = now
    failures = 0
    lastFailure = nil
    held = nil
  }

  mutating func failed(_ error: GoogleImportError, now: Date) {
    if error.holdsAutomaticActivity {
      held = error
      return
    }
    guard error != .cancelled, error != .notAllowed, error != .checkTooSoon else { return }
    failures += 1
    lastFailure = now
  }

  mutating func personConfirmed() { held = nil }

  private func later(_ a: Date?, _ b: Date) -> Date { a.map { max($0, b) } ?? b }
}

extension GoogleImportError {
  var holdsAutomaticActivity: Bool {
    switch self {
    case .signIn, .twoStep, .captcha, .insecureBrowser, .unusualActivity, .onDeviceEncryption: return true
    default: return false
    }
  }
}

struct GoogleRapt: Equatable, Sendable {
  static let parameter = "rapt"

  var token: String
  var seen: Date

  static func token(in url: String, site: GoogleImportSite) -> String? {
    guard site.isPasswords(url), let parts = URLComponents(string: url) else { return nil }
    let value = parts.queryItems?.last { $0.name == parameter }?.value ?? ""
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.~"))
    guard !value.isEmpty, value.count <= 4096, value.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
    return value
  }

  static func url(_ base: String, adding rapt: GoogleRapt?) -> String {
    guard let rapt, var parts = URLComponents(string: base) else { return base }
    var items = (parts.queryItems ?? []).filter { $0.name != parameter }
    items.append(URLQueryItem(name: parameter, value: rapt.token))
    parts.queryItems = items
    return parts.string ?? base
  }
}

enum GoogleExportAction: Equatable, Sendable {
  case wait
  case clickExport
  case clickConfirmExport
  case fillPassword
  case finish
  case needPerson(GoogleImportError)
  case fail(GoogleImportError)
}

struct GoogleExportFlow: Sendable {
  static let overallTimeout: TimeInterval = 60
  static let stepTimeout: TimeInterval = 20
  static let personTimeout: TimeInterval = 300
  static let clickSpacing: TimeInterval = 4
  static let resubmitAfter: TimeInterval = 10
  static let exportClickLimit = 3

  let started: Date
  let mayAnswerCheck: Bool
  var stage: GoogleImportStage = .loading
  var stageSince: Date
  var exportClicks = 0
  var confirmClicks = 0
  var lastClick: Date?
  var passwordSubmissions = 0
  var lastSubmission: Date?
  var person: Date?

  init(started: Date, mayAnswerCheck: Bool) {
    self.started = started
    self.mayAnswerCheck = mayAnswerCheck
    stageSince = started
  }

  mutating func personStarted(_ now: Date) {
    if person == nil { person = now }
  }

  mutating func step(_ next: GoogleImportStage, exportButton: Bool, captured: Bool, now: Date) -> GoogleExportAction {
    if captured { return .finish }
    if next != stage {
      stage = next
      stageSince = now
    }
    let deadline = person.map { $0.addingTimeInterval(Self.personTimeout) } ?? started.addingTimeInterval(Self.overallTimeout)
    if now >= deadline { return .fail(.timeout) }
    if let error = next.needsPerson { return .needPerson(error) }
    let stuck = person == nil && now.timeIntervalSince(stageSince) >= Self.stepTimeout
    switch next {
    case .loading:
      return stuck ? .fail(.network) : .wait
    case .elsewhere:
      return stuck ? .fail(.pageChanged) : .wait
    case .options, .preparing:
      if exportButton, exportClicks < Self.exportClickLimit, spaced(now) {
        exportClicks += 1
        lastClick = now
        return .clickExport
      }
      return stuck ? .fail(.pageChanged) : .wait
    case .confirmExport:
      if confirmClicks < Self.exportClickLimit, spaced(now) {
        confirmClicks += 1
        lastClick = now
        return .clickConfirmExport
      }
      return stuck ? .fail(.pageChanged) : .wait
    case .passwordChallenge(let rejected):
      guard mayAnswerCheck else { return .fail(.checkTooSoon) }
      if rejected, passwordSubmissions > 0 { return .fail(.wrongPassword) }
      let resubmit = lastSubmission.map { now.timeIntervalSince($0) >= Self.resubmitAfter } == true
      if passwordSubmissions == 0 || (passwordSubmissions == 1 && resubmit) {
        passwordSubmissions += 1
        lastSubmission = now
        return .fillPassword
      }
      if passwordSubmissions >= 2, resubmit { return .fail(.wrongPassword) }
      return .wait
    case .insecureBrowser:
      return .fail(.insecureBrowser)
    case .onDeviceEncryption:
      return .fail(.onDeviceEncryption)
    case .selectFile, .readyToImport, .imported, .importFailed:
      return stuck ? .fail(.pageChanged) : .wait
    case .signIn, .twoStep, .captcha, .unusualActivity:
      return .wait
    }
  }

  private func spaced(_ now: Date) -> Bool {
    lastClick.map { now.timeIntervalSince($0) >= Self.clickSpacing } ?? true
  }
}

struct GoogleExportRow: Equatable, Sendable {
  var name: String
  var url: String
  var username: String
  var password: String
}

enum GoogleExportCSV {
  static let vaultName = "Google Account"
  static let largestText = 32 * 1024 * 1024

  static func records(_ text: String) -> [[String]] {
    var records: [[String]] = []
    var record: [String] = []
    var field = ""
    var quoted = false
    var fieldStarted = false
    var scalars = text.unicodeScalars.makeIterator()
    var pending: Unicode.Scalar? = nil
    func next() -> Unicode.Scalar? {
      if let held = pending {
        pending = nil
        return held
      }
      return scalars.next()
    }
    func endRecord() {
      record.append(field)
      if !(record.count == 1 && record[0].isEmpty) { records.append(record) }
      record = []
      field = ""
      fieldStarted = false
    }
    while let scalar = next() {
      if quoted {
        if scalar == "\"" {
          if let following = next() {
            if following == "\"" {
              field.unicodeScalars.append("\"")
            } else {
              quoted = false
              pending = following
            }
          } else {
            quoted = false
          }
        } else {
          field.unicodeScalars.append(scalar)
        }
        continue
      }
      switch scalar {
      case "\"" where !fieldStarted:
        quoted = true
        fieldStarted = true
      case ",":
        record.append(field)
        field = ""
        fieldStarted = false
      case "\r":
        if let following = next(), following != "\n" { pending = following }
        endRecord()
      case "\n":
        endRecord()
      default:
        field.unicodeScalars.append(scalar)
        fieldStarted = true
      }
    }
    if fieldStarted || !record.isEmpty { endRecord() }
    return records
  }

  static func rows(_ text: String) -> [GoogleExportRow]? {
    guard text.utf8.count <= largestText else { return nil }
    let body = text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
    var all = records(body)
    guard let header = all.first?.map({ $0.trimmingCharacters(in: .whitespaces).lowercased() }) else { return nil }
    guard let url = header.firstIndex(of: "url"), let username = header.firstIndex(of: "username"),
      let password = header.firstIndex(of: "password")
    else { return nil }
    let name = header.firstIndex(of: "name")
    all.removeFirst()
    return all.map { record in
      func value(_ index: Int?) -> String { index.flatMap { $0 < record.count ? record[$0] : nil } ?? "" }
      return GoogleExportRow(name: value(name), url: value(url), username: value(username), password: value(password))
    }
  }

  static func list(_ rows: [GoogleExportRow], provider: String) -> VaultItemList {
    var items: [VaultItem] = []
    var passwords: [String: String] = [:]
    for row in rows {
      guard !row.password.isEmpty, isWeb(row.url) else { continue }
      let id = itemId(url: row.url, username: row.username)
      guard passwords[id] == nil else { continue }
      let host = VaultOriginMatch.host(of: row.url) ?? row.url
      let named = row.name.trimmingCharacters(in: .whitespacesAndNewlines)
      let title = named.isEmpty ? (host.hasPrefix("www.") ? String(host.dropFirst(4)) : host) : named
      items.append(VaultItem(provider: provider, id: id, title: title, username: row.username, urls: [row.url], hasTotp: false, vault: vaultName))
      passwords[id] = row.password
    }
    items.sort { ($0.title.lowercased(), $0.username.lowercased(), $0.id) < ($1.title.lowercased(), $1.username.lowercased(), $1.id) }
    return VaultItemList(items: items, passwords: passwords)
  }

  static func itemId(url: String, username: String) -> String {
    let joined = [url, username].map { "\($0.utf8.count):\($0)" }.joined()
    let digest = SHA256.hash(data: Data(joined.utf8)).map { String(format: "%02x", $0) }.joined()
    return "web." + digest.prefix(32)
  }

  static func isValidId(_ id: String) -> Bool {
    guard id.hasPrefix("web.") else { return false }
    let hex = id.dropFirst(4)
    return hex.count == 32 && hex.allSatisfy { $0.isHexDigit && !$0.isUppercase }
  }

  private static func isWeb(_ url: String) -> Bool {
    guard let scheme = URLComponents(string: url)?.scheme?.lowercased() else { return false }
    return scheme == "https" || scheme == "http"
  }
}
