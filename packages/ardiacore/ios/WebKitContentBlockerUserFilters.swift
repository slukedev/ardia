import CryptoKit
import Foundation

struct WebKitUserFilters: Codable, Equatable {
  struct NetworkRule: Codable, Equatable {
    let priority: Int
    let exception: Bool
    let json: String
  }

  var digest = ""
  var network: [NetworkRule] = []
  var hide: [String: [String]] = [:]
  var unhide: [String: [String]] = [:]
  var strictHosts: [String] = []
  var strictAllowHosts: [String] = []
  var accepted = 0
  var rejected = 0

  static let none = WebKitUserFilters()

  private static let separator = "[^a-zA-Z0-9_.%-]"
  private static let hostAnchor = "^[^:]+://+([^:/]+\\.)?"
  private static let regexSpecials = Set(".*+?()[]\\$^|{}")
  private static let simpleTypes: [String: String] = [
    "script": "script", "image": "image", "stylesheet": "style-sheet", "css": "style-sheet", "font": "font", "media": "media",
    "xmlhttprequest": "raw", "xhr": "raw", "websocket": "raw", "object": "raw", "other": "raw", "ping": "ping", "beacon": "ping",
  ]
  private static let frameTypes: Set<String> = ["subdocument", "frame"]
  private static let documentTypes: Set<String> = ["document", "doc"]
  private static let procedural = [
    ":has-text(", ":upward(", ":remove(", ":style(", ":matches-css(", ":matches-css-before(", ":matches-css-after(", ":min-text-length(",
    ":xpath(", ":remove-attr(", ":remove-class(", ":watch-attr(", ":matches-path(", ":matches-attr(", ":matches-prop(", ":matches-media(",
    ":others(", ":shadow(", ":spath(", ":if(", ":if-not(", ":-abp-",
  ]
  private static let operators: [String: String] = [
    "has-text": "has-text", "upward": "upward", "min-text-length": "min-text-length", "xpath": "xpath", "matches-path": "matches-path",
    "matches-media": "matches-media", "others": "others", "shadow": "shadow", "spath": "spath", "if": "if", "if-not": "if-not",
    "-abp-has": "if", "-abp-contains": "has-text",
  ]
  private static let actions: Set<String> = ["remove", "style", "remove-attr", "remove-class"]
  private static let maxProceduralDepth = 8
  private static let parserVersion = "3"

  static func parse(_ text: String) -> WebKitUserFilters {
    var out = WebKitUserFilters()
    out.digest = digest(of: text)
    var hide: [String: Set<String>] = [:], unhide: [String: Set<String>] = [:]
    var strict = Set<String>(), strictAllow = Set<String>()
    for raw in text.split(whereSeparator: \.isNewline) {
      let line = raw.trimmingCharacters(in: .whitespaces)
      if line.isEmpty || line.hasPrefix("!") || line.hasPrefix("[") || line.hasPrefix("# ") || line == "#" { continue }
      if let cosmetic = cosmeticParts(line) {
        guard cosmetic.ok else {
          out.rejected += 1
          continue
        }
        out.accepted += 1
        if cosmetic.exception {
          for host in cosmetic.hosts.isEmpty ? ["*"] : cosmetic.hosts { unhide[host, default: []].insert(cosmetic.body) }
          continue
        }
        if isProcedural(cosmetic.body) {
          guard let json = proceduralJSON(cosmetic.body) else {
            out.accepted -= 1
            out.rejected += 1
            continue
          }
          for host in cosmetic.hosts.isEmpty ? ["*"] : cosmetic.hosts { hide[host, default: []].insert(json) }
          continue
        }
        guard !cosmetic.body.contains(where: { $0 == "{" || $0 == "}" }) else {
          out.accepted -= 1
          out.rejected += 1
          continue
        }
        for host in cosmetic.hosts.isEmpty ? ["*"] : cosmetic.hosts { hide[host, default: []].insert(cosmetic.body) }
        continue
      }
      guard let rules = network(line, strict: &strict, strictAllow: &strictAllow) else {
        out.rejected += 1
        continue
      }
      out.accepted += 1
      out.network.append(contentsOf: rules)
    }
    out.hide = hide.mapValues { $0.sorted() }
    out.unhide = unhide.mapValues { $0.sorted() }
    out.strictHosts = strict.sorted()
    out.strictAllowHosts = strictAllow.sorted()
    return out
  }

