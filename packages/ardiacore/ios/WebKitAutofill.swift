import AppKit
import WebKit

final class WebKitAutofill: NSObject, WKScriptMessageHandler {
  static let shared = WebKitAutofill()
  static let handlerName = "ardiaAutofill"

  enum Kind: String {
    case address
    case card
  }

  private struct Target {
    weak var tab: WebKitTab?
    let frame: WKFrameInfo
    let origin: String
    let token: String
    let kind: Kind
    let type: String
    let typed: String
    let needsNumber: Bool
    let rect: NSRect
  }

  final class Offer {
    let id: Int
    let kind: String
    let payload: [String: Any]
    let save: (_ profile: String, _ done: @escaping (Bool) -> Void) -> Void
    let strikeKey: String

    init(id: Int, kind: String, payload: [String: Any], strikeKey: String, save: @escaping (String, @escaping (Bool) -> Void) -> Void) {
      self.id = id
      self.kind = kind
      self.payload = payload
      self.strikeKey = strikeKey
      self.save = save
    }
  }

  final class Offers {
    var queue: [Offer] = []
    var shown: Offer?
  }

  static let maxStrikes = 3
  private static let insecureNotice = "Automatic payment methods filling is disabled because this form does not use a secure connection."
  static var lastPromptId = 1_000_000

  private var target: Target?
  private var entries: [[String: Any]] = []
  private var entriesToken = ""
  private var ticket = 0
  let offers = NSMapTable<WebKitTab, Offers>.weakToStrongObjects()
  var strikes: [String: Int] = [:]
  private lazy var dropdown: WebKitAutofillDropdown = {
    let dropdown = WebKitAutofillDropdown()
    dropdown.onPick = { [weak self] row in self?.picked(row) }
    dropdown.onSelect = { [weak self] in self?.syncPage() }
    dropdown.onDismiss = { [weak self] in
      self?.syncPage()
      self?.target = nil
    }
    return dropdown
  }()

  static func attach(_ controller: WKUserContentController) {
    controller.addUserScript(WKUserScript(source: WebKitAutofillScript.source, injectionTime: .atDocumentEnd, forMainFrameOnly: false, in: WebKitHub.world))
    controller.add(shared, contentWorld: WebKitHub.world, name: handlerName)
  }

  static func count(_ name: String) { ArdiaEvents.emit("webKit.counted", data: ArdiaConsentStamp.begin().onto(["name": name])) }

  static func profileToggles(_ profile: String, _ done: @escaping ([String: Bool]) -> Void) {
    ArdiaServices.profileToggles(profile: profile, set: nil) { value, _ in
      let toggles = (value as? [String: Any])?.compactMapValues { $0 as? Bool } ?? [:]
      DispatchQueue.main.async { done(toggles) }
    }
  }

  static func fills(_ kind: Kind, in toggles: [String: Bool]) -> Bool { toggles[kind == .address ? "addresses" : "cards"] ?? false }

  private static func mainOrigin(_ tab: WebKitTab) -> String? { tab.webView?.url.flatMap { Origins.of($0) } }

  private static func sameOrigin(_ frame: WKFrameInfo, in tab: WebKitTab) -> String? {
    let scheme = frame.securityOrigin.protocol.lowercased()
    guard scheme == "https" || scheme == "http", !frame.securityOrigin.host.isEmpty else { return nil }
    let origin = Origins.of(frame.securityOrigin)
    return origin == mainOrigin(tab) ? origin : nil
  }

  static func secure(_ frame: WKFrameInfo, in tab: WebKitTab) -> Bool {
    frame.securityOrigin.protocol.lowercased() == "https" && tab.webView?.url?.scheme?.lowercased() == "https" && tab.webView?.hasOnlySecureContent == true
  }

