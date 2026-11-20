import Foundation
import WebKit

final class WebKitPermissions {
  typealias StoreID = WebKitStores.StoreID
  typealias SiteKey = WebKitStores.SiteKey

  private struct Pending {
    let browserId: Int32
    let store: StoreID
    let profile: String
    let keys: [SiteKey]
    var decisions: [(Bool) -> Void]

    func decide(_ allowed: Bool) { decisions.forEach { $0(allowed) } }
  }

  static let kinds = ["camera", "microphone", "location", "notifications"]
  static let sound = "sound"
  static let siteRules = ["popups", "javascript", "images", "cookies", "autoplay", "clipboard"]
  private static let ruleDefaults = ["popups": "block", "clipboard": "ask"]
  private static let waitersPerPrompt = 64

  private unowned let stores: WebKitStores
  private unowned let transfers: WebKitTransfers
  private var pending: [String: Pending] = [:]
  private var lastRequest = 0

  init(stores: WebKitStores, transfers: WebKitTransfers) {
    self.stores = stores
    self.transfers = transfers
  }

  static func sharesChromiumRules(_ profile: String) -> Bool { !WebKitStores.isPrivate(profile) }

  private static func answer(_ value: Any?) -> Bool? {
    switch (value as? [String: Any])?["value"] as? String {
    case "allow": true
    case "block": false
    default: nil
    }
  }

  func answers(profile: String, origin: String, kinds: [String], done: @escaping ([String: Bool]) -> Void) {
    guard Self.sharesChromiumRules(profile) else {
      let remembered = stores.state(stores.id(of: profile)).remembered
      return done(Dictionary(uniqueKeysWithValues: kinds.compactMap { kind in remembered[SiteKey(site: origin, kind: kind)].map { (kind, $0) } }))
    }
    ArdiaServices.siteSettings(profile: profile, origin: origin) { value, _ in
      let settings = value as? [String: Any] ?? [:]
      let found = Dictionary(uniqueKeysWithValues: kinds.compactMap { kind in Self.answer(settings[kind]).map { (kind, $0) } })
      DispatchQueue.main.async { done(found) }
    }
  }

  func request(browserId: Int32, tabId: String?, profile: String, origin: String, kinds: [String], decide: @escaping (Bool) -> Void) {
    let store = stores.id(of: profile)
    answers(profile: profile, origin: origin, kinds: kinds) { [weak self] answers in
      guard let self else { return decide(false) }
      if kinds.contains(where: { answers[$0] == false }) { return decide(false) }
      if kinds.allSatisfy({ answers[$0] == true }) { return decide(true) }
      let keys = kinds.map { SiteKey(site: origin, kind: $0) }
      if let id = self.pending.first(where: { $0.value.browserId == browserId && $0.value.store == store && $0.value.keys == keys })?.key {
        guard (self.pending[id]?.decisions.count ?? 0) < Self.waitersPerPrompt else { return decide(false) }
        self.pending[id]?.decisions.append(decide)
        return
      }
      self.lastRequest += 1
      let id = "wk-permission-\(self.lastRequest)"
      self.pending[id] = Pending(browserId: browserId, store: store, profile: profile, keys: keys, decisions: [decide])
      ArdiaEvents.emit("permissions.requested", data: ["id": id, "tabId": tabId ?? NSNull(), "origin": origin, "permissions": kinds])
    }
  }

  func resolve(_ id: String, result: String, remember: Bool) {
    guard let request = pending.removeValue(forKey: id) else { return }
    let allowed = result == "accept"
    if remember && result != "dismiss" {
      if Self.sharesChromiumRules(request.profile) {
        for key in request.keys { ArdiaServices.setSiteSetting(allowed ? "allow" : "block", profile: request.profile, origin: key.site, type: key.kind) }
      } else {
        stores.update(request.store) { state in for key in request.keys { state.remembered[key] = allowed } }
      }
    }
    request.decide(allowed)
  }

  func drop(browserId: Int32) {
    dismiss { $0.browserId == browserId }
  }

  func drop(store: StoreID) {
    dismiss { $0.store == store }
  }

  private func dismiss(_ matching: (Pending) -> Bool) {
    for (id, request) in pending where matching(request) {
      pending.removeValue(forKey: id)
      request.decide(false)
      ArdiaEvents.emit("permissions.dismissed", data: ["id": id])
    }
  }

  func siteSettings(profile: String, origin: String, done: @escaping ([String: [String: Any]]) -> Void) {
    let done = withSiteRules(profile: profile, origin: origin, done)
    answers(profile: profile, origin: origin, kinds: Self.kinds + [Self.sound]) { answers in
      var settings: [String: [String: Any]] = [:]
      for kind in Self.kinds {
        let answer = answers[kind]
        settings[kind] = ["value": answer.map { $0 ? "allow" : "block" } ?? "ask", "isDefault": answer == nil]
      }
      settings[Self.sound] = ["value": answers[Self.sound] == false ? "block" : "allow", "isDefault": answers[Self.sound] == nil]
      done(settings)
    }
  }

