import Foundation

struct VaultPendingSave: Codable, Equatable, Sendable {
  var item: VaultItem
  var password: String?
  var since: Double
}

struct VaultPendingResult: Equatable, Sendable {
  var items: [VaultItem]
  var pending: [VaultPendingSave]
  var carried: [String: String]
}

enum VaultPendingItems {
  static let lifetime: TimeInterval = 86_400

  static func reconcile(_ listed: [VaultItem], passwords: [String: String], pending: [VaultPendingSave], now: Date) -> VaultPendingResult {
    let base = listed.filter { $0.pending != true }
    var waiting: [VaultPendingSave] = []
    var carried: [String: String] = [:]
    for save in pending where now.timeIntervalSince1970 - save.since < lifetime {
      if let same = base.first(where: { $0.id == save.item.id }) {
        if passwords[same.id] == nil, let password = save.password { carried[same.id] = password }
        continue
      }
      let key = loginKey(save.item)
      let listedSame = base.contains { candidate in
        guard key != nil, loginKey(candidate) == key else { return false }
        guard let password = save.password else { return true }
        return passwords[candidate.id] == password
      }
      if !listedSame { waiting.append(save) }
    }
    let hidden = Set(waiting.compactMap { loginKey($0.item) })
    var items = base.filter { candidate in loginKey(candidate).map { !hidden.contains($0) } ?? true }
    items += waiting.map { save in
      var item = save.item
      item.pending = true
      return item
    }
    return VaultPendingResult(items: items, pending: waiting, carried: carried)
  }

  static func adding(_ save: VaultPendingSave, to pending: [VaultPendingSave]) -> [VaultPendingSave] {
    let key = loginKey(save.item)
    var kept = pending.filter { $0.item.id != save.item.id && (key == nil || loginKey($0.item) != key) }
    kept.append(save)
    return kept
  }

  static func removing(_ id: String, from pending: [VaultPendingSave]) -> [VaultPendingSave] {
    pending.filter { $0.item.id != id }
  }

  static func loginKey(_ item: VaultItem) -> String? {
    let user = item.username.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    for url in item.urls {
      guard var host = VaultOriginMatch.host(of: url)?.lowercased(), !host.isEmpty else { continue }
      while host.hasSuffix(".") { host.removeLast() }
      if host.hasPrefix("www.") { host.removeFirst(4) }
      guard !host.isEmpty else { continue }
      return "\(host)\n\(user)"
    }
    return nil
  }
}