  func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
    guard let webView = message.webView, let tab = WebKitHub.shared.transfers.owner(of: webView), let body = message.body as? [String: Any],
      let kind = body["kind"] as? String, let data = body["data"] as? [String: Any], let token = data["token"] as? String, !token.isEmpty
    else { return }
    guard let origin = Self.sameOrigin(message.frameInfo, in: tab) else {
      if target?.token == token { close(tab) }
      return
    }
    switch kind {
    case "field": field(tab, frame: message.frameInfo, origin: origin, token: token, data: data)
    case "submit": submitted(tab, frame: message.frameInfo, origin: origin, data: data)
    default: break
    }
  }

  private func field(_ tab: WebKitTab, frame: WKFrameInfo, origin: String, token: String, data: [String: Any]) {
    switch data["event"] as? String ?? "show" {
    case "show", "input": show(tab, frame: frame, origin: origin, token: token, data: data)
    case "key": if target?.token == token { key(tab, data["key"] as? String ?? "") }
    default: if target?.token == token { close(tab) }
    }
  }

  private func show(_ tab: WebKitTab, frame: WKFrameInfo, origin: String, token: String, data: [String: Any]) {
    ticket += 1
    let asked = ticket
    Self.profileToggles(tab.profile) { [weak self, weak tab] toggles in
      guard let self, let tab, asked == self.ticket else { return }
      self.showFilling(tab, frame: frame, origin: origin, token: token, data: data, toggles: toggles)
    }
  }

  private func showFilling(_ tab: WebKitTab, frame: WKFrameInfo, origin: String, token: String, data: [String: Any], toggles: [String: Bool]) {
    guard let kind = (data["kind"] as? String).flatMap(Kind.init(rawValue:)), let type = data["type"] as? String,
      Self.fills(kind, in: toggles), let view = tab.webView
    else { return close(tab) }
    let zoom = view.pageZoom * view.magnification
    let rect = NSRect(
      x: (data["x"] as? Double ?? 0) * zoom, y: (data["y"] as? Double ?? 0) * zoom,
      width: max(1, (data["width"] as? Double ?? 0) * zoom), height: max(1, (data["height"] as? Double ?? 0) * zoom))
    let current = Target(
      tab: tab, frame: frame, origin: origin, token: token, kind: kind, type: type, typed: String((data["value"] as? String ?? "").prefix(100)),
      needsNumber: data["needsNumber"] as? Bool ?? false, rect: rect)
    let reuse = target?.token == token && target?.kind == kind && entriesToken == token && data["event"] as? String == "input"
    target = current
    ticket += 1
    let mine = ticket
    if kind == .card, !Self.secure(frame, in: tab) {
      return present([WebKitAutofillDropdown.Row(id: "", title: Self.insecureNotice, detail: "", symbol: "lock.slash", enabled: false)], in: tab)
    }
    if reuse { return present(rows(for: current), in: tab) }
    load(kind, profile: tab.profile) { [weak self, weak tab] list in
      guard let self, let tab, mine == self.ticket, self.target?.tab === tab, Self.mainOrigin(tab) == origin else { return }
      self.entries = list
      self.entriesToken = token
      self.present(self.rows(for: current), in: tab)
    }
  }

  func load(_ kind: Kind, profile: String, done: @escaping ([[String: Any]]) -> Void) {
    let reply: ArdiaServiceReply = { value, _ in
      let list = (value as? [String: Any])?[kind == .address ? "addresses" : "cards"] as? [[String: Any]] ?? []
      DispatchQueue.main.async { done(list) }
    }
    if kind == .address { ArdiaServices.addresses(profile: profile, reply: reply) } else { ArdiaServices.cards(profile: profile, reply: reply) }
  }

  private func present(_ rows: [WebKitAutofillDropdown.Row], in tab: WebKitTab) {
    guard let current = target, !rows.isEmpty, let window = tab.window, !tab.isHiddenOrHasHiddenAncestor else { return close(tab) }
    if LaunchConfig.shared.background { NSLog("[webkit] autofill dropdown: %@ %ld rows", current.kind.rawValue, rows.count) }
    dropdown.show(rows, under: window.convertToScreen(tab.convert(current.rect, to: nil)), in: window)
    syncPage()
  }

  private func rows(for current: Target) -> [WebKitAutofillDropdown.Row] {
    let typed = current.typed.lowercased()
    var seen = Set<String>()
    let rows = entries.compactMap { entry -> WebKitAutofillDropdown.Row? in
      guard let id = entry["id"] as? String, id != Self.manageRow else { return nil }
      let row = current.kind == .address ? Self.addressRow(id, entry, type: current.type) : Self.cardRow(id, entry, type: current.type)
      guard let row, Self.matches(row.title, typed), seen.insert(row.title + "\n" + row.detail).inserted else { return nil }
      return row
    }
    guard !rows.isEmpty else { return [] }
    let manage = current.kind == .address ? "Manage Addresses…" : "Manage Payment Methods…"
    return rows + [WebKitAutofillDropdown.Row(id: Self.manageRow, title: manage, detail: "", symbol: "gearshape")]
  }

  private static let manageRow = "manage"

  private static func matches(_ title: String, _ typed: String) -> Bool {
    guard !typed.isEmpty else { return true }
    let text = title.lowercased()
    return text.hasPrefix(typed) || text.split(whereSeparator: { $0 == " " || $0 == "," }).contains { $0.hasPrefix(typed) }
  }

  static func text(_ entry: [String: Any], _ key: String) -> String {
    (entry[key] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
  }

  static func streetLines(_ entry: [String: Any]) -> [String] {
    text(entry, "street").split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
  }

  static func countryName(_ code: String) -> String {
    code.isEmpty ? "" : Locale.current.localizedString(forRegionCode: code) ?? code
  }

  private static func addressValue(_ entry: [String: Any], type: String) -> String {
    let names = text(entry, "name").split(separator: " ").map(String.init)
    let lines = streetLines(entry)
    switch type {
    case "name": return text(entry, "name")
    case "given-name": return names.first ?? ""
    case "family-name": return names.count > 1 ? names.last ?? "" : ""
    case "additional-name": return names.count > 2 ? names.dropFirst().dropLast().joined(separator: " ") : ""
    case "organization": return text(entry, "organization")
    case "street-address", "address-line1": return lines.first ?? ""
    case "address-line2": return lines.count > 1 ? lines[1] : ""
    case "address-line3": return lines.count > 2 ? lines[2...].joined(separator: ", ") : ""
    case "address-level2": return text(entry, "city")
    case "address-level1": return text(entry, "state")
    case "postal-code": return text(entry, "postalCode")
    case "country": return countryName(text(entry, "country"))
    case "email": return text(entry, "email")
    default: return type.hasPrefix("tel") ? text(entry, "phone") : ""
    }
  }

  private static func addressRow(_ id: String, _ entry: [String: Any], type: String) -> WebKitAutofillDropdown.Row? {
    let raw = addressValue(entry, type: type)
    guard !raw.isEmpty else { return nil }
    let title = type.hasPrefix("tel") ? compactPhone(raw) : raw
    let lines = streetLines(entry)
    let candidates: [String]
    switch type {
    case "email": candidates = [text(entry, "phone"), text(entry, "name"), lines.first ?? ""]
    case _ where type.hasPrefix("tel"): candidates = [text(entry, "email"), text(entry, "name"), lines.first ?? ""]
    case "street-address", "address-line1": candidates = [lines.count > 1 ? lines[1] : "", text(entry, "name"), text(entry, "city")]
    default: candidates = [lines.first ?? "", text(entry, "city"), text(entry, "name")]
    }
    let detail = candidates.first { !$0.isEmpty && $0 != raw } ?? ""
    return WebKitAutofillDropdown.Row(id: id, title: title, detail: detail, symbol: "mappin.and.ellipse")
  }

  private static func compactPhone(_ phone: String) -> String {
    let digits = phone.filter(\.isNumber)
    return phone.trimmingCharacters(in: .whitespaces).hasPrefix("+") ? "+" + digits : digits
  }

  static func displayPhone(_ phone: String) -> String {
    var digits = phone.filter(\.isNumber)
    if digits.count == 11, digits.hasPrefix("1") { digits.removeFirst() }
    guard digits.count == 10 else { return phone }
    let d = Array(digits)
    return "+1 \(String(d[0..<3]))-\(String(d[3..<6]))-\(String(d[6..<10]))"
  }

  static let menuDots = "\u{202A}•\u{2060}\u{2006}\u{2060}•\u{2060}\u{2006}\u{2060}"

  static func cardLabel(network: String, last4: String) -> String { "\(networkName(network))  \(menuDots)\(last4)\u{202C}" }

  static func expiryLabel(month: Int, year: Int) -> String { month > 0 && year > 0 ? String(format: "%02d/%02d", month, year % 100) : "" }

  static func networkName(_ network: String) -> String {
    switch network {
    case "visa": return "Visa"
    case "mastercard": return "Mastercard"
    case "amex": return "American Express"
    case "discover": return "Discover"
    case "diners": return "Diners Club"
    case "jcb": return "JCB"
    case "unionpay": return "UnionPay"
    default: return "Card"
    }
  }

  private static func cardRow(_ id: String, _ entry: [String: Any], type: String) -> WebKitAutofillDropdown.Row? {
    let label = cardLabel(network: text(entry, "network"), last4: text(entry, "last4"))
    let expiry = expiryLabel(month: (entry["expMonth"] as? NSNumber)?.intValue ?? 0, year: (entry["expYear"] as? NSNumber)?.intValue ?? 0)
    let card = expiry.isEmpty ? label : "\(label) • \(expiry)"
    if type == "cc-name" || type == "cc-given-name" || type == "cc-family-name" {
      let name = text(entry, "name")
      guard !name.isEmpty else { return nil }
      let parts = name.split(separator: " ").map(String.init)
      let title = type == "cc-given-name" ? parts.first ?? name : type == "cc-family-name" ? parts.last ?? name : name
      return WebKitAutofillDropdown.Row(id: id, title: title, detail: card, symbol: "creditcard")
    }
    if type == "cc-csc" { return nil }
    if type.hasPrefix("cc-exp"), !expiry.isEmpty { return WebKitAutofillDropdown.Row(id: id, title: expiry, detail: card, symbol: "creditcard") }
    return WebKitAutofillDropdown.Row(id: id, title: card, detail: "", symbol: "creditcard")
  }

  private func key(_ tab: WebKitTab, _ key: String) {
    guard dropdown.isShown, target?.tab === tab else { return }
    switch key {
    case "down": dropdown.move(1)
    case "up": dropdown.move(-1)
    case "enter":
      guard let row = dropdown.selectedRow else { return close(tab) }
      picked(row)
    default: close(tab)
    }
  }

  private func syncPage() {
    guard let current = target, let tab = current.tab else { return }
    let open = dropdown.isShown ? "true" : "false"
    let picking = dropdown.selectedRow == nil ? "false" : "true"
    let code = "window.__ardiaAutofill && window.__ardiaAutofill.dropdown(\(WebKitTab.jsString(current.token)), \(open), \(picking))"
    tab.runInWorld(code, frame: current.frame.isMainFrame ? nil : current.frame)
  }

  func forget(_ tab: WebKitTab) {
    close(tab)
    offers.removeObject(forKey: tab)
  }

  func closeDropdown(for tab: WebKitTab) { close(tab) }

  private func close(_ tab: WebKitTab) {
    guard target?.tab === tab else { return }
    ticket += 1
    dropdown.close()
    syncPage()
    target = nil
  }

  private func picked(_ row: WebKitAutofillDropdown.Row) {
    guard row.enabled, let current = target, let tab = current.tab else { return }
    if row.id == Self.manageRow {
      close(tab)
      let url = current.kind == .address ? "ardia://settings/addresses" : "ardia://settings/payments"
      return tab.emit("openWindow", ["url": url, "disposition": "foreground", "userGesture": true])
    }
    guard let entry = entries.first(where: { $0["id"] as? String == row.id }) else { return }
    close(tab)
    switch current.kind {
    case .address:
      var values: [String: Any] = [:]
      for key in ["name", "organization", "street", "city", "state", "postalCode", "country", "phone", "email"] { values[key] = Self.text(entry, key) }
      values["countryName"] = Self.countryName(Self.text(entry, "country"))
      fill(current, kind: "address", values: values, counted: "autofillAddressFill")
    case .card:
      var values: [String: Any] = ["name": Self.text(entry, "name"), "network": Self.text(entry, "network")]
      values["expMonth"] = entry["expMonth"] ?? NSNull()
      values["expYear"] = entry["expYear"] ?? NSNull()
      guard current.needsNumber else { return fill(current, kind: "card", values: values, counted: "autofillCardFill") }
      ArdiaServices.revealCardNumber(row.id, profile: tab.profile) { [weak self] value, _ in
        let number = (value as? [String: Any])?["number"] as? String
        DispatchQueue.main.async {
          guard let self, let number, !number.isEmpty else { return Self.count("autofillCardReauthRefused") }
          values["number"] = number
          self.fill(current, kind: "card", values: values, counted: "autofillCardFill")
        }
      }
    }
  }

  private func fill(_ current: Target, kind: String, values: [String: Any], counted: String) {
    guard let tab = current.tab, Self.mainOrigin(tab) == current.origin,
      let json = try? JSONSerialization.data(withJSONObject: values), let object = String(data: json, encoding: .utf8)
    else { return }
    let code = "window.__ardiaAutofill ? window.__ardiaAutofill.fill(\(WebKitTab.jsString(current.token)), \(WebKitTab.jsString(kind)), \(object)) : 0"
    tab.runInWorld(code, frame: current.frame.isMainFrame ? nil : current.frame) { result in
      if ((result as? NSNumber)?.intValue ?? 0) > 0 { Self.count(counted) }
    }
  }
}
