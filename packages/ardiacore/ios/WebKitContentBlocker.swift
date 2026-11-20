import CryptoKit
import Foundation
import WebKit

final class WebKitContentBlocker {
  static let shared = WebKitContentBlocker()
  static let changed = Notification.Name("ArdiaContentBlockerDidChange")

  private static let settingsWriter = DispatchQueue(label: "ardia.webkit-content-blocker.settings", qos: .utility)
  private static let userFilterParser = DispatchQueue(label: "ardia.webkit-content-blocker.user-filters", qos: .utility)
  private static let format = "f6"
  private static let listPrefix = "ardia-ubol-"
  private static let checkPrefix = "ardia-ubol-check-"
  private static let sources: [String: [String]] = [
    "ublock-filters": ["ublock-filters"],
    "pgl": ["plowe-0"],
    "ublock-badware": ["ublock-badware"],
    "urlhaus-full": ["urlhaus-1"],
    "annoyances-ai": ["fanboy-ai-suggestions"],
    "annoyances-cookies": ["fanboy-cookiemonster", "ublock-cookies-easylist", "adguard-cookies", "ublock-cookies-adguard"],
    "annoyances-overlays": ["easylist-newsletters", "ublock-annoyances", "adguard-popup-overlays"],
    "annoyances-social": ["fanboy-social", "fanboy-thirdparty_social", "adguard-social"],
    "annoyances-widgets": ["easylist-chat", "adguard-widgets"],
    "annoyances-others": ["easylist-annoyances", "adguard-other-annoyances"],
    "annoyances-notifications": ["easylist-notifications"],
  ]

  private struct Settings: Codable, Equatable {
    var enabled = true
    var lists: [String]?
    var allowedHosts: [String] = []
  }

  private struct Ruleset: Decodable {
    let id: String
    let enabled: Bool
    let scriptlets: [String]?
  }

  private struct Bundled: Decodable {
    let version: String
    let digest: String?
    let scriptletSecret: String?
    let rulesets: [Ruleset]
  }

  private struct UserRules {
    static let none = UserRules(digest: "", rules: [])

    let digest: String
    let rules: [WebKitUserFilters.NetworkRule]
  }

  private struct RejectedUserFilters: Codable {
    let digest: String
    let error: String
    var rules: [String]?
  }

  private final class AppliedLists {
    let key: String
    let lists: [WKContentRuleList]

    init(key: String, lists: [WKContentRuleList]) {
      self.key = key
      self.lists = lists
    }
  }

  private struct Extras {
    let rulesets: [String]
    let strict: WebKitStrictBlock
    let index: WebKitCosmeticIndex
    let sources: WebKitScriptletSources?
    let loadMs: Double
  }

  private let rulesDirectory = Bundle.main.resourceURL?.appendingPathComponent("ContentRules")
  private lazy var bundled: Bundled? = rulesDirectory
    .flatMap { try? Data(contentsOf: $0.appendingPathComponent("rulesets.json")) }
    .flatMap { try? JSONDecoder().decode(Bundled.self, from: $0) }
  private var base: URL {
    URL(fileURLWithPath: (ArdiaHost.dataDirectory as NSString).deletingLastPathComponent).appendingPathComponent("WebKit Content Rules")
  }
  private lazy var store: WKContentRuleListStore? = {
    let url = base.appendingPathComponent("Store")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return WKContentRuleListStore(url: url)
  }()

  private var started = false
  private var settings = Settings()
  private var lists: [WKContentRuleList] = []
  private var listsKey = ""
  private var loadingKey: String?
  private var desiredKey = ""
  private var failedKey: String?
  private var ready = false
  private var waiters: [() -> Void] = []
  private var lastCompileMs: Double = 0
  private var lastError: String?
  private let controllers = NSHashTable<WKUserContentController>.weakObjects()
  private let applied = NSMapTable<WKUserContentController, AppliedLists>.weakToStrongObjects()
  private let scripts = WebKitContentBlockerScripts()
  private var extras: Extras?
  private var extrasKey = ""
  private var extrasReady = false
  private var strict = WebKitStrictBlock.empty
  private var strictPasses: [WebKitStores.StoreID: Set<String>] = [:]
  private var userFilters = WebKitUserFilters.none
  private var userFiltersAsked: Date?
  private var userFiltersPending = false
  private var userFiltersAskAgain = false
  private var rejectedUserFilters: RejectedUserFilters?

