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
    let decide: (Bool) -> Void
  }

  static let kinds = ["camera", "microphone", "location", "notifications"]

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
      self.lastRequest += 1
      let id = "wk-permission-\(self.lastRequest)"
      self.pending[id] = Pending(browserId: browserId, store: store, profile: profile, keys: kinds.map { SiteKey(site: origin, kind: $0) }, decide: decide)
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
    answers(profile: profile, origin: origin, kinds: Self.kinds) { answers in
      var settings: [String: [String: Any]] = [:]
      for kind in Self.kinds {
        let answer = answers[kind]
        settings[kind] = ["value": answer.map { $0 ? "allow" : "block" } ?? "ask", "isDefault": answer == nil]
      }
      done(settings)
    }
  }

  func setSiteSetting(profile: String, origin: String, kind: String, value: String) {
    guard Self.kinds.contains(kind) else { return }
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
    guard value == "block" else { return }
    let store = stores.dataStore(for: profile)
    for view in transfers.views.compactMap({ $0 as? WebKitWebView })
    where view.configuration.websiteDataStore === store && view.captureOrigins[kind]?.contains(origin) == true {
      view.stopCapture(kind)
    }
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
