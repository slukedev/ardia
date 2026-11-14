import Foundation
import WebKit

final class WebKitNotifications {
  private struct Shown {
    let wireId: String
    let tag: String
    let scope: String
    let origin: String
    let entry: [String: Any]
  }

  private struct WorkerShown {
    let wireId: String
    let profile: String
    let origin: String
    let tag: String
    let notification: NSDictionary
    let order: Int
    weak var store: WKWebsiteDataStore?
  }

  private var workerShown: [String: WorkerShown] = [:]
  private var workerDelegates: [ObjectIdentifier: WebKitWorkerNotifications] = [:]
  private var granted: [String: [String: Bool]] = [:]
  private var workerCount = 0

  private static let shownPerScope = 50

  private var shown: [String: [Shown]] = [:]
  static let pageShim = #"""
(() => {
  if (window.__ardiaNotifications) return;
  window.__ardiaNotifications = true;
  const apply = Reflect.apply;
  const dispatch = EventTarget.prototype.dispatchEvent;
  const listen = EventTarget.prototype.addEventListener;
  const detailOf = Object.getOwnPropertyDescriptor(CustomEvent.prototype, "detail").get;
  const Custom = CustomEvent;
  const Plain = Event;
  const { stringify, parse } = JSON;
  const doc = document;
  const live = new Map();
  const requests = new Map();
  let permission = "default";
  let next = 0;
  const send = (detail) => {
    try {
      apply(dispatch, doc, [new Custom("ardia:notification", { detail: stringify(detail) })]);
    } catch (e) {}
  };
  const fire = (n, type) => {
    const event = new Plain(type);
    try {
      apply(dispatch, n, [event]);
    } catch (e) {}
    const handler = n["on" + type];
    if (typeof handler === "function") {
      try {
        handler.call(n, event);
      } catch (e) {}
    }
  };
  const ids = new WeakMap();
  class Notification extends EventTarget {
    constructor(title, options) {
      super();
      if (arguments.length === 0) throw new TypeError("Failed to construct 'Notification': 1 argument required, but only 0 present.");
      const o = options || {};
      this.title = String(title);
      this.body = o.body === undefined ? "" : String(o.body);
      this.tag = o.tag === undefined ? "" : String(o.tag);
      this.icon = o.icon ? String(new URL(String(o.icon), location.href)) : "";
      this.silent = !!o.silent;
      this.requireInteraction = !!o.requireInteraction;
      this.data = o.data === undefined ? null : o.data;
      this.dir = o.dir || "auto";
      this.lang = o.lang || "";
      this.badge = "";
      this.image = "";
      this.renotify = !!o.renotify;
      this.timestamp = Date.now();
      this.actions = [];
      this.onclick = this.onclose = this.onerror = this.onshow = null;
      const id = "n" + ++next;
      ids.set(this, id);
      live.set(id, this);
      queueMicrotask(() => {
        if (permission !== "granted") {
          live.delete(id);
          return fire(this, "error");
        }
        send({ type: "show", id, title: this.title, body: this.body, icon: this.icon, tag: this.tag, silent: this.silent, requireInteraction: this.requireInteraction });
        fire(this, "show");
      });
    }
    close() {
      const id = ids.get(this);
      if (!live.delete(id)) return;
      send({ type: "close", id });
      fire(this, "close");
    }
    static get permission() {
      return permission;
    }
    static get maxActions() {
      return 0;
    }
    static requestPermission(callback) {
      return new Promise((resolve) => {
        if (permission !== "default") {
          if (typeof callback === "function") callback(permission);
          return resolve(permission);
        }
        const id = "p" + ++next;
        requests.set(id, (answer) => {
          permission = answer;
          if (typeof callback === "function") {
            try {
              callback(answer);
            } catch (e) {}
          }
          resolve(answer);
        });
        send({ type: "request", id });
      });
    }
  }
  Object.defineProperty(window, "Notification", { configurable: true, writable: true, value: Notification });
  const listings = new Map();
  class ShownNotification {
    constructor(entry) {
      this.title = String(entry.title || "");
      this.body = String(entry.body || "");
      this.tag = String(entry.tag || "");
      this.icon = String(entry.icon || "");
      this.data = entry.data === undefined ? null : entry.data;
      this.silent = !!entry.silent;
      this.requireInteraction = !!entry.requireInteraction;
      this.timestamp = Number(entry.timestamp) || 0;
      this.dir = "auto";
      this.lang = "";
      this.badge = "";
      this.image = "";
      this.renotify = false;
      this.actions = [];
      ids.set(this, String(entry.id));
    }
    close() {
      const id = ids.get(this);
      if (id) send({ type: "close", id });
    }
  }
  const Registration = window.ServiceWorkerRegistration;
  const scopeOf = Registration && Object.getOwnPropertyDescriptor(Registration.prototype, "scope");
  const activeOf = Registration && Object.getOwnPropertyDescriptor(Registration.prototype, "active");
  if (scopeOf && scopeOf.get && activeOf && activeOf.get) {
    const reject = Promise.reject.bind(Promise);
    const resolve = Promise.resolve.bind(Promise);
    const define = (name, value) => Object.defineProperty(Registration.prototype, name, { configurable: true, writable: true, value });
    define("showNotification", {
      showNotification(title, options) {
        let scope = "";
        try {
          scope = apply(scopeOf.get, this, []);
        } catch (e) {
          return reject(new TypeError("Illegal invocation"));
        }
        if (arguments.length === 0) return reject(new TypeError("Failed to execute 'showNotification' on 'ServiceWorkerRegistration': 1 argument required, but only 0 present."));
        if (!apply(activeOf.get, this, [])) return reject(new TypeError("No active registration available on the ServiceWorkerRegistration."));
        if (permission !== "granted") return reject(new TypeError("No notification permission has been granted for this origin."));
        const o = options || {};
        let data = null;
        try {
          data = o.data === undefined ? null : parse(stringify(o.data));
        } catch (e) {}
        const id = "s" + ++next;
        send({
          type: "show", id, persistent: true, scope, title: String(title), body: o.body === undefined ? "" : String(o.body),
          icon: o.icon ? String(new URL(String(o.icon), location.href)) : "", tag: o.tag === undefined ? "" : String(o.tag),
          silent: !!o.silent, requireInteraction: !!o.requireInteraction, data, timestamp: Date.now(),
        });
        return resolve(undefined);
      },
    }.showNotification);
    define("getNotifications", {
      getNotifications(filter) {
        let scope = "";
        try {
          scope = apply(scopeOf.get, this, []);
        } catch (e) {
          return reject(new TypeError("Illegal invocation"));
        }
        const tag = filter && filter.tag !== undefined ? String(filter.tag) : "";
        return new Promise((done) => {
          const id = "g" + ++next;
          listings.set(id, (items) => done(Array.isArray(items) ? items.map((entry) => new ShownNotification(entry)) : []));
          send({ type: "list", id, scope, tag });
        });
      },
    }.getNotifications);
  }
  apply(listen, doc, [
    "ardia:notification-reply",
    (e) => {
      let reply = null;
      try {
        reply = parse(apply(detailOf, e, []));
      } catch (error) {}
      if (!reply || typeof reply.type !== "string") return;
      if (reply.type === "permission") permission = reply.value;
      else if (reply.type === "answer") {
        const done = requests.get(reply.id);
        requests.delete(reply.id);
        if (done) done(reply.value);
      } else if (reply.type === "list") {
        const done = listings.get(reply.id);
        listings.delete(reply.id);
        if (done) done(reply.items);
      } else if (reply.type === "click" || reply.type === "close") {
        const n = live.get(reply.id);
        if (!n) return;
        if (reply.type === "close") live.delete(reply.id);
        fire(n, reply.type);
      }
    },
    true,
  ]);
})();
"""#

  static let worldBridge = #"""
(() => {
  if (window.__ardiaNotificationBridge) return;
  window.__ardiaNotificationBridge = true;
  document.addEventListener("ardia:notification", (e) => {
    let detail = null;
    try {
      detail = JSON.parse(e.detail);
    } catch (error) {}
    if (!detail || typeof detail.type !== "string") return;
    try {
      window.webkit.messageHandlers.ardia.postMessage({ kind: "notification", data: detail, frame: "notifications" });
    } catch (error) {}
  }, true);
})();
"""#

  static func reply(_ detail: [String: Any], to tab: WebKitTab) {
    guard let data = try? JSONSerialization.data(withJSONObject: detail), let json = String(data: data, encoding: .utf8) else { return }
    let code = "document.dispatchEvent(new CustomEvent(\"ardia:notification-reply\", { detail: \(WebKitTab.jsString(json)) }))"
    tab.webView?.evaluateJavaScript(code, in: nil, in: WebKitHub.world) { _ in }
  }

  private static func origin(of tab: WebKitTab) -> String? {
    guard let url = tab.webView?.url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
    return Origins.of(url)
  }

  private static func wireId(_ id: String, tab: WebKitTab) -> String { "wk-n\(-tab.browserId)-\(id)" }

  func sharePermission(with tab: WebKitTab) {
    guard let origin = Self.origin(of: tab) else { return }
    WebKitHub.shared.permissions.answers(profile: tab.profile, origin: origin, kinds: ["notifications"]) { [weak tab] answers in
      guard let tab, Self.origin(of: tab) == origin else { return }
      WebKitHub.shared.notifications.note(answers["notifications"], profile: tab.profile, origin: origin)
      let value = answers["notifications"].map { $0 ? "granted" : "denied" } ?? "default"
      Self.reply(["type": "permission", "value": value], to: tab)
    }
  }

  private static func scope(_ data: [String: Any], origin: String) -> String? {
    guard let raw = data["scope"] as? String, let url = URL(string: raw), Origins.of(url) == origin else { return nil }
    return url.absoluteString
  }

  private static func shownKey(_ tab: WebKitTab, scope: String) -> String { "\(WebKitHub.shared.stores.id(of: tab.profile).wireKey)|\(scope)" }

  private func remember(_ entry: [String: Any], wireId: String, tag: String, scope: String, origin: String, key: String) {
    if !tag.isEmpty, let replaced = shown[key]?.first(where: { $0.tag == tag }) { forgetShown(replaced.wireId) }
    var list = (shown[key] ?? []).filter { $0.wireId != wireId }
    list.append(Shown(wireId: wireId, tag: tag, scope: scope, origin: origin, entry: entry))
    shown[key] = Array(list.suffix(Self.shownPerScope))
  }

  @discardableResult
  private func forgetShown(_ wireId: String) -> Shown? {
    var found: Shown?
    for (key, list) in shown where list.contains(where: { $0.wireId == wireId }) {
      found = list.first { $0.wireId == wireId }
      let rest = list.filter { $0.wireId != wireId }
      shown[key] = rest.isEmpty ? nil : rest
    }
    return found
  }

  private func shows(_ wireId: String, for tab: WebKitTab, origin: String) -> Bool {
    let site = "\(WebKitHub.shared.stores.id(of: tab.profile).wireKey)|\(origin)/"
    return shown.contains { key, list in key.hasPrefix(site) && list.contains { $0.wireId == wireId } }
  }

  private func list(_ data: [String: Any], id: String, origin: String, tab: WebKitTab) {
    guard let scope = Self.scope(data, origin: origin) else { return Self.reply(["type": "list", "id": id, "items": []], to: tab) }
    let tag = data["tag"] as? String ?? ""
    let items = (shown[Self.shownKey(tab, scope: scope)] ?? []).filter { tag.isEmpty || $0.tag == tag }.map { shown -> [String: Any] in
      var entry = shown.entry
      entry["id"] = shown.wireId
      return entry
    }
    Self.reply(["type": "list", "id": id, "items": items], to: tab)
  }

  func received(_ data: [String: Any], from tab: WebKitTab) {
    guard let type = data["type"] as? String, let id = data["id"] as? String, let origin = Self.origin(of: tab) else { return }
    switch type {
    case "list": list(data, id: id, origin: origin, tab: tab)
    case "request":
      WebKitHub.shared.permissions.request(browserId: tab.browserId, tabId: tab.transferKey, profile: tab.profile, origin: origin, kinds: ["notifications"]) {
        [weak tab] allowed in
        guard let tab else { return }
        WebKitHub.shared.notifications.note(allowed, profile: tab.profile, origin: origin)
        Self.reply(["type": "answer", "id": id, "value": allowed ? "granted" : "denied"], to: tab)
      }
    case "show":
      let persistent = data["persistent"] as? Bool == true
      let scope = Self.scope(data, origin: origin)
      if persistent && scope == nil { return }
      WebKitHub.shared.permissions.answers(profile: tab.profile, origin: origin, kinds: ["notifications"]) { [weak self, weak tab] answers in
        self?.note(answers["notifications"], profile: tab?.profile ?? "", origin: origin)
        guard let self, let tab, answers["notifications"] == true, !WebKitStores.isPrivate(tab.profile), Self.origin(of: tab) == origin else { return }
        let wireId = Self.wireId(id, tab: tab)
        if persistent, let scope {
          let entry: [String: Any] = [
            "title": data["title"] as? String ?? "", "body": data["body"] as? String ?? "", "icon": data["icon"] as? String ?? "",
            "tag": data["tag"] as? String ?? "", "data": data["data"] ?? NSNull(), "silent": data["silent"] as? Bool ?? false,
            "requireInteraction": data["requireInteraction"] as? Bool ?? false, "timestamp": data["timestamp"] ?? Date().timeIntervalSince1970 * 1000,
          ]
          self.remember(entry, wireId: wireId, tag: data["tag"] as? String ?? "", scope: scope, origin: origin, key: Self.shownKey(tab, scope: scope))
        }
        tab.emit("notification", [
          "id": wireId, "title": data["title"] as? String ?? "", "body": data["body"] as? String ?? "",
          "icon": (data["icon"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? NSNull(), "tag": data["tag"] as? String ?? "",
          "silent": data["silent"] as? Bool ?? false, "requireInteraction": data["requireInteraction"] as? Bool ?? false,
          "origin": origin, "tabId": tab.transferKey ?? NSNull(), "isMainFrame": true,
        ])
        ArdiaEvents.emit("webKit.counted", data: ["name": persistent ? "workerNotification" : "notification"])
      }
    case "close":
      let wireId = id.hasPrefix("wk-n") ? id : Self.wireId(id, tab: tab)
      if id.hasPrefix("wk-n"), !shows(wireId, for: tab, origin: origin) { return }
      forgetShown(wireId)
      tab.emit("notificationClose", ["id": wireId])
    default: break
    }
  }

  func act(_ wireId: String, action: String, in tab: WebKitTab) {
    let prefix = "wk-n\(-tab.browserId)-"
    guard wireId.hasPrefix(prefix) else { return }
    if let worker = workerShown.removeValue(forKey: wireId) { return deliver(action, worker.notification, to: worker.store) }
    if let page = forgetShown(wireId) {
      guard action == "click", let made = Self.notificationData(page) else { return }
      return deliver(action, made, to: WebKitHub.shared.stores.dataStore(for: tab.profile))
    }
    Self.reply(["type": action == "click" ? "click" : "close", "id": String(wireId.dropFirst(prefix.count))], to: tab)
  }

  func note(_ allowed: Bool?, profile: String, origin: String) {
    guard let allowed, !profile.isEmpty, !WebKitStores.isPrivate(profile) else { return }
    granted[ArdiaHost.baseProfile(of: profile), default: [:]][origin] = allowed
  }

  func attachWorkers(to store: WKWebsiteDataStore, profile: String) {
    let setter = NSSelectorFromString("set_delegate:")
    guard !WebKitStores.isPrivate(profile), workerDelegates[ObjectIdentifier(store)] == nil, store.responds(to: setter) else { return }
    let delegate = WebKitWorkerNotifications(profile: profile, owner: self)
    workerDelegates[ObjectIdentifier(store)] = delegate
    store.perform(setter, with: delegate)
  }

  fileprivate func workerPermissions(_ profile: String) -> [String: NSNumber] {
    (granted[ArdiaHost.baseProfile(of: profile)] ?? [:]).mapValues { NSNumber(value: $0) }
  }

  fileprivate func workerDisplayed(_ profile: String, origin: String) -> [NSDictionary] {
    workerShown.values.filter { $0.profile == profile && $0.origin == origin }.map(\.notification)
  }

  private static func text(_ notification: NSObject, _ key: String) -> String {
    notification.responds(to: NSSelectorFromString(key)) ? notification.value(forKey: key) as? String ?? "" : ""
  }

  fileprivate func workerShow(_ notification: NSObject, store: WKWebsiteDataStore, profile: String) {
    let representation = NSSelectorFromString("dictionaryRepresentation")
    guard notification.responds(to: representation), notification.responds(to: NSSelectorFromString("securityOrigin")),
      let dictionary = notification.perform(representation)?.takeUnretainedValue() as? NSDictionary,
      let url = notification.value(forKey: "securityOrigin") as? URL, let origin = Origins.of(url),
      ["http", "https"].contains(url.scheme?.lowercased() ?? "")
    else { return }
    let title = Self.text(notification, "title")
    let body = Self.text(notification, "body")
    let tag = Self.text(notification, "tag")
    let silent = notification.responds(to: NSSelectorFromString("alert")) && (notification.value(forKey: "alert") as? NSNumber)?.intValue == 1
    WebKitHub.shared.permissions.answers(profile: profile, origin: origin, kinds: ["notifications"]) { [weak self, weak store] answers in
      guard let self, let store else { return }
      self.note(answers["notifications"], profile: profile, origin: origin)
      let tabs = WebKitHub.shared.transfers.liveTabs.filter { $0.profile == profile && Self.origin(of: $0) == origin }
      guard answers["notifications"] == true, let tab = tabs.first(where: \.visible) ?? tabs.first else { return }
      if !tag.isEmpty, let replaced = self.workerShown.values.first(where: { $0.profile == profile && $0.origin == origin && $0.tag == tag }) {
        self.workerShown.removeValue(forKey: replaced.wireId)
      }
      self.workerCount += 1
      let wireId = Self.wireId("w\(self.workerCount)", tab: tab)
      self.workerShown[wireId] = WorkerShown(
        wireId: wireId, profile: profile, origin: origin, tag: tag, notification: dictionary, order: self.workerCount, store: store)
      if self.workerShown.count > 200, let oldest = self.workerShown.values.min(by: { $0.order < $1.order }) {
        self.workerShown.removeValue(forKey: oldest.wireId)
      }
      tab.emit("notification", [
        "id": wireId, "title": title, "body": body, "icon": NSNull(), "tag": tag, "silent": silent, "requireInteraction": false,
        "origin": origin, "tabId": tab.transferKey ?? NSNull(), "isMainFrame": true,
      ])
      ArdiaEvents.emit("webKit.counted", data: ["name": "workerShownNotification"])
    }
  }

  private static func notificationData(_ page: Shown) -> NSDictionary? {
    guard let type = NSClassFromString("_WKMutableNotificationData") as? NSObject.Type, let scope = URL(string: page.scope),
      let origin = URL(string: page.origin)
    else { return nil }
    let made = type.init()
    let values: [String: Any] = [
      "title": page.entry["title"] as? String ?? "", "body": page.entry["body"] as? String ?? "", "tag": page.tag,
      "securityOrigin": origin, "serviceWorkerRegistrationURL": scope, "uuid": UUID(),
    ]
    for (key, value) in values where made.responds(to: NSSelectorFromString("set\(key.prefix(1).uppercased())\(key.dropFirst()):")) {
      made.setValue(value, forKey: key)
    }
    let representation = NSSelectorFromString("dictionaryRepresentation")
    guard made.responds(to: representation) else { return nil }
    return made.perform(representation)?.takeUnretainedValue() as? NSDictionary
  }

  private func deliver(_ action: String, _ notification: NSDictionary, to store: WKWebsiteDataStore?) {
    guard let store else { return }
    let click = action == "click"
    let selector = NSSelectorFromString(click ? "_processPersistentNotificationClick:completionHandler:" : "_processPersistentNotificationClose:completionHandler:")
    guard store.responds(to: selector) else { return }
    let target = store as AnyObject
    let done: (Bool) -> Void = { delivered in
      guard delivered, click else { return }
      DispatchQueue.main.async { ArdiaEvents.emit("webKit.counted", data: ["name": "workerClick"]) }
    }
    if click { target.processPersistentNotificationClick?(notification, completionHandler: done) } else {
      target.processPersistentNotificationClose?(notification, completionHandler: done)
    }
  }
}

@objc private protocol WebKitPersistentNotificationEvents {
  @objc(_processPersistentNotificationClick:completionHandler:)
  optional func processPersistentNotificationClick(_ notification: NSDictionary, completionHandler: @escaping (Bool) -> Void)
  @objc(_processPersistentNotificationClose:completionHandler:)
  optional func processPersistentNotificationClose(_ notification: NSDictionary, completionHandler: @escaping (Bool) -> Void)
}

final class WebKitWorkerNotifications: NSObject {
  private let profile: String
  private weak var owner: WebKitNotifications?

  init(profile: String, owner: WebKitNotifications) {
    self.profile = profile
    self.owner = owner
  }

  @objc(notificationPermissionsForWebsiteDataStore:)
  func notificationPermissions(forWebsiteDataStore store: WKWebsiteDataStore) -> [String: NSNumber] {
    owner?.workerPermissions(profile) ?? [:]
  }

  @objc(websiteDataStore:showNotification:)
  func websiteDataStore(_ store: WKWebsiteDataStore, showNotification notification: NSObject) {
    owner?.workerShow(notification, store: store, profile: profile)
  }

  @objc(websiteDataStore:getDisplayedNotificationsForWorkerOrigin:completionHandler:)
  func websiteDataStore(_ store: WKWebsiteDataStore, displayedNotificationsFor origin: WKSecurityOrigin, completionHandler: @escaping ([NSDictionary]) -> Void) {
    completionHandler(owner?.workerDisplayed(profile, origin: Origins.of(origin)) ?? [])
  }
}
