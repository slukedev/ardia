import Foundation
import WebKit

struct WebKitCosmeticIndex: @unchecked Sendable {
  struct HostPattern {
    let needle: String
    let pattern: NSRegularExpression
    let selectors: [String]
  }

  struct Part {
    var hide: [String: [String]] = [:]
    var unhide: [String: [String]] = [:]
    var patterns: [HostPattern] = []
  }

  static let empty = WebKitCosmeticIndex(parts: [])

  let parts: [Part]

  var selectorCount: Int { parts.reduce(0) { $0 + $1.hide.values.reduce(0) { $0 + $1.count } + $1.patterns.reduce(0) { $0 + $1.selectors.count } } }

  static func load(_ rulesets: [String], from directory: URL) -> WebKitCosmeticIndex {
    var parts: [Part] = []
    for id in rulesets {
      guard let raw = WebKitContentBlocker.inflate(directory.appendingPathComponent("\(id).cosmetic")),
        let object = try? JSONSerialization.jsonObject(with: raw) as? [String: Any]
      else { continue }
      var part = Part()
      part.hide = object["hide"] as? [String: [String]] ?? [:]
      part.unhide = object["unhide"] as? [String: [String]] ?? [:]
      for entry in object["regexes"] as? [[Any]] ?? [] {
        guard entry.count == 3, let needle = entry[0] as? String, let source = entry[1] as? String, let selectors = entry[2] as? [String],
          let pattern = try? NSRegularExpression(pattern: source)
        else { continue }
        part.patterns.append(HostPattern(needle: needle, pattern: pattern, selectors: selectors))
      }
      parts.append(part)
    }
    return WebKitCosmeticIndex(parts: parts)
  }

  static func part(of user: WebKitUserFilters) -> Part {
    Part(hide: user.hide, unhide: user.unhide, patterns: [])
  }

  func lookup(hostnames: [String], entities: [String], user: Part) -> (css: [String], procedural: [String]) {
    var chosen = Set<String>(), excepted = Set<String>()
    let hostname = hostnames.first ?? ""
    for part in parts + [user] {
      for needle in hostnames + entities {
        if let hide = part.hide[needle] { chosen.formUnion(hide) }
        if let unhide = part.unhide[needle] { excepted.formUnion(unhide) }
      }
      for pattern in part.patterns where hostname.contains(pattern.needle) {
        let range = NSRange(hostname.startIndex..., in: hostname)
        if pattern.pattern.firstMatch(in: hostname, range: range) != nil { chosen.formUnion(pattern.selectors) }
      }
    }
    chosen.subtract(excepted)
    var css: [String] = [], procedural: [String] = []
    for selector in chosen.sorted() {
      if selector.hasPrefix("{") { procedural.append(selector) } else { css.append(selector) }
    }
    return (css, procedural)
  }
}

struct WebKitScriptletSources: Sendable {
  let main: String
  let isolated: String
  let secret: String
  let procedural: String

  static func load(_ rulesets: [String], worlds: [String: [String]], secret: String, from directory: URL) -> WebKitScriptletSources? {
    guard !secret.isEmpty else { return nil }
    func file(_ path: String) -> String? {
      WebKitContentBlocker.inflate(directory.appendingPathComponent(path)).map { String(decoding: $0, as: UTF8.self) }
    }
    func bundle(_ world: String) -> String {
      let files = rulesets.filter { worlds[$0]?.contains(world) == true }.compactMap { file("scriptlets/\(world)/\($0).js") }
      guard !files.isEmpty, let begin = file("scriptlets/\(world)/scriptlet-begin.js"), let end = file("scriptlets/\(world)/scriptlet-end.js") else { return "" }
      return ([begin, WebKitContentBlockerScripts.gatePlaceholder] + files + [end]).joined(separator: "\n")
    }
    return WebKitScriptletSources(main: bundle("main"), isolated: bundle("isolated"), secret: secret,
                                  procedural: file("scripting/css-procedural-api.js") ?? "")
  }
}

final class WebKitContentBlockerScripts: NSObject, WKScriptMessageHandlerWithReply {
  static let world = WKContentWorld.world(name: "ArdiaContentBlocker")
  static let handlerName = "ardiaContentBlocker"
  static let gatePlaceholder = "/*ardia-content-blocker-gate*/"

  private(set) var index = WebKitCosmeticIndex.empty
  private var user = WebKitCosmeticIndex.Part()
  private var scripts: [WKUserScript] = []
  private var key = ""
  private let mine = NSHashTable<WKUserScript>.weakObjects()
  private let controllers = NSHashTable<WKUserContentController>.weakObjects()
  private let installed = NSMapTable<WKUserContentController, NSString>.weakToStrongObjects()
  private(set) var lookups = 0
  private(set) var applied = 0
  private(set) var scriptletBytes = 0

  func attach(_ controller: WKUserContentController) {
    controllers.add(controller)
    controller.addScriptMessageHandler(self, contentWorld: Self.world, name: Self.handlerName)
    apply(controller)
  }

