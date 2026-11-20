import AppKit
import WebKit

extension WebKitTab {
  private var inspector: NSObject? {
    guard let view = webView, view.responds(to: NSSelectorFromString("_inspector")) else { return nil }
    return view.value(forKey: "_inspector") as? NSObject
  }

  private static func flag(_ name: String, of object: NSObject) -> Bool {
    guard object.responds(to: NSSelectorFromString(name)) else { return false }
    return (object.value(forKey: name) as? Bool) ?? false
  }

  private static func send(_ name: String, to object: NSObject) {
    let selector = NSSelectorFromString(name)
    if object.responds(to: selector) { object.perform(selector) }
  }

  func showWebKitDevTools(panel: String?) {
    guard let view = webView else { return }
    WebKitSiteRules.setPreference(view.configuration.preferences, "developerExtrasEnabled", setter: "_setDeveloperExtrasEnabled:", true)
    guard let inspector else { return NSLog("[webkit] Web Inspector isn't available") }
    let visible = Self.flag("isVisible", of: inspector)
    switch panel {
    case "toggle" where visible:
      Self.send("close", to: inspector)
      return
    case "console":
      Self.send("showConsole", to: inspector)
    case "inspect":
      Self.send("show", to: inspector)
      let select = { [weak inspector] in
        guard let inspector, !Self.flag("isElementSelectionActive", of: inspector) else { return }
        Self.send("toggleElementSelection", to: inspector)
      }
      if visible { select() } else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: select) }
    default:
      Self.send("show", to: inspector)
    }
    ArdiaEvents.emit("webKit.counted", data: ArdiaConsentStamp.begin().onto(["name": "devTools"]))
  }

  func viewSource() {
    guard let view = webView, let url = view.url, ["http", "https", "file"].contains(url.scheme?.lowercased() ?? ""),
      view.responds(to: NSSelectorFromString("_getMainResourceDataWithCompletionHandler:"))
    else { return }
    let profile = profile
    let fetch = unsafeBitCast(view.method(for: NSSelectorFromString("_getMainResourceDataWithCompletionHandler:")),
                              to: (@convention(c) (AnyObject, Selector, @escaping @convention(block) (NSData?, NSError?) -> Void) -> Void).self)
    view.evaluateJavaScript("document.characterSet", in: nil, in: WebKitHub.world) { [weak self, weak view] charset in
      guard let view else { return }
      let encoding = ((try? charset.get()) as? String).flatMap(Self.encoding(named:)) ?? .utf8
      fetch(view, NSSelectorFromString("_getMainResourceDataWithCompletionHandler:")) { data, _ in
        DispatchQueue.main.async {
          guard let self, !self.closed, let data else { return }
          let text = String(data: data as Data, encoding: encoding) ?? String(decoding: data as Data, as: UTF8.self)
          self.openSource(text, of: url, profile: profile)
        }
      }
    }
  }

  private static func encoding(named name: String) -> String.Encoding? {
    let cf = CFStringConvertIANACharSetNameToEncoding(name as CFString)
    guard cf != kCFStringEncodingInvalidId else { return nil }
    return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
  }

  private func openSource(_ text: String, of url: URL, profile: String) {
    let configuration = WebKitHub.shared.configuration(profile: profile)
    configuration.defaultWebpagePreferences.allowsContentJavaScript = false
    let child = WebKitWebView(frame: .zero, configuration: configuration)
    child.navigationDelegate = WebKitPopupPolicy.shared
    child.loadHTMLString(Self.sourcePage(text, url: url), baseURL: nil)
    let id = WebKitHub.shared.transfers.offer(child)
    ArdiaEvents.emit("webKit.counted", data: ArdiaConsentStamp.begin().onto(["name": "viewSource"]))
    emit("openWindow", ["url": "", "disposition": "foreground", "adoptId": id, "userGesture": true])
  }

  static func escapeHTML(_ text: String) -> String {
    var out = ""
    out.reserveCapacity(text.utf8.count)
    for character in text {
      switch character {
      case "&": out += "&amp;"
      case "<": out += "&lt;"
      case ">": out += "&gt;"
      case "\"": out += "&quot;"
      default: out.append(character)
      }
    }
    return out
  }

  static func sourcePage(_ text: String, url: URL) -> String {
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
    let rows = lines.enumerated().map { index, line in
      "<tr><td class=n>\(index + 1)</td><td class=l>\(escapeHTML(String(line.hasSuffix("\r") ? line.dropLast() : line)))</td></tr>"
    }.joined(separator: "\n")
    let title = escapeHTML("view-source:" + url.absoluteString.replacingOccurrences(of: "^[a-z]+://", with: "", options: .regularExpression))
    return """
      <!doctype html><html><head><meta charset="utf-8"><meta name="color-scheme" content="light dark"><title>\(title)</title><style>
      body { margin: 0; font: 13px/1.4 ui-monospace, Menlo, monospace; }
      #w { margin: 8px 4px 8px 16px; }
      label { font: 12px -apple-system, sans-serif; }
      table { border-collapse: collapse; }
      td.n { color: GrayText; text-align: right; padding: 0 8px 0 16px; vertical-align: top; user-select: none; -webkit-user-select: none; }
      td.l { white-space: pre; padding-right: 16px; }
      #w:checked ~ table td.l { white-space: pre-wrap; word-break: break-all; }
      </style></head><body><input type=checkbox id=w><label for=w>Line wrap</label>
      <table>
      \(rows)
      </table></body></html>
      """
  }
}
