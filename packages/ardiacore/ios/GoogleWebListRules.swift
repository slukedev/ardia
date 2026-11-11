import Foundation

struct GoogleListSelectors: Codable, Equatable, Sendable {
  var rows = "li[data-id]"
  var rowLinks = "a[href*=\"password/\"]"
  var searchFields = "input[type=text], input[type=search]"

  static let current = GoogleListSelectors()
}

struct GoogleListSite: Equatable, Sendable {
  var name: String
  var count: Int?

  static let countPattern = #"^(\d+)\s+(accounts?|passwords?)$"#

  static func parse(lines: [String]) -> GoogleListSite? {
    let trimmed = lines.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    guard let name = trimmed.first?.lowercased() else { return nil }
    let count = trimmed.dropFirst().lazy.compactMap(Self.count(in:)).first
    return GoogleListSite(name: name, count: count)
  }

  static func count(in line: String) -> Int? {
    guard let pattern = try? NSRegularExpression(pattern: countPattern, options: [.caseInsensitive]),
      let match = pattern.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
      let range = Range(match.range(at: 1), in: line)
    else { return nil }
    return Int(line[range])
  }

  var looksLikeHost: Bool {
    !name.isEmpty && name.contains(".") && !name.contains(" ") && !name.hasPrefix(".") && !name.hasSuffix(".")
  }
}

struct GoogleListSnapshot: Codable, Equatable, Sendable {
  struct Row: Codable, Equatable, Sendable {
    var lines: [String]
  }

  var url: String
  var ready: Bool = true
  var rows: [Row] = []
  var searchField: Bool = false
  var passwordField: Bool = false
  var captcha: Bool = false
  var text: String = ""

  static func parse(_ json: String?) -> GoogleListSnapshot? {
    guard let data = json?.data(using: .utf8) else { return nil }
    return try? JSONDecoder().decode(GoogleListSnapshot.self, from: data)
  }

  var sites: [GoogleListSite] {
    var seen = Set<String>()
    return rows.compactMap { GoogleListSite.parse(lines: $0.lines) }.filter { seen.insert($0.name).inserted }
  }

  var importSnapshot: GoogleImportSnapshot {
    GoogleImportSnapshot(url: url, text: text, passwordField: passwordField, captcha: captcha, ready: ready)
  }
}

enum GoogleListAction: Equatable, Sendable {
  case wait
  case finish([GoogleListSite])
  case fail(GoogleImportError)
}

struct GoogleListFlow: Sendable {
  static let overallTimeout: TimeInterval = 30
  static let stepTimeout: TimeInterval = 15
  static let settleTime: TimeInterval = 1.5
  static let emptyWait: TimeInterval = 6

  let started: Date
  var lastCount: Int?
  var countSince: Date?
  var readySince: Date?
  var stageSince: Date

  init(started: Date) {
    self.started = started
    stageSince = started
  }

  mutating func step(_ snapshot: GoogleListSnapshot?, site: GoogleImportSite, now: Date) -> GoogleListAction {
    if now >= started.addingTimeInterval(Self.overallTimeout) { return .fail(.timeout) }
    guard let snapshot else { return now.timeIntervalSince(stageSince) >= Self.stepTimeout ? .fail(.network) : .wait }
    if site.isAccounts(snapshot.url) {
      switch GoogleImportClassifier.classify(snapshot.importSnapshot, site: site) {
      case .passwordChallenge: return .fail(.checkTooSoon)
      case .insecureBrowser: return .fail(.insecureBrowser)
      case .loading: return .wait
      case let stage: return .fail(stage.needsPerson ?? .signIn)
      }
    }
    guard site.isPasswords(snapshot.url) else {
      let blank = snapshot.url.isEmpty || snapshot.url == "about:blank"
      return now.timeIntervalSince(stageSince) >= Self.stepTimeout ? .fail(blank ? .network : .pageChanged) : .wait
    }
    guard snapshot.ready else { return now.timeIntervalSince(stageSince) >= Self.stepTimeout ? .fail(.network) : .wait }
    if readySince == nil { readySince = now }
    let sites = snapshot.sites
    if sites.count != lastCount {
      lastCount = sites.count
      countSince = now
      return .wait
    }
    let steady = countSince.map { now.timeIntervalSince($0) >= Self.settleTime } ?? false
    if !sites.isEmpty { return steady ? .finish(sites) : .wait }
    let waited = readySince.map { now.timeIntervalSince($0) } ?? 0
    if snapshot.searchField, steady, waited >= Self.emptyWait { return .finish([]) }
    return waited >= Self.stepTimeout ? .fail(.pageChanged) : .wait
  }
}

struct GoogleListLimits: Equatable, Sendable {
  static let personSpacing: TimeInterval = 60
  static let automaticSpacing: TimeInterval = 900

  var lastAttempt: Date?
  var lastSuccess: Date?

