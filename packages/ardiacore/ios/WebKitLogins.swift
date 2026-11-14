import AppKit
import WebKit

final class WebKitLogins: NSObject {
  private struct Pending {
    let origin: String
    let username: String
    let password: String
  }

  static let script = #"""
(() => {
  if (window.__ardiaLogins) return;
  const post = (kind, data) => {
    try {
      window.webkit.messageHandlers.ardia.postMessage({ kind, data, frame: "logins" });
    } catch (e) {}
  };
  const visible = (el) => !!el && !el.disabled && !el.readOnly && el.getClientRects().length > 0;
  const passwordIn = (root) => Array.from((root || document).querySelectorAll("input[type=password]")).find(visible) || null;
  const usernameFor = (password) => {
    const scope = password.form || document;
    const fields = Array.from(scope.querySelectorAll("input")).filter((el) => visible(el) && /^(text|email|tel|)$/i.test(el.type || "text"));
    const before = fields.filter((el) => el.compareDocumentPosition(password) & Node.DOCUMENT_POSITION_FOLLOWING);
    return before.pop() || fields.find((el) => /user|mail|login|account/i.test(el.name + el.id + el.autocomplete)) || null;
  };
  const loginField = (el) => {
    if (!el || el.tagName !== "INPUT") return null;
    if (el.type === "password") return { password: el, username: usernameFor(el) };
    const password = passwordIn(el.form || document);
    if (!password) return null;
    const username = usernameFor(password);
    return username === el ? { password, username } : null;
  };
  addEventListener("pointerdown", (e) => {
    const found = loginField(e.target);
    if (!found || !e.isTrusted) return;
    const r = e.target.getBoundingClientRect();
    post("loginField", { x: r.left, y: r.top, width: r.width, height: r.height, origin: location.origin });
  }, true);
  const submitted = (form) => {
    const password = passwordIn(form);
    if (!password || !password.value) return;
    const username = usernameFor(password);
    post("loginSubmit", { username: username ? username.value : "", password: password.value, origin: location.origin });
  };
  addEventListener("submit", (e) => submitted(e.target), true);
  addEventListener("click", (e) => {
    const button = e.target && e.target.closest && e.target.closest("button, input[type=submit]");
    if (button && e.isTrusted) submitted(button.form || document);
  }, true);
  const setValue = (el, value) => {
    const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value").set;
    el.focus();
    setter.call(el, value);
    el.dispatchEvent(new Event("input", { bubbles: true }));
    el.dispatchEvent(new Event("change", { bubbles: true }));
  };
  window.__ardiaLogins = {
    fill(username, password) {
      const field = passwordIn(document);
      if (!field) return false;
      const user = usernameFor(field);
      if (user && username) setValue(user, username);
      setValue(field, password);
      return true;
    },
  };
})();
"""#

  private var pending: [ObjectIdentifier: Pending] = [:]
  private var neverSaved = Set<String>()
  private var shownAt: [ObjectIdentifier: Date] = [:]

  static func normalized(_ origin: String) -> String {
    origin.hasSuffix("/") ? String(origin.dropLast()).lowercased() : origin.lowercased()
  }

  private static func offers(_ profile: String) -> Bool {
    !WebKitStores.isPrivate(profile) && ArdiaServices.profileToggle(.passwordsOffered, profile: profile)
  }

  private func saved(profile: String, origin: String, done: @escaping ([String]) -> Void) {
    ArdiaServices.listPasswords(profile: profile) { value, _ in
      let entries = (value as? [String: Any])?["passwords"] as? [[String: Any]] ?? []
      let usernames = entries.filter { Self.normalized($0["origin"] as? String ?? "") == origin }.compactMap { $0["username"] as? String }
      DispatchQueue.main.async { done(Array(Set(usernames)).sorted()) }
    }
  }

  func fieldPressed(_ tab: WebKitTab, data: [String: Any]) {
    guard Self.offers(tab.profile), let view = tab.webView, let origin = (data["origin"] as? String).map(Self.normalized),
      origin == view.url.flatMap({ Origins.of($0) }).map(Self.normalized)
    else { return }
    let key = ObjectIdentifier(tab)
    if let last = shownAt[key], Date().timeIntervalSince(last) < 1 { return }
    let zoom = view.pageZoom * view.magnification
    let x = (data["x"] as? Double ?? 0) * zoom
    let y = ((data["y"] as? Double ?? 0) + (data["height"] as? Double ?? 0)) * zoom + 2
    saved(profile: tab.profile, origin: origin) { [weak self, weak tab] usernames in
      guard let self, let tab, !usernames.isEmpty, tab.window != nil else { return }
      self.shownAt[key] = Date()
      if LaunchConfig.shared.background {
        return NSLog("[webkit] saved passwords menu (background mode, not shown): %ld logins", usernames.count)
      }
      let menu = NSMenu()
      for username in usernames {
        let item = NSMenuItem(title: username.isEmpty ? "No user name" : username, action: #selector(self.picked(_:)), keyEquivalent: "")
        item.target = self
        item.image = NSImage(systemSymbolName: "key.fill", accessibilityDescription: nil)
        item.representedObject = Pick(tab: tab, origin: origin, username: username)
        menu.addItem(item)
      }
      _ = menu.popUp(positioning: nil, at: NSPoint(x: x, y: y), in: tab)
    }
  }

  private final class Pick: NSObject {
    weak var tab: WebKitTab?
    let origin: String
    let username: String

    init(tab: WebKitTab, origin: String, username: String) {
      self.tab = tab
      self.origin = origin
      self.username = username
    }
  }

  @objc private func picked(_ item: NSMenuItem) {
    guard let pick = item.representedObject as? Pick, let tab = pick.tab else { return }
    ArdiaServices.password(profile: tab.profile, origin: pick.origin, username: pick.username) { [weak tab] value, _ in
      guard let password = (value as? [String: Any])?["password"] as? String else { return }
      DispatchQueue.main.async {
        guard let tab, tab.webView?.url.flatMap({ Origins.of($0) }).map(Self.normalized) == pick.origin else { return }
        tab.fillLogin(username: pick.username, password: password)
        ArdiaEvents.emit("webKit.counted", data: ["name": "autofillFill"])
      }
    }
  }

  func submitted(_ tab: WebKitTab, data: [String: Any]) {
    guard Self.offers(tab.profile), let password = data["password"] as? String, !password.isEmpty,
      let origin = (data["origin"] as? String).map(Self.normalized), origin.hasPrefix("https://") || origin.hasPrefix("http://"),
      !neverSaved.contains(origin)
    else { return }
    let username = data["username"] as? String ?? ""
    let profile = tab.profile
    ArdiaServices.neverSaveOrigins(profile: profile) { [weak self, weak tab] value, _ in
      let refused = ((value as? [String: Any])?["origins"] as? [String] ?? []).map(Self.normalized)
      guard !refused.contains(origin) else { return }
      self?.saved(profile: profile, origin: origin) { usernames in
        guard let self, let tab, !usernames.contains(username) else { return }
        self.pending[ObjectIdentifier(tab)] = Pending(origin: origin, username: username, password: password)
        tab.emit("passwordPrompt", [
          "state": "save", "origin": origin, "username": username, "passwordLength": password.count, "federation": "", "usernames": [username],
        ])
        ArdiaEvents.emit("webKit.counted", data: ["name": "autofillSaveOffer"])
      }
    }
  }

  func resolveSave(_ tab: WebKitTab, action: String, username: String?, password: String?) {
    guard let login = pending.removeValue(forKey: ObjectIdentifier(tab)) else { return }
    switch action {
    case "save", "update":
      ArdiaServices.savePassword(profile: tab.profile, origin: login.origin, username: username ?? login.username, password: password ?? login.password) { _, error in
        guard error == nil else { return }
        DispatchQueue.main.async { ArdiaEvents.emit("webKit.counted", data: ["name": "autofillSave"]) }
      }
    case "never": neverSaved.insert(login.origin)
    default: break
    }
  }

  func forget(_ tab: WebKitTab) {
    pending.removeValue(forKey: ObjectIdentifier(tab))
    shownAt.removeValue(forKey: ObjectIdentifier(tab))
  }
}