  func soundBlocked(profile: String, origin: String, done: @escaping (Bool) -> Void) {
    answers(profile: profile, origin: origin, kinds: [Self.sound]) { done($0[Self.sound] == false) }
  }

  func setSiteSetting(profile: String, origin: String, kind: String, value: String) {
    if Self.siteRules.contains(kind) { return setSiteRule(profile: profile, origin: origin, kind: kind, value: value) }
    guard Self.kinds.contains(kind) || kind == Self.sound else { return }
    if Self.sharesChromiumRules(profile) {
      ArdiaServices.setSiteSetting(value, profile: profile, origin: origin, type: kind)
    } else {
      let key = SiteKey(site: origin, kind: kind)
      stores.update(stores.id(of: profile)) { state in
        switch value {
        case "allow": state.remembered[key] = true
        case "block": state.remembered[key] = false
        default: state.remembered.removeValue(forKey: key)
        }
      }
    }
    if kind == Self.sound {
      for tab in transfers.liveTabs where tab.profile == profile && tab.pageMedia.soundRuleOrigin == origin { tab.checkSoundRule() }
      return
    }
    guard value == "block" else { return }
    let store = stores.dataStore(for: profile)
    for view in transfers.views.compactMap({ $0 as? WebKitWebView })
    where view.configuration.websiteDataStore === store && view.captureOrigins[kind]?.contains(origin) == true {
      view.stopCapture(kind)
    }
  }

  private func withSiteRules(profile: String, origin: String, _ done: @escaping ([String: [String: Any]]) -> Void) -> ([String: [String: Any]]) -> Void {
    { [weak self] settings in
      guard let self else { return done(settings) }
      self.siteRules(profile: profile, origin: origin) { rules in done(settings.merging(rules) { kept, _ in kept }) }
    }
  }

  func siteRules(profile: String, origin: String, kinds: [String] = siteRules, done: @escaping ([String: [String: Any]]) -> Void) {
    guard Self.sharesChromiumRules(profile) else {
      let remembered = stores.state(stores.id(of: profile)).remembered
      return done(Dictionary(uniqueKeysWithValues: kinds.map { kind in
        let answer = remembered[SiteKey(site: origin, kind: kind)]
        return (kind, ["value": answer.map { $0 ? "allow" : "block" } ?? Self.ruleDefaults[kind, default: "allow"], "isDefault": answer == nil])
      }))
    }
    ArdiaServices.siteSettings(profile: profile, origin: origin) { value, _ in
      let settings = value as? [String: Any] ?? [:]
      let found = Dictionary(uniqueKeysWithValues: kinds.compactMap { kind in (settings[kind] as? [String: Any]).map { (kind, $0) } })
      DispatchQueue.main.async { done(found) }
    }
  }

  private func setSiteRule(profile: String, origin: String, kind: String, value: String) {
    if Self.sharesChromiumRules(profile) { return ArdiaServices.setSiteSetting(value, profile: profile, origin: origin, type: kind) }
    let key = SiteKey(site: origin, kind: kind)
    stores.update(stores.id(of: profile)) { state in
      switch value {
      case "allow": state.remembered[key] = true
      case "block": state.remembered[key] = false
      default: state.remembered.removeValue(forKey: key)
      }
    }
  }

  func sitePolicy(profile: String, origin: String, done: @escaping (WebKitSitePolicy) -> Void) {
    siteRules(profile: profile, origin: origin, kinds: WebKitSitePolicy.kinds) { done(WebKitSitePolicy($0)) }
  }

  func reconcileCapture(_ view: WebKitWebView, profile: String) {
    for (kind, origins) in view.captureOrigins {
      for origin in origins {
        answers(profile: profile, origin: origin, kinds: [kind]) { [weak view] answers in
          if answers[kind] == false { view?.stopCapture(kind) }
        }
      }
    }
  }
}

struct WebKitSitePolicy: Equatable {
  private static let sound = "sound"
  static let kinds = ["javascript", "images", "cookies", "autoplay", "clipboard", sound]

  enum Autoplay: Int {
    case allow = 1
    case deny = 3
  }

  var javascript = true
  var images = true
  var cookies = true
  var clipboard = "ask"
  var autoplay: Autoplay?

  init() {}

  init(_ rules: [String: [String: Any]]) {
    let value = { (kind: String) in rules[kind]?["value"] as? String }
    let chosen = { (kind: String) in rules[kind]?["isDefault"] as? Bool == false }
    javascript = value("javascript") != "block"
    images = value("images") != "block"
    cookies = value("cookies") != "block"
    clipboard = value("clipboard") ?? "ask"
    if value("autoplay") == "block" {
      autoplay = .deny
    } else if chosen(Self.sound) && value(Self.sound) == "allow" {
      autoplay = .allow
    }
  }

  var isDefault: Bool { self == WebKitSitePolicy() }
}