  func attach(_ controller: WKUserContentController) {
    start()
    controllers.add(controller)
    apply(controller)
    scripts.attach(controller)
    refreshUserFilters()
  }

  func strictBlocks(_ url: URL, initiator: String?, store: WebKitStores.StoreID) -> Bool {
    guard settings.enabled, let host = url.host?.lowercased(), !host.isEmpty, strictPasses[store]?.contains(host) != true, !trusted(host) else { return false }
    if !userFilters.strictAllowHosts.isEmpty, WebKitStrictBlock.covered(host, by: Set(userFilters.strictAllowHosts)) { return false }
    if !userFilters.strictHosts.isEmpty, WebKitStrictBlock.covered(host, by: Set(userFilters.strictHosts)) { return true }
    return strict.blocks(url, initiator: initiator)
  }

  func passStrict(_ url: URL, store: WebKitStores.StoreID) {
    if let host = url.host?.lowercased(), !host.isEmpty { strictPasses[store, default: []].insert(host) }
  }

  static func inflate(_ url: URL) -> Data? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    return try? (data as NSData).decompressed(using: .zlib) as Data
  }

  @discardableResult
  func configure(_ preferences: WKWebpagePreferences, for url: URL) -> Bool {
    guard preferences.responds(to: NSSelectorFromString("_setContentBlockersEnabled:")) else { return false }
    let exempt = trusted((url.host ?? "").lowercased())
    preferences.setValue(!exempt, forKey: "contentBlockersEnabled")
    return exempt
  }

  func whenReady(within seconds: Double, _ then: @escaping () -> Void) {
    start()
    if ready && extrasReady { return then() }
    var done = false
    let once = {
      guard !done else { return }
      done = true
      then()
    }
    waiters.append(once)
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: once)
  }

  var state: [String: Any] {
    [
      "ready": ready, "enabled": settings.enabled, "lists": lists.count, "key": listsKey, "loading": loadingKey ?? NSNull(),
      "rulesets": wantedRulesets(), "allowedHosts": settings.allowedHosts, "compileMs": lastCompileMs,
      "error": lastError ?? NSNull(), "version": bundled?.version ?? "",
      "strictHosts": strict.hostCount, "strictRules": strict.rules.count, "strictPasses": strictPasses.values.reduce(0) { $0 + $1.count },
      "scripted": scripts.index.selectorCount, "scriptletBytes": scripts.scriptletBytes, "cosmeticLookups": scripts.lookups,
      "cosmeticApplied": scripts.applied, "extrasMs": extras?.loadMs ?? 0, "extrasReady": extrasReady,
      "userFilters": ["accepted": userFilters.accepted, "rejected": userFilters.rejected, "network": userFilters.network.count,
                      "cosmetic": userFilters.hide.values.reduce(0) { $0 + $1.count }, "strict": userFilters.strictHosts.count,
                      "uncompiled": uncompiledUserRules.count],
    ]
  }

  var isFiltering: Bool { settings.enabled && !lists.isEmpty }

  private func start() {
    guard !started else { return }
    started = true
    if let data = try? Data(contentsOf: base.appendingPathComponent("settings.json")),
      let saved = try? JSONDecoder().decode(Settings.self, from: data)
    {
      settings = saved
    }
    if let data = try? Data(contentsOf: base.appendingPathComponent("user-filters.json")),
      let saved = try? JSONDecoder().decode(WebKitUserFilters.self, from: data)
    {
      userFilters = saved
    }
    if let data = try? Data(contentsOf: base.appendingPathComponent("user-filters-rejected.json")),
      let saved = try? JSONDecoder().decode(RejectedUserFilters.self, from: data)
    {
      rejectedUserFilters = saved
    }
    if let message = userFiltersError {
      lastError = message
      ArdiaEvents.emit("webKit.counted", data: ArdiaConsentStamp.begin().onto(["name": "blockerUserFiltersFailed"]))
    }
    NotificationCenter.default.addObserver(forName: Self.changed, object: nil, queue: nil) { [weak self] note in
      let info = note.userInfo ?? [:]
      if Thread.isMainThread { self?.noteChange(info) } else { DispatchQueue.main.async { self?.noteChange(info) } }
    }
    reselect()
    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
      ArdiaContentBlocker.state { _ in }
      self.refreshUserFilters()
    }
  }

  private func refreshUserFilters(force: Bool = false) {
    guard started else { return }
    if userFiltersPending {
      if force { userFiltersAskAgain = true }
      return
    }
    guard force || userFiltersAsked.map({ Date().timeIntervalSince($0) > 30 }) ?? true else { return }
    userFiltersPending = true
    userFiltersAsked = Date()
    ArdiaContentBlocker.userFilters { [weak self] filters, error in
      DispatchQueue.main.async {
        guard let self else { return }
        self.userFiltersPending = false
        if self.userFiltersAskAgain {
          self.userFiltersAskAgain = false
          DispatchQueue.main.async { self.refreshUserFilters(force: true) }
        }
        guard let filters, error == nil else {
          self.userFiltersAsked = nil
          return
        }
        let text = (filters["enabled"] as? Bool) == false ? "" : (filters["content"] as? String ?? "")
        let current = self.userFilters.digest
        Self.userFilterParser.async {
          let empty = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          if (empty ? "" : WebKitUserFilters.digest(of: text)) == current { return }
          let parsed = empty ? WebKitUserFilters.none : WebKitUserFilters.parse(text)
          DispatchQueue.main.async { self.useUserFilters(parsed) }
        }
      }
    }
  }

  private func useUserFilters(_ parsed: WebKitUserFilters) {
    guard parsed.digest != userFilters.digest else { return }
    userFilters = parsed
    if parsed.accepted > 0 { ArdiaEvents.emit("webKit.counted", data: ArdiaConsentStamp.begin().onto(["name": "blockerUserFilters"])) }
    let url = base
    Self.settingsWriter.async {
      try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
      let file = url.appendingPathComponent("user-filters.json")
      if parsed == .none { try? FileManager.default.removeItem(at: file) } else if let data = try? JSONEncoder().encode(parsed) {
        try? data.write(to: file, options: .atomic)
      }
    }
    reselect()
    applyAll()
  }

  private func noteChange(_ info: [AnyHashable: Any]) {
    var next = settings
    if let enabled = info["enabled"] as? Bool { next.enabled = enabled }
    if let lists = info["lists"] as? [String] { next.lists = lists.map { $0.lowercased() }.sorted() }
    if let hosts = info["allowedHosts"] as? [String] { next.allowedHosts = hosts.map { $0.lowercased() }.sorted() }
    if let host = (info["host"] as? String)?.lowercased(), let allowed = info["allowed"] as? Bool {
      var kept = next.allowedHosts.filter { allowed ? $0 != host : !WebKitHub.covers($0, host: host) }
      if allowed { kept.append(host) }
      next.allowedHosts = kept.sorted()
    }
    if let list = (info["list"] as? String)?.lowercased(), let on = info["listEnabled"] as? Bool, var lists = next.lists {
      lists.removeAll { $0 == list }
      if on { lists.append(list) }
      next.lists = lists.sorted()
    }
    refreshUserFilters(force: (info["userFilters"] as? Bool) == true)
    guard next != settings else { return }
    settings = next
    save()
    reselect()
    applyAll()
  }

  private func save() {
    let snapshot = settings
    let url = base
    Self.settingsWriter.async {
      guard let data = try? JSONEncoder().encode(snapshot) else { return }
      try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
      try? data.write(to: url.appendingPathComponent("settings.json"), options: .atomic)
    }
  }

  private func trusted(_ host: String) -> Bool {
    !host.isEmpty && settings.allowedHosts.contains { WebKitHub.covers($0, host: host) }
  }

  private func wantedRulesets() -> [String] {
    guard let bundled else { return [] }
    guard let chosen = settings.lists.map(Set.init) else { return bundled.rulesets.filter(\.enabled).map(\.id) }
    return bundled.rulesets.map(\.id).filter { id in (Self.sources[id] ?? [id]).contains { chosen.contains($0.lowercased()) } }
  }

  private var uncompiledUserRules: Set<String> {
    guard let rejected = rejectedUserFilters, rejected.digest == userFilters.digest else { return [] }
    return Set(rejected.rules ?? [])
  }

  private var userRules: UserRules {
    let left = uncompiledUserRules
    let kept = left.isEmpty ? userFilters.network : userFilters.network.filter { !left.contains($0.json) }
    guard !kept.isEmpty else { return .none }
    return UserRules(digest: left.isEmpty ? userFilters.digest : "\(userFilters.digest)-\(left.count)", rules: kept)
  }

  private var userFiltersError: String? {
    guard let rejected = rejectedUserFilters, rejected.digest == userFilters.digest, !userFilters.network.isEmpty else { return nil }
    let left = uncompiledUserRules.count
    guard left > 0 else { return nil }
    if left >= userFilters.network.count { return "your filters didn't compile, so they're left out: \(rejected.error)" }
    return "\(left) of your filters didn't compile, so they're left out: \(rejected.error)"
  }

  private func reject(_ digest: String, error: String, rules: [String]) {
    let rejected = RejectedUserFilters(digest: digest, error: error, rules: rules)
    rejectedUserFilters = rejected
    let url = base
    Self.settingsWriter.async {
      guard let data = try? JSONEncoder().encode(rejected) else { return }
      try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
      try? data.write(to: url.appendingPathComponent("user-filters-rejected.json"), options: .atomic)
    }
  }

  private func key(for rulesets: [String]) -> String {
    let rules = userRules
    let user = rules.rules.isEmpty ? "" : ";" + rules.digest
    let digest = SHA256.hash(data: Data((rulesets.sorted().joined(separator: ",") + user).utf8))
    let hex = digest.prefix(6).map { String(format: "%02x", $0) }.joined()
    return "\(bundled?.digest ?? bundled?.version ?? "none")-\(Self.format)-\(hex)"
  }

  private func reselect() {
    refreshExtras()
    let rulesets = settings.enabled ? wantedRulesets() : []
    desiredKey = rulesets.isEmpty || store == nil ? "" : key(for: rulesets)
    if desiredKey == listsKey {
      markReady()
      return applyAll()
    }
    if desiredKey.isEmpty { return install(key: "", lists: []) }
    guard loadingKey == nil, desiredKey != failedKey else { return }
    load(rulesets, key: desiredKey, user: userRules)
  }

  private func load(_ rulesets: [String], key wanted: String, user: UserRules) {
    guard let store else { return }
    loadingKey = wanted
    let prefix = "\(Self.listPrefix)\(wanted)-"
    store.getAvailableContentRuleListIdentifiers { [weak self] identifiers in
      guard let self else { return }
      guard wanted == self.desiredKey else {
        self.loadingKey = nil
        return self.reselect()
      }
      let mine = Set((identifiers ?? []).filter { $0.hasPrefix(prefix) })
      let totals = Set(mine.compactMap { Int($0.components(separatedBy: "of").last ?? "") })
      let total = totals.count == 1 ? totals.first ?? 0 : 0
      let expected = (0..<total).map { "\(prefix)\($0)of\(total)" }
      if total > 0 && Set(expected) == mine {
        self.lookUp(expected, key: wanted, rulesets: rulesets, user: user)
      } else {
        self.markReady()
        self.compile(rulesets, key: wanted, user: user)
      }
    }
  }

  private func lookUp(_ identifiers: [String], key: String, rulesets: [String], user: UserRules) {
    guard let store else { return }
    var found: [Int: WKContentRuleList] = [:]
    var left = identifiers.count
    var failed = false
    for (index, identifier) in identifiers.enumerated() {
      store.lookUpContentRuleList(forIdentifier: identifier) { [weak self] list, _ in
        if let list { found[index] = list } else { failed = true }
        left -= 1
        guard left == 0, let self else { return }
        if failed {
          self.markReady()
          return self.compile(rulesets, key: key, user: user)
        }
        self.finishLoading(key: key, lists: (0..<identifiers.count).compactMap { found[$0] })
      }
    }
  }

  private func compile(_ rulesets: [String], key: String, user: UserRules) {
    guard let store, let directory = rulesDirectory else { return finishLoading(key: key, lists: nil) }
    let started = Date()
    let stamp = ArdiaConsentStamp.begin()
    DispatchQueue.global(qos: .utility).async { [weak self] in
      let encoded = Self.assemble(rulesets, from: directory, user: user.rules)
      DispatchQueue.main.async {
        guard let self else { return }
        guard !encoded.isEmpty else {
          self.lastError = "no rules for \(rulesets.joined(separator: ","))"
          return self.finishLoading(key: key, lists: nil)
        }
        var made: [Int: WKContentRuleList] = [:]
        var left = encoded.count
        var failure: String?
        let identifiers = (0..<encoded.count).map { "\(Self.listPrefix)\(key)-\($0)of\(encoded.count)" }
        for (index, json) in encoded.enumerated() {
          store.compileContentRuleList(forIdentifier: identifiers[index], encodedContentRuleList: json) { list, error in
            if let list { made[index] = list } else { failure = failure ?? error?.localizedDescription ?? "failed" }
            left -= 1
            guard left == 0 else { return }
            self.lastCompileMs = Date().timeIntervalSince(started) * 1000
            if let failure {
              NSLog("[blocker] WebKit rules didn't compile: %@", failure)
              ArdiaEvents.emit("webKit.counted", data: stamp.onto(["name": user.rules.isEmpty ? "blockerCompileFailed" : "blockerUserFiltersFailed"]))
              guard user.rules.isEmpty else { return self.isolateUncompiled(user, error: failure, key: key) }
              self.lastError = failure
              return self.finishLoading(key: key, lists: nil)
            }
            NSLog("[blocker] WebKit rules for %@ compiled in %.0f ms", rulesets.joined(separator: ","), self.lastCompileMs)
            self.lastError = self.userFiltersError
            let previous = self.listsKey
            self.finishLoading(key: key, lists: (0..<encoded.count).compactMap { made[$0] })
            if self.listsKey == key { self.removeStale(keeping: Set(identifiers), previous: previous) }
          }
        }
      }
    }
  }

  private static func assemble(_ rulesets: [String], from directory: URL, user: [WebKitUserFilters.NetworkRule]) -> [String] {
    let texts = rulesets.compactMap { id -> String? in
      guard let data = try? Data(contentsOf: directory.appendingPathComponent("\(id).rules")),
        let raw = try? (data as NSData).decompressed(using: .zlib)
      else { return nil }
      return String(decoding: raw as Data, as: UTF8.self)
    }
    return WebKitRulePacker.lists(texts: texts, user: user)
  }

  private func isolateUncompiled(_ user: UserRules, error: String, key: String) {
    guard let store else { return finishLoading(key: key, lists: nil) }
    let digest = userFilters.digest
    let earlier = uncompiledUserRules
    let rules = user.rules
    var search = WebKitRuleBisect(count: rules.count)
    var checks = 0
    func step() {
      guard let range = search.next else { return finish() }
      checks += 1
      let identifier = "\(Self.checkPrefix)\(checks)"
      DispatchQueue.global(qos: .utility).async {
        let json = WebKitRulePacker.list(of: rules[range])
        DispatchQueue.main.async {
          store.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: json) { list, _ in
            store.removeContentRuleList(forIdentifier: identifier) { _ in }
            search.record(range, compiled: list != nil)
            step()
          }
        }
      }
    }
    func finish() {
      let found = search.rejected.map { rules[$0].json }
      let dropped = found.isEmpty ? rules.map(\.json) : found
      NSLog("[blocker] %d of %d user filters didn't compile (%d checks)", dropped.count, rules.count, checks)
      ArdiaEvents.emit("webKit.counted", data: ArdiaConsentStamp.begin().onto(["name": "blockerUserFiltersIsolated"]))
      guard digest == userFilters.digest else { return finishLoading(key: key, lists: nil) }
      reject(digest, error: error, rules: Array(earlier) + dropped)
      lastError = userFiltersError ?? error
      finishLoading(key: key, lists: nil)
    }
    step()
  }

  private func removeStale(keeping current: Set<String>, previous: String) {
    guard let store else { return }
    let older = previous.isEmpty ? nil : "\(Self.listPrefix)\(previous)-"
    store.getAvailableContentRuleListIdentifiers { identifiers in
      for identifier in identifiers ?? [] where identifier.hasPrefix(Self.listPrefix) && !current.contains(identifier) && !(older.map { identifier.hasPrefix($0) } ?? false) {
        store.removeContentRuleList(forIdentifier: identifier) { _ in }
      }
    }
  }

  private func finishLoading(key: String, lists made: [WKContentRuleList]?) {
    loadingKey = nil
    if made == nil { failedKey = key }
    if let made, key == desiredKey { install(key: key, lists: made) }
    markReady()
    if desiredKey != listsKey { reselect() }
  }

  private func install(key: String, lists made: [WKContentRuleList]) {
    listsKey = key
    lists = made
    markReady()
    applyAll()
  }

  private func markReady() {
    guard !ready else { return }
    ready = true
    flushWaiters()
  }

  private func flushWaiters() {
    guard ready && extrasReady else { return }
    let pending = waiters
    waiters = []
    pending.forEach { $0() }
  }

  private func refreshExtras() {
    let rulesets = settings.enabled ? wantedRulesets() : []
    let trusted = settings.allowedHosts
    let user = settings.enabled ? userFilters : .none
    let key = [rulesets.joined(separator: ","), trusted.joined(separator: ","), user.digest, bundled?.digest ?? ""].joined(separator: "|")
    guard key != extrasKey else { return }
    extrasKey = key
    guard let directory = rulesDirectory, let bundled, settings.enabled else {
      strict = .empty
      scripts.update(sources: nil, index: .empty, user: .none, trusted: [], key: key)
      return finishExtras()
    }
    if let extras, extras.rulesets == rulesets {
      strict = extras.strict
      scripts.update(sources: extras.sources, index: extras.index, user: user, trusted: trusted, key: key)
      return finishExtras()
    }
    let worlds = Dictionary(bundled.rulesets.map { ($0.id, $0.scriptlets ?? []) }, uniquingKeysWith: { a, _ in a })
    let secret = bundled.scriptletSecret ?? ""
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      let started = Date()
      let strict = WebKitStrictBlock.load(rulesets, from: directory)
      let index = WebKitCosmeticIndex.load(rulesets, from: directory)
      let sources = WebKitScriptletSources.load(rulesets, worlds: worlds, secret: secret, from: directory)
      let made = Extras(rulesets: rulesets, strict: strict, index: index, sources: sources, loadMs: Date().timeIntervalSince(started) * 1000)
      DispatchQueue.main.async {
        guard let self, key == self.extrasKey else { return }
        NSLog("[blocker] WebKit strict blocking (%d hosts, %d rules), %d scripted selectors and scriptlets loaded in %.0f ms",
              strict.hostCount, strict.rules.count, index.selectorCount, made.loadMs)
        self.extras = made
        self.strict = strict
        self.scripts.update(sources: sources, index: index, user: user, trusted: trusted, key: key)
        self.finishExtras()
      }
    }
  }

  private func finishExtras() {
    guard !extrasReady else { return }
    extrasReady = true
    flushWaiters()
  }

  private func applyAll() {
    for controller in controllers.allObjects { apply(controller) }
  }

  private func apply(_ controller: WKUserContentController) {
    let want = settings.enabled && !lists.isEmpty ? listsKey : ""
    let current = applied.object(forKey: controller)
    if current?.key == want { return }
    current?.lists.forEach(controller.remove)
    let adding = want.isEmpty ? [] : lists
    adding.forEach(controller.add)
    applied.setObject(AppliedLists(key: want, lists: adding), forKey: controller)
  }
}
