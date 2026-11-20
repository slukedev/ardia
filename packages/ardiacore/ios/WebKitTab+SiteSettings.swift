import ObjectiveC
import WebKit

enum WebKitSiteRules {
  static let clipboardGuard = WKUserScript(source: """
    (() => {
      const clipboard = navigator.clipboard;
      const proto = clipboard && Object.getPrototypeOf(clipboard);
      if (!proto) return;
      for (const name of ["read", "readText"]) {
        if (typeof proto[name] !== "function") continue;
        Object.defineProperty(proto, name, {
          configurable: true, writable: true,
          value: { [name]() { return Promise.reject(new DOMException("Read permission denied.", "NotAllowedError")); } }[name],
        });
      }
    })();
    """, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page)

  private static var cookieLists: [String: WKContentRuleList] = [:]
  private static var compiling: [String: [(WKContentRuleList?) -> Void]] = [:]
  private static let store: WKContentRuleListStore? = {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ArdiaSiteRules", isDirectory: true)
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return WKContentRuleListStore(url: folder)
  }()
  private static var attachedKey: UInt8 = 0

  static func cookieFilter(_ origin: String) -> String? {
    guard let url = URL(string: origin), let scheme = url.scheme, let host = url.host, !host.isEmpty,
      host.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" })
    else { return nil }
    let port = url.port.map { ":\($0)" } ?? ""
    return "^\(scheme)://\(host.replacingOccurrences(of: ".", with: "\\."))\(port)[/?#]"
  }

  static func cookieList(for origin: String, done: @escaping (WKContentRuleList?) -> Void) {
    if let list = cookieLists[origin] { return done(list) }
    guard let store, let filter = cookieFilter(origin),
      let json = try? JSONSerialization.data(withJSONObject: [["trigger": ["url-filter": filter], "action": ["type": "block-cookies"]]]),
      let encoded = String(data: json, encoding: .utf8)
    else { return done(nil) }
    if compiling[origin] != nil { return compiling[origin]!.append(done) }
    compiling[origin] = [done]
    let identifier = "cookies-" + origin.unicodeScalars.map { String($0.value, radix: 16) }.joined()
    store.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: encoded) { list, error in
      DispatchQueue.main.async {
        if let error { NSLog("[webkit] cookie rule for a blocked site didn't compile: \(error.localizedDescription)") }
        if let list { cookieLists[origin] = list }
        for waiting in compiling.removeValue(forKey: origin) ?? [] { waiting(list) }
      }
    }
  }

  private final class CookieBlocks {
    var byView: [ObjectIdentifier: WKContentRuleList] = [:]
    var attached: [WKContentRuleList] = []
  }

  static func attachCookieBlock(_ list: WKContentRuleList?, for webView: WKWebView) {
    let controller = webView.configuration.userContentController
    let blocks = objc_getAssociatedObject(controller, &attachedKey) as? CookieBlocks ?? CookieBlocks()
    blocks.byView[ObjectIdentifier(webView)] = list
    let live = Set(WebKitHub.shared.transfers.views.filter { $0.configuration.userContentController === controller }.map { ObjectIdentifier($0) })
    blocks.byView = blocks.byView.filter { live.contains($0.key) || $0.key == ObjectIdentifier(webView) }
    var wanted: [WKContentRuleList] = []
    for needed in blocks.byView.values where !wanted.contains(where: { $0 === needed }) { wanted.append(needed) }
    for old in blocks.attached where !wanted.contains(where: { $0 === old }) { controller.remove(old) }
    for new in wanted where !blocks.attached.contains(where: { $0 === new }) { controller.add(new) }
    blocks.attached = wanted
    objc_setAssociatedObject(controller, &attachedKey, blocks, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
  }

  static func setClipboardGuard(_ on: Bool, in controller: WKUserContentController) {
    let installed = controller.userScripts.contains { $0 === clipboardGuard }
    guard installed != on else { return }
    if on { return controller.addUserScript(clipboardGuard) }
    let kept = controller.userScripts.filter { $0 !== clipboardGuard }
    controller.removeAllUserScripts()
    kept.forEach(controller.addUserScript)
  }

  static func setPreference(_ preferences: WKPreferences, _ key: String, setter: String, _ value: Bool) {
    guard preferences.responds(to: NSSelectorFromString(setter)) else { return }
    preferences.setValue(value, forKey: key)
  }

  static func setAutoplay(_ autoplay: WebKitSitePolicy.Autoplay?, _ preferences: WKWebpagePreferences) {
    guard let autoplay, preferences.responds(to: NSSelectorFromString("_setAutoplayPolicy:")) else { return }
    preferences.setValue(autoplay.rawValue, forKey: "autoplayPolicy")
  }
}

extension WebKitTab {
  func applySiteSettings(_ action: WKNavigationAction, preferences: WKWebpagePreferences, in webView: WKWebView, then decide: @escaping () -> Void) {
    guard action.targetFrame?.isMainFrame == true, let url = action.request.url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
      let origin = Origins.of(url)
    else { return decide() }
    WebKitHub.shared.permissions.sitePolicy(profile: profile, origin: origin) { [weak self, weak webView] policy in
      guard let self, let webView, !self.closed, webView === self.webView else { return decide() }
      preferences.allowsContentJavaScript = policy.javascript
      WebKitSiteRules.setAutoplay(policy.autoplay, preferences)
      let page = webView.configuration.preferences
      WebKitSiteRules.setPreference(page, "loadsImagesAutomatically", setter: "_setLoadsImagesAutomatically:", policy.images)
      let pastes = policy.clipboard == "allow"
      WebKitSiteRules.setPreference(page, "javaScriptCanAccessClipboard", setter: "_setJavaScriptCanAccessClipboard:", pastes)
      WebKitSiteRules.setPreference(page, "DOMPasteAllowed", setter: "_setDOMPasteAllowed:", pastes)
      let controller = webView.configuration.userContentController
      WebKitSiteRules.setClipboardGuard(policy.clipboard == "block", in: controller)
      if !policy.isDefault { ArdiaEvents.emit("webKit.counted", data: ArdiaConsentStamp.begin().onto(["name": "siteSettingApplied"])) }
      guard !policy.cookies else {
        WebKitSiteRules.attachCookieBlock(nil, for: webView)
        return decide()
      }
      WebKitSiteRules.cookieList(for: origin) { [weak webView] list in
        if let webView { WebKitSiteRules.attachCookieBlock(list, for: webView) }
        decide()
      }
    }
  }
}