  private struct Cosmetic {
    let hosts: [String]
    let exception: Bool
    let body: String
    let ok: Bool
  }

  private static func cosmeticParts(_ line: String) -> Cosmetic? {
    guard line.contains("#"), let match = line.firstMatch(of: /^([^#\/\$|@]*?)#(@?)([?$%]?)#(.+)$/) else { return nil }
    let kind = String(match.3)
    let body = String(match.4).trimmingCharacters(in: .whitespaces)
    var hosts: [String] = []
    var ok = kind.isEmpty || kind == "?"
    for part in match.1.split(separator: ",") {
      let host = part.trimmingCharacters(in: .whitespaces).lowercased()
      if host.isEmpty { continue }
      let named = host.hasSuffix(".*") ? host.dropLast(2) : Substring(host)
      if named.isEmpty || !named.allSatisfy({ $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "." || $0 == "-") }) { ok = false }
      hosts.append(host)
    }
    if body.hasPrefix("+js(") || body.hasPrefix("^") || body.hasPrefix("+") || !body.allSatisfy(\.isASCII) { ok = false }
    return Cosmetic(hosts: hosts, exception: !match.2.isEmpty, body: body, ok: ok && !body.isEmpty)
  }

  static func digest(of text: String) -> String {
    SHA256.hash(data: Data((parserVersion + "\n" + text).utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
  }

  static func isProcedural(_ body: String) -> Bool { procedural.contains(where: body.contains) }

  static func proceduralJSON(_ body: String) -> String? {
    guard let parsed = proceduralTasks(Substring(body)), !isProcedural(parsed.selector) else { return nil }
    var object: [String: Any] = ["selector": parsed.selector]
    if !parsed.tasks.isEmpty { object["tasks"] = parsed.tasks }
    if let action = parsed.action { object["action"] = action }
    return encode(object)
  }

  private static func proceduralTasks(_ body: Substring, depth: Int = 0) -> (selector: String, tasks: [[Any]], action: [String]?)? {
    guard depth < maxProceduralDepth else { return nil }
    var tasks: [[Any]] = []
    var action: [String]?
    var rest = body
    var prefix = ""
    while !rest.isEmpty {
      guard let found = nextOperator(in: rest) else {
        if !tasks.isEmpty || action != nil { tasks.append(["spath", String(rest)]) } else { prefix += rest }
        break
      }
      let before = rest[rest.startIndex..<found.start]
      if tasks.isEmpty && action == nil { prefix += before } else if !before.isEmpty { tasks.append(["spath", String(before)]) }
      guard action == nil else { return nil }
      if actions.contains(found.name) {
        guard found.name != "style" || isSafeStyle(found.argument) else { return nil }
        action = [found.name, String(found.argument)]
      } else if let op = operators[found.name] {
        if op == "if" || op == "if-not" {
          guard let inner = proceduralTasks(found.argument, depth: depth + 1) else { return nil }
          var nested: [String: Any] = ["selector": inner.selector]
          if !inner.tasks.isEmpty { nested["tasks"] = inner.tasks }
          tasks.append([op, nested])
        } else if op == "upward", let depth = Int(found.argument) {
          tasks.append([op, depth])
        } else if op == "min-text-length", let length = Int(found.argument) {
          tasks.append([op, length])
        } else {
          tasks.append([op, String(found.argument)])
        }
      } else {
        return nil
      }
      rest = rest[found.end...]
    }
    let selector = prefix.trimmingCharacters(in: .whitespaces)
    if action?[0] == "style", tasks.isEmpty, !selector.isEmpty {
      return (selector, [], action)
    }
    return (selector.isEmpty ? "*" : selector, tasks, action)
  }

  private static func isSafeStyle(_ declarations: Substring) -> Bool {
    !declarations.contains(where: { $0 == "{" || $0 == "}" || $0 == "\\" }) && declarations.lowercased().firstRange(of: "url(") == nil
  }

  private static func nextOperator(in text: Substring) -> (name: String, argument: Substring, start: Substring.Index, end: Substring.Index)? {
    var index = text.startIndex
    var depth = 0
    var quote: Character?
    while index < text.endIndex {
      let ch = text[index]
      if let open = quote {
        if ch == "\\" { index = text.index(index, offsetBy: 2, limitedBy: text.endIndex) ?? text.endIndex; continue }
        if ch == open { quote = nil }
      } else if ch == "\"" || ch == "'" {
        quote = ch
      } else if ch == "[" || ch == "(" {
        depth += 1
      } else if ch == "]" || ch == ")" {
        depth -= 1
      } else if ch == ":", depth == 0 {
        let after = text[text.index(after: index)...]
        if let name = after.prefix(while: { $0.isLetter || $0 == "-" }).nilIfEmptySubstring,
          operators[String(name)] != nil || actions.contains(String(name)),
          after.dropFirst(name.count).first == "("
        {
          let open = text.index(index, offsetBy: name.count + 2)
          guard let close = matchingParen(text, from: open) else { return nil }
          return (String(name), text[open..<close], index, text.index(after: close))
        }
      }
      index = text.index(after: index)
    }
    return nil
  }

  private static func matchingParen(_ text: Substring, from start: Substring.Index) -> Substring.Index? {
    var depth = 1
    var index = start
    var escaped = false
    while index < text.endIndex {
      let ch = text[index]
      if escaped {
        escaped = false
      } else if ch == "\\" {
        escaped = true
      } else if ch == "(" {
        depth += 1
      } else if ch == ")" {
        depth -= 1
        if depth == 0 { return index }
      }
      index = text.index(after: index)
    }
    return nil
  }

  private static func network(_ line: String, strict: inout Set<String>, strictAllow: inout Set<String>) -> [NetworkRule]? {
    var text = Substring(line)
    if text.first == "0" || text.first == "1", let hosts = text.firstMatch(of: /^(?:0\.0\.0\.0|127\.0\.0\.1)\s+([a-z0-9.-]+)$/) {
      text = Substring("||\(hosts.1)^")
    }
    let exception = text.hasPrefix("@@")
    if exception { text = text.dropFirst(2) }
    var options: [Substring] = []
    if !text.hasPrefix("/") || !text.hasSuffix("/"), let dollar = text.lastIndex(of: "$"), dollar != text.startIndex {
      options = text[text.index(after: dollar)...].split(separator: ",")
      text = text[..<dollar]
    }
    guard !text.hasPrefix("/") || text.count < 2 || !text.hasSuffix("/"), text.allSatisfy(\.isASCII) else { return nil }
    var types: [String] = []
    var frames = false, document = false, important = false, caseSensitive = false
    var loadType: String?
    var ifDomains: [String] = [], unlessDomains: [String] = []
    for option in options {
      let name = option.lowercased()
      switch name {
      case "third-party", "3p": loadType = "third-party"
      case "~third-party", "1p", "first-party", "~3p": loadType = "first-party"
      case "important": important = true
      case "match-case": caseSensitive = true
      case "all": document = true
      default:
        if let mapped = simpleTypes[name] {
          types.append(mapped)
        } else if frameTypes.contains(name) {
          frames = true
        } else if documentTypes.contains(name) {
          document = true
        } else if name.hasPrefix("domain=") || name.hasPrefix("from=") {
          for domain in name.split(separator: "=", maxSplits: 1).last?.split(separator: "|") ?? [] {
            if domain.hasPrefix("~") { unlessDomains.append("*" + domain.dropFirst()) } else { ifDomains.append("*" + domain) }
          }
          if domainsHaveEntities(ifDomains + unlessDomains) { return nil }
        } else {
          return nil
        }
      }
    }
    if !ifDomains.isEmpty && !unlessDomains.isEmpty { return nil }
    let host = pureHost(text)
    if document || (host != nil && options.isEmpty) {
      if let host, ifDomains.isEmpty, unlessDomains.isEmpty {
        if exception { strictAllow.insert(host) } else { strict.insert(host) }
      }
    }
    if document && types.isEmpty && !frames {
      return host != nil && ifDomains.isEmpty && unlessDomains.isEmpty ? [] : nil
    }
    let patterns = urlFilterPatterns(String(text))
    guard !patterns.isEmpty else { return nil }
    var groups: [[String: Any]] = []
    let simple = Array(Set(types)).sorted()
    if !simple.isEmpty || (!frames && types.isEmpty) {
      groups.append(simple.isEmpty ? [:] : ["resource-type": simple])
    }
    if frames { groups.append(["resource-type": ["document"], "load-context": ["child-frame"]]) }
    let priority = exception ? 30 : important ? 40 : 10
    var out: [NetworkRule] = []
    for pattern in patterns {
      for group in groups {
        var trigger: [String: Any] = ["url-filter": pattern]
        trigger.merge(group) { a, _ in a }
        if caseSensitive { trigger["url-filter-is-case-sensitive"] = true }
        if let loadType { trigger["load-type"] = [loadType] }
        if !ifDomains.isEmpty { trigger["if-domain"] = ifDomains }
        if !unlessDomains.isEmpty { trigger["unless-domain"] = unlessDomains }
        let kind = exception ? "ignore-previous-rules" : "block"
        guard let json = encode(["trigger": trigger, "action": ["type": kind]]) else { return nil }
        out.append(NetworkRule(priority: priority, exception: exception, json: json))
      }
    }
    return out
  }

  private static func domainsHaveEntities(_ names: [String]) -> Bool {
    names.contains { $0.hasSuffix(".*") || $0.count < 2 || !$0.dropFirst().allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "." || $0 == "-") } }
  }

  private static func pureHost(_ text: Substring) -> String? {
    guard text.hasPrefix("||"), text.hasSuffix("^") else { return nil }
    let host = text.dropFirst(2).dropLast()
    guard !host.isEmpty, host.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }) else { return nil }
    return host.lowercased()
  }

