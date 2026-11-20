import AppKit
import WebKit

extension WebKitAutofill {
  func submitted(_ tab: WebKitTab, frame: WKFrameInfo, origin: String, data: [String: Any]) {
    let profile = tab.profile
    guard !WebKitStores.isPrivate(profile) else { return }
    Self.profileToggles(profile) { [weak self, weak tab] toggles in
      guard let self, let tab else { return }
      self.submitted(tab, frame: frame, origin: origin, data: data, toggles: toggles)
    }
  }

  private func submitted(_ tab: WebKitTab, frame: WKFrameInfo, origin: String, data: [String: Any], toggles: [String: Bool]) {
    let address = Self.fills(.address, in: toggles) ? (data["address"] as? [String: Any]).flatMap(Self.importableAddress) : nil
    let offerAddress = { [weak self, weak tab] in
      guard let self, let tab, let address else { return }
      self.offerAddress(address, origin: origin, in: tab)
    }
    guard Self.fills(.card, in: toggles), Self.secure(frame, in: tab), let card = (data["card"] as? [String: Any]).flatMap(Self.importableCard) else {
      return offerAddress()
    }
    offerCard(card, origin: origin, in: tab, otherwise: offerAddress)
  }

  struct NewCard {
    let number: String
    let name: String
    let month: Int
    let year: Int
    var network: String { WebKitAutofill.network(of: number) }
    var last4: String { String(number.suffix(4)) }
  }

  static func network(of number: String) -> String {
    let prefix = { (n: Int) in Int(number.prefix(n)) ?? 0 }
    if number.hasPrefix("4") { return "visa" }
    if (51...55).contains(prefix(2)) || (2221...2720).contains(prefix(4)) { return "mastercard" }
    if [34, 37].contains(prefix(2)) { return "amex" }
    if prefix(4) == 6011 || prefix(2) == 65 || (644...649).contains(prefix(3)) { return "discover" }
    if (300...305).contains(prefix(3)) || [36, 38, 39].contains(prefix(2)) { return "diners" }
    if (3528...3589).contains(prefix(4)) { return "jcb" }
    if prefix(2) == 62 { return "unionpay" }
    return "card"
  }

  static func luhn(_ number: String) -> Bool {
    let digits = number.compactMap(\.wholeNumberValue)
    guard digits.count == number.count, (12...19).contains(digits.count) else { return false }
    let sum = digits.reversed().enumerated().reduce(0) { total, item in
      let doubled = item.offset % 2 == 1 ? item.element * 2 : item.element
      return total + (doubled > 9 ? doubled - 9 : doubled)
    }
    return sum % 10 == 0
  }

  static func importableCard(_ card: [String: Any]) -> NewCard? {
    guard card["filled"] as? Bool != true, let number = card["number"] as? String, luhn(number) else { return nil }
    let month = (card["expMonth"] as? NSNumber)?.intValue ?? 0
    let year = (card["expYear"] as? NSNumber)?.intValue ?? 0
    let now = Calendar(identifier: .gregorian).dateComponents([.year, .month], from: Date())
    guard (1...12).contains(month), let thisYear = now.year, let thisMonth = now.month, year > thisYear || year == thisYear && month >= thisMonth,
      year < thisYear + 25
    else { return nil }
    return NewCard(number: number, name: String((card["name"] as? String ?? "").prefix(200)), month: month, year: year)
  }

  func offerCard(_ card: NewCard, origin: String, in tab: WebKitTab, otherwise: @escaping () -> Void) {
    let strikeKey = "card|\(card.network)|\(card.last4)"
    guard strikes[strikeKey, default: 0] < Self.maxStrikes else { return otherwise() }
    load(.card, profile: tab.profile) { [weak self, weak tab] saved in
      guard let self, let tab else { return }
      if saved.contains(where: { Self.text($0, "last4") == card.last4 && Self.text($0, "network") == card.network }) { return otherwise() }
      let identifier = "\(Self.cardLabel(network: card.network, last4: card.last4)) • \(Self.expiryLabel(month: card.month, year: card.year))"
      let payload: [String: Any] = [
        "kind": "saveCard", "title": "Save card?", "message": "To pay faster next time, save your card to your device",
        "accept": "Save", "decline": "No Thanks", "footer": "", "lines": [identifier],
      ]
      let fields: [String: Any] = ["name": card.name, "expMonth": card.month, "expYear": card.year]
      self.enqueue(kind: "card", payload: payload, origin: origin, strikeKey: strikeKey, in: tab) { profile, done in
        ArdiaServices.saveCard(fields, number: card.number, profile: profile) { _, error in DispatchQueue.main.async { done(error == nil) } }
      }
    }
  }

  static let addressKeys = ["name", "organization", "street", "city", "state", "postalCode", "country", "phone", "email"]

