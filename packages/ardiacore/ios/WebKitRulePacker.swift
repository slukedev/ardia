import Foundation

enum WebKitRulePacker {
  static let ruleBudget = 140_000
  static let ignoreTopDocuments =
    #"{"action":{"type":"ignore-previous-rules"},"trigger":{"load-context":["top-frame"],"resource-type":["document"],"url-filter":".*"}}"#

  private struct Rule {
    let priority: Int
    let exception: Bool
    let json: Substring
    let order: Int
    var weight = 1
  }

  private static func ruleCount(inGroup json: Substring) -> Int {
    max(1, json.ranges(of: #"{"action":"#).count)
  }

  static func lists(texts: [String], user: [WebKitUserFilters.NetworkRule]) -> [String] {
    var groups: [Int: [Rule]] = [:], blocks: [Rule] = [], allows: [Rule] = [], cosmetic: [Substring] = []
    var order = 0
    for text in texts {
      for line in text.split(separator: "\n") {
        guard let tag = line.first, let tab = line.firstIndex(of: "\t") else { continue }
        let header = line[line.index(after: line.startIndex)..<tab].split(separator: ".").map { Int($0) }
        let priority = header.first.flatMap { $0 } ?? 1
        let json = line[line.index(after: tab)...]
        order += 1
        switch tag {
        case "p":
          guard header.count == 3, let set = header[1], let rank = header[2] else { continue }
          groups[set, default: []].append(Rule(priority: priority, exception: false, json: json, order: rank, weight: ruleCount(inGroup: json)))
        case "b": blocks.append(Rule(priority: priority, exception: false, json: json, order: order))
        case "a": allows.append(Rule(priority: priority, exception: true, json: json, order: order))
        case "c": cosmetic.append(json)
        default: break
        }
      }
    }
    for rule in user {
      order += 1
      let made = Rule(priority: rule.priority, exception: rule.exception, json: Substring(rule.json), order: order)
      if rule.exception { allows.append(made) } else { blocks.append(made) }
    }
    let ordered: (Rule, Rule) -> Bool = { a, b in
      if a.priority != b.priority { return a.priority < b.priority }
      if a.exception != b.exception { return !a.exception }
      return a.order < b.order
    }
    var out: [String] = []
    let budget = max(1000, ruleBudget - allows.reduce(0) { $0 + $1.weight } - 1)
    func pack(_ rules: [Rule]) {
      var chunk: [Rule] = []
      var weight = 0
      func flush() {
        var parts = (chunk + allows).sorted(by: ordered).map(\.json)
        parts.append(Substring(ignoreTopDocuments))
        out.append("[" + parts.joined(separator: ",") + "]")
        chunk = []
        weight = 0
      }
      for rule in rules.sorted(by: ordered) {
        if !chunk.isEmpty && weight + rule.weight > budget { flush() }
        chunk.append(rule)
        weight += rule.weight
      }
      if !chunk.isEmpty { flush() }
    }
    for set in groups.keys.sorted() { pack(groups[set] ?? []) }
    pack(blocks)
    var start = 0
    while start < cosmetic.count {
      let end = min(cosmetic.count, start + ruleBudget)
      out.append("[" + cosmetic[start..<end].joined(separator: ",") + "]")
      start = end
    }
    return out
  }

  static func list(of rules: ArraySlice<WebKitUserFilters.NetworkRule>) -> String {
    "[" + rules.map(\.json).joined(separator: ",") + "]"
  }
}

struct WebKitRuleBisect {
  private(set) var pending: [Range<Int>]
  private(set) var bad: [Int] = []
  private(set) var attempts = 0
  let limit: Int

  init(count: Int) {
    pending = count > 0 ? [0..<count] : []
    limit = 8 * (Int.bitWidth - count.leadingZeroBitCount) + 1
  }

  var next: Range<Int>? { attempts < limit ? pending.last : nil }

  var finished: Bool { next == nil }

  var rejected: [Int] { (bad + pending.flatMap { Array($0) }).sorted() }

  mutating func record(_ range: Range<Int>, compiled: Bool) {
    guard let index = pending.lastIndex(of: range) else { return }
    attempts += 1
    pending.remove(at: index)
    guard !compiled else { return }
    if range.count == 1 { return bad.append(range.lowerBound) }
    let middle = range.lowerBound + range.count / 2
    pending.append(middle..<range.upperBound)
    pending.append(range.lowerBound..<middle)
  }
}