  func verdict(byPerson: Bool, now: Date, busy: Bool, lastExport: Date?, held: Bool) -> GoogleWebVerdict {
    if busy { return .busy }
    if byPerson {
      guard let lastAttempt, now < lastAttempt.addingTimeInterval(Self.personSpacing) else { return .go }
      return .notDue(until: lastAttempt.addingTimeInterval(Self.personSpacing))
    }
    if held { return .notDue(until: nil) }
    let latest = [lastAttempt, lastSuccess, lastExport].compactMap { $0 }.max()
    guard let latest, now < latest.addingTimeInterval(Self.automaticSpacing) else { return .go }
    return .notDue(until: latest.addingTimeInterval(Self.automaticSpacing))
  }

  mutating func started(_ now: Date) { lastAttempt = now }
  mutating func succeeded(_ now: Date) { lastSuccess = now }
}

struct GoogleListReconcile: Equatable, Sendable {
  var items: [VaultItem]
  var added: Int
  var dropped: Int
}

enum GoogleListRows {
  static let placeholderScheme = "site:"

  static func placeholderId(site name: String) -> String {
    GoogleExportCSV.itemId(url: placeholderScheme + name.lowercased(), username: "")
  }

  static func placeholderIds(for url: String) -> Set<String> {
    guard var host = VaultOriginMatch.host(of: url)?.lowercased() else { return [] }
    var ids: Set<String> = []
    while host.contains(".") {
      ids.insert(placeholderId(site: host))
      host = String(host.drop { $0 != "." }.dropFirst())
    }
    return ids
  }

  static func placeholder(_ site: GoogleListSite, provider: String) -> VaultItem {
    VaultItem(
      provider: provider, id: placeholderId(site: site.name), title: site.name, username: "", urls: ["https://\(site.name)/"], hasTotp: false,
      vault: GoogleExportCSV.vaultName)
  }

  static func isPlaceholder(_ item: VaultItem) -> Bool {
    item.username.isEmpty && item.urls.count == 1 && item.id == placeholderId(site: VaultOriginMatch.host(of: item.urls[0]) ?? "")
  }

  static func site(of item: VaultItem, in sites: [GoogleListSite]) -> GoogleListSite? {
    guard let host = item.urls.lazy.compactMap(VaultOriginMatch.host(of:)).first else { return nil }
    return sites.first { VaultOriginMatch.hostsMatch(host, $0.name) }
  }

  static func reconcile(previous: [VaultItem], sites: [GoogleListSite], provider: String) -> GoogleListReconcile? {
    if sites.isEmpty, !previous.isEmpty { return nil }
    var kept: [VaultItem] = []
    var known: [String: Int] = [:]
    var dropped = 0
    for item in previous where !isPlaceholder(item) {
      guard let site = site(of: item, in: sites) else {
        dropped += 1
        continue
      }
      kept.append(item)
      known[site.name, default: 0] += 1
    }
    let realCount = previous.count - previous.filter(isPlaceholder).count
    if dropped > max(2, realCount / 2) { return nil }
    var added = 0
    let hadPlaceholder = Set(previous.filter(isPlaceholder).map(\.id))
    for site in sites where site.looksLikeHost {
      let listed = known[site.name] ?? 0
      guard listed == 0 || (site.count ?? 0) > listed else { continue }
      let item = placeholder(site, provider: provider)
      if !hadPlaceholder.contains(item.id) { added += 1 }
      kept.append(item)
    }
    kept.sort { ($0.title.lowercased(), $0.username.lowercased(), $0.id) < ($1.title.lowercased(), $1.username.lowercased(), $1.id) }
    return GoogleListReconcile(items: kept, added: added, dropped: dropped)
  }

  static func row(for itemId: String, in rows: [GoogleExportRow]) -> GoogleExportRow? {
    if let exact = rows.first(where: { GoogleExportCSV.itemId(url: $0.url, username: $0.username) == itemId }) { return exact }
    let bySite = rows.filter { !$0.password.isEmpty && placeholderIds(for: $0.url).contains(itemId) }
    return bySite.count == 1 ? bySite[0] : nil
  }
}

struct GoogleSyncPlan: Equatable, Sendable {
  var mayExport: Bool
  var mayRead: Bool
  var readByPerson: Bool

  init(trigger: GoogleWebTrigger, readOnly: Bool) {
    if readOnly {
      self.init(mayExport: false, mayRead: true, readByPerson: true)
      return
    }
    switch trigger {
    case .person, .personAnyway, .afterSave:
      self.init(mayExport: true, mayRead: false, readByPerson: false)
    case .unlock, .schedule, .use:
      self.init(mayExport: true, mayRead: true, readByPerson: false)
    }
  }

  init(mayExport: Bool, mayRead: Bool, readByPerson: Bool) {
    self.mayExport = mayExport
    self.mayRead = mayRead
    self.readByPerson = readByPerson
  }
}
