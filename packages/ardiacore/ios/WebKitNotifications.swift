import Foundation
import WebKit

final class WebKitNotifications {
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
      let value = answers["notifications"].map { $0 ? "granted" : "denied" } ?? "default"
      Self.reply(["type": "permission", "value": value], to: tab)
    }
  }

  func received(_ data: [String: Any], from tab: WebKitTab) {
    guard let type = data["type"] as? String, let id = data["id"] as? String, let origin = Self.origin(of: tab) else { return }
    switch type {
    case "request":
      WebKitHub.shared.permissions.request(browserId: tab.browserId, tabId: tab.transferKey, profile: tab.profile, origin: origin, kinds: ["notifications"]) {
        [weak tab] allowed in
        guard let tab else { return }
        Self.reply(["type": "answer", "id": id, "value": allowed ? "granted" : "denied"], to: tab)
      }
    case "show":
      WebKitHub.shared.permissions.answers(profile: tab.profile, origin: origin, kinds: ["notifications"]) { [weak tab] answers in
        guard let tab, answers["notifications"] == true, !WebKitStores.isPrivate(tab.profile) else { return }
        tab.emit("notification", [
          "id": Self.wireId(id, tab: tab), "title": data["title"] as? String ?? "", "body": data["body"] as? String ?? "",
          "icon": (data["icon"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? NSNull(), "tag": data["tag"] as? String ?? "",
          "silent": data["silent"] as? Bool ?? false, "requireInteraction": data["requireInteraction"] as? Bool ?? false,
          "origin": origin, "tabId": tab.transferKey ?? NSNull(), "isMainFrame": true,
        ])
        ArdiaEvents.emit("webKit.counted", data: ["name": "notification"])
      }
    case "close":
      tab.emit("notificationClose", ["id": Self.wireId(id, tab: tab)])
    default: break
    }
  }

  func act(_ wireId: String, action: String, in tab: WebKitTab) {
    let prefix = "wk-n\(-tab.browserId)-"
    guard wireId.hasPrefix(prefix) else { return }
    Self.reply(["type": action == "click" ? "click" : "close", "id": String(wireId.dropFirst(prefix.count))], to: tab)
  }
}