  static func urlFilterPatterns(_ filter: String) -> [String] {
    var text = Substring(filter)
    var prefix = ""
    var hostAnchored = false
    if text.hasPrefix("||") {
      prefix = hostAnchor
      text = text.dropFirst(2)
      hostAnchored = true
    } else if text.hasPrefix("|") {
      prefix = "^"
      text = text.dropFirst()
    }
    var suffix = ""
    if text.hasSuffix("|") && !text.hasSuffix("\\|") {
      suffix = "$"
      text = text.dropLast()
    }
    let trailingSeparator = text.hasSuffix("^") && suffix.isEmpty
    if trailingSeparator { text = text.dropLast() }
    while text.hasPrefix("*") && prefix.isEmpty { text = text.dropFirst() }
    while text.hasSuffix("*") && suffix.isEmpty && !trailingSeparator { text = text.dropLast() }
    var body = ""
    for ch in text {
      if ch == "*" {
        body += ".*"
      } else if ch == "^" {
        body += separator
      } else if regexSpecials.contains(ch) {
        body += "\\" + String(ch)
      } else {
        body.append(ch)
      }
    }
    let core = prefix + body
    if trailingSeparator {
      let hostOnly = hostAnchored && text.allSatisfy { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }
      return hostOnly ? [core + separator] : [core + separator, core + "$"]
    }
    let pattern = core + suffix
    return [pattern.isEmpty ? ".*" : pattern]
  }

  private static func encode(_ object: [String: Any]) -> String? {
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]) else { return nil }
    return String(data: data, encoding: .utf8)
  }
}

private extension Substring {
  var nilIfEmptySubstring: Substring? { isEmpty ? nil : self }
}