  func update(sources: WebKitScriptletSources?, index: WebKitCosmeticIndex, user: WebKitUserFilters, trusted: [String], key: String) {
    self.index = index
    self.user = WebKitCosmeticIndex.part(of: user)
    guard key != self.key else { return }
    self.key = key
    scripts = sources.map { Self.make($0, trusted: trusted, cosmetic: index.selectorCount > 0 || !user.hide.isEmpty) } ?? []
    scriptletBytes = scripts.reduce(0) { $0 + $1.source.utf8.count }
    scripts.forEach(mine.add)
    for controller in controllers.allObjects { apply(controller) }
  }

  private func apply(_ controller: WKUserContentController) {
    if (installed.object(forKey: controller) as String?) == key { return }
    let others = controller.userScripts.filter { !mine.contains($0) }
    controller.removeAllUserScripts()
    others.forEach(controller.addUserScript)
    scripts.forEach(controller.addUserScript)
    installed.setObject(key as NSString, forKey: controller)
  }

  private static func jsonString(_ value: Any) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]) else { return "null" }
    return String(decoding: data, as: UTF8.self)
  }

  private static func trustedCheck(_ trusted: [String]) -> String {
    """
    ((t) => { let h = ''; try { const a = location.ancestorOrigins; h = new URL(a && a.length ? a[a.length - 1] : location.href).hostname; } catch (e) { h = location.hostname; } return !!h && t.some((d) => h === d || h.endsWith('.' + d)); })(\(jsonString(trusted)))
    """
  }

  private static func make(_ sources: WebKitScriptletSources, trusted: [String], cosmetic: Bool) -> [WKUserScript] {
    let gate = "(function (id) { const g = self[id]; if (g && \(trustedCheck(trusted))) g.origins = []; })(\(jsonString(sources.secret)));"
    var out: [WKUserScript] = []
    if !sources.main.isEmpty {
      out.append(WKUserScript(source: sources.main.replacingOccurrences(of: gatePlaceholder, with: gate), injectionTime: .atDocumentStart,
                              forMainFrameOnly: false, in: .page))
    }
    var isolated = sources.isolated.replacingOccurrences(of: gatePlaceholder, with: gate)
    if cosmetic, !sources.procedural.isEmpty { isolated += "\n" + sources.procedural + "\n" + cosmeticScript(trusted) }
    if !isolated.isEmpty {
      out.append(WKUserScript(source: isolated, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: world))
    }
    return out
  }

  private static func cosmeticScript(_ trusted: [String]) -> String {
    """
    (() => {
      const handler = self.webkit && self.webkit.messageHandlers && self.webkit.messageHandlers[\(jsonString(handlerName))];
      const hn = document.location.hostname;
      if (!handler || !hn || \(trustedCheck(trusted))) return;
      const hostnames = [hn];
      for (let pos = 0; ; ) { pos = hn.indexOf('.', pos) + 1; if (pos === 0) break; hostnames.push(hn.slice(pos)); }
      hostnames.push('*');
      const entities = [];
      for (let h of hostnames) { for (;;) { const p = h.lastIndexOf('.'); if (p === -1) break; h = h.slice(0, p); entities.push(h + '.*'); } }
      const insert = (css) => {
        const sheet = document.createElement('style');
        sheet.textContent = css;
        (document.head || document.documentElement).append(sheet);
      };
      self.cssAPI = { insert };
      handler.postMessage({ hostnames, entities }).then((reply) => {
        if (!reply) return;
        if (reply.css && reply.css.length) insert(reply.css.map((s) => s + '\\n{display:none!important;}').join('\\n'));
        const all = (reply.procedural || []).map((s) => { try { return JSON.parse(s); } catch (e) { return null; } }).filter(Boolean);
        if (!all.length || typeof self.ProceduralFiltererAPI !== 'function') return;
        const api = new self.ProceduralFiltererAPI();
        const declarative = (a) => a.cssable || (!a.tasks && a.action && a.action[0] === 'style');
        const declaratives = all.filter(declarative);
        if (declaratives.length) api.addDeclaratives(declaratives);
        const procedurals = all.filter((a) => !declarative(a));
        if (procedurals.length) api.addProcedurals(procedurals);
      }, () => {});
    })();
    """
  }

  func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage,
                             replyHandler: @escaping (Any?, String?) -> Void) {
    guard let body = message.body as? [String: Any], let hostnames = body["hostnames"] as? [String], hostnames.count <= 64,
      let entities = body["entities"] as? [String], entities.count <= 256
    else { return replyHandler(nil, nil) }
    lookups += 1
    let found = index.lookup(hostnames: hostnames.map { $0.lowercased() }, entities: entities.map { $0.lowercased() }, user: user)
    guard !found.css.isEmpty || !found.procedural.isEmpty else { return replyHandler(nil, nil) }
    applied += 1
    if message.frameInfo.isMainFrame { ArdiaEvents.emit("webKit.counted", data: ArdiaConsentStamp.begin().onto(["name": "blockerCosmeticApplied"])) }
    replyHandler(["css": found.css, "procedural": found.procedural], nil)
  }
}
