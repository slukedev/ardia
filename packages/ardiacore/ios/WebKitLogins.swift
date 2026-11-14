import AppKit
import WebKit

final class WebKitLogins: NSObject {
  struct Login: Equatable {
    let username: String
    let realm: String
    let match: String
  }

  private struct Pending {
    let url: String
    let origin: String
    let username: String
    let password: String
    let update: Bool
  }

  private struct Listing {
    let at: Date
    let logins: [Login]
  }

  private struct Field {
    weak var tab: WebKitTab?
    let origin: String
    let url: String
    let rect: NSRect
    let password: Bool
    let typed: String
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
    if (!el || el.tagName !== "INPUT" || !visible(el)) return null;
    if (el.type === "password") return { password: el, username: usernameFor(el) };
    const password = passwordIn(el.form || document);
    if (!password) return null;
    const username = usernameFor(password);
    return username === el ? { password, username } : null;
  };
  let active = null;
  let open = false;
  let picking = false;
  const hide = () => {
    if (open) post("loginField", { event: "hide" });
  };
  const report = (event, el) => {
    const found = loginField(el);
    if (!found) return hide();
    active = { el, found };
    const r = el.getBoundingClientRect();
    const isPassword = el.type === "password";
    post("loginField", {
      event, origin: location.origin, password: isPassword, value: isPassword ? "" : String(el.value || "").slice(0, 200),
      x: r.left, y: r.top, width: r.width, height: r.height,
    });
  };
  addEventListener("pointerdown", (e) => {
    if (e.isTrusted) report("show", e.target);
  }, true);
  addEventListener("input", (e) => {
    const el = e.target;
    if (!e.isTrusted || !el || el.tagName !== "INPUT") return;
    if (el.type === "password") return hide();
    if (loginField(el)) report("input", el);
  }, true);
  addEventListener("keydown", (e) => {
    if (!e.isTrusted || !active || e.target !== active.el) return;
    const key = { ArrowDown: "down", ArrowUp: "up", Enter: "enter", Escape: "escape", Tab: "tab" }[e.key];
    if (!key) return;
    if (!open) {
      if (key === "down") {
        e.preventDefault();
        report("show", e.target);
      }
      return;
    }
    if (key !== "tab" && (key !== "enter" || picking)) {
      e.preventDefault();
      e.stopImmediatePropagation();
    }
    post("loginField", { event: "key", key });
  }, true);
  addEventListener("focusout", (e) => {
    if (active && e.target === active.el) hide();
  }, true);
  addEventListener("scroll", hide, true);
  addEventListener("resize", hide);
  addEventListener("pagehide", hide);
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
    dropdown(isOpen, hasPick) {
      open = !!isOpen;
      picking = !!hasPick;
    },
    fill(username, password) {
      const target = active && active.el.isConnected && active.found.password.isConnected ? active.found : null;
      const field = target ? target.password : passwordIn(document);
      if (!field) return false;
      const user = target ? target.username : usernameFor(field);
      if (user && username) setValue(user, username);
      setValue(field, password);
      open = picking = false;
      return true;
    },
  };
})();
"""#

  private static let listingLifetime: TimeInterval = 30
  private static let missingCall = "the engine has no"

  private var pending: [ObjectIdentifier: Pending] = [:]
  private var neverSaved = Set<String>()
  private var listings: [String: Listing] = [:]
  private var field: Field?
  private var ticket = 0
  private lazy var dropdown: WebKitLoginsDropdown = {
    let dropdown = WebKitLoginsDropdown()
    dropdown.onPick = { [weak self] login in self?.picked(login) }
    dropdown.onSelect = { [weak self] in self?.syncPage() }
    dropdown.onDismiss = { [weak self] in
      self?.syncPage()
      self?.field = nil
    }
    return dropdown
  }()

  static func normalized(_ origin: String) -> String {
    origin.hasSuffix("/") ? String(origin.dropLast()).lowercased() : origin.lowercased()
  }

  private static func fills(_ profile: String) -> Bool { ArdiaServices.profileToggle(.passwordsOffered, profile: profile) }

  private static func saves(_ profile: String) -> Bool { !WebKitStores.isPrivate(profile) && fills(profile) }

  private static func lacksCall(_ error: Any?) -> Bool { (error as? String)?.hasPrefix(missingCall) == true }

  private static func count(_ name: String) { ArdiaEvents.emit("webKit.counted", data: ["name": name]) }

  private static func pageOrigin(_ tab: WebKitTab) -> String? { tab.webView?.url.flatMap { Origins.of($0) }.map(normalized) }

  private static func secretCall(_ name: String, profile: String, args: [String: Any], done: @escaping ([String: Any]) -> Void) {
    guard var json = try? JSONSerialization.data(withJSONObject: args) else { return done(["error": "bad arguments"]) }
    json.append(0)
    let secret = NSMutableData(data: json)
    json.resetBytes(in: 0..<json.count)
    ArdiaEngineBridge.callWithSecret(name, profile: profile, args: secret) { reply in
      let parsed = (try? JSONSerialization.jsonObject(with: Data(reply.utf8))) as? [String: Any] ?? ["error": "bad reply from the engine"]
      DispatchQueue.main.async { done(parsed) }
    }
  }

  private static func call(_ name: String, profile: String, args: [String: Any], done: @escaping ([String: Any]) -> Void) {
    ArdiaServices.call(name, profile: ArdiaHost.baseProfile(of: profile), args: args) { result in
      DispatchQueue.main.async { done(result) }
    }
  }

  private func listingKey(_ profile: String, _ origin: String) -> String { "\(ArdiaHost.baseProfile(of: profile))|\(origin)" }

  private func logins(profile: String, origin: String, url: String, done: @escaping ([Login]) -> Void) {
    let key = listingKey(profile, origin)
    if let listing = listings[key], Date().timeIntervalSince(listing.at) < Self.listingLifetime { return done(listing.logins) }
    Self.call("ac_passwords_page_logins", profile: profile, args: ["url": url]) { [weak self] result in
      guard let self else { return }
      if Self.lacksCall(result["error"]) { return self.exactLogins(profile: profile, origin: origin, done: done) }
      let logins = (result["logins"] as? [[String: Any]] ?? []).compactMap { entry -> Login? in
        guard let username = entry["username"] as? String, let realm = entry["realm"] as? String else { return nil }
        return Login(username: username, realm: realm, match: entry["match"] as? String ?? "exact")
      }
      if result["error"] == nil { self.listings[key] = Listing(at: Date(), logins: logins) }
      done(logins)
    }
  }

  private func exactLogins(profile: String, origin: String, done: @escaping ([Login]) -> Void) {
    ArdiaServices.listPasswords(profile: profile) { value, _ in
      let entries = (value as? [String: Any])?["passwords"] as? [[String: Any]] ?? []
      let usernames = Set(entries.filter { Self.normalized($0["origin"] as? String ?? "") == origin }.compactMap { $0["username"] as? String })
      let logins = usernames.sorted().map { Login(username: $0, realm: origin + "/", match: "exact") }
      DispatchQueue.main.async { done(logins) }
    }
  }

  func fieldPressed(_ tab: WebKitTab, data: [String: Any]) {
    switch data["event"] as? String ?? "show" {
    case "show", "input": show(tab, data: data)
    case "key": key(tab, data["key"] as? String ?? "")
    default: close(tab)
    }
  }

  private func show(_ tab: WebKitTab, data: [String: Any]) {
    guard Self.fills(tab.profile), let view = tab.webView, let url = view.url, let page = Self.pageOrigin(tab),
      (data["origin"] as? String).map(Self.normalized) == page
    else { return close(tab) }
    let zoom = view.pageZoom * view.magnification
    let rect = NSRect(
      x: (data["x"] as? Double ?? 0) * zoom, y: (data["y"] as? Double ?? 0) * zoom,
      width: max(1, (data["width"] as? Double ?? 0) * zoom), height: max(1, (data["height"] as? Double ?? 0) * zoom))
    let password = data["password"] as? Bool ?? false
    let current = Field(tab: tab, origin: page, url: url.absoluteString, rect: rect, password: password, typed: password ? "" : data["value"] as? String ?? "")
    field = current
    ticket += 1
    let mine = ticket
    logins(profile: tab.profile, origin: page, url: current.url) { [weak self, weak tab] logins in
      guard let self, let tab, mine == self.ticket, self.field?.tab === tab, Self.pageOrigin(tab) == page else { return }
      self.present(logins, for: current, in: tab)
    }
  }

  private func present(_ logins: [Login], for current: Field, in tab: WebKitTab) {
    let typed = current.typed.lowercased()
    let shown = typed.isEmpty ? logins : logins.filter { $0.username.lowercased().hasPrefix(typed) }
    guard !shown.isEmpty, let window = tab.window, !tab.isHiddenOrHasHiddenAncestor else { return close(tab) }
    if LaunchConfig.shared.background { NSLog("[webkit] saved passwords dropdown: %ld logins", shown.count) }
    dropdown.show(shown, under: window.convertToScreen(tab.convert(current.rect, to: nil)), in: window)
    syncPage()
  }

  private func key(_ tab: WebKitTab, _ key: String) {
    guard dropdown.isShown, field?.tab === tab else { return }
    switch key {
    case "down": dropdown.move(1)
    case "up": dropdown.move(-1)
    case "enter":
      guard let login = dropdown.selectedLogin else { return close(tab) }
      picked(login)
    default: close(tab)
    }
  }

  private func syncPage() {
    guard let tab = field?.tab else { return }
    let open = dropdown.isShown ? "true" : "false"
    let picking = dropdown.selectedLogin == nil ? "false" : "true"
    tab.webView?.evaluateJavaScript("window.__ardiaLogins && window.__ardiaLogins.dropdown(\(open), \(picking))", in: nil, in: WebKitHub.world) { _ in }
  }

  private func close(_ tab: WebKitTab) {
    guard field?.tab === tab else { return }
    ticket += 1
    dropdown.close()
    syncPage()
    field = nil
  }

  private func picked(_ login: Login) {
    guard let current = field, let tab = current.tab else { return }
    close(tab)
    Self.call("ac_passwords_page_fill", profile: tab.profile, args: ["url": current.url, "realm": login.realm, "username": login.username]) {
      [weak self, weak tab] result in
      guard let self, let tab else { return }
      if Self.lacksCall(result["error"]) { return self.revealAndFill(login, origin: current.origin, in: tab) }
      guard let password = result["password"] as? String else { return }
      self.fill(tab, origin: current.origin, username: result["username"] as? String ?? login.username, password: password)
    }
  }

  private func revealAndFill(_ login: Login, origin: String, in tab: WebKitTab) {
    ArdiaServices.password(profile: tab.profile, origin: origin, username: login.username) { [weak self, weak tab] value, _ in
      guard let password = (value as? [String: Any])?["password"] as? String else { return }
      DispatchQueue.main.async {
        guard let self, let tab else { return }
        self.fill(tab, origin: origin, username: login.username, password: password)
      }
    }
  }

  private func fill(_ tab: WebKitTab, origin: String, username: String, password: String) {
    guard Self.pageOrigin(tab) == origin else { return }
    tab.fillLogin(username: username, password: password)
    Self.count("autofillFill")
  }

  func submitted(_ tab: WebKitTab, data: [String: Any]) {
    guard Self.saves(tab.profile), let password = data["password"] as? String, !password.isEmpty,
      let origin = (data["origin"] as? String).map(Self.normalized), origin.hasPrefix("https://") || origin.hasPrefix("http://"),
      !neverSaved.contains(origin)
    else { return }
    let username = data["username"] as? String ?? ""
    let url = Self.pageOrigin(tab) == origin ? tab.webView?.url?.absoluteString ?? origin + "/" : origin + "/"
    Self.secretCall("ac_passwords_page_submitted", profile: tab.profile, args: ["url": url, "username": username, "password": password]) {
      [weak self, weak tab] reply in
      guard let self, let tab else { return }
      if Self.lacksCall(reply["error"]) { return self.submittedOnExactSite(tab, url: url, origin: origin, username: username, password: password) }
      switch reply["state"] as? String {
      case "save":
        self.offer(Pending(url: url, origin: origin, username: username, password: password, update: false), usernames: [username], in: tab)
      case "update":
        let saved = reply["username"] as? String ?? username
        let usernames = reply["usernames"] as? [String] ?? [saved]
        self.offer(Pending(url: url, origin: origin, username: saved, password: password, update: true), usernames: usernames, in: tab)
      default: break
      }
    }
  }

  private func submittedOnExactSite(_ tab: WebKitTab, url: String, origin: String, username: String, password: String) {
    let profile = tab.profile
    ArdiaServices.neverSaveOrigins(profile: profile) { [weak self, weak tab] value, _ in
      let refused = ((value as? [String: Any])?["origins"] as? [String] ?? []).map(Self.normalized)
      DispatchQueue.main.async {
        guard let self, !refused.contains(origin) else { return }
        self.exactLogins(profile: profile, origin: origin) { [weak self, weak tab] logins in
          guard let self, let tab, !logins.contains(where: { $0.username == username }) else { return }
          self.offer(Pending(url: url, origin: origin, username: username, password: password, update: false), usernames: [username], in: tab)
        }
      }
    }
  }

  private func offer(_ login: Pending, usernames: [String], in tab: WebKitTab) {
    pending[ObjectIdentifier(tab)] = login
    tab.emit("passwordPrompt", [
      "state": login.update ? "update" : "save", "origin": login.origin, "username": login.username, "passwordLength": login.password.count,
      "federation": "", "usernames": usernames,
    ])
    Self.count(login.update ? "autofillUpdateOffer" : "autofillSaveOffer")
  }

  func resolveSave(_ tab: WebKitTab, action: String, username: String?, password: String?) {
    guard let login = pending.removeValue(forKey: ObjectIdentifier(tab)) else { return }
    let profile = tab.profile
    let name = username ?? login.username
    let secret = password ?? login.password
    listings.removeValue(forKey: listingKey(profile, login.origin))
    switch action {
    case "save":
      ArdiaServices.savePassword(profile: profile, origin: login.origin, username: name, password: secret) { _, error in
        guard error == nil else { return }
        DispatchQueue.main.async { Self.count("autofillSave") }
      }
    case "update" where login.update:
      Self.secretCall("ac_passwords_page_update", profile: profile, args: ["url": login.url, "username": name, "password": secret]) { reply in
        if reply["error"] == nil { return Self.count("autofillUpdate") }
        guard Self.lacksCall(reply["error"]) else { return }
        ArdiaServices.updatePassword(profile: profile, origin: login.origin, username: name, newUsername: nil, newPassword: secret) { _, error in
          guard error == nil else { return }
          DispatchQueue.main.async { Self.count("autofillUpdate") }
        }
      }
    case "never":
      Self.count("autofillNever")
      Self.call("ac_passwords_page_never", profile: profile, args: ["url": login.url]) { [weak self] result in
        if Self.lacksCall(result["error"]) { self?.neverSaved.insert(login.origin) }
      }
    default: break
    }
  }

  func forget(_ tab: WebKitTab) {
    pending.removeValue(forKey: ObjectIdentifier(tab))
    close(tab)
  }
}