  static func regionCode(_ value: String, shown: String) -> String? {
    let candidates = [value, shown].map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    for candidate in candidates where candidate.count == 2 && candidate.allSatisfy(\.isLetter) { return candidate.uppercased() }
    let locales = [Locale.current, Locale(identifier: "en_US")]
    for candidate in candidates {
      let wanted = candidate.lowercased()
      for region in Locale.Region.isoRegions where region.identifier.count == 2 {
        if locales.contains(where: { $0.localizedString(forRegionCode: region.identifier)?.lowercased() == wanted }) { return region.identifier }
      }
    }
    return nil
  }

  static func importableAddress(_ raw: [String: Any]) -> [String: String]? {
    var address: [String: String] = [:]
    for key in addressKeys {
      let value = (raw[key] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      if !value.isEmpty { address[key] = String(value.prefix(300)) }
    }
    address["country"] = regionCode(address["country"] ?? "", shown: raw["countryText"] as? String ?? "") ?? Locale.current.region?.identifier ?? "US"
    guard address["street"] != nil, address["city"] != nil else { return nil }
    if address["country"] == "US" {
      guard address["state"] != nil, let zip = address["postalCode"], zip.wholeMatch(of: /\d{5}(-?\d{4})?/) != nil else { return nil }
    }
    if let email = address["email"], email.wholeMatch(of: /[^@\s]+@[^@\s]+\.[^@\s]+/) == nil { return nil }
    if let phone = address["phone"], phone.filter(\.isNumber).count < 7 { return nil }
    return address
  }

  static func folded(_ value: String) -> String {
    value.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
  }

  static func sameValue(_ key: String, _ a: String, _ b: String) -> Bool {
    if key == "phone" { return a.filter(\.isNumber).hasSuffix(String(b.filter(\.isNumber).suffix(10))) || b.filter(\.isNumber).hasSuffix(String(a.filter(\.isNumber).suffix(10))) }
    if key == "postalCode" { return a.filter { $0.isLetter || $0.isNumber }.lowercased().prefix(5) == b.filter { $0.isLetter || $0.isNumber }.lowercased().prefix(5) }
    return folded(a) == folded(b)
  }

  static func summary(_ address: [String: String]) -> [String] {
    var lines: [String] = []
    if let name = address["name"] { lines.append(name) }
    if let organization = address["organization"] { lines.append(organization) }
    lines += (address["street"] ?? "").split(separator: "\n").map(String.init)
    let region = [address["state"], address["postalCode"]].compactMap { $0 }.joined(separator: " ")
    let place = [address["city"], region.isEmpty ? nil : region].compactMap { $0 }.joined(separator: ", ")
    if !place.isEmpty { lines.append(place) }
    if let country = address["country"] { lines.append(countryName(country)) }
    if let email = address["email"] { lines.append(email) }
    if let phone = address["phone"] { lines.append(displayPhone(phone)) }
    return lines
  }

  static func addressBlock(_ address: [String: String]) -> String {
    var lines: [String] = []
    if let organization = address["organization"] { lines.append(organization) }
    lines += (address["street"] ?? "").split(separator: "\n").map(String.init)
    let region = [address["state"], address["postalCode"]].compactMap { $0 }.joined(separator: " ")
    let place = [address["city"], region.isEmpty ? nil : region].compactMap { $0 }.joined(separator: ", ")
    if !place.isEmpty { lines.append(place) }
    if let country = address["country"] { lines.append(countryName(country)) }
    return lines.joined(separator: "\n")
  }

  static func sameStreet(_ a: String, _ b: String) -> Bool {
    let left = a.split(separator: "\n").map { folded(String($0)) }
    let right = b.split(separator: "\n").map { folded(String($0)) }
    let shorter = min(left.count, right.count)
    return shorter > 0 && Array(left.prefix(shorter)) == Array(right.prefix(shorter))
  }


  func offerAddress(_ address: [String: String], origin: String, in tab: WebKitTab) {
    let strikeKey = "address|\(origin)"
    guard strikes[strikeKey, default: 0] < Self.maxStrikes else { return }
    load(.address, profile: tab.profile) { [weak self, weak tab] saved in
      guard let self, let tab else { return }
      let existing = saved.map { entry -> (id: String, fields: [String: String]) in
        var fields: [String: String] = [:]
        for key in Self.addressKeys where !Self.text(entry, key).isEmpty { fields[key] = Self.text(entry, key) }
        return (entry["id"] as? String ?? "", fields)
      }
      let mergeable = existing.first { old in
        ["street", "city", "postalCode"].allSatisfy { key in
          switch (old.fields[key], address[key]) {
          case let (a?, b?): return key == "street" ? Self.sameStreet(a, b) : Self.sameValue(key, a, b)
          case (nil, nil): return true
          default: return key == "postalCode"
          }
        } && ["name", "organization", "email", "phone", "state", "country"].allSatisfy { key in
          guard let a = old.fields[key], let b = address[key] else { return true }
          return Self.sameValue(key, a, b) || key == "state" && WebKitAutofill.sameState(a, b)
        }
      }
      if let old = mergeable {
        var merged = old.fields
        for key in Self.addressKeys where merged[key] == nil || key == "street" && (address[key]?.count ?? 0) > (merged[key]?.count ?? 0) {
          if let value = address[key] { merged[key] = value }
        }
        let groups: [(field: String, keys: [String])] = [
          ("name", ["name"]), ("address", ["organization", "street", "city", "state", "postalCode", "country"]), ("email", ["email"]), ("phone", ["phone"]),
        ]
        let changed = groups.filter { group in group.keys.contains { merged[$0] != old.fields[$0] } }
        guard !changed.isEmpty else { return }
        let show = { (fields: [String: String], group: (field: String, keys: [String])) -> String in
          switch group.field {
          case "address": return Self.addressBlock(fields)
          case "phone": return fields["phone"].map(Self.displayPhone) ?? ""
          default: return fields[group.keys[0]] ?? ""
          }
        }
        let changes = changed.map { ["field": $0.field, "to": show(merged, $0), "from": show(old.fields, $0)] }
        let addsOnly = changes.allSatisfy { ($0["from"] ?? "").isEmpty }
        let hasAddress = changed.contains { $0.field == "address" }
        let description = ([old.fields["name"]] + (hasAddress ? [] : [(old.fields["street"] ?? "").split(separator: "\n").first.map(String.init)]))
          .compactMap { $0 }.joined(separator: ", ")
        let payload: [String: Any] = [
          "kind": "updateAddress", "title": "Update address?", "message": description, "accept": "Update", "decline": "No thanks",
          "footer": "", "lines": [], "changes": changes, "newLabel": addsOnly ? "" : "New", "oldLabel": addsOnly ? "" : "Old",
        ]
        var fields: [String: Any] = merged
        fields["id"] = old.id
        self.enqueue(kind: "addressUpdate", payload: payload, origin: origin, strikeKey: strikeKey, in: tab) { profile, done in
          ArdiaServices.saveAddress(fields, profile: profile) { _, error in DispatchQueue.main.async { done(error == nil) } }
        }
        return
      }
      let payload: [String: Any] = [
        "kind": "saveAddress", "title": "Save address?", "message": "", "accept": "Save", "decline": "No thanks", "footer": "",
        "lines": Self.summary(address),
      ]
      self.enqueue(kind: "address", payload: payload, origin: origin, strikeKey: strikeKey, in: tab) { profile, done in
        ArdiaServices.saveAddress(address, profile: profile) { _, error in DispatchQueue.main.async { done(error == nil) } }
      }
    }
  }

  static func sameState(_ a: String, _ b: String) -> Bool {
    let short = [a, b].first { $0.count == 2 }
    let long = [a, b].first { $0.count > 2 }
    guard let short, let long else { return false }
    return long.lowercased().split(separator: " ").map { $0.prefix(1) }.joined() == short.lowercased() || long.lowercased().hasPrefix(short.lowercased())
  }

  func enqueue(kind: String, payload: [String: Any], origin: String, strikeKey: String, in tab: WebKitTab,
                       save: @escaping (String, @escaping (Bool) -> Void) -> Void) {
    Self.lastPromptId += 1
    var full = payload
    full["id"] = Self.lastPromptId
    full["origin"] = origin
    let offer = Offer(id: Self.lastPromptId, kind: kind, payload: full, strikeKey: strikeKey, save: save)
    let list = offers.object(forKey: tab) ?? Offers()
    offers.setObject(list, forKey: tab)
    list.queue.removeAll { $0.kind == kind }
    if list.shown?.kind == kind {
      tab.emit("autofillPrompt", ["id": list.shown?.id ?? 0, "closed": true])
      list.shown = nil
    }
    list.queue.append(offer)
    showNext(in: tab)
  }

  func showNext(in tab: WebKitTab) {
    guard let list = offers.object(forKey: tab), list.shown == nil, !list.queue.isEmpty else { return }
    let offer = list.queue.removeFirst()
    list.shown = offer
    Self.count(offer.kind == "card" ? "autofillCardSaveOffer" : "autofillAddressSaveOffer")
    tab.emit("autofillPrompt", offer.payload)
  }

  func resolve(_ tab: WebKitTab, promptId: Int, action: String) {
    guard let list = offers.object(forKey: tab), let offer = list.shown, offer.id == promptId else { return }
    list.shown = nil
    switch action {
    case "accept":
      strikes.removeValue(forKey: offer.strikeKey)
      offer.save(tab.profile) { saved in
        if saved { Self.count(offer.kind == "card" ? "autofillCardSave" : "autofillAddressSave") }
      }
    case "decline": strikes[offer.strikeKey, default: 0] += 1
    default: break
    }
    tab.emit("autofillPrompt", ["id": promptId, "closed": true])
    showNext(in: tab)
  }
}
