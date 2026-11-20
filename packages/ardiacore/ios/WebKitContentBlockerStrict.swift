import Foundation

struct WebKitHostList: Sendable {
  private let bytes: [UInt8]
  private let starts: [Int32]

  init(_ data: Data) {
    let bytes = [UInt8](data)
    var starts: [Int32] = bytes.isEmpty ? [] : [0]
    for (index, byte) in bytes.enumerated() where byte == 0x0A { starts.append(Int32(index + 1)) }
    self.bytes = bytes
    self.starts = starts
  }

  var count: Int { starts.count }

  func contains(_ host: Substring.UTF8View) -> Bool {
    var low = 0, high = starts.count
    while low < high {
      let mid = (low + high) / 2
      let order = compare(entry: mid, with: host)
      if order == 0 { return true }
      if order < 0 { low = mid + 1 } else { high = mid }
    }
    return false
  }

  private func compare(entry: Int, with host: Substring.UTF8View) -> Int {
    var at = Int(starts[entry])
    let end = entry + 1 < starts.count ? Int(starts[entry + 1]) - 1 : bytes.count
    var key = host.startIndex
    while at < end, key != host.endIndex {
      let a = bytes[at], b = host[key]
      if a != b { return a < b ? -1 : 1 }
      at += 1
      key = host.index(after: key)
    }
    if at == end { return key == host.endIndex ? 0 : -1 }
    return 1
  }
}

struct WebKitStrictRule: @unchecked Sendable {
  let block: Bool
  let priority: Int
  let pattern: NSRegularExpression?
  let hosts: Set<String>
  let excludedHosts: Set<String>
  let initiators: Set<String>
  let excludedInitiators: Set<String>

  init?(_ entry: [String: Any]) {
    block = (entry["k"] as? String) == "block"
    priority = entry["p"] as? Int ?? 1
    let names = { (key: String) in Set((entry[key] as? [String]) ?? []) }
    hosts = names("d")
    excludedHosts = names("xd")
    initiators = names("i")
    excludedInitiators = names("xi")
    if let source = entry["re"] as? String {
      guard let compiled = try? NSRegularExpression(pattern: source, options: (entry["cs"] as? Bool) == true ? [] : [.caseInsensitive]) else { return nil }
      pattern = compiled
    } else {
      pattern = nil
    }
  }

  func matches(url: String, host: String, initiator: String?) -> Bool {
    if !hosts.isEmpty, !WebKitStrictBlock.covered(host, by: hosts) { return false }
    if !excludedHosts.isEmpty, WebKitStrictBlock.covered(host, by: excludedHosts) { return false }
    if !initiators.isEmpty, !(initiator.map { WebKitStrictBlock.covered($0, by: initiators) } ?? false) { return false }
    if !excludedInitiators.isEmpty, let initiator, WebKitStrictBlock.covered(initiator, by: excludedInitiators) { return false }
    if let pattern {
      let range = NSRange(url.startIndex..., in: url)
      if pattern.firstMatch(in: url, options: [], range: range) == nil { return false }
    }
    return true
  }
}

struct WebKitStrictBlock: Sendable {
  static let empty = WebKitStrictBlock(hostLists: [], rules: [])

  let hostLists: [WebKitHostList]
  let rules: [WebKitStrictRule]

  var hostCount: Int { hostLists.reduce(0) { $0 + $1.count } }

  static func load(_ rulesets: [String], from directory: URL) -> WebKitStrictBlock {
    var lists: [WebKitHostList] = []
    var rules: [WebKitStrictRule] = []
    for id in rulesets {
      if let hosts = WebKitContentBlocker.inflate(directory.appendingPathComponent("\(id).hosts")), !hosts.isEmpty {
        lists.append(WebKitHostList(hosts))
      }
      if let raw = WebKitContentBlocker.inflate(directory.appendingPathComponent("\(id).strict")),
        let entries = try? JSONSerialization.jsonObject(with: raw) as? [[String: Any]]
      {
        rules.append(contentsOf: entries.compactMap(WebKitStrictRule.init))
      }
    }
    return WebKitStrictBlock(hostLists: lists, rules: rules.sorted { $0.priority > $1.priority })
  }

  static func covered(_ host: String, by names: Set<String>) -> Bool {
    var rest = Substring(host)
    while true {
      if names.contains(String(rest)) { return true }
      guard let dot = rest.firstIndex(of: ".") else { return false }
      rest = rest[rest.index(after: dot)...]
    }
  }

  func blocks(_ url: URL, initiator: String?) -> Bool {
    guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
      let host = url.host?.lowercased(), !host.isEmpty
    else { return false }
    let text = url.absoluteString
    var blockPriority: Int?
    var allowPriority: Int?
    for rule in rules {
      if rule.block ? blockPriority != nil : allowPriority != nil { continue }
      guard rule.matches(url: text, host: host, initiator: initiator) else { continue }
      if rule.block { blockPriority = rule.priority } else { allowPriority = rule.priority }
      if blockPriority != nil && allowPriority != nil { break }
    }
    if let blockPriority { return allowPriority.map { $0 < blockPriority } ?? true }
    if allowPriority != nil { return false }
    var rest = Substring(host)
    while true {
      if hostLists.contains(where: { $0.contains(rest.utf8) }) { return true }
      guard let dot = rest.firstIndex(of: ".") else { return false }
      rest = rest[rest.index(after: dot)...]
    }
  }
}
