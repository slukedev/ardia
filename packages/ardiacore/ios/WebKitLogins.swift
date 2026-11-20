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
    let field: [String: String]
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
    const field = { name: password.getAttribute("name") || "", id: password.id || "", autocomplete: password.getAttribute("autocomplete") || "" };
    post("loginSubmit", { username: username ? username.value : "", password: password.value, origin: location.origin, field });
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
    formShown(origin, field) {
      if (location.origin !== origin) return false;
      const same = (el) => (el.getAttribute("name") || "") === field.name && (el.id || "") === field.id && (el.getAttribute("autocomplete") || "") === field.autocomplete;
      return Array.from(document.querySelectorAll("input[type=password]")).some((el) => visible(el) && same(el));
    },
    fill(username, password, origin) {
      if (location.origin !== origin) return false;
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
  private var landings: [ObjectIdentifier: Int] = [:]
  private var landingTurns = 0
  private static let landingSeconds = 15.0
  private static let navigationGrace = 0.4
  private static let landingCheckInterval = 0.25
  private var neverSaved = Set<String>()
  private var listings: [String: Listing] = [:]
  private var field: Field?
  private var shownLogins: [String: Login] = [:]
  private var ticket = 0
  private lazy var dropdown: WebKitAutofillDropdown = {
    let dropdown = WebKitAutofillDropdown()
    dropdown.onPick = { [weak self] row in
      guard let self, let login = self.shownLogins[row.id] else { return }
      self.picked(login)
    }
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

  private static func manages(_ use: WebKitPasswordGate.Use, for profile: String, _ done: @escaping (Bool) -> Void) {
    WebKitAutofill.profileToggles(profile) { toggles in
      let verdict = WebKitPasswordGate.verdict(
        use, passwordsOn: toggles["passwords"] ?? false, systemProvider: ArdiaWebView.fieldProvider(profile: profile) != nil,
        privateProfile: WebKitStores.isPrivate(profile))
      if verdict == .leftToManager { count("passwordsLeftToManager") }
      done(verdict == .ardia)
    }
  }

  private static func lacksCall(_ error: Any?) -> Bool { (error as? String)?.hasPrefix(missingCall) == true }

  private static func count(_ name: String) { ArdiaEvents.emit("webKit.counted", data: ArdiaConsentStamp.begin().onto(["name": name])) }

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

  static func frameOrigin(_ origin: WKSecurityOrigin, claimed: Any?) -> String? {
    let scheme = origin.protocol.lowercased()
    guard scheme == "https" || scheme == "http", !origin.host.isEmpty else { return nil }
    let frame = normalized(Origins.of(origin))
    guard let claimed = claimed as? String, normalized(claimed) == frame else { return nil }
    return frame
  }

  func fieldPressed(_ tab: WebKitTab, data: [String: Any], origin: WKSecurityOrigin) {
    guard let frame = Self.frameOrigin(origin, claimed: data["origin"]) else { return close(tab) }
    pressed(tab, data: data, origin: frame)
  }

  private func pressed(_ tab: WebKitTab, data: [String: Any], origin: String) {
    switch data["event"] as? String ?? "show" {
    case "show", "input": show(tab, data: data, origin: origin)
    case "key": key(tab, data["key"] as? String ?? "")
    default: close(tab)
    }
  }

  private func show(_ tab: WebKitTab, data: [String: Any], origin: String) {
    ticket += 1
    let asked = ticket
    Self.manages(.fill, for: tab.profile) { [weak self, weak tab] on in
      guard let self, let tab, asked == self.ticket else { return }
      if on { self.showFilling(tab, data: data, origin: origin) } else { self.close(tab) }
    }
  }

  private func showFilling(_ tab: WebKitTab, data: [String: Any], origin: String) {
    guard let view = tab.webView, let url = view.url, let page = Self.pageOrigin(tab), origin == page else { return close(tab) }
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
    shownLogins = Dictionary(shown.map { (Self.rowId($0), $0) }, uniquingKeysWith: { first, _ in first })
    dropdown.show(shown.map(Self.row), under: window.convertToScreen(tab.convert(current.rect, to: nil)), in: window)
    syncPage()
  }

  private static func rowId(_ login: Login) -> String { "\(login.realm)\n\(login.username)" }

  private static func row(_ login: Login) -> WebKitAutofillDropdown.Row {
    let title = login.username.isEmpty ? "No username" : login.username
    let exact = login.match == "exact"
    let detail = exact ? String(repeating: "•", count: 8) : URL(string: login.realm)?.host ?? login.realm
    return WebKitAutofillDropdown.Row(
      id: rowId(login), title: title, detail: detail, symbol: "key.fill", muted: login.username.isEmpty, spokenLabel: exact ? title : nil)
  }

  private func key(_ tab: WebKitTab, _ key: String) {
    guard dropdown.isShown, field?.tab === tab else { return }
    switch key {
    case "down": dropdown.move(1)
    case "up": dropdown.move(-1)
    case "enter":
      guard let login = dropdown.selectedRow.flatMap({ shownLogins[$0.id] }) else { return close(tab) }
      picked(login)
    default: close(tab)
    }
  }

  private func syncPage() {
    guard let tab = field?.tab else { return }
    let open = dropdown.isShown ? "true" : "false"
    let picking = dropdown.selectedRow == nil ? "false" : "true"
    tab.webView?.evaluateJavaScript("window.__ardiaLogins && window.__ardiaLogins.dropdown(\(open), \(picking))", in: nil, in: WebKitHub.world) { _ in }
  }

  private func close(_ tab: WebKitTab) {
    guard field == nil || field?.tab === tab else { return }
    ticket += 1
    dropdown.close()
    syncPage()
    field = nil
    shownLogins = [:]
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
    tab.fillLogin(username: username, password: password, origin: origin)
    Self.count("autofillFill")
  }

  func submitted(_ tab: WebKitTab, data: [String: Any], origin: WKSecurityOrigin) {
    guard let frame = Self.frameOrigin(origin, claimed: data["origin"]) else { return }
    submitted(tab, data: data, frame: frame)
  }

  private func submitted(_ tab: WebKitTab, data: [String: Any], frame origin: String) {
    Self.manages(.offerToSave, for: tab.profile) { [weak self, weak tab] on in
      guard let self, let tab, on else { return }
      self.submittedWhileSaving(tab, data: data, origin: origin)
    }
  }

  private func submittedWhileSaving(_ tab: WebKitTab, data: [String: Any], origin: String) {
    guard let password = data["password"] as? String, !password.isEmpty,
      origin.hasPrefix("https://") || origin.hasPrefix("http://"),
      !neverSaved.contains(origin)
    else { return }
    let username = data["username"] as? String ?? ""
    let field = Self.submittedField(data["field"])
    let url = Self.pageOrigin(tab) == origin ? tab.webView?.url?.absoluteString ?? origin + "/" : origin + "/"
    Self.secretCall("ac_passwords_page_submitted", profile: tab.profile, args: ["url": url, "username": username, "password": password]) {
      [weak self, weak tab] reply in
      guard let self, let tab else { return }
      if Self.lacksCall(reply["error"]) {
        return self.submittedOnExactSite(tab, url: url, origin: origin, username: username, password: password, field: field)
      }
      switch reply["state"] as? String {
      case "save":
        self.offer(Pending(url: url, origin: origin, username: username, password: password, update: false, field: field), usernames: [username], in: tab)
      case "update":
        let saved = reply["username"] as? String ?? username
        let usernames = reply["usernames"] as? [String] ?? [saved]
        self.offer(Pending(url: url, origin: origin, username: saved, password: password, update: true, field: field), usernames: usernames, in: tab)
      default: break
      }
    }
  }

  private static func submittedField(_ raw: Any?) -> [String: String] {
    let given = raw as? [String: Any] ?? [:]
    return Dictionary(uniqueKeysWithValues: ["name", "id", "autocomplete"].map { ($0, String((given[$0] as? String ?? "").prefix(200))) })
  }

  private func submittedOnExactSite(_ tab: WebKitTab, url: String, origin: String, username: String, password: String, field: [String: String]) {
    let profile = tab.profile
    ArdiaServices.neverSaveOrigins(profile: profile) { [weak self, weak tab] value, _ in
      let refused = ((value as? [String: Any])?["origins"] as? [String] ?? []).map(Self.normalized)
      DispatchQueue.main.async {
        guard let self, !refused.contains(origin) else { return }
        self.exactLogins(profile: profile, origin: origin) { [weak self, weak tab] logins in
          guard let self, let tab, !logins.contains(where: { $0.username == username }) else { return }
          self.offer(Pending(url: url, origin: origin, username: username, password: password, update: false, field: field), usernames: [username], in: tab)
        }
      }
    }
  }

  private func offer(_ login: Pending, usernames: [String], in tab: WebKitTab) {
    let key = ObjectIdentifier(tab)
    pending[key] = login
    landingTurns += 1
    let turn = landingTurns
    landings[key] = turn
    let prompt: [String: Any] = [
      "state": login.update ? "update" : "save", "origin": login.origin, "username": login.username, "passwordLength": login.password.count,
      "federation": "", "usernames": usernames,
    ]
    let deadline = Date().addingTimeInterval(Self.landingSeconds)
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.navigationGrace) { [weak self, weak tab] in
      self?.land(key, turn: turn, prompt: prompt, deadline: deadline, in: tab)
    }
  }

  private func land(_ key: ObjectIdentifier, turn: Int, prompt: [String: Any], deadline: Date, in tab: WebKitTab?) {
    guard landings[key] == turn else { return }
    guard let tab, let login = pending[key], let view = tab.webView else {
      landings.removeValue(forKey: key)
      return
    }
    let lastLook = Date() >= deadline
    let lookAgain = { [weak self, weak tab] in
      DispatchQueue.main.asyncAfter(deadline: .now() + Self.landingCheckInterval) {
        self?.land(key, turn: turn, prompt: prompt, deadline: deadline, in: tab)
      }
    }
    if view.isLoading, !lastLook { return lookAgain() }
    guard let fieldData = try? JSONSerialization.data(withJSONObject: login.field), let fieldJSON = String(data: fieldData, encoding: .utf8) else {
      landings.removeValue(forKey: key)
      return
    }
    tab.runInWorld("window.__ardiaLogins ? window.__ardiaLogins.formShown(\(WebKitTab.jsString(login.origin)), \(fieldJSON)) : false") { [weak self, weak tab] shown in
      guard let self, self.landings[key] == turn else { return }
      if (shown as? Bool) != true {
        self.landings.removeValue(forKey: key)
        guard let tab else { return }
        Self.count(login.update ? "autofillUpdateOffer" : "autofillSaveOffer")
        return tab.emit("passwordPrompt", prompt)
      }
      guard lastLook else { return lookAgain() }
      self.landings.removeValue(forKey: key)
      self.pending.removeValue(forKey: key)
      Self.count("autofillSaveSuppressed")
    }
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
    landings.removeValue(forKey: ObjectIdentifier(tab))
    close(tab)
  }

  func closeDropdowns(for tab: WebKitTab) {
    close(tab)
    WebKitAutofill.shared.closeDropdown(for: tab)
  }
}
